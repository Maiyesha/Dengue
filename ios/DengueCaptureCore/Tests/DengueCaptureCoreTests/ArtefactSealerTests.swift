import XCTest
import Crypto
@testable import DengueCaptureCore

final class ArtefactSealerTests: XCTestCase {
    private let mib = 1_048_576
    private let overhead = 16   // GCM tag
    private let headerLen = 13  // magic(4) + version(1) + nonce prefix(8)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeInput(size: Int) throws -> (url: URL, bytes: Data) {
        var data = Data(count: size)
        for i in 0..<size { data[i] = UInt8.random(in: 0...255) }
        let url = dir.appendingPathComponent("in-\(UUID().uuidString).bin")
        try data.write(to: url)
        return (url, data)
    }

    private func sha(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private func sealed(size: Int, keys: InMemoryKeyStore = InMemoryKeyStore())
        throws -> (s: SealedArtefact, plain: Data, sealer: ArtefactSealer, out: URL) {
        let (inURL, plain) = try makeInput(size: size)
        let out = dir.appendingPathComponent("out-\(UUID().uuidString).dsv1")
        let sealer = ArtefactSealer(keys: keys)
        let s = try sealer.seal(input: inURL, output: out)
        return (s, plain, sealer, out)
    }

    func testRoundtrip5MiBRandomFile() throws {
        let r = try sealed(size: 5 * mib + 123)
        let dec = dir.appendingPathComponent("dec.bin")
        try r.sealer.open(r.s, to: dec)
        XCTAssertEqual(try Data(contentsOf: dec), r.plain)
        XCTAssertEqual(r.s.sizeBytes, Int64(r.plain.count))
        XCTAssertEqual(r.s.path, r.out)
    }

    func testRoundtripEdgeSizes() throws {
        for size in [0, 1, mib, mib + 1, 2 * mib] {
            let r = try sealed(size: size)
            let dec = dir.appendingPathComponent("dec-\(size).bin")
            try r.sealer.open(r.s, to: dec)
            XCTAssertEqual(try Data(contentsOf: dec), r.plain, "size \(size)")
        }
    }

    func testSha256MatchesPlaintext() throws {
        let r = try sealed(size: 2 * mib + 7)
        XCTAssertEqual(r.s.sha256OfPlaintext, sha(r.plain))
    }

    func testCiphertextHashAndSizeMatchOutputFile() throws {
        let r = try sealed(size: 3 * mib + 5)
        let file = try Data(contentsOf: r.out)
        XCTAssertEqual(r.s.sha256OfCiphertext, sha(file))
        XCTAssertEqual(r.s.sealedSizeBytes, Int64(file.count))
        XCTAssertEqual(file.prefix(4), Data("DSv1".utf8))
    }

    func testFlippedByteIsIntegrity() throws {
        let r = try sealed(size: 2 * mib)
        var file = try Data(contentsOf: r.out)
        file[headerLen + 1000] ^= 0x01
        try file.write(to: r.out)
        XCTAssertThrowsError(try r.sealer.open(r.s, to: dir.appendingPathComponent("d.bin"))) {
            XCTAssertEqual($0 as? SealerError, .integrity)
        }
    }

    func testDroppedFinalChunkIsIntegrity() throws {
        let r = try sealed(size: 3 * mib - 10)  // 3 chunks
        var file = try Data(contentsOf: r.out)
        let chunk = mib + overhead
        file = file.prefix(headerLen + 2 * chunk)
        try file.write(to: r.out)
        XCTAssertThrowsError(try r.sealer.open(r.s, to: dir.appendingPathComponent("d.bin"))) {
            XCTAssertEqual($0 as? SealerError, .integrity)
        }
    }

    func testTrailingBytesAreIntegrity() throws {
        let r = try sealed(size: mib / 2)
        var file = try Data(contentsOf: r.out)
        file.append(contentsOf: [1, 2, 3])
        try file.write(to: r.out)
        XCTAssertThrowsError(try r.sealer.open(r.s, to: dir.appendingPathComponent("d.bin"))) {
            XCTAssertEqual($0 as? SealerError, .integrity)
        }
    }

    func testSwappedChunksIsIntegrity() throws {
        let r = try sealed(size: 3 * mib)
        let file = try Data(contentsOf: r.out)
        let chunk = mib + overhead
        var swapped = Data(file.prefix(headerLen))
        let c0 = file.subdata(in: headerLen..<(headerLen + chunk))
        let c1 = file.subdata(in: (headerLen + chunk)..<(headerLen + 2 * chunk))
        let rest = file.suffix(from: headerLen + 2 * chunk)
        swapped.append(c1); swapped.append(c0); swapped.append(rest)
        try swapped.write(to: r.out)
        XCTAssertThrowsError(try r.sealer.open(r.s, to: dir.appendingPathComponent("d.bin"))) {
            XCTAssertEqual($0 as? SealerError, .integrity)
        }
    }

    func testBadMagicIsIntegrity() throws {
        let r = try sealed(size: 100)
        var file = try Data(contentsOf: r.out)
        file[0] = 0x58
        try file.write(to: r.out)
        XCTAssertThrowsError(try r.sealer.open(r.s, to: dir.appendingPathComponent("d.bin"))) {
            XCTAssertEqual($0 as? SealerError, .integrity)
        }
    }

    func testFailedOpenLeavesNoOutput() throws {
        let r = try sealed(size: 2 * mib)
        var file = try Data(contentsOf: r.out)
        file[file.count - 1] ^= 0x80
        try file.write(to: r.out)
        let dec = dir.appendingPathComponent("d.bin")
        XCTAssertThrowsError(try r.sealer.open(r.s, to: dec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dec.path))
    }

    func testDestroyedKeyIsKeyUnavailable() throws {
        let keys = InMemoryKeyStore()
        let r = try sealed(size: 1000, keys: keys)
        try keys.destroy(id: r.s.keyId)
        XCTAssertThrowsError(try r.sealer.open(r.s, to: dir.appendingPathComponent("d.bin"))) {
            XCTAssertEqual($0 as? SealerError, .keyUnavailable)
        }
    }

    func testSealedArtefactCodableRoundtrip() throws {
        let r = try sealed(size: 10)
        let data = try JSONEncoder().encode(r.s)
        XCTAssertEqual(try JSONDecoder().decode(SealedArtefact.self, from: data), r.s)
    }
}
