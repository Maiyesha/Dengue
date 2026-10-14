import Foundation
import Crypto

public enum SealerError: Error, Equatable {
    case keyUnavailable
    case integrity
}

public struct SealedArtefact: Codable, Equatable {
    public var keyId: String
    public var path: URL
    /// Lowercase hex SHA-256 of the plaintext (local integrity only).
    public var sha256OfPlaintext: String
    /// Plaintext size in bytes.
    public var sizeBytes: Int64
    /// Lowercase hex SHA-256 of the entire sealed file as uploaded (sent in the artefact declare).
    public var sha256OfCiphertext: String
    /// Size of the sealed file in bytes (sent in the artefact declare).
    public var sealedSizeBytes: Int64

    public init(keyId: String, path: URL, sha256OfPlaintext: String, sizeBytes: Int64,
                sha256OfCiphertext: String, sealedSizeBytes: Int64) {
        self.keyId = keyId
        self.path = path
        self.sha256OfPlaintext = sha256OfPlaintext
        self.sizeBytes = sizeBytes
        self.sha256OfCiphertext = sha256OfCiphertext
        self.sealedSizeBytes = sealedSizeBytes
    }
}

/// Chunked AES-256-GCM file sealer.
///
/// Format: `DSv1` | version (1 byte, = 1) | 8-byte per-file random nonce prefix | chunks.
/// Each chunk holds up to 1 MiB of plaintext and is stored as ciphertext || 16-byte tag.
/// Nonce = prefix || 4-byte big-endian chunk index. AAD = 4-byte big-endian chunk index || isFinal byte.
/// The final chunk is the last one in the file (an empty input yields one empty final chunk), so
/// reordering, truncation, extension and tampering all fail authentication.
public struct ArtefactSealer {
    static let magic = Data("DSv1".utf8)
    static let version: UInt8 = 1
    static let prefixLen = 8
    static let chunkSize = 1 << 20
    static let tagLen = 16

    private let keys: KeyStore

    public init(keys: KeyStore) { self.keys = keys }

    // MARK: seal

    public func seal(input: URL, output: URL) throws -> SealedArtefact {
        let (keyId, key) = try keys.newKey()
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }

        let fm = FileManager.default
        fm.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        var finished = false
        defer {
            try? writer.close()
            if !finished { try? fm.removeItem(at: output) }
        }

        var plainHash = SHA256()
        var sealedHash = SHA256()
        var plainSize: Int64 = 0
        var sealedSize: Int64 = 0

        func emit(_ d: Data) throws {
            try writer.write(contentsOf: d)
            sealedHash.update(data: d)
            sealedSize += Int64(d.count)
        }

        var prefix = Data(count: Self.prefixLen)
        for i in 0..<Self.prefixLen { prefix[i] = UInt8.random(in: 0...255) }
        try emit(Self.magic + Data([Self.version]) + prefix)

        var index: UInt32 = 0
        var current = try reader.read(upToCount: Self.chunkSize) ?? Data()
        while true {
            // Read ahead one chunk to know whether `current` is final.
            let next = current.count == Self.chunkSize
                ? (try reader.read(upToCount: Self.chunkSize) ?? Data())
                : Data()
            let isFinal = next.isEmpty
            plainHash.update(data: current)
            plainSize += Int64(current.count)
            let box = try AES.GCM.seal(
                current, using: key,
                nonce: try Self.nonce(prefix: prefix, index: index),
                authenticating: Self.aad(index: index, isFinal: isFinal))
            try emit(box.ciphertext + box.tag)
            if isFinal { break }
            guard index < UInt32.max else { throw SealerError.integrity }
            index += 1
            current = next
        }
        try writer.synchronize()
        finished = true
        return SealedArtefact(
            keyId: keyId, path: output,
            sha256OfPlaintext: Self.hex(plainHash.finalize()), sizeBytes: plainSize,
            sha256OfCiphertext: Self.hex(sealedHash.finalize()), sealedSizeBytes: sealedSize)
    }

    // MARK: open

    public func open(_ s: SealedArtefact, to: URL) throws {
        let key: SymmetricKey
        do { key = try keys.key(id: s.keyId) } catch { throw SealerError.keyUnavailable }

        let reader = try FileHandle(forReadingFrom: s.path)
        defer { try? reader.close() }

        let header = try reader.read(upToCount: 4 + 1 + Self.prefixLen) ?? Data()
        guard header.count == 4 + 1 + Self.prefixLen,
              header.prefix(4) == Self.magic,
              header[4] == Self.version else { throw SealerError.integrity }
        let prefix = header.suffix(Self.prefixLen)

        let fm = FileManager.default
        fm.createFile(atPath: to.path, contents: nil)
        let writer = try FileHandle(forWritingTo: to)
        var finished = false
        defer {
            try? writer.close()
            if !finished { try? fm.removeItem(at: to) }
        }

        let sealedChunk = Self.chunkSize + Self.tagLen
        var plainHash = SHA256()
        var plainSize: Int64 = 0
        var index: UInt32 = 0
        var current = try reader.read(upToCount: sealedChunk) ?? Data()
        while true {
            let next = current.count == sealedChunk
                ? (try reader.read(upToCount: sealedChunk) ?? Data())
                : Data()
            let isFinal = next.isEmpty
            guard current.count >= Self.tagLen else { throw SealerError.integrity }
            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: try Self.nonce(prefix: Data(prefix), index: index),
                    ciphertext: current.prefix(current.count - Self.tagLen),
                    tag: current.suffix(Self.tagLen))
                plain = try AES.GCM.open(box, using: key,
                                         authenticating: Self.aad(index: index, isFinal: isFinal))
            } catch {
                throw SealerError.integrity
            }
            plainHash.update(data: plain)
            plainSize += Int64(plain.count)
            try writer.write(contentsOf: plain)
            if isFinal { break }
            guard index < UInt32.max else { throw SealerError.integrity }
            index += 1
            current = next
        }
        guard plainSize == s.sizeBytes, Self.hex(plainHash.finalize()) == s.sha256OfPlaintext else {
            throw SealerError.integrity
        }
        try writer.synchronize()
        finished = true
    }

    // MARK: helpers

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    private static func nonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: prefix + be32(index))
    }

    private static func aad(index: UInt32, isFinal: Bool) -> Data {
        be32(index) + Data([isFinal ? 1 : 0])
    }

    private static func hex<D: Digest>(_ d: D) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }
}
