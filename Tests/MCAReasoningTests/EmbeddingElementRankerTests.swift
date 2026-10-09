import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [[String]] = []
    private var _criteria: [String: String]?
    var inputs: [[String]] { lock.withLock { _inputs } }
    var criteria: [String: String]? { lock.withLock { _criteria } }
    func record(_ input: [String]) { lock.withLock { _inputs.append(input) } }
    func record(criteria: [String: String]?) { lock.withLock { _criteria = criteria } }
}

/// A fake `/v1/embeddings`: each text maps to a vector by keyword, so similarity is
/// decided by the test, not by a model.
private func fakeServer(_ recorder: Recorder) -> EmbeddingElementRanker.Transport {
    { request in
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let inputs = try #require(json["input"] as? [String])
        recorder.record(inputs)
        let data = inputs.enumerated().map { index, text -> [String: Any] in
            let vector: [Float] = text.contains("保存") || text.contains("Save") ? [1, 0] : [0, 1]
            return ["index": index, "embedding": vector]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: ["data": data]), response)
    }
}

private func element(_ index: Int, _ label: String, role: String = "AXButton") -> UIElementCandidate {
    UIElementCandidate(id: "elem_\(index)", role: role, label: label,
                       bounds: CGRect(x: 10, y: 10 + index * 30, width: 80, height: 24))
}

private let endpoint = URL(string: "http://127.0.0.1:38765/v1/embeddings")!

@Suite("Element ranking with eg2")
struct EmbeddingElementRankerTests {
    @Test("Elements are ordered by meaning, and element vectors are not requested twice")
    func ranksAndCaches() async throws {
        let recorder = Recorder()
        let ranker = EmbeddingElementRanker(endpoint: endpoint, transport: fakeServer(recorder))
        let candidates = [element(0, "閉じる"), element(1, "戻る"), element(2, "保存")]

        let ranked = try #require(await ranker.rank(goal: "ファイルを保存する", candidates: candidates))
        #expect(ranked.first?.id == "elem_2")
        // Ties keep tree order.
        #expect(ranked.map(\.id) == ["elem_2", "elem_0", "elem_1"])

        _ = await ranker.rank(goal: "Save the file", candidates: candidates)
        let documentRequests = recorder.inputs.filter { $0.count > 1 || $0.contains("Button 閉じる") }
        #expect(documentRequests.count == 1, "the second step must reuse the cached element vectors")
    }

    @Test("Coordinates are not part of what is embedded")
    func describesWithoutCoordinates() {
        let text = EmbeddingElementRanker.describe(
            UIElementCandidate(id: "elem_1", role: "AXTextField", label: "検索", value: "天気",
                               bounds: CGRect(x: 120, y: 340, width: 200, height: 24)))
        #expect(text == "TextField 検索 天気")
    }

    @Test("An unreachable server yields no ranking instead of an error")
    func unreachable() async {
        let ranker = EmbeddingElementRanker(endpoint: endpoint) { _ in throw URLError(.cannotConnectToHost) }
        #expect(await ranker.rank(goal: "保存", candidates: [element(0, "保存")]) == nil)
    }

    @Test("Only a loopback eg2 is used: screen labels do not leave the machine")
    func loopbackOnly() {
        #expect(EmbeddingElementRanker.local(environment: ["EG2_URL": "https://example.com"]) == nil)
        #expect(EmbeddingElementRanker.local(environment: ["EG2_URL": "http://127.0.0.1:38765"]) != nil)
        #expect(EmbeddingElementRanker.local(environment: [:]) != nil)
    }

    @Test("EG2_URL says where eg2 is, but does not move System One decisions onto it")
    func eg2URLDoesNotPickBackend() {
        let env = ["EG2_URL": "http://127.0.0.1:38765"]
        #expect(EmbeddingGemmaClient(environment: env).isConfigured == false)
        #expect(!(SystemOneBackend.resolve(environment: env) is EmbeddingGemmaClient))
        #expect(EmbeddingGemmaClient(environment: env).endpoint.absoluteString == "http://127.0.0.1:38765/v1/evaluate")
    }

    @Test("eg2 is found by path, with EG2_BIN first")
    func locatesExecutable() {
        let found = EG2Launcher.locate(environment: ["EG2_BIN": "/custom/eg2", "HOME": "/Users/x"],
                                       isExecutable: { $0 == "/custom/eg2" || $0 == "/Users/x/.local/bin/eg2" })
        #expect(found?.path == "/custom/eg2")
        let fallback = EG2Launcher.locate(environment: ["HOME": "/Users/x"],
                                          isExecutable: { $0 == "/Users/x/.local/bin/eg2" })
        #expect(fallback?.path == "/Users/x/.local/bin/eg2")
        #expect(EG2Launcher.locate(environment: ["HOME": "/Users/x"], isExecutable: { _ in false }) == nil)
    }
}

@Suite("Decision engine with a ranker")
struct RankedDecisionTests {
    /// 40 elements with the one the goal needs at the end, past where tree order cuts.
    /// Labelled "Save" so it is found by meaning, not by the lexical direct match.
    private let candidates = (0..<39).map { element($0, "項目 \($0)") } + [element(39, "Save")]

    private func engine(_ recorder: Recorder, ranker: (any UIElementRanking)?) -> TypeSafeDecisionEngine {
        TypeSafeDecisionEngine(client: SystemOneBackend.Offline(), customEvaluator: { request in
            recorder.record(criteria: request.questions["target_element"]?.criteria)
            return TypeSafeClient.EvaluationResponse(model: "fixture", answers: [
                "target_element": .init(type: "choice", choice: "none", confidence: 0.1),
                "action_type": .init(type: "choice", choice: "none", confidence: 0.1),
                "is_completed": .init(type: "noul", noul: 0),
            ])
        }, elementRanker: ranker)
    }

    @Test("A ranked element deep in the window is offered, and the choices are narrowed")
    func rankedTargetOffered() async throws {
        let recorder = Recorder()
        let ranker = EmbeddingElementRanker(endpoint: endpoint, transport: fakeServer(Recorder()))
        _ = try await engine(recorder, ranker: ranker).decideNextAction(goal: "ファイルを保存する", candidates: candidates)
        let criteria = try #require(recorder.criteria)
        #expect(criteria["elem_39"] != nil)
        #expect(criteria.count == TypeSafeDecisionEngine.rankedCandidateLimit + 1) // + "none"
    }

    @Test("With the server down, the capture's tree order is kept")
    func unrankedKeepsTreeOrder() async throws {
        let recorder = Recorder()
        let ranker = EmbeddingElementRanker(endpoint: endpoint) { _ in throw URLError(.cannotConnectToHost) }
        _ = try await engine(recorder, ranker: ranker).decideNextAction(goal: "ファイルを保存する", candidates: candidates)
        let criteria = try #require(recorder.criteria)
        #expect(criteria["elem_0"] != nil)
        #expect(criteria["elem_39"] == nil)
        #expect(criteria.count == TypeSafeDecisionEngine.rankedCandidateLimit + 1)
    }

    @Test("Without a ranker nothing changes: up to 50 candidates are offered as before")
    func noRankerUnchanged() async throws {
        let recorder = Recorder()
        _ = try await engine(recorder, ranker: nil).decideNextAction(goal: "ファイルを保存する", candidates: candidates)
        #expect(recorder.criteria?.count == candidates.count + 1)
    }
}

