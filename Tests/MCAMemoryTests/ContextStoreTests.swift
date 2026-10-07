import Foundation
import MCACore
import Testing

@testable import MCAMemory

/// Runs against a real SQLite file, not a mock.
///
/// The previous implementation's tests injected fake records into an in-memory
/// list owned by the very object under test, then asserted the fake came back.
/// These exercise the actual schema, the actual FTS5 triggers and the actual
/// fusion, because that is where the bugs are.
@Suite("SQLiteContextStore", .serialized)
struct ContextStoreTests {
    /// A throwaway database per test.
    static func makeStore(embedder: (any TextEmbedding)? = nil) throws -> (SQLiteContextStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mca-test-\(UUID().uuidString).sqlite3")
        return (try SQLiteContextStore(url: url, embedder: embedder), url)
    }

    static func cleanUp(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    @Test("this SQLite build has FTS5")
    func fts5Available() {
        // If this fails, hybrid search silently degrades, so it is checked
        // explicitly rather than discovered at query time.
        #expect(SQLiteDatabase.hasFTS5())
    }

    @Test("stores and reads back a screen observation")
    func screenRoundTrip() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            appName: "Xcode",
            windowTitle: "Copilot.swift",
            text: "func startAudioSensing() async {",
            source: .accessibility,
            trigger: .focusChanged)))

        let recent = try await store.recent(seconds: 60, limit: 10)
        #expect(recent.count == 1)

        guard case .screen(let screen) = recent[0] else {
            Issue.record("expected a screen observation")
            return
        }
        #expect(screen.appName == "Xcode")
        #expect(screen.windowTitle == "Copilot.swift")
        #expect(screen.source == .accessibility)
        #expect(screen.trigger == .focusChanged)
    }

    @Test("stores and reads back an audio observation with its channel")
    func audioRoundTrip() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.audio(AudioObservation(
            channel: .systemAudio,
            speakerID: "participant-2",
            text: "Let's ship the API spec on Friday.")))

        let recent = try await store.recent(seconds: 60, limit: 10)
        guard case .audio(let audio) = recent.first else {
            Issue.record("expected an audio observation")
            return
        }
        // Channel is the speaker separation, so losing it in storage would
        // conflate the user with the people they are talking to.
        #expect(audio.channel == .systemAudio)
        #expect(audio.speakerID == "participant-2")
    }

    @Test("full-text search finds exact identifiers")
    func lexicalSearch() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            appName: "Terminal", windowTitle: "zsh",
            text: "error: cannot find 'kAXSecureTextFieldRole' in scope",
            source: .accessibility)))
        try await store.append(.screen(ScreenObservation(
            appName: "Safari", windowTitle: "News",
            text: "completely unrelated content about gardening",
            source: .ocr)))

        let results = try await store.search(ContextQuery(text: "kAXSecureTextFieldRole"))
        #expect(results.count == 1)
        guard case .screen(let screen) = results.first?.observation else {
            Issue.record("expected a match")
            return
        }
        #expect(screen.appName == "Terminal")
    }

    @Test("search survives FTS5 syntax in user input")
    func escapesQuerySyntax() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            appName: "Terminal", windowTitle: "zsh",
            text: "deployment failed", source: .accessibility)))

        // Unescaped, each of these is either an FTS5 operator or a syntax
        // error, and would throw instead of returning results.
        for query in ["deploy*", "\"unbalanced", "NEAR(a b)", "a OR b", "-negated"] {
            _ = try await store.search(ContextQuery(text: query))
        }
    }

    @Test("finds Japanese text")
    func unicodeSearch() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            appName: "Finder", windowTitle: "書類",
            text: "書類 サイドバー 最近の項目 共有フォルダ", source: .accessibility)))

        // The unicode61 tokenizer has to handle CJK for this to work at all.
        let results = try await store.search(ContextQuery(text: "サイドバー"))
        #expect(results.count == 1)
    }

    @Test("time filters bound the result set")
    func timeFiltering() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            timestamp: Date().addingTimeInterval(-7200),
            appName: "Slack", windowTitle: "#general",
            text: "ancient message about deployment", source: .accessibility)))
        try await store.append(.screen(ScreenObservation(
            appName: "Slack", windowTitle: "#general",
            text: "recent message about deployment", source: .accessibility)))

        let recentOnly = try await store.search(ContextQuery(
            text: "deployment", since: Date().addingTimeInterval(-600)))
        #expect(recentOnly.count == 1)

        let everything = try await store.search(ContextQuery(text: "deployment"))
        #expect(everything.count == 2)
    }

    @Test("app filter restricts to one application")
    func appFiltering() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            appName: "Xcode", windowTitle: "a.swift",
            text: "shared keyword here", source: .accessibility)))
        try await store.append(.screen(ScreenObservation(
            appName: "Slack", windowTitle: "#eng",
            text: "shared keyword here too", source: .accessibility)))

        let results = try await store.search(ContextQuery(text: "shared", appName: "Xcode"))
        #expect(results.count == 1)
    }

    @Test("semantic ranker contributes results lexical search cannot find")
    func hybridSearchFusesBothRankers() async throws {
        // A deterministic embedder, so this tests the fusion mechanism rather
        // than the quality of whichever model happens to be installed.
        let (store, url) = try Self.makeStore(
            embedder: KeywordEmbedding(axes: ["schedule", "food"]))
        defer { Self.cleanUp(url) }

        try await store.append(.audio(AudioObservation(
            channel: .systemAudio,
            text: "We agreed to release the new build on Friday. schedule")))
        try await store.append(.audio(AudioObservation(
            channel: .systemAudio,
            text: "The cafeteria menu changed this week. food")))

        let results = try await store.search(ContextQuery(text: "schedule"))
        #expect(!results.isEmpty)

        guard case .audio(let audio) = results.first?.observation else {
            Issue.record("expected an audio match")
            return
        }
        #expect(audio.text.contains("Friday"))
    }

    @Test("NLEmbedding is not fit for this corpus")
    func documentsWhyNLEmbeddingIsNotDefault() async throws {
        let embedder = NLTextEmbedding()
        try #require(embedder.isAvailable, "no sentence embedding model on this machine")

        let query = try #require(await embedder.embed("when are we shipping"))
        let relevant = try #require(
            await embedder.embed("We agreed to release the new build on Friday afternoon."))
        let irrelevant = try #require(
            await embedder.embed("The cafeteria menu changed this week."))

        let relevantScore = VectorMath.cosineSimilarity(query, relevant)
        let irrelevantScore = VectorMath.cosineSimilarity(query, irrelevant)

        // Asserting the *defect*: the built-in sentence embedding ranks the
        // unrelated sentence higher. This is why the composition root leaves
        // the embedder unset and uses on-device query expansion instead. If a
        // future OS fixes this, the test fails and the decision gets revisited.
        #expect(
            irrelevantScore > relevantScore,
            """
            NLEmbedding now ranks correctly (relevant \(relevantScore) > \
            irrelevant \(irrelevantScore)). Reconsider enabling it as the \
            semantic ranker.
            """)
    }

    @Test("empty text yields a plain reverse-chronological listing")
    func filterOnlyQuery() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        for index in 0..<5 {
            try await store.append(.screen(ScreenObservation(
                timestamp: Date().addingTimeInterval(Double(-index)),
                appName: "App\(index)", windowTitle: "w",
                text: "entry number \(index)", source: .accessibility)))
        }

        let results = try await store.search(ContextQuery(limit: 3))
        #expect(results.count == 3)
        guard case .screen(let newest) = results.first?.observation else {
            Issue.record("expected a screen result")
            return
        }
        #expect(newest.appName == "App0")
    }

    @Test("empty text is never stored")
    func rejectsEmptyText() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            appName: "Finder", windowTitle: "Desktop", text: "", source: .accessibility)))
        try await store.append(.audio(AudioObservation(channel: .microphone, text: "")))

        #expect(try await store.count() == 0)
    }

    @Test("purge removes expired rows and keeps the FTS index consistent")
    func purge() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            timestamp: Date().addingTimeInterval(-40 * 86_400),
            appName: "Old", windowTitle: "w",
            text: "expired observation about penguins", source: .accessibility)))
        try await store.append(.screen(ScreenObservation(
            appName: "New", windowTitle: "w",
            text: "fresh observation about penguins", source: .accessibility)))

        let removed = try await store.purge(olderThan: 30)
        #expect(removed == 1)
        #expect(try await store.count() == 1)

        // If the delete trigger did not fire, the dropped row would still be
        // searchable and the join would then produce a phantom result.
        let results = try await store.search(ContextQuery(text: "penguins"))
        #expect(results.count == 1)
    }

    @Test("re-appending the same observation is idempotent")
    func idempotentAppend() async throws {
        let (store, url) = try Self.makeStore()
        defer { Self.cleanUp(url) }

        let observation = DesktopObservation.screen(ScreenObservation(
            appName: "Xcode", windowTitle: "x.swift",
            text: "duplicate content", source: .accessibility))

        try await store.append(observation)
        try await store.append(observation)

        #expect(try await store.count() == 1)
    }

    @Test("semantic retrieval filters by embedder model to prevent cross-model latent pollution")
    func semanticRetrievalFiltersByModel() async throws {
        struct MockModelEmbedding: TextEmbedding {
            let modelIdentifier: String?
            var dimension: Int { 2 }
            func embed(_ text: String) async -> [Float]? {
                return [1.0, 0.0]
            }
        }

        let (store, url) = try Self.makeStore(embedder: MockModelEmbedding(modelIdentifier: "google/embeddinggemma-2-740m"))
        defer { Self.cleanUp(url) }

        try await store.append(.screen(ScreenObservation(
            appName: "TestApp", windowTitle: "Title",
            text: "Important observation content", source: .accessibility)))

        // Query with matching model finds the observation
        let match = try await store.search(ContextQuery(text: "Important observation content"))
        #expect(!match.isEmpty)

        // Switch embedder to a different model
        await store.setEmbedder(MockModelEmbedding(modelIdentifier: "google/embeddinggemma-2-270m"))

        // Search with non-matching lexical query to ensure it cannot match across model boundaries
        let crossModelSearch = try await store.search(ContextQuery(text: "CompletelyUnrelatedLexicalKeywordXYZ"))
        #expect(crossModelSearch.isEmpty)
    }
}

@Suite("Vector math")
struct VectorMathTests {
    @Test("normalisation produces unit length")
    func normalization() {
        let normalized = VectorMath.normalized([3, 4])
        #expect(abs(normalized[0] - 0.6) < 0.0001)
        #expect(abs(normalized[1] - 0.8) < 0.0001)
    }

    @Test("normalising a zero vector does not divide by zero")
    func zeroVector() {
        #expect(VectorMath.normalized([0, 0, 0]) == [0, 0, 0])
    }

    @Test("cosine similarity behaves at the extremes")
    func cosineExtremes() {
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [1, 0]) - 1) < 0.0001)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [0, 1])) < 0.0001)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [-1, 0]) + 1) < 0.0001)
    }

    @Test("mismatched or empty vectors score zero rather than crashing")
    func mismatchedDimensions() {
        #expect(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
        #expect(VectorMath.cosineSimilarity([], []) == 0)
    }
}

/// Deterministic embedder for testing fusion: one axis per keyword, set to 1
/// when the text contains it. Makes similarity exactly predictable.
struct KeywordEmbedding: TextEmbedding {
    let axes: [String]
    var dimension: Int { axes.count }

    func embed(_ text: String) async -> [Float]? {
        let lower = text.lowercased()
        let vector = axes.map { lower.contains($0) ? Float(1) : Float(0) }
        guard vector.contains(1) else { return nil }
        return VectorMath.normalized(vector)
    }
}
