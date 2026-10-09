import CoreGraphics
import Foundation
import MCACore
import MCASensing

/// Picks the model behind System One for the app and CLI.
///
/// `MCA_SYSTEM_ONE` picks one (`typesafe`, `clef`, `clef-flash`, `local` / `gemma` / `embeddinggemma`, `offline`). Otherwise a
/// TypeSafe key wins, then the offline heuristics. Clef is opt-in only: it sends the
/// request and on-screen labels (and sometimes a screenshot) to Cloudflare, which a
/// cf auth login alone does not mean the user agreed to. Library defaults stay on
/// `TypeSafeClient()` so tests never reach the network by accident.
public enum SystemOneBackend {
    /// Shared so every engine reuses one element-vector cache. `MCA_ELEMENT_RANKING=off` disables it.
    static let elementRanker: EmbeddingElementRanker? =
        ProcessInfo.processInfo.environment["MCA_ELEMENT_RANKING"]?.lowercased() == "off"
            ? nil : EmbeddingElementRanker.local()

    /// How many elements an autonomous step captures. Wider with a ranker, which
    /// narrows them back to `TypeSafeDecisionEngine.rankedCandidateLimit` by meaning,
    /// so an element deep in a large window is no longer cut by tree order alone.
    public static var loopCandidateLimit: Int { elementRanker == nil ? 25 : 80 }

    public static func resolve(
        model: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any TypeSafeEvaluating {
        let gemmaModel = model ?? environment["MCA_EMBEDDING_GEMMA_MODEL"]
        switch environment["MCA_SYSTEM_ONE"]?.lowercased() {
        case "typesafe": return TypeSafeClient()
        case "clef": return CloudflareClefClient(model: .clef)
        case "clef-flash": return CloudflareClefClient(model: .clefFlash)
        case "embeddinggemma", "embeddinggemma2", "gemma", "local":
            return EmbeddingGemmaClient(model: gemmaModel, environment: environment)
        case "offline": return Offline()
        default:
            let localGemma = EmbeddingGemmaClient(model: gemmaModel, environment: environment)
            if localGemma.isConfigured { return localGemma }
            let typeSafe = TypeSafeClient()
            return typeSafe.hasKey ? typeSafe : Offline()
        }
    }

    /// The selected window, or the display for an unscoped caller, as a JPEG small enough for Clef.
    /// Its token estimate scales
    /// with the base64 size; 1024px overflows the 65k window, 768px does not.
    /// `nil` without Screen Recording permission; the caller then escalates as before.
    public static let screenshot: TypeSafeDecisionEngine.Screenshot = makeScreenshot()

    static func makeScreenshot(
        hasPermission: @escaping @Sendable () async -> Bool = { await ScreenCapturer.hasPermission() },
        captureWindow: @escaping @Sendable (PinnedWindow) async throws -> ScreenCapturer.WindowCapture = {
            try await ScreenCapturer(scale: 0.5).captureWindow($0)
        },
        captureDisplay: @escaping @Sendable () async throws -> CGImage = {
            try await ScreenCapturer(scale: 0.5).captureDisplay()
        },
        freshWindow: @escaping @Sendable (PinnedWindow) async throws -> PinnedWindow? = { selected in
            try await ScreenCapturer().availableWindows().first { $0.id == selected.id }
        }
    ) -> TypeSafeDecisionEngine.Screenshot {
        {
            do {
                try Task.checkCancellation()
                let session = ActionAuthorization.current
                if let session, await session.terminalFailure != nil { return nil }
                // An unknown scoped target is not permission to read the display.
                if session?.requiresWindowScope == true && session?.targetWindow == nil { return nil }
                if let selected = session?.targetWindow, selected.processID == nil { return nil }
                guard await hasPermission() else { return nil }
                try Task.checkCancellation()
                let image: CGImage
                if let selected = session?.targetWindow {
                    let captured = try await captureWindow(selected)
                    guard captured.processID == selected.processID,
                          captured.bundleID == selected.bundleID,
                          !PrivacyFilter.configuration.isExcluded(bundleID: captured.bundleID,
                              windowTitle: captured.windowTitle) else { return nil }
                    try Task.checkCancellation()
                    // The capture carries pre-await metadata. Re-read the same window
                    // after capture so navigation into an excluded title cannot reuse it.
                    guard let fresh = try await freshWindow(selected), fresh.id == selected.id,
                          fresh.processID == selected.processID, fresh.bundleID == selected.bundleID,
                          !PrivacyFilter.configuration.isExcluded(bundleID: fresh.bundleID,
                              windowTitle: fresh.windowTitle) else { return nil }
                    image = captured.image
                } else {
                    image = try await captureDisplay()
                }
                try Task.checkCancellation()
                if let session, await session.terminalFailure != nil { return nil }
                guard let jpeg = ImageEncoder.jpeg(image, maximumDimension: 768, quality: 0.6) else { return nil }
                try Task.checkCancellation()
                return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            } catch {
                // Lost, excluded or cancelled windows cannot fall back to another target.
                return nil
            }
        }
    }

    /// No model: every call fails fast into the engine's deterministic fallback.
    public struct Offline: TypeSafeEvaluating {
        public struct Unavailable: Error {}
        public init() {}
        public func evaluate(request: TypeSafeClient.EvaluationRequest) async throws -> TypeSafeClient.EvaluationResponse {
            throw Unavailable()
        }
    }
}

extension TypeSafeDecisionEngine {
    /// The engine the app and CLI use: resolved backend, plus a screenshot when the model can read one.
    /// The engine for the app and CLI. Elements are ranked by the local `eg2` server
    /// whichever backend decides: ranking is on the machine and only reorders, so it
    /// is not an opt-in the way a decision backend is.
    public static func live(confidenceThreshold: Float = 0.80, model: String? = nil) -> TypeSafeDecisionEngine {
        let client = SystemOneBackend.resolve(model: model)
        if client is CloudflareClefClient { CloudflareCredentials.shared.prefetch() }
        return TypeSafeDecisionEngine(
            client: client,
            confidenceThreshold: confidenceThreshold,
            screenshot: client.acceptsImages ? SystemOneBackend.screenshot : nil,
            elementRanker: SystemOneBackend.elementRanker
        )
    }
}
