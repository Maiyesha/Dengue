import XCTest
import Foundation
import Crypto
import _CryptoExtras
@testable import DengueCaptureCore

/// Test double: "wraps" a DEK as its base64 (NOT encryption). Lets hand-off tests run without RSA.
struct FakeKeyWrapper: KeyWrapper {
    var kmsKeyId = "kms-test"
    func wrap(_ dek: SymmetricKey) throws -> WrappedKey {
        WrappedKey(wrappedKeyB64: dek.withUnsafeBytes { Data($0) }.base64EncodedString(), kmsKeyId: kmsKeyId)
    }
}

/// One RSA-3072 key pair per test run (generation is slow).
enum TestRSA {
    static let privateKey: _RSA.Encryption.PrivateKey = try! _RSA.Encryption.PrivateKey(keySize: .bits3072)
    static var publicPEM: String { privateKey.publicKey.pemRepresentation }
}

final class KeyWrapperTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kw-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testWrapUnwrapRoundTripRSAOAEPSHA256() throws {
        let w = try RSAKeyWrapper(publicKeyPEM: TestRSA.publicPEM, kmsKeyId: "kms-1")
        let dek = SymmetricKey(size: .bits256)
        let wrapped = try w.wrap(dek)
        XCTAssertEqual(wrapped.alg, "RSA-OAEP-256")
        XCTAssertEqual(wrapped.kmsKeyId, "kms-1")
        let ct = try XCTUnwrap(Data(base64Encoded: wrapped.wrappedKeyB64))
        XCTAssertEqual(ct.count, 384)   // 3072-bit modulus
        let raw = try TestRSA.privateKey.decrypt(ct, padding: .PKCS1_OAEP_SHA256)
        XCTAssertEqual(raw, dek.withUnsafeBytes { Data($0) })
    }

    func testRejectsGarbageAndSmallKeys() throws {
        for bad in ["not a key", "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----", ""] {
            XCTAssertThrowsError(try RSAKeyWrapper(publicKeyPEM: bad, kmsKeyId: "k")) {
                XCTAssertEqual($0 as? KeyWrapperError, .invalidPublicKey)
            }
        }
        let small = try _RSA.Encryption.PrivateKey(keySize: .bits2048)
        XCTAssertThrowsError(try RSAKeyWrapper(publicKeyPEM: small.publicKey.pemRepresentation, kmsKeyId: "k")) {
            XCTAssertEqual($0 as? KeyWrapperError, .keyTooSmall(bits: 2048))
        }
    }

    func testSealerWrapsTheArtefactKeyAtSealTime() throws {
        let keys = InMemoryKeyStore()
        let w = try RSAKeyWrapper(publicKeyPEM: TestRSA.publicPEM, kmsKeyId: "kms-1")
        let input = dir.appendingPathComponent("p.bin")
        try Data("hello".utf8).write(to: input)
        let s = try ArtefactSealer(keys: keys, wrapper: w).seal(input: input, output: dir.appendingPathComponent("s"))
        let wrapped = try XCTUnwrap(s.wrappedKey)
        let raw = try TestRSA.privateKey.decrypt(Data(base64Encoded: wrapped.wrappedKeyB64)!, padding: .PKCS1_OAEP_SHA256)
        XCTAssertEqual(raw, try keys.key(id: s.keyId).withUnsafeBytes { Data($0) })
    }

    func testFailedWrapDestroysTheNewKey() throws {
        struct Boom: KeyWrapper { func wrap(_ dek: SymmetricKey) throws -> WrappedKey { throw KeyWrapperError.wrapFailed } }
        let keys = InMemoryKeyStore()
        let input = dir.appendingPathComponent("p.bin")
        try Data("x".utf8).write(to: input)
        XCTAssertThrowsError(try ArtefactSealer(keys: keys, wrapper: Boom()).seal(input: input, output: dir.appendingPathComponent("s")))
        XCTAssertEqual(try keys.allKeyIds(), [])
    }

    func testDeclareBodyCarriesWrappedKeyFields() throws {
        let req = DeclareArtefactRequest(step: .neutralFace, attempt: 1, kind: .video, sizeBytes: 10,
                                         sha256: String(repeating: "a", count: 64), deviceVerdict: .accept,
                                         wrappedKey: WrappedKey(wrappedKeyB64: "QUJD", kmsKeyId: "kms-9"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(obj["wrapped_key"] as? String, "QUJD")
        XCTAssertEqual(obj["key_alg"] as? String, "RSA-OAEP-256")
        XCTAssertEqual(obj["kms_key_id"] as? String, "kms-9")
        XCTAssertEqual(try JSONDecoder().decode(DeclareArtefactRequest.self, from: JSONEncoder().encode(req)), req)
    }

    func testEngineDeclareSendsTheArtefactsWrappedKey() async throws {
        let log = EventLog()
        let api = FakeUploadAPI(log: log)
        let keys = InMemoryKeyStore()
        let (keyId, _) = try keys.newKey()
        let path = dir.appendingPathComponent("a.sealed")
        try Data(count: 64).write(to: path)
        let wk = WrappedKey(wrappedKeyB64: "V1JBUA==", kmsKeyId: "kms-2")
        let sealed = SealedArtefact(keyId: keyId, path: path, sha256OfPlaintext: "p", sizeBytes: 24,
                                    sha256OfCiphertext: String(repeating: "c", count: 64), sealedSizeBytes: 64,
                                    wrappedKey: wk)
        let e = UploadEngine(outbox: Outbox(store: FlakyOutboxStore(), clock: TestClock()), api: api,
                             sessions: InMemoryUploadSessionStore(), keys: keys,
                             uploader: FakePartUploader(log: log), notifier: FakeNotifier())
        let session = UUID()
        try e.enqueueSession(sessionId: session, participantCode: "DS-1", createScan: nil, scanId: UUID(),
                             artefacts: [ArtefactUpload(step: .neutralFace, attempt: 1, kind: .video, sealed: sealed)])
        _ = await e.drain()
        XCTAssertEqual(api.declares.first?.request.wrappedKey, wk)
    }

    func testEngineFailsADeclareWithoutWrappedKey() async throws {
        let log = EventLog()
        let api = FakeUploadAPI(log: log)
        let keys = InMemoryKeyStore()
        let (keyId, _) = try keys.newKey()
        let path = dir.appendingPathComponent("a.sealed")
        try Data(count: 64).write(to: path)
        let sealed = SealedArtefact(keyId: keyId, path: path, sha256OfPlaintext: "p", sizeBytes: 24,
                                    sha256OfCiphertext: String(repeating: "c", count: 64), sealedSizeBytes: 64)
        let ob = Outbox(store: FlakyOutboxStore(), clock: TestClock())
        let e = UploadEngine(outbox: ob, api: api, sessions: InMemoryUploadSessionStore(), keys: keys,
                             uploader: FakePartUploader(log: log), notifier: FakeNotifier())
        let session = UUID()
        try e.enqueueSession(sessionId: session, participantCode: "DS-1", createScan: nil, scanId: UUID(),
                             artefacts: [ArtefactUpload(step: .neutralFace, attempt: 1, kind: .video, sealed: sealed)])
        _ = await e.drain()
        XCTAssertTrue(api.declares.isEmpty)
        XCTAssertEqual(try ob.items(sessionId: session).first { $0.kind == .declareArtefact }?.failureReason, "KMS_KEY_MISSING")
    }

    // MARK: hand-off

    private func handoffFixture(_ keys: InMemoryKeyStore) throws -> PendingHandoff {
        let sealedDir = dir.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: sealedDir, withIntermediateDirectories: true)
        let sealer = ArtefactSealer(keys: keys)   // no KMS key at seal time
        var arts: [SealedStepArtefact] = []
        for step in [CaptureStep.neutralFace, .fingertipPPG] {
            for kind in CaptureHandoff.artefactKinds {
                let plain = dir.appendingPathComponent(UUID().uuidString)
                try Data("\(step)-\(kind)".utf8).write(to: plain)
                let s = try sealer.seal(input: plain, output: sealedDir.appendingPathComponent(UUID().uuidString))
                arts.append(SealedStepArtefact(step: step, attempt: 1, kind: kind, sealed: s))
            }
        }
        let meta = CaptureMetadata(deviceModel: "iPhone15,2", step: .neutralFace, attempt: 1, cameraRole: .frontFace,
                                   fps: 30, resolution: "1080x1920", exposureDurationMs: 10, iso: 200, torchLevel: 0,
                                   distanceCm: 45, angleDeg: 3, lux: 320, mount: "holder", lightingType: "overhead",
                                   ambientTempC: nil, ambientHumidityPct: nil, durationSeconds: 40, frameCount: 1200,
                                   videoCodec: "hevc", videoAverageBitRate: 25_000_000)
        return PendingHandoff(sessionId: UUID(), patientId: UUID(), maskedCode: "\u{2022}\u{2022}417",
                              capturedAt: Date(), offline: false, protocolVersion: "phase-a-1",
                              attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept),
                                         AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .accept)],
                              vitals: [], artefacts: arts, metadata: meta, isOpen: false)
    }

    private func engine(_ keys: KeyStore) -> UploadEngine {
        UploadEngine(outbox: Outbox(store: FlakyOutboxStore(), clock: TestClock()), api: FakeUploadAPI(log: EventLog()),
                     sessions: InMemoryUploadSessionStore(), keys: keys, uploader: FakePartUploader(log: EventLog()),
                     notifier: FakeNotifier())
    }

    func testMissingKMSConfigHoldsTheHandoff() throws {
        let keys = InMemoryKeyStore()
        let p = try handoffFixture(keys)
        let store = try FileHeldHandoffStore(directory: dir.appendingPathComponent("held"), keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: nil)
        let e = engine(keys)
        XCTAssertEqual(svc.submit(p, engine: e), .held(.kmsKeyMissing))
        XCTAssertNil(e.record(p.sessionId))
        XCTAssertEqual(try svc.heldSummaries().first?.diagnostic, "KMS_KEY_MISSING")

        // Config arrives: the retry wraps every accepted artefact's key and enqueues.
        svc.keyWrapper = try RSAKeyWrapper(publicKeyPEM: TestRSA.publicPEM, kmsKeyId: "kms-1")
        XCTAssertEqual(svc.retryHeld(engine: e)[p.sessionId], .enqueued)
        let rec = try XCTUnwrap(e.record(p.sessionId))
        XCTAssertEqual(rec.artefacts.count, 6)
        for a in rec.artefacts {
            let w = try XCTUnwrap(a.sealed.wrappedKey)
            let raw = try TestRSA.privateKey.decrypt(Data(base64Encoded: w.wrappedKeyB64)!, padding: .PKCS1_OAEP_SHA256)
            XCTAssertEqual(raw, try keys.key(id: a.sealed.keyId).withUnsafeBytes { Data($0) })
        }
    }

    // MARK: cross-language fixture (contracts/fixtures/sealed-artefact-v1)

    static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/fixtures/sealed-artefact-v1", isDirectory: true)
    }

    struct Manifest: Codable {
        var warning: String
        var format: String
        var plaintextFile: String
        var plaintextSha256: String
        var plaintextSizeBytes: Int64
        var sealedFile: String
        var sealedSha256: String
        var sealedSizeBytes: Int64
        var wrappedKeyB64: String
        var keyAlg: String
        var kmsKeyId: String
        var privateKeyFile: String
        var publicKeyFile: String
        enum CodingKeys: String, CodingKey {
            case warning, format, plaintextFile = "plaintext_file", plaintextSha256 = "plaintext_sha256"
            case plaintextSizeBytes = "plaintext_size_bytes", sealedFile = "sealed_file", sealedSha256 = "sealed_sha256"
            case sealedSizeBytes = "sealed_size_bytes", wrappedKeyB64 = "wrapped_key_b64", keyAlg = "key_alg"
            case kmsKeyId = "kms_key_id", privateKeyFile = "private_key_file", publicKeyFile = "public_key_file"
        }
    }

    /// Deterministic plaintext spanning two chunks (1 MiB + 1000 bytes) so chunk boundaries are exercised.
    static func fixturePlaintext() -> Data {
        var d = Data(count: (1 << 20) + 1000)
        var x: UInt32 = 0x2545F491
        for i in 0..<d.count { x ^= x << 13; x ^= x >> 17; x ^= x << 5; d[i] = UInt8(truncatingIfNeeded: x) }
        return d
    }

    /// `WRITE_FIXTURES=1 swift test --filter testSealedArtefactFixture` regenerates the fixture (new TEST key pair).
    /// Otherwise the committed fixture is verified: unwrap with the TEST private key, open, compare.
    func testSealedArtefactFixture() throws {
        let fm = FileManager.default
        let out = Self.fixtureDir
        if ProcessInfo.processInfo.environment["WRITE_FIXTURES"] == "1" {
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let keys = InMemoryKeyStore()
            let wrapper = try RSAKeyWrapper(publicKeyPEM: TestRSA.publicPEM, kmsKeyId: "test-kms-key-DO-NOT-USE")
            let plain = Self.fixturePlaintext()
            let plainURL = out.appendingPathComponent("plaintext.bin")
            try plain.write(to: plainURL)
            let tmp = dir.appendingPathComponent("in.bin")
            try plain.write(to: tmp)
            let sealedURL = out.appendingPathComponent("artefact.sealed")
            try? fm.removeItem(at: sealedURL)
            let s = try ArtefactSealer(keys: keys, wrapper: wrapper).seal(input: tmp, output: sealedURL)
            let w = try XCTUnwrap(s.wrappedKey)
            try Data(TestRSA.privateKey.pkcs8PEMRepresentation.utf8)
                .write(to: out.appendingPathComponent("TEST-ONLY-DO-NOT-USE.private-key.pem"))
            try Data(TestRSA.publicPEM.utf8).write(to: out.appendingPathComponent("TEST-ONLY-DO-NOT-USE.public-key.pem"))
            let m = Manifest(
                warning: "TEST-ONLY fixture. The RSA private key here is a throwaway test key generated by "
                    + "KeyWrapperTests; it protects nothing and must never be used outside tests.",
                format: "DSv1", plaintextFile: "plaintext.bin", plaintextSha256: s.sha256OfPlaintext,
                plaintextSizeBytes: s.sizeBytes, sealedFile: "artefact.sealed", sealedSha256: s.sha256OfCiphertext,
                sealedSizeBytes: s.sealedSizeBytes, wrappedKeyB64: w.wrappedKeyB64, keyAlg: w.alg, kmsKeyId: w.kmsKeyId,
                privateKeyFile: "TEST-ONLY-DO-NOT-USE.private-key.pem",
                publicKeyFile: "TEST-ONLY-DO-NOT-USE.public-key.pem")
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(m).write(to: out.appendingPathComponent("manifest.json"))
        }
        let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        XCTAssertEqual(m.format, "DSv1")
        XCTAssertEqual(m.keyAlg, "RSA-OAEP-256")
        let pem = try String(contentsOf: out.appendingPathComponent(m.privateKeyFile), encoding: .utf8)
        let priv = try _RSA.Encryption.PrivateKey(pemRepresentation: pem)
        let dek = try priv.decrypt(Data(base64Encoded: m.wrappedKeyB64)!, padding: .PKCS1_OAEP_SHA256)
        let keys = InMemoryKeyStore()
        keys.insert(SymmetricKey(data: dek), id: "fixture")
        let sealed = SealedArtefact(keyId: "fixture", path: out.appendingPathComponent(m.sealedFile),
                                    sha256OfPlaintext: m.plaintextSha256, sizeBytes: m.plaintextSizeBytes,
                                    sha256OfCiphertext: m.sealedSha256, sealedSizeBytes: m.sealedSizeBytes)
        let opened = dir.appendingPathComponent("opened.bin")
        try ArtefactSealer(keys: keys).open(sealed, to: opened)
        XCTAssertEqual(try Data(contentsOf: opened), try Data(contentsOf: out.appendingPathComponent(m.plaintextFile)))
        XCTAssertEqual(try Data(contentsOf: opened), Self.fixturePlaintext())
    }
}
