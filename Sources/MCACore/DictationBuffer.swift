import Foundation

/// Turns a stream of on-device transcript revisions into whole utterances.
///
/// The speech engine emits a running commentary: partial guesses that get
/// revised, and settled ranges that will not change again. Sending each settled
/// range as its own question would ask the model four separate half-sentences
/// for one spoken thought, so something has to decide where the thought ended.
///
/// Silence decides. Not the engine's own endpointing, because that fires between
/// clauses, and not a "stop" button, because the whole point of speaking is not
/// having to reach for the keyboard. Pure and separate from the audio path so
/// the boundary rules — which decide whether a question is sent whole, twice, or
/// not at all — can be tested without a microphone.
public struct DictationBuffer: Sendable, Equatable {
    /// How long the user has to stay quiet before what they said counts as
    /// finished.
    ///
    /// Long enough to survive the pause in "how do I… uh… rename this", short
    /// enough that the answer does not feel withheld. Below about a second this
    /// splits ordinary sentences in half.
    public var silenceTimeout: TimeInterval
    /// Utterances shorter than this are dropped. A cough, a chair, or the tail
    /// of the model's own voice reaching the microphone all transcribe as one
    /// or two characters, and each one would otherwise cost a request.
    public var minimumCharacters: Int
    /// Ceiling on what is held before it is sent.
    ///
    /// Reached only while an answer is still streaming — nothing is taken until
    /// it finishes — so without this, someone who keeps talking through a long
    /// reply grows one unbounded question. The oldest text is dropped rather
    /// than the newest: what was said most recently is what the question is
    /// about.
    public var maximumCharacters: Int
    /// How long after an utterance is taken the engine may still deliver the
    /// same words again.
    ///
    /// Silence is what ends an utterance here, and the engine's own endpointing
    /// is slower than that: a sentence taken on silence is usually still
    /// unsettled, and the settled version of exactly those words lands a second
    /// or two later. Without a window in which that arrival is recognised as a
    /// repeat, it starts a fresh utterance, goes quiet, and is asked a second
    /// time — one spoken question, two questions sent.
    public var redeliveryWindow: TimeInterval

    /// Transcript the engine will not revise again.
    public private(set) var settled: String = ""
    /// The current guess at what is being said right now. Replaced wholesale on
    /// every revision, never appended to.
    public private(set) var pending: String = ""
    /// When the last chunk of either kind arrived. `nil` when nothing is held.
    public private(set) var lastActivity: Date?

    /// Words already taken as an utterance that the engine has not finished
    /// re-delivering. Shrinks to nothing as the repeat arrives.
    private var consumed: String = ""
    private var consumedAt: Date?

    public init(
        silenceTimeout: TimeInterval = 1.4,
        minimumCharacters: Int = 2,
        maximumCharacters: Int = 2000,
        redeliveryWindow: TimeInterval = 5
    ) {
        self.silenceTimeout = silenceTimeout
        self.minimumCharacters = minimumCharacters
        self.maximumCharacters = maximumCharacters
        self.redeliveryWindow = redeliveryWindow
    }

    /// Everything heard so far in this utterance, settled and not. This is what
    /// goes on screen: a caption that only showed settled text would lag the
    /// speaker by a clause and look like it had stopped listening.
    public var displayText: String {
        if pending.isEmpty { return settled }
        if settled.isEmpty { return pending }
        let cleanPending = Self.stripOverlap(settled: settled, from: pending)
        return settled + cleanPending
    }

    public var isEmpty: Bool { settled.isEmpty && pending.isEmpty }

    public mutating func append(_ text: String, isFinal: Bool, now: Date = Date()) {
        guard !text.isEmpty else { return }
        // A repeat of what has already been asked is not new speech, so it must
        // not restart the silence clock either — `lastActivity` stays where it
        // was, and the buffer stays empty.
        guard let text = admitting(text, now: now) else { return }

        if isFinal {
            let delta = Self.stripOverlap(settled: settled, from: text)
            settled += delta
            pending = ""
            if settled.count > maximumCharacters {
                settled.removeFirst(settled.count - maximumCharacters)
            }
        } else {
            pending = Self.stripOverlap(settled: settled, from: text)
        }
        lastActivity = now
    }

    /// Strips any overlapping prefix between settled text and an incoming chunk.
    ///
    /// Speech engines (such as Apple's `SpeechTranscriber`) often emit cumulative
    /// results starting from the beginning of the utterance or clause. If an earlier
    /// chunk was finalized into `settled`, subsequent chunks (whether volatile or final)
    /// still contain the settled words. Appending without stripping the overlap results
    /// in duplicated text (e.g. "こんにちはこんにちは世界").
    public static func stripOverlap(settled: String, from text: String) -> String {
        guard !settled.isEmpty, !text.isEmpty else { return text }

        switch overlap(of: settled, with: text) {
        case .whole(let remainder):
            return remainder
        case .partial:
            return ""
        case .unrelated:
            break
        }

        // Suffix-prefix overlap (longest match from min(sChars.count, tChars.count) down to 2)
        let sChars = Array(settled)
        let tChars = Array(text)
        let maxOverlap = min(sChars.count, tChars.count)

        if maxOverlap >= 2 {
            for len in stride(from: maxOverlap, through: 2, by: -1) {
                let sSuffix = String(sChars[(sChars.count - len)...])
                let tPrefix = String(tChars[..<len])
                if sSuffix.lowercased() == tPrefix.lowercased() ||
                   sSuffix.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) ==
                   tPrefix.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil) {
                    return String(tChars[len...])
                }
            }
        }

        return text
    }

    /// What is genuinely new in a chunk, or `nil` when all of it has been sent
    /// already.
    ///
    /// Whitespace, punctuation, and casing are ignored in the comparison: the
    /// engine does not place spaces, commas, or periods identically between a
    /// volatile guess and the settled version of the same words, and punctuation
    /// or formatting differences are not a reason to ask a question twice.
    private mutating func admitting(_ text: String, now: Date) -> String? {
        guard !consumed.isEmpty else { return text }
        guard let consumedAt, now.timeIntervalSince(consumedAt) < redeliveryWindow else {
            forgetConsumed()
            return text
        }

        let normConsumed = consumed.normalizedForSpeechComparison()
        let normText = text.normalizedForSpeechComparison()

        // Exact match under speech normalization
        if !normConsumed.isEmpty && normConsumed == normText {
            self.consumedAt = now
            return nil
        }

        switch Self.overlap(of: consumed, with: text) {
        case .partial(let stillOwed):
            // Only part of the repeat has arrived. What is left of it is still
            // coming, and the clock runs from this piece rather than from the
            // send, so a long sentence delivered in four chunks does not fall
            // out of the window halfway through.
            consumed = stillOwed
            self.consumedAt = now
            return nil
        case .whole(let remainder):
            let normRemainder = remainder.normalizedForSpeechComparison()
            if normRemainder.isEmpty || normRemainder.count < minimumCharacters {
                forgetConsumed()
                return nil
            }
            forgetConsumed()
            return remainder
        case .unrelated:
            // If the chunk is a substring or substantially equivalent to what was
            // already consumed (e.g. kanji/kana variations or minor engine revisions),
            // it is a late final of the same utterance, not a new question.
            if !normConsumed.isEmpty && (normConsumed.contains(normText) || Self.areSubstantiallyEquivalent(normConsumed, normText)) {
                self.consumedAt = now
                return nil
            }
            // Truly new words. Nothing further can be a repeat of what was sent.
            forgetConsumed()
            return text
        }
    }

    private enum Overlap: Equatable {
        /// The chunk repeats everything already sent; `remainder` is what is new.
        case whole(remainder: String)
        /// The chunk is a leading part of what was already sent; `stillOwed` is
        /// the rest of the repeat, yet to arrive.
        case partial(stillOwed: String)
        case unrelated
    }

    private static func shouldSkipInOverlap(_ c: Character) -> Bool {
        c.isWhitespace || c.isPunctuation || "。、！？・…〜「」『』".contains(c)
    }

    private static func overlap(of consumed: String, with text: String) -> Overlap {
        var consumedIndex = consumed.startIndex
        var textIndex = text.startIndex

        while consumedIndex < consumed.endIndex && textIndex < text.endIndex {
            let c1 = consumed[consumedIndex]
            let c2 = text[textIndex]

            if shouldSkipInOverlap(c1) && shouldSkipInOverlap(c2) {
                consumedIndex = consumed.index(after: consumedIndex)
                textIndex = text.index(after: textIndex)
                continue
            }
            if shouldSkipInOverlap(c1) {
                consumedIndex = consumed.index(after: consumedIndex)
                continue
            }
            if shouldSkipInOverlap(c2) {
                textIndex = text.index(after: textIndex)
                continue
            }

            guard c1.lowercased() == c2.lowercased() else {
                return .unrelated
            }
            consumedIndex = consumed.index(after: consumedIndex)
            textIndex = text.index(after: textIndex)
        }

        while consumedIndex < consumed.endIndex && shouldSkipInOverlap(consumed[consumedIndex]) {
            consumedIndex = consumed.index(after: consumedIndex)
        }

        if consumedIndex == consumed.endIndex {
            return .whole(remainder: String(text[textIndex...]))
        }
        if textIndex == text.endIndex {
            return .partial(stillOwed: String(consumed[consumedIndex...]))
        }
        return .unrelated
    }

    /// Determines if two normalized speech strings are so similar that one is
    /// almost certainly a revision, re-delivery, or alternate transcription of
    /// the other (such as kanji vs kana, or phrasing refinement).
    public static func areSubstantiallyEquivalent(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }

        if a.contains(b) || b.contains(a) {
            let shorter = min(a.count, b.count)
            let longer = max(a.count, b.count)
            if longer - shorter <= 4 || Double(shorter) / Double(longer) >= 0.6 {
                return true
            }
        }

        let lcsLen = longestCommonSubsequenceLength(a, b)
        let maxLen = max(a.count, b.count)
        if maxLen > 0 && Double(lcsLen) / Double(maxLen) >= 0.65 {
            return true
        }

        return false
    }

    /// Computes the length of the Longest Common Subsequence between two strings.
    private static func longestCommonSubsequenceLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        guard !aChars.isEmpty && !bChars.isEmpty else { return 0 }

        var prev = [Int](repeating: 0, count: bChars.count + 1)
        var current = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    current[j] = prev[j - 1] + 1
                } else {
                    current[j] = max(prev[j], current[j - 1])
                }
            }
            prev = current
        }
        return prev[bChars.count]
    }

    private mutating func forgetConsumed() {
        consumed = ""
        consumedAt = nil
    }

    /// The finished utterance, if the user has stopped talking long enough for
    /// there to be one.
    ///
    /// `isBusy` holds everything back while an answer is still arriving. Two
    /// questions in flight at once would interleave their streamed tokens into
    /// one unreadable answer, and the second would be missing the first one's
    /// reply from its context — so the user would be answered as if they had
    /// never asked.
    ///
    /// Pending text is included rather than discarded. The engine does not
    /// always settle the last few words before the room goes quiet, and dropping
    /// them silently truncates the question at exactly the point the user
    /// stopped speaking — which is usually the operative word. Taking unsettled
    /// words is also why what was taken is remembered: the settled version of
    /// the same sentence is still on its way.
    public mutating func takeUtterance(now: Date = Date(), isBusy: Bool = false) -> String? {
        guard !isBusy, let lastActivity else { return nil }
        guard now.timeIntervalSince(lastActivity) >= silenceTimeout else { return nil }

        let utterance = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cleared either way: a fragment too short to send is still a fragment
        // that has been dealt with, and leaving it would glue it to whatever is
        // said next.
        reset()
        // Remembered either way too. A dropped fragment that arrives again would
        // otherwise restart the silence clock and stick itself to the next
        // sentence.
        consumed = utterance
        consumedAt = now
        guard utterance.count >= minimumCharacters else { return nil }
        return utterance
    }

    public mutating func reset() {
        settled = ""
        pending = ""
        lastActivity = nil
        forgetConsumed()
    }
}

extension String {
    /// Strips punctuation, symbols, whitespace, and lowercases for speech comparison.
    public func normalizedForSpeechComparison() -> String {
        let folded = self.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) ||
               CharacterSet.punctuationCharacters.contains(scalar) ||
               CharacterSet.symbols.contains(scalar) ||
               Self.isExtraSpeechPunctuation(scalar) {
                continue
            }
            result.append(String(scalar))
        }
        return result
    }

    private static func isExtraSpeechPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK symbols & punctuation (U+3000..U+303F)
        if (0x3000...0x303F).contains(v) { return true }
        // Fullwidth forms of ASCII punctuation
        if (0xFF01...0xFF0F).contains(v) || (0xFF1A...0xFF20).contains(v) || (0xFF3B...0xFF40).contains(v) || (0xFF5B...0xFF65).contains(v) {
            return true
        }
        return false
    }
}
