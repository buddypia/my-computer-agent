import CryptoKit
import Foundation
import Testing

@testable import MCAReasoning

/// These touch the real login keychain — there is no in-memory keychain to
/// substitute, and a fake would only test the fake rather than the thing that
/// has to hold the user's API key.
///
/// Isolation therefore comes from the service namespace: each test gets its own,
/// nobody shares state, and nothing here is visible to the router tests running
/// beside it. This is the same trick the hot-key tests use with a private
/// `UserDefaults` suite.
@Suite("Encrypted secret store")
struct SecretStoreTests {
    private let store: SecretStore
    private let accounts = ["gemini", "anthropic"]

    init() {
        store = SecretStore(namespace: "com.buddypia.mca.tests.\(UUID().uuidString)")
    }

    /// Swift Testing makes a fresh instance per test, so this is the per-test
    /// teardown. Leaving items behind would not just be untidy: every run would
    /// add three more orphans to the developer's login keychain, for ever.
    private func tearDown() {
        for account in accounts { store.delete(account: account) }
        store.destroyWrappingKeyForTesting()
    }

    @Test("a stored key comes back exactly")
    func roundTrip() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "AIza-round-trip-🔐")
        #expect(store.read(account: "gemini") == "AIza-round-trip-🔐")
    }

    /// The whole point of the exercise. If this ever passes with the secret
    /// present, the envelope has been bypassed somewhere.
    @Test("the plaintext never reaches the keychain")
    func storedBytesAreCiphertext() throws {
        defer { tearDown() }
        let secret = "sk-ant-super-secret-value"
        try store.write(account: "anthropic", value: secret)

        let record = try #require(store.rawRecordForTesting(account: "anthropic"))
        #expect(record.range(of: Data(secret.utf8)) == nil)
        #expect(record.starts(with: Data("MCA1".utf8)))
    }

    /// HPKE seals with a fresh ephemeral key each time, so identical input must
    /// not produce identical output. Equal records would mean a fixed nonce or a
    /// reused ephemeral — the classic way to break an AEAD.
    @Test("sealing the same value twice produces different records")
    func sealingIsNonDeterministic() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "same-value")
        let first = try #require(store.rawRecordForTesting(account: "gemini"))
        try store.write(account: "gemini", value: "same-value")
        let second = try #require(store.rawRecordForTesting(account: "gemini"))

        #expect(first != second)
        #expect(store.read(account: "gemini") == "same-value")
    }

    /// The provider name is authenticated additional data, so a record cannot be
    /// moved between providers. Without this, swapping two keychain items would
    /// quietly send the Anthropic key to Google.
    @Test("a record moved to another provider will not open")
    func recordsAreBoundToTheirProvider() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "gemini-key")
        let record = try #require(store.rawRecordForTesting(account: "gemini"))

        try store.plantRecordForTesting(account: "anthropic", data: record)
        #expect(store.read(account: "anthropic") == nil)
        // …and the original is untouched, so this is a rejection rather than
        // collateral damage.
        #expect(store.read(account: "gemini") == "gemini-key")
    }

    /// A plaintext item written by an older build has to keep working, and has
    /// to stop being plaintext. Asking the user to re-paste every key on upgrade
    /// would be the more likely outcome of getting this wrong.
    @Test("a legacy plaintext key is returned and re-sealed in place")
    func legacyPlaintextIsMigrated() throws {
        defer { tearDown() }
        try store.writeLegacyPlaintextForTesting(account: "gemini", value: "legacy-key")
        #expect(store.rawRecordForTesting(account: "gemini") == Data("legacy-key".utf8))

        #expect(store.read(account: "gemini") == "legacy-key")

        let migrated = try #require(store.rawRecordForTesting(account: "gemini"))
        #expect(migrated.starts(with: Data("MCA1".utf8)))
        #expect(migrated.range(of: Data("legacy-key".utf8)) == nil)
        #expect(store.read(account: "gemini") == "legacy-key")
    }

    /// Losing the wrapping key — an erased Mac, a reset Secure Enclave — must
    /// read as "no key" rather than crash or return garbage.
    @Test("a record whose wrapping key is gone reads as absent")
    func unopenableRecordReadsAsNil() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "doomed")
        store.destroyWrappingKeyForTesting()
        #expect(store.read(account: "gemini") == nil)
    }

    @Test("deleting removes the record")
    func deletion() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "temporary")
        #expect(store.delete(account: "gemini"))
        #expect(store.read(account: "gemini") == nil)
    }

    /// Not an assertion about the machine — an Intel Mac legitimately has no
    /// Secure Enclave — but the reported protection has to match reality, since
    /// Settings shows it to the user as a security claim.
    @Test("reported protection matches Secure Enclave availability")
    func protectionIsHonest() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "any")
        if SecureEnclave.isAvailable {
            #expect(store.protection() == .secureEnclave)
        } else if case .softwareKey = store.protection() {
        } else {
            Issue.record("claimed Secure Enclave protection on a Mac without one")
        }
    }

    /// `CredentialStore` is the only thing the router talks to, so the seam has
    /// to actually reach the encrypted store rather than a stale copy.
    @Test("the credential store reads through to the encrypted store")
    func credentialStoreReadsThrough() throws {
        defer { tearDown() }
        try store.write(account: "gemini", value: "routed-key")
        let credentials = CredentialStore(environment: [:], secrets: store)

        #expect(credentials.key(for: "gemini") == "routed-key")
        #expect(credentials.source(for: "gemini") == .keychain)
        #expect(credentials.key(for: "anthropic") == nil)
        // The environment still wins — a developer exporting a key for one run
        // must not be silently overridden by something stored months ago.
        let overridden = CredentialStore(
            environment: ["GEMINI_API_KEY": "from-env"], secrets: store)
        #expect(overridden.key(for: "gemini") == "from-env")
    }
}
