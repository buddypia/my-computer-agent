import Foundation
import FoundationModels
@testable import MCAReasoning
import Testing

@Suite("Apple on-device error classification")
struct AppleOnDeviceExecutorTests {
    @Test("A refused language is unsupported input that falls through, not a network error")
    func unsupportedLanguageIsNotNetwork() {
        let refused = AppleOnDeviceExecutor.classify(LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(
            .init(debugDescription: "Unsupported language")))
        guard case MCAReasoning.LanguageModelError.unsupportedInput = refused else {
            Issue.record("expected unsupportedInput, got \(refused)"); return
        }
        #expect(refused.isRetryable)
        #expect(!refused.description.contains("Network"))
    }

    @Test("Other failures keep the transport classification")
    func otherFailuresStayTransport() {
        guard case MCAReasoning.LanguageModelError.transport = AppleOnDeviceExecutor.classify(URLError(.timedOut)) else {
            Issue.record("expected transport"); return
        }
    }
}
