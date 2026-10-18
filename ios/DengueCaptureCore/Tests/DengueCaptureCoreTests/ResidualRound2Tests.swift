import XCTest
import Foundation
@testable import DengueCaptureCore

/// Residual fix round 2 (independent review of R-1/R-2): I2 interrupted clips merged into the stored record,
/// I3 prefixed server codes on createScan never destroy data, M2 submitRepeat destroys only on its explicit causes.
final class ResidualRound2Tests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    var keys: InMemoryKeyStore!
    var clock: TestClock!
    var log: EventLog!
    var api: FakeUploadAPI!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keys = InMemoryKeyStore()
        clock = TestClock(wall: now)
        log = EventLog()
        api = FakeUploadAPI(log: log)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: helpers

    func sealed(_ step: CaptureStep, attempt: Int = 1) throws -> [SealedStepArtefact] {
        try FileManager.default.createDirectory(at: sealedDir, withIntermediateDirectories: true)
        let sealer = ArtefactSealer(keys: keys, wrapper: FakeKeyWrapper())
        return try [ArtefactKind.video, .roiTrace, .metadata].map { kind in
            let plain = dir.appendingPathComponent("\(UUID().uuidString).plain")
            try Data("\(step.rawValue)-\(kind.rawValue)".utf8).write(to: plain)
            let s = try CaptureHandoff.sealAndRemovePlaintext(
                input: plain, output: sealedDir.appendingPathComponent("\(UUID().uuidString).sealed"), sealer: sealer)
            return SealedStepArtefact(step: step, attempt: attempt, kind: kind, sealed: s)
        }
    }

    func alive(_ a: SealedStepArtefact) -> Bool {
        FileManager.default.fileExists(atPath: a.sealed.path.path) && (try? keys.key(id: a.sealed.keyId)) != nil
    }

    func engine(_ store: OutboxStore = FlakyOutboxStore()) -> (UploadEngine, Outbox) {
        let ob = Outbox(store: store, clock: clock)
        return (UploadEngine(outbox: ob, api: api, sessions: InMemoryUploadSessionStore(), keys: keys,
                             uploader: FakePartUploader(log: log), notifier: FakeNotifier(), partSize: 1000,
                             now: { [clock] in clock!.wallNow }), ob)
    }

    func metadata() -> ScanMetadata {
        ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01, distanceCm: 40,
                     angleDeg: 2, lightingLux: 300, ambientTempC: nil, ambientHumidityPct: nil, mount: "holder",
                     lightingType: "overhead", exposureDurationMs: 10)
    }

    func uploads(_ arts: [SealedStepArtefact]) -> [ArtefactUpload] {
        arts.map { ArtefactUpload(step: CaptureStepName(rawValue: $0.step.rawValue)!, attempt: $0.attempt, kind: $0.kind,
                                  deviceVerdict: .accept, sealed: $0.sealed) }
    }

    @discardableResult
    func enqueue(_ e: UploadEngine, _ arts: [SealedStepArtefact], capturedAt: Date, offline: Bool = true) throws -> UUID {
        let s = UUID()
        let req = CreateScanRequest(clientSessionId: s, patientId: UUID(), capturedAt: capturedAt, offline: offline,
                                    protocolVersion: "1", captureSteps: [.neutralFace], deviceAttempts: [],
                                    metadata: metadata())
        try e.enqueueSession(sessionId: s, participantCode: "DS-2026-00417", createScan: req, scanId: nil,
                             artefacts: uploads(arts))
        return s
    }

    func envelope(_ code: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"m","detail":{},"request_id":"r","trace_id":"t","timestamp":"2026-01-01T00:00:00Z"}}"#.utf8)
    }

    func captureMeta() -> CaptureMetadata {
        CaptureMetadata(deviceModel: "iPhone15,2", step: .neutralFace, attempt: 1, cameraRole: .frontFace, fps: 30,
                        resolution: "1080x1920", exposureDurationMs: 10, iso: 200, torchLevel: 0, distanceCm: 45,
                        angleDeg: 3, lux: 320, mount: "holder", lightingType: "overhead", ambientTempC: nil,
                        ambientHumidityPct: nil, durationSeconds: 40, frameCount: 1200, videoCodec: "hevc",
                        videoAverageBitRate: 25_000_000)
    }

    func pending(_ session: UUID, _ arts: [SealedStepArtefact]) -> PendingHandoff {
        PendingHandoff(sessionId: session, patientId: UUID(), maskedCode: NurseCopy.maskedStudyID("DS-2026-00417"),
                       capturedAt: now, offline: false, protocolVersion: "phase-a-1",
                       attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)], vitals: [],
                       artefacts: arts, metadata: captureMeta(), isOpen: true)
    }

    // MARK: I3 prefixed codes on createScan

    func testUnrecognisedQGCodeOnCreateScanForOldOfflineCaptureKeepsData() async throws {
        let (e, ob) = engine()
        let arts = try sealed(.neutralFace)
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope("DS_QG_123"), status: 422)]
        let s = try enqueue(e, arts, capturedAt: now.addingTimeInterval(-3 * 3600))
        await e.drain()
        XCTAssertTrue(arts.allSatisfy(alive), "a DS_QG_* on createScan never destroys data")
        XCTAssertNotEqual(e.record(s)?.verdict, .closed)
        XCTAssertEqual(try ob.items(sessionId: s).first { $0.kind == .createScan }?.status, .pending)
    }

    func testOtherPrefixedCodesOnCreateScanKeepData() async throws {
        for (code, status) in [("DS_SEG_9", 422), ("DS_RPPG_42", 422), ("DS_REG_901", 451), ("DS_QG_099", 422)] {
            let (e, _) = engine()
            let arts = try sealed(.neutralFace)
            api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope(code), status: status)]
            let s = try enqueue(e, arts, capturedAt: now.addingTimeInterval(-3 * 3600))
            await e.drain()
            XCTAssertTrue(arts.allSatisfy(alive), code)
            XCTAssertEqual(e.record(s)?.verdict, .uploading, code)
        }
    }

    func testConsentStopOnCreateScanStillQuarantines() async throws {
        let (e, _) = engine()
        let arts = try sealed(.neutralFace)
        api.createScanErrors = [URLSessionDengueAPI.decodeError(data: envelope("DS_REG_001"), status: 451)]
        let s = try enqueue(e, arts, capturedAt: now)
        await e.drain()
        XCTAssertEqual(e.record(s)?.verdict, .quarantined)
        XCTAssertTrue(arts.allSatisfy { !alive($0) }, "a consent stop is the intended destroy exception")
    }

    func testUnrecognisedRegCodeOnAnArtefactRouteKeepsData() async throws {
        let (e, _) = engine()
        let arts = try sealed(.neutralFace)
        api.declareErrors = [URLSessionDengueAPI.decodeError(data: envelope("DS_REG_977"), status: 451)]
        let s = try enqueue(e, arts, capturedAt: now)
        await e.drain()
        XCTAssertTrue(arts.allSatisfy(alive))
        XCTAssertNotEqual(e.record(s)?.verdict, .quarantined)
    }

    // MARK: I2 clips merged into the stored record

    func testClipMergedAfterThePendingWasBuiltSurvivesEnqueue() throws {
        let session = UUID()
        let accepted = try sealed(.neutralFace)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let p = pending(session, accepted)
        try svc.checkpoint(p)
        // The clip finishes sealing after the hand-off's PendingHandoff was built and is merged into the record.
        let clipArts = try sealed(.fingertipPPG)
        let clip = InterruptedClip(step: .fingertipPPG, attempt: 1, recordedSeconds: 7, interruptedAt: now, artefacts: clipArts)
        try svc.keepInterruptedClip(clip, sessionId: session, maskedCode: p.maskedCode, capturedAt: now)
        let (e, _) = engine()
        XCTAssertEqual(svc.submit(p, engine: e), .enqueued)
        XCTAssertEqual(try store.load(session)?.interruptedClips, [clip], "the stored clip is not dropped")
        _ = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir, engine: e)
        XCTAssertTrue(clipArts.allSatisfy(alive))
        XCTAssertTrue(accepted.allSatisfy(alive))
    }

    func testClipMergedAfterThePendingWasBuiltSurvivesHold() throws {
        let session = UUID()
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let p = pending(session, try sealed(.neutralFace))
        try svc.checkpoint(p)
        let clip = InterruptedClip(step: .fingertipPPG, attempt: 1, recordedSeconds: 7, interruptedAt: now,
                                   artefacts: try sealed(.fingertipPPG))
        try svc.keepInterruptedClip(clip, sessionId: session, maskedCode: p.maskedCode, capturedAt: now)
        XCTAssertEqual(svc.submit(p, engine: nil), .held(.uploadNotConfigured))
        XCTAssertEqual(try store.load(session)?.interruptedClips, [clip])
    }

    // MARK: M2 submitRepeat destroys only on its explicit causes

    func testSubmitRepeatNeverDestroysArtefactsTheEngineAlreadyTook() throws {
        let obStore = FlakyOutboxStore()
        let (e, _) = engine(obStore)
        let session = try enqueue(e, try sealed(.neutralFace), capturedAt: now, offline: false)
        obStore.failKinds = [.recapture]   // enqueueRecapture adds the artefacts to the record, then the outbox fails
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                        keyWrapper: FakeKeyWrapper())
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let outcome = svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                       sealed: repeatArts, engine: e)
        XCTAssertNotEqual(outcome, .notQueued)
        XCTAssertTrue(repeatArts.allSatisfy(alive), "the engine record references them")
    }

    func testSubmitRepeatHoldsOnAnUnexpectedError() throws {
        let (e, _) = engine()
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let session = UUID()   // unknown to the engine (e.g. its record could not be read)
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let outcome = svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                       sealed: repeatArts, engine: e)
        XCTAssertNotEqual(outcome, .notQueued)
        XCTAssertTrue(repeatArts.allSatisfy(alive))
        XCTAssertNotNil(try store.load(PendingHandoff.repeatSlot(for: session)), "held for retry")
    }
}
