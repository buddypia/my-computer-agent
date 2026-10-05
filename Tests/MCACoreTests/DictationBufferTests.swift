import Foundation
import Testing

@testable import MCACore

/// Where a spoken question begins and ends is decided here, and getting it
/// wrong is not a subtle failure: too eager and one sentence is asked as three
/// half-questions, too slow and the user is left talking to something that
/// never answers.
@Suite("Dictation buffer")
struct DictationBufferTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func buffer(silence: TimeInterval = 1.4) -> DictationBuffer {
        DictationBuffer(silenceTimeout: silence)
    }

    @Test("nothing is sent while the user is still talking")
    func holdsWhileSpeaking() {
        var buffer = buffer()
        buffer.append("how do I ", isFinal: true, now: start)
        buffer.append("rename this file", isFinal: false, now: start.addingTimeInterval(0.5))

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.0)) == nil)
    }

    @Test("silence ends the utterance")
    func silenceSends() {
        var buffer = buffer()
        buffer.append("how do I rename this file", isFinal: true, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.5))
            == "how do I rename this file")
    }

    /// The engine does not always settle the last words before the room goes
    /// quiet. Dropping them truncates the question at exactly the point the
    /// user stopped speaking — which is usually the operative word.
    @Test("words the engine never settled are still sent")
    func unsettledTailIsIncluded() {
        var buffer = buffer()
        buffer.append("what does this ", isFinal: true, now: start)
        buffer.append("error mean", isFinal: false, now: start.addingTimeInterval(0.2))

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(2))
            == "what does this error mean")
    }

    /// Partials are revisions of the same words, not new ones. Appending them
    /// would repeat every word each time the engine changed its mind.
    @Test("a revised guess replaces the previous one")
    func partialsReplaceRatherThanAccumulate() {
        var buffer = buffer()
        buffer.append("open the", isFinal: false, now: start)
        buffer.append("open the file", isFinal: false, now: start.addingTimeInterval(0.3))

        #expect(buffer.displayText == "open the file")
    }

    @Test("settled text accumulates across chunks")
    func finalChunksAccumulate() {
        var buffer = buffer()
        buffer.append("first ", isFinal: true, now: start)
        buffer.append("second", isFinal: true, now: start.addingTimeInterval(0.4))

        #expect(buffer.displayText == "first second")
    }

    /// Two questions in flight would interleave their streamed tokens into one
    /// unreadable answer, and the second would be missing the first one's reply
    /// from its context.
    @Test("nothing is sent while an answer is still arriving")
    func busyHoldsEverythingBack() {
        var buffer = buffer()
        buffer.append("and what about the second one", isFinal: true, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(5), isBusy: true) == nil)
        // Still there once the answer lands, rather than lost to the wait.
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(6), isBusy: false)
            == "and what about the second one")
    }

    /// A cough, a chair, or the model's own voice reaching the microphone all
    /// transcribe as a character or two, and each one would otherwise cost a
    /// request and an interruption.
    @Test("a fragment too short to be a question is dropped")
    func dropsFragments() {
        var buffer = DictationBuffer(silenceTimeout: 1, minimumCharacters: 3)
        buffer.append("あ", isFinal: true, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(2)) == nil)
        // And it is cleared rather than left to glue itself to what is said
        // next.
        #expect(buffer.isEmpty)
    }

    @Test("an utterance is not sent twice")
    func takingClearsTheBuffer() {
        var buffer = buffer(silence: 1)
        buffer.append("summarise this page", isFinal: true, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(2)) != nil)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(3)) == nil)
        #expect(buffer.isEmpty)
    }

    /// The reported bug: say one sentence, get asked twice. Silence ends the
    /// utterance before the engine has settled it, so the settled copy of the
    /// same words lands a second later — and read as new speech it goes quiet
    /// and is sent again.
    @Test("the engine settling what was already sent does not send it again")
    func lateFinalIsNotASecondQuestion() {
        var buffer = buffer(silence: 1)
        buffer.append("なんで2回入力されるんだ", isFinal: false, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2))
            == "なんで2回入力されるんだ")

        // The same words, now settled, arriving after the question went out.
        buffer.append("なんで2回入力されるんだ", isFinal: true, now: start.addingTimeInterval(1.6))

        #expect(buffer.isEmpty)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(5)) == nil)
    }

    @Test("the engine settling with added punctuation does not send it again")
    func lateFinalWithPunctuationIsNotASecondQuestion() {
        var buffer = buffer(silence: 1)
        buffer.append("テストを実行して", isFinal: false, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2))
            == "テストを実行して")

        buffer.append("テストを実行して。", isFinal: true, now: start.addingTimeInterval(1.6))

        #expect(buffer.isEmpty)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(5)) == nil)
    }

    @Test("the engine settling with commas and question marks does not send it again")
    func lateFinalWithCommaIsNotASecondQuestion() {
        var buffer = buffer(silence: 1)
        buffer.append("こんにちは元気ですか", isFinal: false, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2))
            == "こんにちは元気ですか")

        buffer.append("こんにちは、元気ですか？", isFinal: true, now: start.addingTimeInterval(1.6))

        #expect(buffer.isEmpty)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(5)) == nil)
    }

    @Test("the engine settling with casing and punctuation changes does not send it again")
    func lateFinalWithCasingIsNotASecondQuestion() {
        var buffer = buffer(silence: 1)
        buffer.append("how do i fix this", isFinal: false, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2))
            == "how do i fix this")

        buffer.append("How do I fix this?", isFinal: true, now: start.addingTimeInterval(1.6))

        #expect(buffer.isEmpty)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(5)) == nil)
    }

    @Test("the engine settling with kanji or number variation does not send it again")
    func lateFinalWithKanjiVariationIsNotASecondQuestion() {
        var buffer = buffer(silence: 1)
        buffer.append("なんで二回入力されるんだ", isFinal: false, now: start)

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2))
            == "なんで二回入力されるんだ")

        buffer.append("なんで2回入力されるんだ", isFinal: true, now: start.addingTimeInterval(1.6))

        #expect(buffer.isEmpty)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(5)) == nil)
    }

    /// The repeat does not always arrive whole. Each piece has to be recognised
    /// as one, or the tail of a sentence is asked as a question of its own.
    @Test("a repeat delivered in pieces is dropped piece by piece")
    func piecewiseRedeliveryIsDropped() {
        var buffer = buffer(silence: 1)
        buffer.append("open the file and rename it", isFinal: false, now: start)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2)) != nil)

        buffer.append("open the file", isFinal: true, now: start.addingTimeInterval(1.4))
        buffer.append(" and rename it", isFinal: true, now: start.addingTimeInterval(1.6))

        #expect(buffer.isEmpty)
    }

    /// Only the repeat is dropped. Words spoken on top of it are the next
    /// question and must survive.
    @Test("speech that continues past the repeat is kept")
    func newWordsAfterARepeatSurvive() {
        var buffer = buffer(silence: 1)
        buffer.append("what is this", isFinal: false, now: start)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2)) == "what is this")

        buffer.append("what is this error", isFinal: true, now: start.addingTimeInterval(1.5))

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(3)) == "error")
    }

    /// Whitespace moves around between a volatile guess and the settled version
    /// of the same words, and a space is not a reason to ask twice.
    @Test("a repeat spaced differently is still a repeat")
    func spacingDoesNotDefeatTheCheck() {
        var buffer = buffer(silence: 1)
        buffer.append("rename this file", isFinal: false, now: start)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2)) != nil)

        buffer.append(" rename  this file ", isFinal: true, now: start.addingTimeInterval(1.4))

        #expect(buffer.isEmpty)
    }

    /// Suppression is a window around one utterance, not a permanent rule.
    /// Someone who genuinely repeats themselves a minute later is asking again.
    @Test("the same sentence said again later is a new question")
    func repeatsOutsideTheWindowAreNew() {
        var buffer = DictationBuffer(silenceTimeout: 1, redeliveryWindow: 5)
        buffer.append("say that again", isFinal: true, now: start)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2)) != nil)

        buffer.append("say that again", isFinal: true, now: start.addingTimeInterval(30))

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(32)) == "say that again")
    }

    /// A different sentence inside the window is ordinary speech, not a repeat.
    @Test("unrelated words inside the window are untouched")
    func unrelatedSpeechIsNotSuppressed() {
        var buffer = buffer(silence: 1)
        buffer.append("first question", isFinal: false, now: start)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(1.2)) != nil)

        buffer.append("second question", isFinal: true, now: start.addingTimeInterval(1.4))

        #expect(buffer.displayText == "second question")
    }

    @Test("an empty buffer never produces an utterance")
    func emptyStaysEmpty() {
        var buffer = buffer()
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(60)) == nil)
    }

    /// Reached only while an answer is streaming, since nothing is taken until
    /// it finishes. Without the ceiling, someone who keeps talking through a
    /// long reply grows one unbounded question.
    @Test("held text is capped, dropping the oldest")
    func capsWhatIsHeld() {
        var buffer = DictationBuffer(silenceTimeout: 1, maximumCharacters: 10)
        buffer.append("0123456789", isFinal: true, now: start)
        buffer.append("abcde", isFinal: true, now: start.addingTimeInterval(0.5))

        #expect(buffer.settled == "56789abcde")
    }

    /// Silence is measured from the last thing heard, not from the first: a
    /// pause mid-sentence must not end the question, and a long dictation must
    /// not be cut off just because it started a while ago.
    @Test("the timeout runs from the most recent words")
    func timeoutIsRelativeToTheLastChunk() {
        var buffer = buffer(silence: 1.4)
        buffer.append("first part", isFinal: true, now: start)
        buffer.append(" and the rest", isFinal: true, now: start.addingTimeInterval(1.2))

        #expect(buffer.takeUtterance(now: start.addingTimeInterval(2.0)) == nil)
        #expect(buffer.takeUtterance(now: start.addingTimeInterval(2.7))
            == "first part and the rest")
    }

    /// Speech engines emitting cumulative transcription chunks repeat earlier
    /// settled text in subsequent partial chunks. Appending without stripping
    /// the overlap would duplicate the displayed words.
    @Test("cumulative partial chunk overlapping settled text does not duplicate")
    func cumulativePartialOverlappingSettledDoesNotDuplicate() {
        var buffer = buffer()
        buffer.append("日本語で聞き取ります。", isFinal: true, now: start)
        buffer.append("日本語で聞き取ります。質問を声に出して話してください。", isFinal: false, now: start.addingTimeInterval(0.5))

        #expect(buffer.settled == "日本語で聞き取ります。")
        #expect(buffer.pending == "質問を声に出して話してください。")
        #expect(buffer.displayText == "日本語で聞き取ります。質問を声に出して話してください。")
    }

    /// Cumulative final chunks from speech recogniser repeating earlier settled text
    /// must accumulate only the delta.
    @Test("cumulative final chunk overlapping settled text accumulates only the delta")
    func cumulativeFinalChunkOverlappingSettledAccumulatesOnlyDelta() {
        var buffer = buffer()
        buffer.append("日本語で聞き取ります。", isFinal: true, now: start)
        buffer.append("日本語で聞き取ります。質問を声に出して話してください。", isFinal: true, now: start.addingTimeInterval(0.5))

        #expect(buffer.settled == "日本語で聞き取ります。質問を声に出して話してください。")
        #expect(buffer.pending == "")
        #expect(buffer.displayText == "日本語で聞き取ります。質問を声に出して話してください。")
    }

    /// Suffix-prefix overlap strip correctly deduplicates words across boundary revisions.
    @Test("stripOverlap handles suffix-prefix overlaps and exact matches")
    func stripOverlapCases() {
        #expect(DictationBuffer.stripOverlap(settled: "こんにちは", from: "こんにちは世界") == "世界")
        #expect(DictationBuffer.stripOverlap(settled: "こんにちは、", from: "こんにちは、世界") == "世界")
        #expect(DictationBuffer.stripOverlap(settled: "こんにちは", from: "こんにちは") == "")
        #expect(DictationBuffer.stripOverlap(settled: "Hello world", from: "world, how are you?") == ", how are you?")
    }
}
