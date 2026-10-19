import XCTest
import Foundation
@testable import DengueCaptureCore

/// Residual fix round 4: repeat holds have their own durable slot (`PendingHandoff.repeatSlot(for:)`) and memory
/// key, separate from the session's own hand-off record; a second repeat unions into the repeat hold; a mixed
/// taken + new batch is one recapture; a repeat hold that cannot be saved is kept in memory and retried.
final class ResidualRound4Tests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    var keys: InMemoryKeyStore!
    var clock: TestClock!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr4-\(UUID().uuidString)")
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

    func engine(_ store: FlakyOutboxStore = FlakyOutboxStore()) -> (UploadEngine, Outbox) {
        let ob = Outbox(store: store, clock: clock)
        return (UploadEngine(outbox: ob, api: FakeUploadAPI(log: EventLog()), sessions: InMemoryUploadSessionStore(),
                             keys: keys, uploader: FakePartUploader(log: EventLog()), notifier: FakeNotifier(),
                             now: { [clock] in clock!.wallNow }), ob)
    }

    func uploads(_ arts: [SealedStepArtefact], attempt: Int? = nil) -> [ArtefactUpload] {
        arts.map { ArtefactUpload(step: CaptureStepName(rawValue: $0.step.rawValue)!, attempt: attempt ?? $0.attempt,
                                  kind: $0.kind, deviceVerdict: .accept, sealed: $0.sealed) }
    }

    func engineOwning(_ e: UploadEngine, _ session: UUID, _ arts: [SealedStepArtefact]) throws {
        let req = CreateScanRequest(
            clientSessionId: session, patientId: UUID(), capturedAt: now, offline: false, protocolVersion: "1",
            captureSteps: [.neutralFace], deviceAttempts: [],
            metadata: ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01,
                                   distanceCm: 40, angleDeg: 2, lightingLux: 300, ambientTempC: nil,
                                   ambientHumidityPct: nil, mount: "holder", lightingType: "overhead",
                                   exposureDurationMs: 10))
        try e.enqueueSession(sessionId: session, participantCode: "DS-2026-00417", createScan: req, scanId: nil,
                             artefacts: uploads(arts))
    }

    func sessionHold(_ session: UUID, _ arts: [SealedStepArtefact], stage: PendingHandoff.Stage) -> PendingHandoff {
        PendingHandoff(sessionId: session, patientId: UUID(), maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                       offline: false, protocolVersion: "phase-a-1",
                       attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)], vitals: [],
                       artefacts: arts, metadata: nil, isOpen: false, stage: stage)
    }

    func count(_ ob: Outbox, _ s: UUID, _ k: OutboxKind) throws -> Int { try ob.items(sessionId: s).filter { $0.kind == k }.count }

    // MARK: 1. separate slots

    func testSessionHoldAndRepeatHoldCoexistAndProcessingOneNeverDropsTheOther() throws {
        let session = UUID()
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let sessionArts = try sealed(.neutralFace)
        // The session's own hand-off is held (no upload engine yet).
        XCTAssertEqual(svc.submit(sessionHold(session, sessionArts, stage: .session), engine: nil), .held(.uploadNotConfigured))
        let repeatArts = try sealed(.fingertipPPG, attempt: 2)
        try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                 reason: "DS_QG_002", accepted: [.fingertipPPG], sealed: repeatArts, isOpen: false)
        XCTAssertEqual(try store.load(session)?.artefacts, sessionArts, "the session record is untouched")
        XCTAssertEqual(try store.load(PendingHandoff.repeatSlot(for: session))?.artefacts, repeatArts)
        // Processing the session hold again (still no engine) keeps the repeat hold, and vice versa.
        _ = svc.retryHeld(engine: nil)
        XCTAssertNotNil(try store.load(session))
        XCTAssertNotNil(try store.load(PendingHandoff.repeatSlot(for: session)))
        XCTAssertEqual(try svc.heldSummaries().filter { $0.sessionId == session }.count, 2)
        XCTAssertEqual(Set(try svc.heldSummaries().map { $0.slotId }).count, 2, "distinct rows")
        // A nurse discard of the repeat row removes only the repeat hold.
        try svc.discard(sessionId: session, reason: .nurseDiscard, engine: nil, repeatHold: true)
        XCTAssertNil(try store.load(PendingHandoff.repeatSlot(for: session)))
        XCTAssertNotNil(try store.load(session))
        XCTAssertTrue(repeatArts.allSatisfy { !alive($0) })
        XCTAssertTrue(sessionArts.allSatisfy(alive))
    }

    func testRepeatCheckpointsDurablyWhileAnEngineOwnedRecordExistsAndSurvivesKillAndSweep() throws {
        let session = UUID()
        let (e, _) = engine()
        let owned = try sealed(.neutralFace)
        try engineOwning(e, session, owned)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        try store.save(sessionHold(session, owned, stage: .engineOwned))
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        try CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
            .checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                              reason: "DS_QG_002", accepted: [.neutralFace], sealed: repeatArts)
        XCTAssertEqual(try store.load(session)?.stage, .engineOwned, "the session record is not overwritten")
        // Kill; relaunch: close open, sweep.
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                        keyWrapper: FakeKeyWrapper())
        try svc.closeOpen()
        let report = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir, engine: e)
        XCTAssertFalse(report.sealedSweepSkipped)
        XCTAssertTrue(repeatArts.allSatisfy(alive), "repeat-hold artefacts are referenced")
        XCTAssertEqual(try store.load(PendingHandoff.repeatSlot(for: session))?.stage, .repeatPending)
    }

    func testRecaptureOutboxFailureKeepsTheRepeatHoldBesideASessionRecordUntilRepaired() throws {
        let session = UUID()
        let obStore = FlakyOutboxStore()
        let (e, ob) = engine(obStore)
        let owned = try sealed(.neutralFace)
        try engineOwning(e, session, owned)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        try store.save(sessionHold(session, owned, stage: .engineOwned))
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        obStore.failKinds = [.recapture]
        XCTAssertEqual(svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                        sealed: repeatArts, engine: e), .held)
        XCTAssertNotNil(try store.load(PendingHandoff.repeatSlot(for: session)), "the repeat hold persists")
        obStore.failKinds = []
        _ = svc.retryHeld(engine: e)
        XCTAssertNil(try store.load(PendingHandoff.repeatSlot(for: session)), "repaired and settled")
        XCTAssertEqual(try count(ob, session, .recapture), 1)
        XCTAssertEqual(try count(ob, session, .declareArtefact), 6, "no stuck .uploading: the chains were queued")
    }

    // MARK: 2. a second repeat unions

    func testSecondRepeatUnionsIntoTheExistingRepeatHold() throws {
        let session = UUID()
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let first = try sealed(.neutralFace, attempt: 2)
        let second = try sealed(.fingertipPPG, attempt: 2)
        try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                 reason: "DS_QG_002", accepted: [.neutralFace], sealed: first, isOpen: false)
        try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                 reason: "DS_QG_005", accepted: [.fingertipPPG], sealed: second + first, isOpen: false)
        let held = try XCTUnwrap(try store.load(PendingHandoff.repeatSlot(for: session)))
        XCTAssertEqual(Set(held.artefacts.map { $0.sealed.keyId }), Set((first + second).map { $0.sealed.keyId }))
        XCTAssertEqual(held.artefacts.count, 6, "union by key id: no duplicates")
        XCTAssertEqual(Set(held.repeatAcceptedSteps ?? []), [.neutralFace, .fingertipPPG])
    }

    // MARK: 3. one recapture for a mixed batch

    func testMixedTakenAndNewBatchIsASingleRecapture() throws {
        let session = UUID()
        let obStore = FlakyOutboxStore()
        let (e, ob) = engine(obStore)
        try engineOwning(e, session, try sealed(.neutralFace))
        let taken = try sealed(.neutralFace, attempt: 2)
        obStore.failKinds = [.recapture]   // the engine record took them; no recapture item was written
        XCTAssertThrowsError(try e.enqueueRecapture(sessionId: session, steps: [.neutralFace], reason: "x",
                                                    artefacts: uploads(taken)))
        obStore.failKinds = []
        let mine = try sealed(.fingertipPPG, attempt: 1)
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                        keyWrapper: FakeKeyWrapper())
        XCTAssertEqual(svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace, .fingertipPPG],
                                        sealed: taken + mine, engine: e), .enqueued)
        XCTAssertEqual(try count(ob, session, .recapture), 1, "one recapture for the whole batch")
        let rec = try XCTUnwrap(e.record(session))
        XCTAssertEqual(rec.artefacts.count, 9)
        let identities = rec.artefacts.map { "\($0.step.rawValue)#\($0.attempt)#\($0.kind.rawValue)" }
        XCTAssertEqual(Set(identities).count, identities.count, "no attempt-number clash")
    }

    // MARK: 4. a repeat hold that cannot be saved

    func testRepeatHoldSaveFailureIsKeptInMemoryAndRetried() throws {
        let session = UUID()
        let st = TestHeldStore(try FileHeldHandoffStore(directory: heldDir, keys: keys))
        let svc = CaptureHandoffService(store: st, keys: keys, keyWrapper: FakeKeyWrapper())
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        st.failSave = true
        XCTAssertFalse(try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                                reason: "DS_QG_002", accepted: [.neutralFace], sealed: repeatArts,
                                                isOpen: false), "not persisted: kept in memory")
        let (e, _) = engine()
        _ = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir, engine: e)
        XCTAssertTrue(repeatArts.allSatisfy(alive), "an in-memory repeat hold is referenced")
        XCTAssertEqual(svc.retryHeld(engine: nil)[session], .holdFailed(.uploadNotConfigured), "the backoff keeps retrying")
        st.failSave = false
        _ = svc.retryHeld(engine: nil)
        XCTAssertNotNil(try st.load(PendingHandoff.repeatSlot(for: session)), "persisted on a later retry")
    }
}
