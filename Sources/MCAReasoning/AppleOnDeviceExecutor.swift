import Foundation
import FoundationModels
import MCACore

/// Apple's on-device foundation model, behind the same interface as the cloud
/// providers.
///
/// This is the executor that makes 24/7 operation affordable. Routing every
/// background scan to a cloud model costs roughly $390/month at a five-second
/// cadence; running a local gate first and escalating only what clears it cuts
/// that by roughly fifty times. It is also the only executor that keeps the
/// user's screen contents entirely on the machine.
///
/// Apple is explicit that this model is wrong for code generation, arithmetic
/// and factual recall, so it is used for exactly one thing here: the
/// classification decision "does this deserve the user's attention?".
public struct AppleOnDeviceExecutor: LanguageModelExecuting {
    public let identifier = "apple/system"
    public let capabilities: ModelCapabilities = [
        .toolCalling, .guidedGeneration, .streaming, .onDevice,
    ]

    public init() {}

    /// Why the on-device model cannot run, if it cannot. Callers use this to
    /// decide whether to fall back rather than to fail.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off in System Settings"
            case .modelNotReady:
                return "The on-device model is still downloading"
            @unknown default:
                return "The on-device model is unavailable"
            }
        @unknown default:
            return "The on-device model is unavailable"
        }
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    /// Deep link to the System Settings pane where Apple Intelligence lives.
    /// Verified against the Sidebar plists inside System Settings.app.
    public static let systemSettingsURL = "x-apple.systempreferences:com.apple.Siri-Settings"

    /// Whether opening System Settings can change the answer. A switch that is
    /// merely off — or a model that is still downloading — is fixable by the
    /// user; an ineligible device is not, so offering the button there would
    /// be a button that does nothing.
    public static var canBeEnabledInSettings: Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return false
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled, .modelNotReady:
                return true
            case .deviceNotEligible:
                return false
            @unknown default:
                return false
            }
        @unknown default:
            return false
        }
    }

    public func respond(
        to request: GenerationRequest,
        streamingInto channel: GenerationChannel
    ) async throws {
        if let reason = Self.unavailableReason {
            throw LanguageModelError.transport(reason)
        }

        // Flatten the transcript. The on-device session keeps its own history,
        // but this executor is stateless by design — every call is a fresh
        // decision, which is what a triage gate wants.
        var instructions: [String] = []
        var conversation: [String] = []

        for entry in request.transcript {
            switch entry {
            case .instructions(let text):
                instructions.append(text)
            case .prompt(let prompt):
                // Images are dropped: the on-device text model has no vision
                // path, and silently sending nothing is better than failing —
                // but the caller should route `.vision` elsewhere.
                conversation.append(prompt.text)
            case .response(let text):
                conversation.append("Assistant: \(text)")
            case .toolOutput(let output):
                conversation.append("Tool \(output.name) returned: \(output.content)")
            case .toolCalls, .reasoning:
                continue
            }
        }

        let session = LanguageModelSession(
            instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"))

        var options = FoundationModels.GenerationOptions()
        if let temperature = request.options.temperature {
            options = FoundationModels.GenerationOptions(temperature: temperature)
        }

        channel.send(.metadata([
            "provider": "apple",
            "modelID": "system-language-model",
            "requestID": request.id.uuidString,
        ]))

        let prompt = conversation.joined(separator: "\n\n")

        do {
            // Snapshots are cumulative, so deltas are produced by diffing
            // against what has already been sent downstream.
            var emitted = ""
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                try Task.checkCancellation()
                let content = snapshot.content
                guard content.count > emitted.count else { continue }
                let delta = String(content.dropFirst(emitted.count))
                emitted = content
                channel.send(.text(delta))
            }
            // The framework does not expose token counts for on-device runs;
            // reporting zeros is honest — these tokens genuinely cost nothing.
            channel.send(.usage(TokenUsage()))
            channel.send(.finished(.stop))
        } catch is CancellationError {
            channel.send(.finished(.cancelled))
            throw LanguageModelError.cancelled
        } catch {
            channel.send(.finished(.error))
            throw LanguageModelError.transport(error.localizedDescription)
        }
    }
}
