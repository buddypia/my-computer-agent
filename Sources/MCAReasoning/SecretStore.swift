import CryptoKit
import Foundation
import OSLog
import Security

/// Encrypted storage for provider API keys.
///
/// The keychain already encrypts what it holds, so a second layer needs a
/// reason. It has two.
///
/// The first is *what the ciphertext is worth on its own*. A login keychain
/// item is protected by the login password, which means a copied
/// `login.keychain-db` plus a guessed or phished password yields the key. Here
/// the stored bytes are sealed to a P-256 key generated **inside the Secure
/// Enclave**: the private half never exists outside the SEP, is not derived
/// from any password, and cannot be exported. The blob is inert on any other
/// Mac no matter what the attacker knows.
///
/// The second is *blast radius*. A keychain read that succeeds — because the
/// user clicked "Always Allow" once, years ago — hands over the plaintext. Here
/// it hands over a sealed envelope that still has to go back through the SEP,
/// under an access-control policy this process declared.
///
/// ## Why not the data protection keychain
///
/// It is the modern answer and the one Apple points new code at, but
/// `kSecUseDataProtectionKeychain` is entitlement-gated: it needs
/// `com.apple.application-identifier` or `keychain-access-groups`, and those are
/// restricted entitlements that only a provisioning profile can grant. This app
/// is deliberately unsandboxed and profile-less (see `Scripts/bundle.sh`), so
/// `SecItemAdd` returns `-34018 errSecMissingEntitlement` — measured, not
/// assumed. CryptoKit's Secure Enclave keys have no such gate because they are
/// never stored *in* a keychain: `SecureEnclave` hands back an opaque wrapped
/// blob and we persist that ourselves.
///
/// ## The scheme
///
/// HPKE (RFC 9180) in base mode, ciphersuite `P256_SHA256_AES_GCM_256`, which
/// is the shape the Secure Enclave's P-256 key agreement fits. HPKE rather than
/// a hand-rolled ECIES because the ephemeral key, the HKDF derivation and the
/// AEAD nonce are all specified and all handled by CryptoKit — three of the
/// four places a bespoke envelope scheme usually goes wrong.
///
/// The provider name is passed as authenticated additional data, so a stored
/// blob is bound to the provider it was saved under. Moving the Anthropic
/// record into the Gemini slot fails to open rather than silently sending the
/// wrong key to the wrong vendor.
public struct SecretStore: Sendable {
    /// The store the app uses. A value rather than a global so a test can hold
    /// its own — the keychain is process-wide shared state, and a test suite
    /// that reached into the real service would both clobber the developer's
    /// keys and be seen by every other suite running beside it.
    public static let shared = SecretStore()

    /// Prefix for both keychain services.
    let namespace: String

    public init(namespace: String = "com.buddypia.mca") {
        self.namespace = namespace
    }

    private static let log = Logger(subsystem: "com.buddypia.mca", category: "SecretStore")

    /// Bumping this string changes the HPKE `info` binding, which invalidates
    /// every existing record. That is the intended way to force a re-entry of
    /// all keys if the scheme is ever found wanting.
    private static let info = Data("com.buddypia.mca.credential.v1".utf8)
    private static let ciphersuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

    var credentialService: String { "\(namespace).providers" }
    var wrappingService: String { "\(namespace).wrapping-key" }
    private var wrappingAccount: String { "default" }

    // MARK: - API

    /// The decrypted key for `provider`, or `nil` if none is stored.
    ///
    /// A plaintext record written by an older build is returned *and* silently
    /// re-sealed, so upgrading does not ask the user to paste their keys again
    /// and does not leave the plaintext behind.
    public func read(account: String) -> String? {
        guard let record = KeychainItem.read(account: account, service: credentialService)
        else { return nil }

        if let sealed = SealedRecord(record) {
            do {
                let plaintext = try open(sealed, account: account)
                return plaintext.isEmpty ? nil : plaintext
            } catch {
                // A record that will not open is not recoverable: the Secure
                // Enclave key it was sealed to is gone (erased device, new
                // user, reset SEP). Say so rather than reporting "no key",
                // which sends the user hunting for a setting they already set.
                Self.log.error("""
                    Stored key for \(account, privacy: .public) cannot be decrypted \
                    (\(String(describing: error), privacy: .public)). Re-enter it in Settings.
                    """)
                return nil
            }
        }

        // Legacy plaintext from a build before this file existed.
        guard let legacy = String(data: record, encoding: .utf8), !legacy.isEmpty else {
            return nil
        }
        do {
            try write(account: account, value: legacy)
            Self.log.notice("Re-sealed plaintext key for \(account, privacy: .public).")
        } catch {
            Self.log.error("""
                Could not re-seal plaintext key for \(account, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
        return legacy
    }

    /// Seals `value` and stores it.
    ///
    /// Throws rather than returning a `Bool` because every failure here is one
    /// the user has to act on — a silent false is indistinguishable in the UI
    /// from a key that saved fine and then did not work.
    public func write(account: String, value: String) throws {
        let key = try wrappingKey()
        var sender = try HPKE.Sender(
            recipientKey: key.publicKey, ciphersuite: Self.ciphersuite, info: Self.info)
        let ciphertext = try sender.seal(Data(value.utf8), authenticating: Data(account.utf8))
        let record = SealedRecord(
            encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext)
        try KeychainItem.write(
            account: account, data: record.encoded(), service: credentialService)
    }

    @discardableResult
    public func delete(account: String) -> Bool {
        KeychainItem.delete(account: account, service: credentialService)
    }

    /// How the stored keys are protected, for display in Settings.
    ///
    /// Surfaced because the two cases are not equally strong and the user
    /// cannot tell them apart otherwise.
    public enum Protection: Sendable, Equatable {
        /// Sealed to a key that only exists inside the Secure Enclave.
        case secureEnclave
        /// Sealed to a software key held in the login keychain. The envelope
        /// still binds the record to this Mac and this provider, but the
        /// wrapping key is ultimately protected by the login password, so this
        /// is keychain-grade rather than hardware-grade.
        case softwareKey(reason: String)
    }

    public func protection() -> Protection {
        (try? wrappingKey())?.protection ?? .softwareKey(reason: "no wrapping key")
    }

    // MARK: - Wrapping key

    /// Long-lived, per-Mac, one per namespace. Cached because reloading it
    /// costs a keychain round trip plus a SEP import on every single credential
    /// read, and the router reads credentials on a five-second cadence.
    private static let cache = WrappingKeyCache()

    private func wrappingKey() throws -> WrappingKey {
        try Self.cache.key(for: wrappingService) {
            let (stored, status) = KeychainItem.load(
                account: wrappingAccount, service: wrappingService)
            if let stored { return try WrappingKey(stored: stored) }

            // "Absent" and "there but I cannot read it" must not be conflated.
            // The second happens for real — the item was written by a different
            // binary and the user dismissed the access prompt — and treating it
            // as absent would mint a fresh key and orphan every stored
            // credential at once, silently and irreversibly.
            guard status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }

            let key = WrappingKey.generate()
            try KeychainItem.write(
                account: wrappingAccount, data: key.stored, service: wrappingService,
                label: "My Computer Agent — credential wrapping key")
            return key
        }
    }

    private func open(_ record: SealedRecord, account: String) throws -> String {
        let key = try wrappingKey()
        let plaintext = try key.open(
            record.ciphertext,
            encapsulatedKey: record.encapsulatedKey,
            authenticating: Data(account.utf8))
        return String(decoding: plaintext, as: UTF8.self)
    }

    // MARK: - Test seams

    /// The bytes actually sitting in the keychain, so a test can assert the
    /// secret is not among them.
    func rawRecordForTesting(account: String) -> Data? {
        KeychainItem.read(account: account, service: credentialService)
    }

    /// Writes an unsealed value the way builds before this file did, so the
    /// migration path has something to migrate.
    func writeLegacyPlaintextForTesting(account: String, value: String) throws {
        try KeychainItem.write(
            account: account, data: Data(value.utf8), service: credentialService)
    }

    /// Overwrites a record without sealing it, so a test can plant one provider's
    /// ciphertext under another provider's account.
    func plantRecordForTesting(account: String, data: Data) throws {
        try KeychainItem.write(account: account, data: data, service: credentialService)
    }

    /// Throws away this namespace's wrapping key, standing in for an erased
    /// Secure Enclave.
    func destroyWrappingKeyForTesting() {
        KeychainItem.delete(account: wrappingAccount, service: wrappingService)
        Self.cache.forget(wrappingService)
    }
}

/// Namespace-keyed wrapping keys.
///
/// A `final class` with a lock rather than an actor because every caller is
/// synchronous — `CredentialStore.key(for:)` is called from `Sendable` value
/// types and from the router's non-async paths, and making it `async` would
/// ripple through the whole executor chain to save one lock.
private final class WrappingKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: WrappingKey] = [:]

    func key(for service: String, make: () throws -> WrappingKey) throws -> WrappingKey {
        lock.lock()
        defer { lock.unlock() }
        if let existing = keys[service] { return existing }
        let key = try make()
        keys[service] = key
        return key
    }

    func forget(_ service: String) {
        lock.lock()
        keys[service] = nil
        lock.unlock()
    }
}

// MARK: - Wrapping key

/// The recipient key an envelope is sealed to.
///
/// Two cases rather than one because the Secure Enclave is not universally
/// available — an Intel Mac without a T2 has none — and a credential store that
/// refuses to work there is worse than one that degrades and says so.
private enum WrappingKey: Sendable {
    case secureEnclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
    case software(P256.KeyAgreement.PrivateKey, reason: String)

    /// Tagged so a stored blob is never fed to the wrong constructor. The SEP
    /// blob and a raw private key are both opaque bytes; getting this wrong
    /// would mean handing raw key material to `SecureEnclave` and back.
    private static let secureEnclaveTag: UInt8 = 0x01
    private static let softwareTag: UInt8 = 0x02

    static func generate() -> WrappingKey {
        guard SecureEnclave.isAvailable else {
            return .software(P256.KeyAgreement.PrivateKey(), reason: "no Secure Enclave on this Mac")
        }
        do {
            // `.privateKeyUsage` and nothing else: no `.userPresence`. This is a
            // background agent that reasons on a timer, and a Touch ID prompt
            // per model call would make it unusable. `AfterFirstUnlock` for the
            // same reason — the agent must survive the screen locking.
            // `ThisDeviceOnly` because a credential wrapping key has no business
            // in a backup or on another Mac.
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.privateKeyUsage],
                &error)
            else {
                throw error?.takeRetainedValue() ?? CryptoKitError.underlyingCoreCryptoError(error: 0)
            }
            return .secureEnclave(
                try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access))
        } catch {
            return .software(
                P256.KeyAgreement.PrivateKey(),
                reason: "Secure Enclave rejected the key: \(error)")
        }
    }

    init(stored: Data) throws {
        guard let tag = stored.first else { throw SecretStoreError.corruptRecord }
        let body = stored.dropFirst()
        switch tag {
        case Self.secureEnclaveTag:
            self = .secureEnclave(
                try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: body))
        case Self.softwareTag:
            self = .software(
                try P256.KeyAgreement.PrivateKey(rawRepresentation: body),
                reason: "restored from a software wrapping key")
        default:
            throw SecretStoreError.corruptRecord
        }
    }

    var stored: Data {
        switch self {
        case .secureEnclave(let key):
            return Data([Self.secureEnclaveTag]) + key.dataRepresentation
        case .software(let key, _):
            return Data([Self.softwareTag]) + key.rawRepresentation
        }
    }

    var publicKey: P256.KeyAgreement.PublicKey {
        switch self {
        case .secureEnclave(let key): return key.publicKey
        case .software(let key, _): return key.publicKey
        }
    }

    var protection: SecretStore.Protection {
        switch self {
        case .secureEnclave: return .secureEnclave
        case .software(_, let reason): return .softwareKey(reason: reason)
        }
    }

    func open(
        _ ciphertext: Data, encapsulatedKey: Data, authenticating aad: Data
    ) throws -> Data {
        switch self {
        case .secureEnclave(let key):
            return try Self.open(ciphertext, encapsulatedKey: encapsulatedKey, aad: aad, key: key)
        case .software(let key, _):
            return try Self.open(ciphertext, encapsulatedKey: encapsulatedKey, aad: aad, key: key)
        }
    }

    private static func open<Key: HPKEDiffieHellmanPrivateKey>(
        _ ciphertext: Data, encapsulatedKey: Data, aad: Data, key: Key
    ) throws -> Data {
        var recipient = try HPKE.Recipient(
            privateKey: key,
            ciphersuite: SecretStore.hpkeCiphersuite,
            info: SecretStore.hpkeInfo,
            encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext, authenticating: aad)
    }
}

extension SecretStore {
    fileprivate static var hpkeInfo: Data { info }
    fileprivate static var hpkeCiphersuite: HPKE.Ciphersuite { ciphersuite }
}

// MARK: - Record format

/// `"MCA1" | UInt16 big-endian encapsulated-key length | encapsulated key | ciphertext`
///
/// The magic prefix is what distinguishes a sealed record from a plaintext key
/// written by an older build, which is how the migration in `read` can be
/// automatic. It is four bytes that no API key starts with.
private struct SealedRecord {
    static let magic = Data("MCA1".utf8)

    var encapsulatedKey: Data
    var ciphertext: Data

    init(encapsulatedKey: Data, ciphertext: Data) {
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }

    init?(_ data: Data) {
        let bytes = Array(data)
        guard bytes.count >= Self.magic.count + 2,
              bytes.starts(with: Self.magic)
        else { return nil }

        let lengthOffset = Self.magic.count
        let length = Int(bytes[lengthOffset]) << 8 | Int(bytes[lengthOffset + 1])
        let keyStart = lengthOffset + 2
        guard length > 0, keyStart + length <= bytes.count else { return nil }

        encapsulatedKey = Data(bytes[keyStart..<(keyStart + length)])
        ciphertext = Data(bytes[(keyStart + length)...])
    }

    func encoded() -> Data {
        var data = Self.magic
        let length = UInt16(encapsulatedKey.count)
        data.append(UInt8(truncatingIfNeeded: length >> 8))
        data.append(UInt8(truncatingIfNeeded: length))
        data.append(encapsulatedKey)
        data.append(ciphertext)
        return data
    }
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case corruptRecord

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .corruptRecord:
            return "The stored record is not in a format this build understands."
        }
    }
}

// MARK: - Raw keychain access

/// Untyped generic-password items. Private on purpose: everything outside this
/// file goes through `SecretStore`, so there is no call site that *can* write a
/// key without sealing it first.
private enum KeychainItem {
    static func read(account: String, service: String) -> Data? {
        load(account: account, service: service).data
    }

    /// The status is returned alongside the data because callers have to tell
    /// "no such item" apart from "exists, but this process may not read it".
    static func load(account: String, service: String) -> (data: Data?, status: OSStatus) {
        var query = base(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            return (nil, status)
        }
        return (data, status)
    }

    static func write(
        account: String,
        data: Data,
        service: String,
        label: String = "My Computer Agent — API key"
    ) throws {
        // Update in place when the item exists. Deleting and re-adding would
        // discard the item's ACL, and the ACL is what stops macOS prompting the
        // user again the next time this app reads its own key back.
        let query = base(account: account, service: service)
        let update: [String: Any] = [
            kSecValueData as String: data,
            // `ThisDeviceOnly` keeps the record out of iCloud Keychain and out
            // of a restored backup: a wrapping key that cannot leave this Mac
            // makes a synced ciphertext worthless anyway, so syncing it would
            // only widen the attack surface for nothing.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.keychain(updateStatus)
        }

        var attributes = query
        attributes.merge(update) { _, new in new }
        attributes[kSecAttrLabel as String] = label
        attributes[kSecAttrDescription as String] = "Encrypted API key (HPKE / Secure Enclave)"
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
    }

    @discardableResult
    static func delete(account: String, service: String) -> Bool {
        let query = base(account: account, service: service)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func base(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit rather than defaulted: an item that syncs is a copy of
            // the record on every Mac signed into the account.
            kSecAttrSynchronizable as String: false,
        ]
    }
}
