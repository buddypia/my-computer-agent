import Foundation
import Testing

@testable import MCAReasoning

/// Where the TypeSafe key comes from. Uses a private keychain namespace per test, as
/// `SecretStoreTests` does, so a developer's real key is neither read nor touched.
@Suite("TypeSafe key source")
struct TypeSafeKeySourceTests {
    private let store = SecretStore(namespace: "com.buddypia.mca.tests.\(UUID().uuidString)")

    private func tearDown() {
        store.delete(account: "typesafe")
        store.delete(account: "gemini")
        store.destroyWrappingKeyForTesting()
    }

    @Test("the sealed key wins over a plaintext TYPESAFE_API_KEY")
    func sealedKeyWins() throws {
        defer { tearDown() }
        try store.write(account: "typesafe", value: "sealed")
        let credentials = CredentialStore(environment: ["TYPESAFE_API_KEY": "plain"], secrets: store)
        #expect(credentials.key(for: "typesafe") == "sealed")
        #expect(credentials.source(for: "typesafe") == .keychain)
        #expect(SystemOneBackend.typeSafeKey(secrets: store, environment: ["TYPESAFE_API_KEY": "plain"]) == "sealed")
    }

    @Test("a sealed key alone selects TypeSafe")
    func sealedKeyAloneSelectsTypeSafe() throws {
        defer { tearDown() }
        try store.write(account: "typesafe", value: "sealed")
        #expect(SystemOneBackend.typeSafeKey(secrets: store, environment: [:]) == "sealed")
        #expect(SystemOneBackend.resolve(environment: [:], secrets: store) is TypeSafeClient)
    }

    @Test("TYPESAFE_API_KEY is the fallback when nothing is sealed")
    func environmentFallback() {
        defer { tearDown() }
        let credentials = CredentialStore(environment: ["TYPESAFE_API_KEY": "plain"], secrets: store)
        #expect(credentials.key(for: "typesafe") == "plain")
        #expect(credentials.source(for: "typesafe") == .environment(variable: "TYPESAFE_API_KEY"))
        #expect(SystemOneBackend.resolve(environment: ["TYPESAFE_API_KEY": "plain"], secrets: store) is TypeSafeClient)
        #expect(SystemOneBackend.resolve(environment: [:], secrets: store) is SystemOneBackend.Offline)
    }

    @Test("other providers keep the environment first")
    func otherProvidersUnchanged() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "sealed")
        let credentials = CredentialStore(environment: ["GEMINI_API_KEY": "plain"], secrets: store)
        #expect(credentials.key(for: "gemini") == "plain")
    }
}
