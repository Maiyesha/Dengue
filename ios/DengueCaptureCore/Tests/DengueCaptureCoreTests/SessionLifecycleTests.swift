import XCTest
import Foundation
@testable import DengueCaptureCore

/// I2 (session status read model, 2 h repeat window) and I3 (retention: terminal createScan failures,
/// step-scoped needsRepeat, 7-day unsent flag).
final class SessionLifecycleTests: XCTestCase {
    var dir: URL!
    var clock: TestClock!
    var outbox: Outbox!
    var log: EventLog!
    var api: FakeUploadAPI!
    var uploader: FakePartUploader!
    var notifier: FakeNotifier!
    var keys: InMemoryKeyStore!
    var sessions: InMemoryUploadSessionStore!
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("life-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = TestClock()
        outbox = Outbox(store: FlakyOutboxStore(), clock: clock)
        log = EventLog()
        api = FakeUploadAPI(log: log)
        uploader = FakePartUploader(log: log)
        notifier = FakeNotifier()
        keys = InMemoryKeyStore()
        sessions = InMemoryUploadSessionStore()
        now = Date(timeIntervalSince1970: 1_800_000_000)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeEngine() -> UploadEngine {
        UploadEngine(outbox: outbox, api: api, sessions: sessions, keys: keys, uploader: uploader, notifier: notifier,
                     partSize: 1000, now: { [unowned self] in self.now })
    }

    func artefact(_ step: CaptureStepName = .neutralFace, kind: ArtefactKind = .video, attempt: Int = 1) throws -> ArtefactUpload {
        let (keyId, _) = try keys.newKey()
        let path = dir.appendingPathComponent("\(UUID().uuidString).sealed")
        try Data(count: 300).write(to: path)
        let sealed = SealedArtefact(keyId: keyId, path: path, sha256OfPlaintext: "p", sizeBytes: 260,
                                    sha256OfCiphertext: String(repeating: "c", count: 64), sealedSizeBytes: 300,
                                    wrappedKey: WrappedKey(wrappedKeyB64: "V1JBUA==", kmsKeyId: "kms"))
        return ArtefactUpload(step: step, attempt: attempt, kind: kind, deviceVerdict: .accept, sealed: sealed)
    }

    func createScan(_ session: UUID, capturedAt: Date) -> CreateScanRequest {
        CreateScanRequest(
            clientSessionId: session, patientId: UUID(), capturedAt: capturedAt, offline: false, protocolVersion: "1",
            captureSteps: [.neutralFace, .fingertipPPG],
            deviceAttempts: [DeviceAttempt(step: .neutralFace, attempt: 1, deviceVerdict: .accept, reasonCodes: [])],
            metadata: ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01,
                                   distanceCm: 40, angleDeg: 2, lightingLux: 300, ambientTempC: nil,
                                   ambientHumidityPct: nil, mount: "holder", lightingType: "overhead",
                                   exposureDurationMs: 10))
    }

    @discardableResult
    func enqueue(_ e: UploadEngine, _ arts: [ArtefactUpload], capturedAt: Date? = nil) throws -> UUID {
        let s = UUID()
        try e.enqueueSession(sessionId: s, participantCode: "DS-2026-00417",
                             createScan: createScan(s, capturedAt: capturedAt ?? now), scanId: nil, artefacts: arts)
        return s
    }

    func alive(_ a: ArtefactUpload) -> Bool {
        FileManager.default.fileExists(atPath: a.sealed.path.path) && (try? keys.key(id: a.sealed.keyId)) != nil
    }

    func scan(status: ScanStatus, steps: [(String, Int, String?, [String])]) throws -> ScanResponse {
        let stepsJSON = steps.map { s in
            let v = s.2.map { "\"\($0)\"" } ?? "null"
            let rc = s.3.map { "\"\($0)\"" }.joined(separator: ",")
            return #"{"step":"\#(s.0)","attempt":\#(s.1),"device_verdict":"ACCEPT","server_verdict":\#(v),"reason_codes":[\#(rc)]}"#
        }.joined(separator: ",")
        let json = #"{"scan":{"id":"\#(api.scanId.uuidString)","status":"\#(status.rawValue)","steps":[\#(stepsJSON)],"recaptures_remaining":{}}}"#
        return try JSONDecoder().decode(ScanResponse.self, from: Data(json.utf8))
    }

    // MARK: I3 terminal createScan failures

    func testDuplicateRecentClosesSessionWithNoticeAndDestroysData() async throws {
        let e = makeEngine()
        let arts = [try artefact(), try artefact(.fingertipPPG)]
        api.createScanErrors = [.duplicateRecent]
        let s = try enqueue(e, arts)
        await e.drain()
        let rec = try XCTUnwrap(e.record(s))
        XCTAssertEqual(rec.verdict, .closed)
        XCTAssertEqual(rec.notice, NurseCopy.recentScan)
        XCTAssertEqual(NurseCopy.recentScan, "This patient was recorded in the last 30 min")
        XCTAssertTrue(rec.localDataDestroyed)
        XCTAssertFalse(arts.contains(where: alive))
        XCTAssertEqual(e.status(s), .closed(notice: NurseCopy.recentScan))
        XCTAssertNil(try outbox.nextWakeAt())
    }

    func testValidationAndNotFoundOnCreateScanCloseTheSession() async throws {
        for code in ["DS_VALIDATION_001", "DS_NOT_FOUND"] {
            let e = makeEngine()
            let a = try artefact()
            api.createScanErrors = [.invalid(code: code)]
            let s = try enqueue(e, [a])
            await e.drain()
            XCTAssertEqual(e.record(s)?.verdict, .closed, code)
            XCTAssertEqual(e.record(s)?.notice, NurseCopy.uploadRejected, code)
            XCTAssertFalse(alive(a), code)
        }
        XCTAssertTrue(NurseCopy.forbiddenTerms(in: NurseCopy.uploadRejected).isEmpty)
    }

    func testRetryableCreateScanFailureKeepsData() async throws {
        let e = makeEngine()
        let a = try artefact()
        api.createScanErrors = [.retryable]
        let s = try enqueue(e, [a])
        await e.drain()
        XCTAssertTrue(alive(a))
        XCTAssertEqual(e.status(s), .queued)
    }

    // MARK: I3 step-scoped needsRepeat

    func testItemNeedsRepeatFreezesOnlyThatStep() async throws {
        let e = makeEngine()
        let face = [try artefact(.neutralFace, kind: .video), try artefact(.neutralFace, kind: .roiTrace)]
        let finger = [try artefact(.fingertipPPG, kind: .video), try artefact(.fingertipPPG, kind: .roiTrace)]
        api.completeErrorQueue = [.needsRepeat([.dsQG001])]   // the first complete (face video)
        let s = try enqueue(e, face + finger)
        await e.drain()
        let rec = try XCTUnwrap(e.record(s))
        XCTAssertEqual(rec.verdict, .needsRepeat)
        // The first complete to run (store order) gets the repeat; the OTHER step must still be fully sent.
        XCTAssertEqual(rec.repeatSteps.count, 1)
        let failing = rec.repeatSteps[0]
        let (same, other) = failing == .neutralFace ? (face, finger) : (finger, face)
        let byLocal = Dictionary(uniqueKeysWithValues: rec.artefacts.map { ($0.localId, $0.status) })
        XCTAssertTrue(other.allSatisfy { byLocal[$0.localId] == .verified }, "the other step keeps uploading")
        XCTAssertFalse(same.allSatisfy { byLocal[$0.localId] == .verified }, "the failing step's other chain is frozen")
        let items = try outbox.items(sessionId: s)
        XCTAssertFalse(items.contains { $0.status == .pending }, "nothing left to retry")
        XCTAssertEqual(e.status(s), .needsRepeat(steps: [failing], reasons: [.dsQG001]))
    }

    // MARK: I3 7-day unsent flag

    func testUnsentForSevenDaysIsFlagged() async throws {
        let e = makeEngine()
        api.createScanErrors = [.retryable]
        let old = try enqueue(e, [try artefact()], capturedAt: now.addingTimeInterval(-8 * 86400))
        let recent = try enqueue(e, [try artefact()], capturedAt: now.addingTimeInterval(-6 * 86400))
        let summaries = Dictionary(uniqueKeysWithValues: e.sessionSummaries().map { ($0.sessionId, $0) })
        XCTAssertEqual(summaries[old]?.unsentTooLong, true)
        XCTAssertEqual(summaries[recent]?.unsentTooLong, false)
        XCTAssertEqual(summaries[old]?.maskedCode, "\u{2022}\u{2022}417")
        XCTAssertTrue(RetentionPolicy.isUnsentTooLong(capturedAt: now.addingTimeInterval(-7 * 86400 - 1), now: now))
        XCTAssertFalse(RetentionPolicy.isUnsentTooLong(capturedAt: now.addingTimeInterval(-7 * 86400 + 1), now: now))
    }

    func testSentSessionIsNeverFlagged() async throws {
        let e = makeEngine()
        let s = try enqueue(e, [try artefact()], capturedAt: now.addingTimeInterval(-8 * 86400))
        await e.drain()
        XCTAssertEqual(e.status(s), .sent)
        XCTAssertEqual(e.sessionSummaries().first?.unsentTooLong, false)
    }

    func testHeldSummaryCarriesCapturedAtForTheSevenDayFlag() throws {
        let store = try FileHeldHandoffStore(directory: dir.appendingPathComponent("held"), keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: nil)
        let captured = now.addingTimeInterval(-8 * 86400)
        let p = PendingHandoff(sessionId: UUID(), patientId: nil, maskedCode: "\u{2022}\u{2022}417", capturedAt: captured,
                               offline: true, protocolVersion: "1", attempts: [], vitals: [], artefacts: [], metadata: nil,
                               isOpen: false)
        _ = svc.submit(p, engine: nil)
        let h = try XCTUnwrap(try svc.heldSummaries().first)
        XCTAssertEqual(h.capturedAt, captured)
        XCTAssertTrue(h.unsentTooLong(now: now))
    }

    // MARK: I2 status read model

    func testStatusProgression() async throws {
        let e = makeEngine()
        let a = try artefact()
        let s = try enqueue(e, [a])
        XCTAssertEqual(e.status(s), .queued)
        await e.drain(shouldContinue: { [log] in (log?.events.count ?? 0) < 2 })   // createScan + declare
        XCTAssertEqual(e.status(s), .uploading)
        await e.drain()
        XCTAssertEqual(e.status(s), .sent)
        api.scanResponse = try scan(status: .qualityPassed, steps: [])
        await e.refreshVerdicts()
        XCTAssertEqual(e.status(s), .sent)
        XCTAssertNil(e.status(UUID()))
    }

    // MARK: I2 repeat window

    func testServerRepeatWithinTwoHoursIsOffered() async throws {
        let e = makeEngine()
        let s = try enqueue(e, [try artefact()], capturedAt: now.addingTimeInterval(-3600))
        await e.drain()
        api.scanResponse = try scan(status: .qualityFailed, steps: [("neutral_face", 1, "fail", ["DS_QG_002"])])
        await e.refreshVerdicts()
        XCTAssertEqual(e.status(s), .needsRepeat(steps: [.neutralFace], reasons: [.dsQG002]))
        XCTAssertEqual(notifier.texts.count, 1)
        XCTAssertEqual(e.recaptureAttempt(sessionId: s, step: .neutralFace), 2)
    }

    func testServerRepeatAfterTwoHoursClosesAsAcquisitionFailure() async throws {
        let e = makeEngine()
        let s = try enqueue(e, [try artefact()], capturedAt: now.addingTimeInterval(-2 * 3600 - 1))
        await e.drain()
        api.scanResponse = try scan(status: .qualityFailed, steps: [("neutral_face", 1, "fail", ["DS_QG_002"])])
        await e.refreshVerdicts()
        XCTAssertEqual(e.status(s), .closed(notice: NurseCopy.acquisitionFailure))
        XCTAssertTrue(notifier.texts.isEmpty, "never ask for a repeat that cannot be offered")
        XCTAssertThrowsError(try e.enqueueRecapture(sessionId: s, steps: [.neutralFace], reason: "DS_QG_002",
                                                    artefacts: [try artefact()])) {
            XCTAssertEqual($0 as? UploadEngineError, .repeatWindowExpired)
        }
    }

    func testOfferedRepeatExpiresWhileWaiting() async throws {
        let e = makeEngine()
        let s = try enqueue(e, [try artefact()], capturedAt: now.addingTimeInterval(-3600))
        await e.drain()
        api.scanResponse = try scan(status: .qualityFailed, steps: [("neutral_face", 1, "fail", [])])
        await e.refreshVerdicts()
        XCTAssertEqual(e.status(s), .needsRepeat(steps: [.neutralFace], reasons: []))
        now = now.addingTimeInterval(3601)
        XCTAssertEqual(e.status(s), .closed(notice: NurseCopy.acquisitionFailure))
        e.expireRepeatWindows()
        XCTAssertEqual(e.record(s)?.verdict, .closed)
    }

    func testRecaptureRequiresWrappedKeys() async throws {
        let e = makeEngine()
        let s = try enqueue(e, [try artefact()])
        var bare = try artefact()
        bare = ArtefactUpload(step: bare.step, attempt: 2, kind: bare.kind, deviceVerdict: .accept,
                              sealed: SealedArtefact(keyId: bare.sealed.keyId, path: bare.sealed.path,
                                                     sha256OfPlaintext: "p", sizeBytes: 1, sha256OfCiphertext: "c",
                                                     sealedSizeBytes: 300))
        XCTAssertThrowsError(try e.enqueueRecapture(sessionId: s, steps: [.neutralFace], reason: "x", artefacts: [bare])) {
            XCTAssertEqual($0 as? UploadEngineError, .kmsKeyMissing)
        }
    }
}
