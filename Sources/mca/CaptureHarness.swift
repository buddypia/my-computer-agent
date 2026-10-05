import AppKit
import Foundation
import MCACore
import MCAPerception
import MCASensing

/// Stage-3 acceptance harness: one screen capture cycle, printed.
///
/// Separates "the agent said nothing" from "the agent saw nothing", which are
/// very different bugs and indistinguishable from the outside.
enum CaptureHarness {
    static func run(waitSeconds: Double) async {
        print("Accessibility trusted: \(AccessibilityReader.isTrusted ? "yes" : "NO")")
        print("Screen Recording:      \(await ScreenCapturer.hasPermission() ? "yes" : "NO")")

        if waitSeconds > 0 {
            print("\nSwitch to the window you want to capture. Sampling in \(Int(waitSeconds))s…")
            try? await Task.sleep(for: .seconds(waitSeconds))
        }
        print("")

        guard let app = NSWorkspace.shared.frontmostApplication else {
            print("No frontmost application.")
            return
        }
        print("Frontmost: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "no bundle id"))")

        let reader = AccessibilityReader()
        guard let snapshot = reader.readFocusedWindow() else {
            print("readFocusedWindow returned nil — no focused window exposed.")
            return
        }

        print("Window:    \(snapshot.windowTitle.isEmpty ? "(untitled)" : snapshot.windowTitle)")
        print("AX elements visited: \(snapshot.elementCount)")
        print("AX text length:      \(snapshot.text.count)")

        let configuration = (try? AgentConfiguration.load()) ?? AgentConfiguration()
        if configuration.isExcluded(
            bundleID: snapshot.bundleID, windowTitle: snapshot.windowTitle) {
            print("\nEXCLUDED by the privacy filter — nothing would be stored.")
            return
        }

        if !snapshot.text.isEmpty {
            print("\n--- accessibility text (first 600 chars) ---")
            print(String(snapshot.text.prefix(600)))
        }

        // Mirrors the threshold the real capture path uses, so this harness
        // agrees with production about what counts as "nothing to store".
        if snapshot.text.count < 40 {
            print("\nAX text is thin (<40 chars); production would fall back to OCR.")
            guard await ScreenCapturer.hasPermission() else {
                print("No Screen Recording permission, so OCR is unavailable.")
                return
            }
            do {
                let image = try await ScreenCapturer()
                    .captureFocusedWindow(pid: app.processIdentifier)
                let text = try await TextRecognizer().recognizeText(in: image)
                print("\n--- OCR text (first 600 chars) ---")
                print(String(text.prefix(600)))
            } catch {
                print("OCR failed: \(error)")
            }
        }

        if snapshot.text.count < 20 {
            print("\nBelow the 20-character floor — production would store nothing.")
        }
    }
}
