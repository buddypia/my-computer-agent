import CoreGraphics
import Foundation
import MCACore
@testable import MCASensing
import Testing

@Suite("PrivacyFilter tests")
struct PrivacyFilterTests {
    @Test("Capture exclusion composes task scope with an explicit permissive callback")
    func scopedCaptureExclusion() {
        let config = AgentConfiguration(excludedWindowPatterns: ["scopefixture-secret"])
        PrivacyFilter.$configuration.withValue(config) {
            #expect(ScreenCapturer.isRefused(bundleID: "com.google.Chrome", windowTitle: "scopefixture-secret", extra: { _, _ in false }))
            #expect(!ScreenCapturer.isRefused(bundleID: "com.google.Chrome", windowTitle: "scopefixture-public", extra: { _, _ in false }))
            #expect(ScreenCapturer.isRefused(bundleID: "com.apple.keychainaccess", windowTitle: "scopefixture-public", extra: { _, _ in false }))
            #expect(ScreenCapturer.isRefused(bundleID: "com.google.Chrome", windowTitle: "scopefixture-public", extra: { _, _ in true }))
        }
    }

    @Test("blocks sensitive credential manager bundle IDs")
    func testBlocksSensitiveApps() {
        let filter = PrivacyFilter()
        #expect(filter.isApplicationBlocked(bundleID: "com.1password.1password"))
        #expect(filter.isApplicationBlocked(bundleID: "com.bitwarden.desktop"))
        #expect(filter.isApplicationBlocked(bundleID: "com.apple.keychainaccess"))
        #expect(filter.isApplicationBlocked(bundleID: "com.apple.passwords"))
        #expect(filter.isApplicationBlocked(bundleID: "com.apple.Passwords"))
        #expect(!filter.isApplicationBlocked(bundleID: "com.apple.Safari"))
        #expect(!filter.isApplicationBlocked(bundleID: "com.google.Chrome"))
    }

    @Test("redacts API keys, tokens, and credit card numbers")
    func testRedactsSensitivePatterns() {
        let filter = PrivacyFilter()
        let textWithKey = "Connecting with api_key=apikey_2116505b0252980f4652bf740b170afb to server"
        let redactedKey = filter.redactSensitiveText(textWithKey)
        #expect(!redactedKey.contains("apikey_2116505b0252980f4652bf740b170afb"))
        #expect(redactedKey.contains("[REDACTED]"))

        // Standalone secret tokens without key= prefix
        let openAIKey = "Found standalone key sk-proj-1234567890abcdef123456 in terminal"
        let redactedOpenAI = filter.redactSensitiveText(openAIKey)
        #expect(!redactedOpenAI.contains("sk-proj-1234567890abcdef123456"))
        #expect(redactedOpenAI.contains("[REDACTED_SECRET]"))

        let githubToken = "Commit hash references ghp_123456789012345678901234567890123456 in branch"
        let redactedGitHub = filter.redactSensitiveText(githubToken)
        #expect(!redactedGitHub.contains("ghp_123456789012345678901234567890123456"))
        #expect(redactedGitHub.contains("[REDACTED_SECRET]"))

        let awsKey = "Using AWS access key AKIAIOSFODNN7EXAMPLE for deployment"
        let redactedAWS = filter.redactSensitiveText(awsKey)
        #expect(!redactedAWS.contains("AKIAIOSFODNN7EXAMPLE"))
        #expect(redactedAWS.contains("[REDACTED_SECRET]"))

        let textWithCC = "Payment card 4111 2222 3333 4444 entered"
        let redactedCC = filter.redactSensitiveText(textWithCC)
        #expect(!redactedCC.contains("4111 2222 3333 4444"))
        #expect(redactedCC.contains("[REDACTED_CC]"))
    }

    @Test("drops AXSecureTextField and redacts candidate values")
    func testSanitizesCandidates() {
        let filter = PrivacyFilter()
        let candidates = [
            UIElementCandidate(
                id: "c1",
                role: "AXButton",
                label: "Submit with bearer token_1234567890abcdef",
                bounds: CGRect(x: 10, y: 10, width: 100, height: 30)
            ),
            UIElementCandidate(
                id: "c2",
                role: "AXSecureTextField",
                label: "Password",
                value: "SuperSecretPassword123",
                bounds: CGRect(x: 10, y: 50, width: 200, height: 30)
            ),
            UIElementCandidate(
                id: "c3",
                role: "AXTextField",
                label: "Username",
                value: "alice",
                bounds: CGRect(x: 10, y: 90, width: 200, height: 30)
            )
        ]

        let sanitized = filter.sanitizeCandidates(candidates)
        #expect(sanitized.count == 2)
        #expect(sanitized.allSatisfy { $0.role != "AXSecureTextField" })
        #expect(sanitized[0].label.contains("[REDACTED]"))
        #expect(sanitized[1].label == "Username")
    }
}
