import XCTest
import Foundation
@testable import DengueCaptureCore

/// Residual fix round 3 (R-3 repeat path): submitRepeat is idempotent by sealed key id, never destroys what the
/// engine owns, enqueueRecapture repairs missing items, in-memory repeat holds are routed by stage, and a repeat
/// checkpoint never overwrites a session hand-off.
final class ResidualRound3Tests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    var keys: InMemoryKeyStore!
    var clock: TestClock!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keys = InMemoryKeyStore()
        clock = TestClock(wall: now)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

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

    func engine(_ store: FlakyOutboxStore) -> (UploadEngine, Outbox) {
        let ob = Outbox(store: store, clock: clock)
        return (UploadEngine(outbox: ob, api: FakeUploadAPI(log: EventLog()), sessions: InMemoryUploadSessionStore(),
                             keys: keys, uploader: FakePartUploader(log: EventLog()), notifier: FakeNotifier(),
                             now: { [clock] in clock!.wallNow }), ob)
    }

    func uploads(_ arts: [SealedStepArtefact], attempt: Int? = nil) -> [ArtefactUpload] {
        arts.map { ArtefactUpload(step: CaptureStepName(rawValue: $0.step.rawValue)!, attempt: attempt ?? $0.attempt,
                                  kind: $0.kind, deviceVerdict: .accept, sealed: $0.sealed) }
    }

    func engineOwning(_ e: UploadEngine, _ session: UUID, _ arts: [SealedStepArtefact], capturedAt: Date) throws {
        let req = CreateScanRequest(
            clientSessionId: session, patientId: UUID(), capturedAt: capturedAt, offline: false, protocolVersion: "1",
            captureSteps: [.neutralFace], deviceAttempts: [],
            metadata: ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01,
                                   distanceCm: 40, angleDeg: 2, lightingLux: 300, ambientTempC: nil,
                                   ambientHumidityPct: nil, mount: "holder", lightingType: "overhead",
                                   exposureDurationMs: 10))
        try e.enqueueSession(sessionId: session, participantCode: "DS-2026-00417", createScan: req, scanId: nil,
                             artefacts: uploads(arts))
    }

    func count(_ ob: Outbox, _ s: UUID, _ k: OutboxKind) throws -> Int { try ob.items(sessionId: s).filter { $0.kind == k }.count }

    // MARK: 1. idempotent by sealed key id

    func testRetryAfterKillBetweenEnqueueAndRecordRemovalDoesNotEnqueueTwice() throws {
        let session = UUID()
        let (e, ob) = engine(FlakyOutboxStore())
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                        keyWrapper: FakeKeyWrapper())
        try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                 reason: "DS_QG_002", accepted: [.neutralFace], sealed: repeatArts)
        try svc.keepInterruptedClip(InterruptedClip(step: .fingertipPPG, attempt: 1, recordedSeconds: 3, interruptedAt: now,
                                                    artefacts: try sealed(.fingertipPPG)),
                                    sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now)
        // The recapture was queued, then the app was killed before the repeat-pending record was settled.
        try e.enqueueRecapture(sessionId: session, steps: [.neutralFace], reason: "DS_QG_002",
                               artefacts: uploads(repeatArts, attempt: 2))
        let relaunched = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                               keyWrapper: FakeKeyWrapper())
        try relaunched.closeOpen()
        XCTAssertEqual(relaunched.retryHeld(engine: e)[session], .enqueued)
        XCTAssertEqual(e.record(session)?.artefacts.count, 6, "the same sealed files are never queued twice")
        XCTAssertEqual(try count(ob, session, .recapture), 1)
        XCTAssertEqual(try count(ob, session, .declareArtefact), 6)
        XCTAssertTrue(repeatArts.allSatisfy(alive))
        let kept = try XCTUnwrap(try FileHeldHandoffStore(directory: heldDir, keys: keys).load(session))
        XCTAssertEqual(kept.stage, .interruptedOnly, "settled; only the clip remains")
    }

    func testWindowExpiredNeverDestroysWhatTheEngineOwns() throws {
        let session = UUID()
        let (e, _) = engine(FlakyOutboxStore())
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let taken = try sealed(.neutralFace, attempt: 2)
        try e.enqueueRecapture(sessionId: session, steps: [.neutralFace], reason: "DS_QG_002",
                               artefacts: uploads(taken, attempt: 2))
        clock.wallNow = now.addingTimeInterval(3 * 3600)   // the window has passed since
        let notTaken = try sealed(.fingertipPPG, attempt: 2)
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                        keyWrapper: FakeKeyWrapper())
        _ = svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace, .fingertipPPG],
                             sealed: taken + notTaken, engine: e)
        XCTAssertTrue(taken.allSatisfy(alive), "the engine is still uploading these")
        XCTAssertTrue(notTaken.allSatisfy { !alive($0) }, "only the repeat's own artefacts are given up")
    }

    // MARK: 2. enqueueRecapture repairs missing items

    func testRecaptureWhoseOutboxWriteFailedIsRequeuedOnTheNextRetry() throws {
        let session = UUID()
        let obStore = FlakyOutboxStore()
        let (e, ob) = engine(obStore)
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        obStore.failKinds = [.recapture]
        XCTAssertEqual(svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                        sealed: repeatArts, engine: e, maskedCode: "\u{2022}\u{2022}417",
                                        capturedAt: now), .held)
        XCTAssertNotNil(try store.load(PendingHandoff.repeatSlot(for: session)), "kept for retry even though the engine record has the artefacts")
        obStore.failKinds = []
        XCTAssertEqual(svc.retryHeld(engine: e)[session], .enqueued)
        XCTAssertEqual(try count(ob, session, .recapture), 1)
        XCTAssertEqual(try count(ob, session, .declareArtefact), 6, "the recapture's chains were re-queued")
        XCTAssertEqual(try count(ob, session, .completeArtefact), 6)
        XCTAssertEqual(e.record(session)?.artefacts.count, 6)
        XCTAssertNil(try store.load(PendingHandoff.repeatSlot(for: session)))
    }

    func testEnqueueRecaptureIsIdempotentBySealedKeyId() throws {
        let session = UUID()
        let (e, ob) = engine(FlakyOutboxStore())
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        try e.enqueueRecapture(sessionId: session, steps: [.neutralFace], reason: "x", artefacts: uploads(repeatArts, attempt: 2))
        try e.enqueueRecapture(sessionId: session, steps: [.neutralFace], reason: "x", artefacts: uploads(repeatArts, attempt: 3))
        XCTAssertEqual(e.record(session)?.artefacts.count, 6)
        XCTAssertEqual(try count(ob, session, .recapture), 1)
        XCTAssertEqual(try count(ob, session, .uploadArtefact), 6)
    }

    // MARK: 4. in-memory repeat holds are routed by stage

    func testInMemoryRepeatHoldIsRoutedToSubmitRepeat() throws {
        let session = UUID()
        let obStore = FlakyOutboxStore()
        let (e, ob) = engine(obStore)
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let st = TestHeldStore(try FileHeldHandoffStore(directory: heldDir, keys: keys))
        let svc = CaptureHandoffService(store: st, keys: keys, keyWrapper: FakeKeyWrapper())
        obStore.failKinds = [.recapture]
        st.failSave = true   // the hold cannot be persisted: kept in memory
        XCTAssertNotEqual(svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                           sealed: repeatArts, engine: e), .notQueued)
        obStore.failKinds = []
        st.failSave = false
        XCTAssertEqual(svc.retryHeld(engine: e)[session], .enqueued, "routed to submitRepeat, not to process()")
        XCTAssertEqual(try count(ob, session, .recapture), 1)
        XCTAssertTrue(try svc.heldSummaries().isEmpty)
    }

    // MARK: 5. a repeat checkpoint never overwrites a session hand-off

    func testCheckpointRepeatDoesNotOverwriteASessionHandoff() throws {
        let session = UUID()
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let original = try sealed(.neutralFace)
        for stage in [PendingHandoff.Stage.session, .engineOwned] {
            let p = PendingHandoff(sessionId: session, patientId: UUID(), maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                   offline: false, protocolVersion: "phase-a-1",
                                   attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)], vitals: [],
                                   artefacts: original, metadata: nil, isOpen: false, stage: stage)
            try store.save(p)
            try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                     reason: "DS_QG_002", accepted: [.neutralFace], sealed: try sealed(.neutralFace, attempt: 2))
            let kept = try XCTUnwrap(try store.load(session))
            XCTAssertEqual(kept.stage, stage, "\(stage)")
            XCTAssertEqual(kept.artefacts, original, "\(stage)")
            XCTAssertEqual(kept.patientId, p.patientId, "\(stage)")
        }
    }
}
