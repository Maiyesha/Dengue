import Foundation
import CryptoKit
import Security
import DengueCaptureCore

/// Per-artefact AES-256 keys wrapped by a P-256 key-agreement key.
///
/// - Device: the wrapping key is created inside the Secure Enclave (non-exportable).
/// - Simulator / no Secure Enclave: a software P-256 key (stored in the Keychain) is used. `usesSecureEnclave`
///   reports which path is active; this fallback must never ship as the production path on hardware.
///
/// Wrapping: ECDH(ephemeral software key, wrapping public key) -> HKDF-SHA256 (info = key id) -> AES-GCM(key).
/// Only `ephemeralPublic(65) || AES-GCM combined` is stored (Keychain, AfterFirstUnlockThisDeviceOnly, so
/// background uploads can unseal after the first unlock). `destroy` deletes that item: crypto-shredding.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
public final class SecureEnclaveKeyStore: KeyStore {
    public enum StoreError: Error { case keychain(OSStatus), corrupt, secureEnclaveUnavailable }

    public let usesSecureEnclave: Bool
    private let service: String
    private let wrappingTag: String
    private let softwareForced: Bool
    private let lock = NSLock()

    #if DEBUG
    /// Debug builds only: use the software fallback even where a Secure Enclave exists.
    public init(service: String = "ai.reainmaker.denguecapture.artefact-keys", forceSoftware: Bool = false) {
        self.service = service
        self.wrappingTag = service + ".wrapping"
        self.softwareForced = forceSoftware
        self.usesSecureEnclave = SecureEnclave.isAvailable && !forceSoftware
    }
    #else
    public init(service: String = "ai.reainmaker.denguecapture.artefact-keys") {
        self.service = service
        self.wrappingTag = service + ".wrapping"
        self.softwareForced = false
        self.usesSecureEnclave = SecureEnclave.isAvailable
    }
    #endif

    /// On device builds a missing Secure Enclave is an error, never a silent software fallback.
    private func requireSecureEnclaveOnDevice() throws {
        #if !targetEnvironment(simulator)
        if !usesSecureEnclave && !softwareForced { throw StoreError.secureEnclaveUnavailable }
        #endif
    }

    public func newKey() throws -> (id: String, key: SymmetricKey) {
        lock.lock(); defer { lock.unlock() }
        try requireSecureEnclaveOnDevice()
        let id = UUID().uuidString
        let key = SymmetricKey(size: .bits256)
        let blob = try wrap(key, id: id)
        try keychainStore(account: id, data: blob)
        return (id, key)
    }

    public func key(id: String) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        try requireSecureEnclaveOnDevice()
        guard let blob = try keychainLoad(account: id) else { throw SealerError.keyUnavailable }
        return try unwrap(blob, id: id)
    }

    public func destroy(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(account: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }

    // MARK: Wrapping

    private func wrap(_ key: SymmetricKey, id: String) throws -> Data {
        let wrappingPublic = try loadOrCreateWrappingKey().publicKey   // only newKey creates
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: wrappingPublic)
        let kek = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
                                                 sharedInfo: Data(id.utf8), outputByteCount: 32)
        let raw = key.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(raw, using: kek, authenticating: Data(id.utf8))
        guard let combined = box.combined else { throw StoreError.corrupt }
        return ephemeral.publicKey.x963Representation + combined
    }

    private func unwrap(_ blob: Data, id: String) throws -> SymmetricKey {
        guard blob.count > 65 else { throw StoreError.corrupt }
        let ephPub = try P256.KeyAgreement.PublicKey(x963Representation: blob.prefix(65))
        let combined = blob.dropFirst(65)
        // key(id:) never creates a wrapping key: a missing one means the stored key is unrecoverable.
        guard let wrapping = try loadWrappingKey() else { throw SealerError.keyUnavailable }
        let shared = try wrapping.sharedSecretFromKeyAgreement(with: ephPub)
        let kek = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
                                                 sharedInfo: Data(id.utf8), outputByteCount: 32)
        let raw = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: kek,
                                   authenticating: Data(id.utf8))
        return SymmetricKey(data: raw)
    }

    /// Type-erased private key agreement (Secure Enclave or software).
    private protocol Agreeing {
        var publicKey: P256.KeyAgreement.PublicKey { get }
        func sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey) throws -> SharedSecret
    }
    private struct SEKey: Agreeing {
        let k: SecureEnclave.P256.KeyAgreement.PrivateKey
        var publicKey: P256.KeyAgreement.PublicKey { k.publicKey }
        func sharedSecretFromKeyAgreement(with p: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
            try k.sharedSecretFromKeyAgreement(with: p)
        }
    }
    private struct SWKey: Agreeing {
        let k: P256.KeyAgreement.PrivateKey
        var publicKey: P256.KeyAgreement.PublicKey { k.publicKey }
        func sharedSecretFromKeyAgreement(with p: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
            try k.sharedSecretFromKeyAgreement(with: p)
        }
    }

    private func loadWrappingKey() throws -> Agreeing? {
        guard let data = try keychainLoad(account: wrappingTag) else { return nil }
        return usesSecureEnclave
            ? SEKey(k: try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data))
            : SWKey(k: try P256.KeyAgreement.PrivateKey(rawRepresentation: data))
    }

    /// Called from newKey only. SecItemAdd without a prior delete; if another creator won the race
    /// (errSecDuplicateItem) the existing key is loaded and ours is discarded.
    private func loadOrCreateWrappingKey() throws -> Agreeing {
        if let existing = try loadWrappingKey() { return existing }
        if usesSecureEnclave {
            var err: Unmanaged<CFError>?
            guard let ac = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &err) else {
                throw err!.takeRetainedValue() as Error
            }
            let k = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
            if try !keychainAdd(account: wrappingTag, data: k.dataRepresentation), let existing = try loadWrappingKey() {
                return existing
            }
            return SEKey(k: k)
        }
        let k = P256.KeyAgreement.PrivateKey()
        if try !keychainAdd(account: wrappingTag, data: k.rawRepresentation), let existing = try loadWrappingKey() {
            return existing
        }
        return SWKey(k: k)
    }

    // MARK: Keychain

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Adds without deleting. Returns false on errSecDuplicateItem.
    private func keychainAdd(account: String, data: Data) throws -> Bool {
        var q = baseQuery(account: account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return true
    }

    private func keychainStore(account: String, data: Data) throws {
        var q = baseQuery(account: account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private func keychainLoad(account: String) throws -> Data? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data else { throw StoreError.keychain(status) }
        return d
    }
}
