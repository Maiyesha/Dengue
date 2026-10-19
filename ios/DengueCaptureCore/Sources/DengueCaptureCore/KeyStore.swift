import Foundation
import Crypto

/// Source of per-artefact encryption keys. Deleting a key ("crypto-shredding") makes the
/// sealed artefact permanently unreadable, which is how this app implements deletion.
///
/// The app target supplies a Secure-Enclave-wrapped Keychain implementation (Task 11).
public protocol KeyStore {
    func newKey() throws -> (id: String, key: SymmetricKey)
    func key(id: String) throws -> SymmetricKey
    func destroy(id: String) throws
}

/// A key store that can list its artefact key ids (for the relaunch sweep). Implementations must list ONLY
/// per-artefact keys, never wrapping keys or other items.
public protocol KeyEnumerating {
    func allKeyIds() throws -> [String]
}

/// NOT FOR PRODUCTION. Keys live only in process memory and are not protected by the
/// Keychain or Secure Enclave. Intended for unit tests and SwiftUI previews.
public final class InMemoryKeyStore: KeyStore {
    private var keys: [String: SymmetricKey] = [:]
    private let lock = NSLock()

    public init() {}

    public func newKey() throws -> (id: String, key: SymmetricKey) {
        let id = UUID().uuidString
        let key = SymmetricKey(size: .bits256)
        lock.lock(); defer { lock.unlock() }
        keys[id] = key
        return (id, key)
    }

    public func key(id: String) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        guard let k = keys[id] else { throw SealerError.keyUnavailable }
        return k
    }

    public func destroy(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        keys[id] = nil
    }

    /// Tests / fixtures: a known key under an arbitrary id.
    public func insert(_ key: SymmetricKey, id: String) {
        lock.lock(); defer { lock.unlock() }
        keys[id] = key
    }

    /// Tests: a key under an arbitrary id.
    public func insertForTesting(id: String) {
        lock.lock(); defer { lock.unlock() }
        keys[id] = SymmetricKey(size: .bits256)
    }
}

extension InMemoryKeyStore: KeyEnumerating {
    public func allKeyIds() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(keys.keys)
    }
}
