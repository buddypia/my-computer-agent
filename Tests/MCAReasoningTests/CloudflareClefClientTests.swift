import CoreGraphics
import Foundation
import MCACore
@testable import MCAReasoning
import Testing

/// Records calls; `Sendable` because the client and engine hold their closures across tasks.
private final class Calls<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

private func http(_ status: Int, _ body: String) -> (Data, URLResponse) {
    let url = URL(string: "https://api.cloudflare.com")!
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private let okBody = #"{"result":{"model":"clef","answers":{"q":{"type":"noul","noul":0.9}}},"success":true,"errors":[],"messages":[]}"#

private func request(images: [String]? = nil) -> TypeSafeClient.EvaluationRequest {
    .init(state: .string("s"), questions: ["q": .init(type: "noul", instructions: "?")], images: images)
}

@Suite("Cloudflare Clef client")
struct CloudflareClefClientTests {
    let env = ["CLOUDFLARE_API_TOKEN": "tok", "CLOUDFLARE_ACCOUNT_ID": "acc"]

    @Test("posts to the Workers AI model with the Clef model name and unwraps the result")
    func postsAndUnwraps() async throws {
        let sent = Calls<URLRequest>()
        let client = CloudflareClefClient(model: .clefFlash, credentials: .init(environment: env)) {
            sent.append($0)
            return http(200, okBody)
        }
        let response = try await client.evaluate(request: request(images: ["data:image/jpeg;base64,AAAA"]))
        #expect(response.answers["q"]?.noul == 0.9)

        let r = try #require(sent.all.first)
        #expect(r.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/acc/ai/run/@cf/cloudflare/clef-flash")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "clef-flash")
        #expect(body["images"] as? [String] == ["data:image/jpeg;base64,AAAA"])
    }

    @Test("a request without images does not send the field, so TypeSafe never sees it")
    func omitsImagesWhenAbsent() throws {
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
        #expect(json["images"] == nil)
        #expect(!TypeSafeClient(apiKey: "k").acceptsImages)
        #expect(CloudflareClefClient(credentials: .init(environment: env)).acceptsImages)
    }

    @Test("success:false surfaces the API message instead of an empty answer")
    func apiErrorSurfaces() async {
        let client = CloudflareClefClient(credentials: .init(environment: env)) { _ in
            http(200, #"{"result":null,"success":false,"errors":[{"message":"context window exceeded"}]}"#)
        }
        await #expect(throws: CloudflareClefClient.ClientError.self) { try await client.evaluate(request: request()) }
    }

    @Test("a 401 refreshes the wrangler token once and retries")
    func refreshesOn401() async throws {
        let runs = Calls<[String]>()
        let credentials = CloudflareCredentials(environment: [:]) { args in
            runs.append(args)
            if args.first == "whoami" { return #"{"accounts":[{"id":"acc","name":"me"}]}"# }
            return "⛅️ banner\n{\"type\":\"oauth\",\"token\":\"t\(runs.all.count)\"}"
        }
        let sent = Calls<URLRequest>()
        let client = CloudflareClefClient(credentials: credentials) {
            sent.append($0)
            return sent.all.count == 1 ? http(401, "expired") : http(200, okBody)
        }
        _ = try await client.evaluate(request: request())
        #expect(sent.all.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer t1", "Bearer t3"])
        #expect(runs.all.filter { $0.first == "whoami" }.count == 1)
    }

    @Test("wrangler tokens are cached, and several accounts need CLOUDFLARE_ACCOUNT_ID")
    func cachingAndAmbiguity() async throws {
        let runs = Calls<[String]>()
        let one = CloudflareCredentials(environment: [:]) { args in
            runs.append(args)
            return args.first == "whoami" ? #"{"accounts":[{"id":"a"}]}"# : #"{"token":"t"}"#
        }
        _ = try await one.current()
        _ = try await one.current()
        #expect(runs.all.count == 2)

        let two = CloudflareCredentials(environment: [:]) { args in
            args.first == "whoami" ? #"{"accounts":[{"id":"a"},{"id":"b"}]}"# : #"{"token":"t"}"#
        }
        await #expect(throws: CloudflareCredentials.CredentialError.self) { try await two.current() }

        let pinned = CloudflareCredentials(environment: ["CLOUDFLARE_ACCOUNT_ID": "b"]) { _ in #"{"token":"t"}"# }
        #expect(try await pinned.current() == .init(accountId: "b", token: "t"))
    }

    @Test("a prefetch and a first call share one wrangler run")
    func concurrentCallsShareOneRun() async throws {
        let runs = Calls<[String]>()
        let credentials = CloudflareCredentials(environment: ["CLOUDFLARE_ACCOUNT_ID": "a"]) { args in
            runs.append(args)
            try await Task.sleep(for: .milliseconds(50))
            return #"{"token":"t"}"#
        }
        async let first = credentials.current()
        async let second = credentials.current()
        #expect(try await [first, second].map(\.token) == ["t", "t"])
        #expect(runs.all.count == 1)
    }

    @Test("a failed wrangler lookup backs off instead of running wrangler on every decision")
    func failureBacksOff() async {
        let runs = Calls<[String]>()
        let credentials = CloudflareCredentials(environment: [:]) { args in
            runs.append(args)
            throw CloudflareCredentials.CredentialError.wranglerUnavailable("revoked")
        }
        _ = try? await credentials.current()
        _ = try? await credentials.current()
        _ = try? await credentials.current(forceRefresh: true)
        #expect(runs.all.count == 1)
    }

    @Test("a 403 is not retried: a fresh token would not fix a missing entitlement")
    func forbiddenIsNotRetried() async {
        let sent = Calls<URLRequest>()
        let client = CloudflareClefClient(credentials: .init(environment: env)) {
            sent.append($0)
            return http(403, "forbidden")
        }
        _ = try? await client.evaluate(request: request())
        #expect(sent.all.count == 1)
    }

    @Test("MCA_SYSTEM_ONE forces the backend")
    func backendOverride() {
        #expect((SystemOneBackend.resolve(environment: ["MCA_SYSTEM_ONE": "clef-flash"]) as? CloudflareClefClient)?.model == .clefFlash)
        #expect((SystemOneBackend.resolve(environment: ["MCA_SYSTEM_ONE": "clef"]) as? CloudflareClefClient)?.model == .clef)
        #expect(SystemOneBackend.resolve(environment: ["MCA_SYSTEM_ONE": "offline"]) is SystemOneBackend.Offline)
        #expect(SystemOneBackend.resolve(environment: ["MCA_SYSTEM_ONE": "typesafe"]) is TypeSafeClient)
    }

    @Test("Clef is opt-in: Cloudflare credentials alone never select it")
    func clefIsOptIn() {
        #expect(!(SystemOneBackend.resolve(environment: env) is CloudflareClefClient))
        #expect(!(SystemOneBackend.resolve(environment: [:]) is CloudflareClefClient))
    }
}

@Suite("System One screenshot retry")
struct SystemOneScreenshotTests {
    let button = [UIElementCandidate(id: "btn-ok", role: "AXButton", label: "OK", bounds: CGRect(x: 0, y: 0, width: 80, height: 30))]

    private func answers(action: String, target: String?, confidence: Float, done: Float = 0) -> TypeSafeClient.EvaluationResponse {
        var a: [String: TypeSafeClient.AnswerPayload] = [
            "action_type": .init(type: "choice", choice: action, confidence: confidence),
            "is_completed": .init(type: "noul", noul: done),
        ]
        if let target { a["target_element"] = .init(type: "choice", choice: target, confidence: confidence) }
        return .init(model: "clef", answers: a)
    }

    @Test("a low-confidence text answer is re-asked with the screenshot and the clearer answer wins")
    func retriesWhenUnsure() async throws {
        let seen = Calls<[String]?>()
        let engine = TypeSafeDecisionEngine(
            customEvaluator: { req in
                seen.append(req.images)
                return req.images == nil
                    ? answers(action: "click", target: "btn-ok", confidence: 0.4)
                    : answers(action: "click", target: "btn-ok", confidence: 0.93)
            },
            screenshot: { "data:image/jpeg;base64,AAAA" }
        )
        let decision = try await engine.decideNextAction(goal: "Confirm the dialog", candidates: button)
        #expect(seen.all == [nil, ["data:image/jpeg;base64,AAAA"]])
        #expect(decision.confidence == 0.93)
        #expect(decision.reasoning?.hasSuffix("[screenshot]") == true)
    }

    @Test("a confident text answer never takes a screenshot")
    func skipsWhenSure() async throws {
        let shots = Calls<Int>()
        let engine = TypeSafeDecisionEngine(
            customEvaluator: { _ in answers(action: "click", target: "btn-ok", confidence: 0.95) },
            screenshot: { shots.append(1); return "data:image/jpeg;base64,AAAA" }
        )
        _ = try await engine.decideNextAction(goal: "Click OK", candidates: button)
        #expect(shots.all.isEmpty)
    }

    @Test("a screenshot answer that is no clearer keeps the text decision")
    func keepsTextWhenNoBetter() async throws {
        let engine = TypeSafeDecisionEngine(
            customEvaluator: { req in answers(action: "click", target: "btn-ok", confidence: req.images == nil ? 0.5 : 0.3) },
            screenshot: { "data:image/jpeg;base64,AAAA" }
        )
        let decision = try await engine.decideNextAction(goal: "Confirm", candidates: button)
        #expect(decision.confidence == 0.5)
    }

    @Test("a screenshot answer that would still escalate does not replace the text one")
    func undecisiveScreenshotIsIgnored() async throws {
        let engine = TypeSafeDecisionEngine(
            customEvaluator: { req in
                req.images == nil
                    ? answers(action: "click", target: "btn-ok", confidence: 0.79)
                    : answers(action: "none", target: nil, confidence: 0.9, done: 0.72)
            },
            screenshot: { "data:image/jpeg;base64,AAAA" }
        )
        let decision = try await engine.decideNextAction(goal: "Confirm", candidates: button)
        #expect(decision.action == .click && decision.confidence == 0.79)
    }

    @Test("with no AX candidates, only a completion is taken from the screenshot")
    func emptyCandidatesIgnoreActions() async throws {
        let engine = TypeSafeDecisionEngine(
            customEvaluator: { _ in answers(action: "wait", target: nil, confidence: 0.95) },
            screenshot: { "data:image/jpeg;base64,AAAA" }
        )
        let decision = try await engine.decideNextAction(goal: "Load the page", candidates: [])
        #expect(decision.action == .none && decision.confidence == 0 && !decision.isCompleted)
    }

    @Test("with no AX candidates, the screenshot can still show the goal is done")
    func emptyCandidatesUseScreenshot() async throws {
        let questions = Calls<Set<String>>()
        let engine = TypeSafeDecisionEngine(
            customEvaluator: { req in
                questions.append(Set(req.questions.keys))
                return answers(action: "none", target: nil, confidence: 0.9, done: 0.95)
            },
            screenshot: { "data:image/jpeg;base64,AAAA" }
        )
        let decision = try await engine.decideNextAction(goal: "Open the settings page", candidates: [])
        #expect(decision.isCompleted)
        #expect(questions.all.first.map { !$0.contains("target_element") } == true)
    }

    @Test("without a screenshot, empty candidates escalate exactly as before")
    func emptyCandidatesWithoutScreenshot() async throws {
        let engine = TypeSafeDecisionEngine(customEvaluator: { _ in Issue.record("no model call expected"); throw CancellationError() })
        let decision = try await engine.decideNextAction(goal: "Open the settings page", candidates: [])
        #expect(decision.confidence == 0 && !decision.isCompleted)
    }
}
