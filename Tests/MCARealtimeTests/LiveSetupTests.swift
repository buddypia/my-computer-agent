import Foundation
import Testing

@testable import MCARealtime

/// The setup frame is the whole negotiation with the Live API, and the server's
/// answer to a wrong one is a WebSocket close code — no error message, nothing
/// logged, just a voice button that switches itself back off. These assertions
/// are the only place that frame is checked before it reaches Google.
@Suite("Gemini Live setup frame")
struct LiveSetupTests {
    private func setup(webSearchEnabled: Bool = true) -> [String: Any] {
        let payload = GeminiLiveSession.setupPayload(
            model: "gemini-3.1-flash-live-preview",
            systemInstruction: "be brief",
            webSearchEnabled: webSearchEnabled)
        return payload["setup"] as? [String: Any] ?? [:]
    }

    @Test("the model is sent fully qualified")
    func modelIsQualified() {
        #expect(setup()["model"] as? String == "models/gemini-3.1-flash-live-preview")
    }

    /// Both transcriptions are what the caption and the stored conversation are
    /// made of. Drop either and the session works while appearing to hear
    /// nothing, which is the failure this app keeps having to fix.
    @Test("both sides of the conversation are transcribed")
    func transcriptionIsRequested() {
        let setup = setup()
        #expect(setup["inputAudioTranscription"] != nil)
        #expect(setup["outputAudioTranscription"] != nil)
    }

    @Test("audio is the response modality")
    func audioIsRequested() {
        let config = setup()["generationConfig"] as? [String: Any]
        #expect(config?["responseModalities"] as? [String] == ["AUDIO"])
    }

    /// The search tool has to arrive as `googleSearch` with an object value.
    /// A bare string, or the snake-cased name, is refused during setup.
    @Test("web search is offered as a server-side tool")
    func searchToolIsDeclared() {
        let tools = setup()["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        #expect(tools?.first?["googleSearch"] as? [String: Any] != nil)
    }

    /// Absent rather than present-and-empty: an empty tool list is a different
    /// request, and one the API is entitled to reject.
    @Test("no tool block at all when search is off")
    func searchCanBeSwitchedOff() {
        #expect(setup(webSearchEnabled: false)["tools"] == nil)
    }

    @Test("the system instruction is carried as a text part")
    func systemInstructionIsCarried() {
        let instruction = setup()["systemInstruction"] as? [String: Any]
        let parts = instruction?["parts"] as? [[String: String]]
        #expect(parts?.first?["text"] == "be brief")
    }

    // MARK: - Grounding

    /// Where the search queries live is not documented as stable, and they are
    /// the only account the user gets of where a spoken answer came from.
    @Test("search queries are read from the server content")
    func readsQueriesFromServerContent() {
        let queries = GeminiLiveSession.searchQueries(in: [
            "groundingMetadata": ["webSearchQueries": ["swift 6.2 release date"]]
        ])
        #expect(queries == ["swift 6.2 release date"])
    }

    @Test("search queries are also read from the model turn")
    func readsQueriesFromModelTurn() {
        let queries = GeminiLiveSession.searchQueries(in: [
            "modelTurn": ["groundingMetadata": ["webSearchQueries": ["mac mini m5"]]]
        ])
        #expect(queries == ["mac mini m5"])
    }

    /// The common case by far: most frames carry no grounding at all, and an
    /// answer from memory must not be reported as one that was looked up.
    @Test("a frame with no grounding reports no search")
    func noGroundingMeansNoSearch() {
        #expect(GeminiLiveSession.searchQueries(in: ["turnComplete": true]).isEmpty)
        #expect(GeminiLiveSession.searchQueries(in: [
            "groundingMetadata": ["webSearchQueries": [String]()]
        ]).isEmpty)
    }
}
