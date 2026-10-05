import CoreGraphics
import MCACore
@testable import MCASensing
@testable import mca
import Testing

@Suite("Copilot screenshot privacy")
@MainActor
struct CopilotScreenshotPrivacyTests {
    private let pinned = PinnedWindow(id: 42, appName: "Browser", windowTitle: "Public page",
                                      bundleID: "test.browser", processID: 123)

    private func frame(title: String, bundleID: String? = "test.browser", pid: pid_t? = 123) throws -> ScreenCapturer.WindowCapture {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return ScreenCapturer.WindowCapture(image: try #require(context.makeImage()), appName: "Browser",
            bundleID: bundleID, windowTitle: title, processID: pid)
    }

    private actor FreshProbe { var count = 0; func record() { count += 1 } }

    @Test("Ordinary pinned Explain validates metadata queried after pixels arrive",
          arguments: ["allowed", "excluded", "missing", "pid", "bundle", "frame", "id", "title"])
    func lateMetadata(_ change: String) async throws {
        var captured = try frame(title: "Public page")
        captured.frame = CGRect(x: 10, y: 20, width: 8, height: 8)
        let before = captured, probe = FreshProbe()
        let config = AgentConfiguration(excludedWindowPatterns: ["password"])
        let fresh = change == "missing" ? nil : PinnedWindow(id: change == "id" ? 43 : 42,
            appName: "Browser", windowTitle: change == "excluded" ? "Password Manager" : (change == "title" ? "Another page" : "Public page"),
            bundleID: change == "bundle" ? "test.other" : "test.browser", processID: change == "pid" ? 456 : 123)
        let bounds = change == "frame" ? CGRect(x: 100, y: 20, width: 8, height: 8) : before.frame
        let copilot = Copilot(configuration: config, capturePinnedSubject: { target in
            try await ScreenCapturer.revalidatedWindowCapture(before, target: target,
                excluding: { config.isExcluded(bundleID: $0, windowTitle: $1) }, freshWindow: {
                    await probe.record()
                    return fresh.map { (window: $0, frame: bounds) }
                })
        })
        let image = await copilot.subjectFrame(for: .pinned(pinned))
        #expect((image != nil) == (change == "allowed"))
        #expect(await probe.count == 1)
    }

    @Test("Explain refuses a pinned window that navigated to an excluded title")
    func freshTitle() async throws {
        let captured = try frame(title: "Password Manager")
        let copilot = Copilot(configuration: AgentConfiguration(excludedWindowPatterns: ["password"]),
            capturePinnedSubject: { _ in captured })
        #expect(await copilot.subjectFrame(for: .pinned(pinned)) == nil)
    }

    @Test("Explain refuses a reused window identity", arguments: [true, false])
    func changedOwner(_ changedPID: Bool) async throws {
        let captured = try frame(title: "Public page", bundleID: changedPID ? "test.browser" : "test.other",
                                 pid: changedPID ? 456 : 123)
        let copilot = Copilot(configuration: AgentConfiguration(), capturePinnedSubject: { _ in captured })
        #expect(await copilot.subjectFrame(for: .pinned(pinned)) == nil)
    }

    @Test("Explain still sends a permitted pinned frame")
    func allowed() async throws {
        let captured = try frame(title: "Another public page")
        let copilot = Copilot(configuration: AgentConfiguration(), capturePinnedSubject: { _ in captured })
        #expect(await copilot.subjectFrame(for: .pinned(pinned)) != nil)
    }
}
