import Foundation
import Testing

@testable import MCAReasoning

@Suite("TypeSafe client credentials")
struct TypeSafeClientCredentialTests {
    /// The machine's key (exported or stored) is not the library default's to take: tests
    /// built on `TypeSafeDecisionEngine()` called the live API once a key was installed.
    @Test("A default client is keyless whatever the machine has")
    func defaultClientIsKeyless() {
        #expect(!TypeSafeClient().hasKey)
    }

    @Test("configured() takes the key from the credential store")
    func configuredUsesCredentials() throws {
        let secrets = SecretStore(namespace: "com.buddypia.mca.tests.\(UUID().uuidString)")
        defer { secrets.delete(account: "typesafe") }

        #expect(!TypeSafeClient.configured(credentials: CredentialStore(environment: [:], secrets: secrets)).hasKey)
        #expect(TypeSafeClient.configured(
            credentials: CredentialStore(environment: ["TYPESAFE_API_KEY": "from-env"], secrets: secrets)).hasKey)

        try secrets.write(account: "typesafe", value: "sealed")
        #expect(TypeSafeClient.configured(credentials: CredentialStore(environment: [:], secrets: secrets)).hasKey)
    }

    @Test("The backend reads the key from the environment it is given")
    func backendUsesGivenEnvironment() {
        let client = SystemOneBackend.resolve(environment: ["MCA_SYSTEM_ONE": "typesafe", "TYPESAFE_API_KEY": "k"])
        #expect((client as? TypeSafeClient)?.hasKey == true)
    }
}
