import CoreGraphics
import Foundation
import MCACore
@testable import MCASensing
@testable import MCAReasoning
import Testing

private enum ScreenshotScopeCase: CaseIterable, Sendable {
    case pinned, missingTarget, missingOwner, excludedTitle, changedOwner, captureFailure, cancelledCapture, unscoped
    case freshExcludedTitle, freshMissing, freshWrongID, freshChangedPID, freshChangedBundle
    var sendsImage: Bool { self == .pinned || self == .unscoped }
}

private final class ScreenshotScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func record(_ call: String) { lock.lock(); defer { lock.unlock() }; calls.append(call) }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

private actor ScreenshotScopeEvaluator {
    private var images: [[String]] = []
    func evaluate(_ request: TypeSafeClient.EvaluationRequest) -> TypeSafeClient.EvaluationResponse {
        images.append(request.images ?? [])
        let completed = !(request.images ?? []).isEmpty
        return TypeSafeClient.EvaluationResponse(model: "screenshot-fixture", answers: [
            "target_element": .init(type: "choice", choice: "none", confidence: completed ? 0.95 : 0.1),
            "action_type": .init(type: "choice", choice: "none", confidence: completed ? 0.95 : 0.1),
            "is_completed": .init(type: "noul", noul: completed ? 1 : 0)
        ])
    }
    var requests: [[String]] { images }
}

@Suite("System One screenshot target scope")
struct SystemOneScreenshotScopeTests {
    private func image(red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    @Test("Public fallback refuses display pixels if exclusions change after capture",
          arguments: ["allowed", "newExclusion", "removedExclusion", "lostDisplay"])
    func displayPrivacyChanged(_ change: String) async throws {
        let image = try image(red: 0, blue: 1), recorder = ScreenshotScopeRecorder(), evaluator = ScreenshotScopeEvaluator()
        let screenshot = SystemOneBackend.makeScreenshot(hasPermission: { true }, captureDisplay: {
            try await ScreenCapturer.revalidatedDisplayImage(image, excluded: [2], freshExcluded: {
                recorder.record("fresh")
                if change == "lostDisplay" { throw ScreenCapturer.CaptureError.displayGone }
                return change == "newExclusion" ? [2, 3] : (change == "removedExclusion" ? [] : [2])
            })
        })
        let engine = TypeSafeDecisionEngine(client: SystemOneBackend.Offline(),
            customEvaluator: { await evaluator.evaluate($0) }, screenshot: screenshot)
        let decision = try await engine.decideNextAction(goal: "Verify observed content", candidates: [
            UIElementCandidate(id: "fixture", role: "AXButton", label: "Fixture", bounds: CGRect(x: 10, y: 20, width: 30, height: 40))
        ])
        let requests = await evaluator.requests
        #expect(decision.isCompleted == (change == "allowed"))
        #expect(requests.count == (change == "allowed" ? 2 : 1))
        #expect(requests.first == [])
        #expect(recorder.recorded == ["fresh"])
        if change == "allowed" {
            let jpeg = try #require(ImageEncoder.jpeg(image, maximumDimension: 768, quality: 0.6))
            #expect(requests.last == ["data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
        } else { #expect(requests.allSatisfy { $0.isEmpty }) }
    }

    @Test("Public decision fallback sends only permitted task pixels", arguments: ScreenshotScopeCase.allCases)
    fileprivate func fallbackScope(_ scenario: ScreenshotScopeCase) async throws {
        struct CaptureFailure: Error {}
        let windowImage = try image(red: 1, blue: 0)
        let displayImage = try image(red: 0, blue: 1)
        let recorder = ScreenshotScopeRecorder()
        let evaluator = ScreenshotScopeEvaluator()
        let screenshot = SystemOneBackend.makeScreenshot(
            hasPermission: { recorder.record("permission"); return true },
            captureWindow: { target in
                recorder.record("window:\(target.id)")
                if scenario == .captureFailure { throw CaptureFailure() }
                if scenario == .cancelledCapture { withUnsafeCurrentTask { $0?.cancel() } }
                return ScreenCapturer.WindowCapture(image: windowImage, appName: "Fixture",
                    bundleID: scenario == .changedOwner ? "fixture.other" : "fixture.browser",
                    windowTitle: scenario == .excludedTitle ? "Password Manager" : "Public content",
                    processID: scenario == .changedOwner ? 456 : 123)
            },
            captureDisplay: { recorder.record("display"); return displayImage },
            freshWindow: { target in
                recorder.record("fresh:\(target.id)")
                if scenario == .freshMissing { return nil }
                return PinnedWindow(id: scenario == .freshWrongID ? 43 : 42, appName: "Fixture",
                    windowTitle: scenario == .freshExcludedTitle ? "Password Manager" : "Public content",
                    bundleID: scenario == .freshChangedBundle ? "fixture.other" : "fixture.browser",
                    processID: scenario == .freshChangedPID ? 456 : 123)
            })
        let engine = TypeSafeDecisionEngine(client: SystemOneBackend.Offline(),
            customEvaluator: { await evaluator.evaluate($0) }, screenshot: screenshot)
        let selected = PinnedWindow(id: 42, appName: "Fixture", windowTitle: "Public content",
            bundleID: "fixture.browser", processID: scenario == .missingOwner ? nil : 123)
        let session = ActionAuthorization(goal: "Inspect selected fixture", requestApproval: { _ in .rejected },
            targetWindow: scenario == .missingTarget || scenario == .unscoped ? nil : selected,
            requiresWindowScope: scenario != .unscoped,
            privacyConfiguration: AgentConfiguration(excludedWindowPatterns: ["password"]))
        // A child task isolates the deliberately cancelled capture from the test runner.
        let task = Task {
            await ActionAuthorization.withSession(session) {
                try? await engine.decideNextAction(goal: "Verify observed content", candidates: [
                    UIElementCandidate(id: "fixture", role: "AXButton", label: "Fixture",
                        bounds: CGRect(x: 10, y: 20, width: 30, height: 40))
                ])
            }
        }
        let decision = try #require(await task.value)
        let requests = await evaluator.requests
        #expect(decision.isCompleted == scenario.sendsImage)
        #expect(requests.count == (scenario.sendsImage ? 2 : 1))
        #expect(requests.first == [])
        switch scenario {
        case .missingTarget, .missingOwner:
            #expect(recorder.recorded == [])
        case .unscoped:
            #expect(recorder.recorded == ["permission", "display"])
        case .pinned, .freshExcludedTitle, .freshMissing, .freshWrongID, .freshChangedPID, .freshChangedBundle:
            #expect(recorder.recorded == ["permission", "window:42", "fresh:42"])
        default:
            #expect(recorder.recorded == ["permission", "window:42"])
        }
        if scenario.sendsImage {
            let expected = try #require(ImageEncoder.jpeg(scenario == .pinned ? windowImage : displayImage,
                maximumDimension: 768, quality: 0.6))
            #expect(requests.last == ["data:image/jpeg;base64,\(expected.base64EncodedString())"])
        } else {
            #expect(requests.allSatisfy { $0.isEmpty }, "Denied or cancelled scope must never reach model images")
        }
        #expect(ActionAuthorization.current == nil)
    }
}
