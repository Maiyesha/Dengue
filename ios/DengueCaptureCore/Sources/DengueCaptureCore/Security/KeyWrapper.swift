import Foundation
import Crypto
import _CryptoExtras

/// A per-artefact data key (DEK) wrapped for the server's KMS key (C1 ruling: envelope encryption).
public struct WrappedKey: Codable, Equatable {
    public static let rsaOAEP256 = "RSA-OAEP-256"

    /// base64 (standard, padded) of the RSA-OAEP-SHA256 ciphertext of the raw 32-byte DEK.
    public var wrappedKeyB64: String
    /// Always `RSA-OAEP-256`.
    public var alg: String
    /// Server KMS key id the DEK was wrapped for (from Managed App Config `kms_key_id`).
    public var kmsKeyId: String

    public init(wrappedKeyB64: String, alg: String = WrappedKey.rsaOAEP256, kmsKeyId: String) {
        self.wrappedKeyB64 = wrappedKeyB64; self.alg = alg; self.kmsKeyId = kmsKeyId
    }
}

/// Wraps an artefact DEK for the server. Called at seal time, while the DEK is in memory.
public protocol KeyWrapper {
    func wrap(_ dek: SymmetricKey) throws -> WrappedKey
}

public enum KeyWrapperError: Error, Equatable {
    /// The PEM could not be parsed as an RSA public key.
    case invalidPublicKey
    /// The key is smaller than 3072 bits.
    case keyTooSmall(bits: Int)
    case wrapFailed
}

/// RSA-OAEP with SHA-256 (MGF1-SHA256) over the raw DEK, using swift-crypto `_CryptoExtras`.
/// Interoperable with Node `crypto.privateDecrypt({ oaepHash: 'sha256' })` and AWS KMS `RSAES_OAEP_SHA_256`.
public struct RSAKeyWrapper: KeyWrapper {
    public static let minimumBits = 3072

    private let publicKey: _RSA.Encryption.PublicKey
    public let kmsKeyId: String

    public init(publicKeyPEM: String, kmsKeyId: String) throws {
        // PEM framing is checked here and the DER is parsed directly: swift-crypto's PEM path traps on
        // non-PEM input on Windows, and MDM config is untrusted input.
        guard let der = Self.der(fromPEM: publicKeyPEM) else { throw KeyWrapperError.invalidPublicKey }
        let key: _RSA.Encryption.PublicKey
        do { key = try _RSA.Encryption.PublicKey(derRepresentation: der) }
        catch { throw KeyWrapperError.invalidPublicKey }
        guard key.keySizeInBits >= Self.minimumBits else { throw KeyWrapperError.keyTooSmall(bits: key.keySizeInBits) }
        self.publicKey = key
        self.kmsKeyId = kmsKeyId
    }

    /// Body of a single `-----BEGIN PUBLIC KEY-----` (SubjectPublicKeyInfo) block, base64-decoded.
    static func der(fromPEM pem: String) -> Data? {
        let begin = "-----BEGIN PUBLIC KEY-----", end = "-----END PUBLIC KEY-----"
        guard let b = pem.range(of: begin), let e = pem.range(of: end), b.upperBound <= e.lowerBound else { return nil }
        let body = pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard !body.isEmpty, let d = Data(base64Encoded: String(body)), isPlausibleSPKI(d) else { return nil }
        return d
    }

    /// Outer DER SEQUENCE whose definite length covers exactly the data (swift-crypto traps on some
    /// malformed DER on Windows, so obviously malformed input never reaches it).
    static func isPlausibleSPKI(_ d: Data) -> Bool {
        let b = [UInt8](d)
        guard b.count >= 160, b[0] == 0x30 else { return false }
        var len = 0, header = 2
        if b[1] < 0x80 {
            len = Int(b[1])
        } else {
            let n = Int(b[1] & 0x7f)
            guard (1...3).contains(n), b.count > 2 + n else { return false }
            for i in 0..<n { len = len << 8 | Int(b[2 + i]) }
            header = 2 + n
        }
        return header + len == b.count
    }

    public func wrap(_ dek: SymmetricKey) throws -> WrappedKey {
        let raw = dek.withUnsafeBytes { Data($0) }
        do {
            let ct = try publicKey.encrypt(raw, padding: .PKCS1_OAEP_SHA256)
            return WrappedKey(wrappedKeyB64: Data(ct).base64EncodedString(), kmsKeyId: kmsKeyId)
        } catch {
            throw KeyWrapperError.wrapFailed
        }
    }
}
