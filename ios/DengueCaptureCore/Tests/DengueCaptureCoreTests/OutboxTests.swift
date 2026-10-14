import XCTest
@testable import DengueCaptureCore

final class TestClock: DengueCaptureCore.Clock {
    var wallNow: Date
    var monotonicNanos: UInt64
    var serverOffset: TimeInterval
    init(wall: Date = Date(timeIntervalSince1970: 1_800_000_000), mono: UInt64 = 1_000, offset: TimeInterval = 0) {
        wallNow = wall; monotonicNanos = mono; serverOffset = offset
    }
}

final class OutboxTests: XCTestCase {
    var dir: URL!
    var clock: TestClock!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        clock = TestClock()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeOutbox() throws -> Outbox {
        Outbox(store: try FileOutboxStore(directory: dir), clock: clock)
    }

    func testIdempotencyKeyUnchangedAfter3Retries() throws {
        let ob = try makeOutbox()
        let item = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data("x".utf8), dependsOn: nil)
        for _ in 0..<3 {
            try ob.markRetry(item.id)
            clock.wallNow = clock.wallNow.addingTimeInterval(1000)
        }
        let after = try XCTUnwrap(ob.item(item.id))
        XCTAssertEqual(after.idempotencyKey, item.idempotencyKey)
        XCTAssertEqual(after.attempts, 3)
    }

    func testArtefactUploadNotReadyUntilCreateScanDone() throws {
        let ob = try makeOutbox()
        let s = UUID()
        let scan = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        let up = try ob.enqueue(.uploadArtefact, sessionId: s, payload: Data(), dependsOn: scan.id)
        XCTAssertEqual(try ob.nextReady()?.id, scan.id)
        try ob.markInFlight(scan.id)
        XCTAssertNil(try ob.nextReady())
        try ob.markDone(scan.id)
        XCTAssertEqual(try ob.nextReady()?.id, up.id)
    }

    func testBackoffDoublesAndCapsAt900s() throws {
        let ob = try makeOutbox()
        let item = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data(), dependsOn: nil)
        var delays: [TimeInterval] = []
        for _ in 0..<12 {
            let t0 = clock.wallNow
            try ob.markRetry(item.id)
            let n = try XCTUnwrap(ob.item(item.id)).nextAttemptAt
            delays.append(n.timeIntervalSince(t0))
        }
        XCTAssertEqual(Array(delays.prefix(4)), [2, 4, 8, 16])
        XCTAssertEqual(delays[8], 512)
        XCTAssertEqual(delays[9], 900)
        XCTAssertEqual(delays[11], 900)
        // Not ready until the backoff elapses.
        XCTAssertNil(try ob.nextReady())
        clock.wallNow = clock.wallNow.addingTimeInterval(900)
        XCTAssertNotNil(try ob.nextReady())
    }

    func testQuarantineDestroysKeysAndRemovesFiles() throws {
        let ob = try makeOutbox()
        let keys = InMemoryKeyStore()
        let k = try keys.newKey()
        let file = dir.appendingPathComponent("a.sealed")
        try Data("secret".utf8).write(to: file)
        let art = SealedArtefact(keyId: k.id, path: file, sha256OfPlaintext: "", sizeBytes: 6,
                                 sha256OfCiphertext: "", sealedSizeBytes: 6)
        let s = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        let done = try ob.enqueue(.clinicalData, sessionId: s, payload: Data(), dependsOn: nil)
        try ob.markDone(done.id)
        let other = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data(), dependsOn: nil)

        try ob.quarantine(sessionId: s, keys: keys, sealedPaths: [art])

        XCTAssertThrowsError(try keys.key(id: k.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try ob.item(a.id)?.status, .quarantined)
        XCTAssertEqual(try ob.item(done.id)?.status, .done)
        XCTAssertEqual(try ob.item(other.id)?.status, .pending)
        XCTAssertNil(try ob.nextReady().flatMap { $0.sessionId == s ? $0 : nil })
    }

    func testCapturedAtCorrectedByServerOffset() throws {
        clock.serverOffset = 3600 // device clock is one hour behind the server
        let ob = try makeOutbox()
        let item = try ob.enqueue(.createScan, sessionId: UUID(), payload: Data(), dependsOn: nil)
        clock.serverOffset = 0 // later re-measurement must not change the stored value
        XCTAssertEqual(ob.correctedCapturedAt(for: item), item.createdWall.addingTimeInterval(3600))
        XCTAssertEqual(item.serverOffset, 3600)
        XCTAssertEqual(item.createdMonotonicNanos, 1_000)
    }

    func testServer422DSQGOnQualityMapsToNeedsRepeat() throws {
        let ob = try makeOutbox()
        let s = UUID()
        let item = try ob.enqueue(.completeArtefact, sessionId: s, payload: Data(), dependsOn: nil)
        let err = APIError.from(code: "DS_QG_002", httpStatus: 422)
        XCTAssertEqual(err, .needsRepeat([.dsQG002]))
        XCTAssertEqual(try ob.apply(err, to: item.id), .needsRepeat)
        let after = try XCTUnwrap(ob.item(item.id))
        XCTAssertEqual(after.status, .needsRepeat)
        XCTAssertEqual(after.reasons, [.dsQG002])
        XCTAssertNil(try ob.nextReady())
    }

    func testItemsSurviveReopening() throws {
        let s = UUID()
        let scan = try makeOutbox().enqueue(.createScan, sessionId: s, payload: Data("p".utf8), dependsOn: nil)
        let reopened = try makeOutbox()
        let got = try XCTUnwrap(reopened.item(scan.id))
        XCTAssertEqual(got, scan)
        XCTAssertEqual(try reopened.nextReady()?.id, scan.id)
    }

    func testApplyActions() throws {
        let ob = try makeOutbox()
        let s = UUID()
        let a = try ob.enqueue(.createScan, sessionId: s, payload: Data(), dependsOn: nil)
        XCTAssertEqual(try ob.apply(.retryable, to: a.id), .retryScheduled)
        XCTAssertEqual(try ob.item(a.id)?.attempts, 1)
        XCTAssertEqual(try ob.apply(.stopAndQuarantine(code: "DS_REG_001"), to: a.id),
                       .quarantineRequired(sessionId: s))
        XCTAssertEqual(try ob.apply(.uploadHashMismatch, to: a.id), .failed)
        XCTAssertEqual(try ob.item(a.id)?.status, .failed)
        for e in [APIError.duplicateRecent, .unauthorized, .reEnrol, .invalid(code: "DS_VALIDATION_001")] {
            XCTAssertEqual(try ob.apply(e, to: a.id), .failed)
            XCTAssertEqual(try ob.item(a.id)?.status, .failed)
            XCTAssertNotNil(try ob.item(a.id)?.failureReason)
        }
    }
}

final class APIErrorTests: XCTestCase {
    func testMappingTable() {
        let cases: [(String, Int, APIError)] = [
            ("DS_REG_001", 422, .stopAndQuarantine(code: "DS_REG_001")),
            ("DS_REG_002", 422, .stopAndQuarantine(code: "DS_REG_002")),
            ("DS_QG_001", 422, .needsRepeat([.dsQG001])),
            ("DS_RPPG_001", 422, .needsRepeat([.dsRPPG001])),
            ("DS_SEG_001", 422, .needsRepeat([.dsSEG001])),
            ("DS_SCAN_001", 409, .duplicateRecent),
            ("DS_UPLOAD_001", 422, .uploadHashMismatch),
            ("DS_UPLOAD_005", 409, .retryable),
            ("DS_RATE_001", 429, .retryable),
            ("DS_AUD_001", 400, .retryable),
            ("DS_ANY", 503, .retryable),
            ("DS_DEVICE_001", 403, .reEnrol),
            ("DS_DEVICE_002", 403, .unauthorized),
            ("DS_DEVICE_003", 403, .unauthorized),
            ("DS_DEVICE_004", 403, .unauthorized),
            ("DS_DEVICE_005", 403, .unauthorized),
            ("DS_AUTH_003", 403, .unauthorized),
            ("", 401, .unauthorized),
            ("DS_VALIDATION_001", 422, .invalid(code: "DS_VALIDATION_001")),
            ("DS_SCAN_002", 409, .invalid(code: "DS_SCAN_002")),
            ("DS_NOT_FOUND", 404, .invalid(code: "DS_NOT_FOUND")),
            ("DS_WHATEVER", 400, .invalid(code: "DS_WHATEVER")),
        ]
        for (code, status, expected) in cases {
            XCTAssertEqual(APIError.from(code: code, httpStatus: status), expected, "\(code) \(status)")
        }
    }

    func testExplicitReasonCodesWin() {
        XCTAssertEqual(APIError.from(code: "DS_QG_099", httpStatus: 422, reasonCodes: [.dsQG001, .dsQG002]),
                       .needsRepeat([.dsQG001, .dsQG002]))
    }
}
