import XCTest
import Foundation
@testable import DengueCaptureCore

/// R-3: a server-requested repeat used to checkpoint a standalone pending hand-off under the original session
/// (patientId nil) that `handOffRepeat` never removed: after a relaunch it was held as HANDOFF_PATIENT_UNKNOWN,
/// shown as waiting, got the 7-day warning and pointed at keys the engine may already have destroyed.
final class RepeatHandoffTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    var keys: InMemoryKeyStore!
    var clock: TestClock!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("r3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keys = InMemoryKeyStore()
        clock = TestClock(wall: now)
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

    func engine() -> UploadEngine {
        UploadEngine(outbox: Outbox(store: FlakyOutboxStore(), clock: clock), api: FakeUploadAPI(log: EventLog()),
                     sessions: InMemoryUploadSessionStore(), keys: keys, uploader: FakePartUploader(log: EventLog()),
                     notifier: FakeNotifier(), now: { [clock] in clock!.wallNow })
    }

    /// The engine owns `session` with `artefacts` (as after a hand-off, or after `enqueueRecapture`).
    func engineOwning(_ e: UploadEngine, _ session: UUID, _ artefacts: [SealedStepArtefact], capturedAt: Date) throws {
        let uploads = artefacts.map {
            ArtefactUpload(step: CaptureStepName(rawValue: $0.step.rawValue)!, attempt: $0.attempt, kind: $0.kind,
                           deviceVerdict: .accept, sealed: $0.sealed)
        }
        let req = CreateScanRequest(
            clientSessionId: session, patientId: UUID(), capturedAt: capturedAt, offline: false, protocolVersion: "1",
            captureSteps: [.neutralFace], deviceAttempts: [],
            metadata: ScanMetadata(cameraModel: "iPhone", frameRate: 30, resolution: "1920x1080", exposure: 0.01,
                                   distanceCm: 40, angleDeg: 2, lightingLux: 300, ambientTempC: nil,
                                   ambientHumidityPct: nil, mount: "holder", lightingType: "overhead",
                                   exposureDurationMs: 10))
        try e.enqueueSession(sessionId: session, participantCode: "DS-2026-00417", createScan: req, scanId: nil,
                             artefacts: uploads)
    }

    /// What the repeat flow used to checkpoint: the original session id, no patient id.
    func staleRepeatCheckpoint(_ session: UUID, _ artefacts: [SealedStepArtefact], capturedAt: Date) -> PendingHandoff {
        PendingHandoff(sessionId: session, patientId: nil, maskedCode: NurseCopy.maskedStudyID("DS-2026-00417"),
                       capturedAt: capturedAt, offline: false, protocolVersion: "phase-a-1",
                       attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)], vitals: [],
                       artefacts: artefacts, metadata: nil, isOpen: true)
    }

    // MARK: repeat hand-off

    func testRepeatHandOffLeavesNoHeldRecord() throws {
        let session = UUID()
        let e = engine()
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let rejected = try sealed(.fingertipPPG, attempt: 2)   // not accepted on the device: never uploaded

        XCTAssertEqual(svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                        sealed: repeatArts + rejected, engine: e), .enqueued)
        XCTAssertNil(try store.load(session), "no standalone hand-off of the original session")
        XCTAssertTrue(try svc.heldSummaries().isEmpty)
        XCTAssertEqual(e.record(session)?.artefacts.count, 6)
        XCTAssertTrue(repeatArts.allSatisfy(alive), "the engine owns them now")
        XCTAssertTrue(rejected.allSatisfy { !alive($0) })
    }

    func testRepeatHandOffRemovesAStaleCheckpointOfTheOriginalSession() throws {
        let session = UUID()
        let e = engine()
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        try svc.checkpoint(staleRepeatCheckpoint(session, repeatArts, capturedAt: now))   // what the old flow wrote
        var stale = try XCTUnwrap(try store.load(session))
        stale.isOpen = false
        try store.save(stale)
        XCTAssertEqual(svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                        sealed: repeatArts, engine: e), .enqueued)
        XCTAssertNil(try store.load(session))
        XCTAssertTrue(repeatArts.allSatisfy(alive))
    }

    func testRepeatThatCannotBeQueuedDestroysItsArtefactsAndLeavesNoRecord() throws {
        let session = UUID()
        let e = engine()
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now.addingTimeInterval(-3 * 3600))
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        XCTAssertEqual(svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                        sealed: repeatArts, engine: e), .notQueued)   // 2 h window passed
        XCTAssertNil(try store.load(session))
        XCTAssertTrue(repeatArts.allSatisfy { !alive($0) })
    }

    func testInterruptedOnlyRecordsAreListedWithoutTheSevenDayWarning() throws {
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let clip = InterruptedClip(step: .neutralFace, attempt: 1, recordedSeconds: 3, interruptedAt: now,
                                   artefacts: try sealed(.neutralFace))
        try svc.keepInterruptedClip(clip, sessionId: UUID(), maskedCode: "\u{2022}\u{2022}417",
                                    capturedAt: now.addingTimeInterval(-8 * 86400))
        let s = try XCTUnwrap(try svc.heldSummaries().first)
        XCTAssertTrue(s.isInterruptedOnly)
        XCTAssertFalse(s.needsAction, "nothing to send")
        XCTAssertFalse(s.unsentTooLong(now: now), "never sent by design: no unsent warning")
    }

    // MARK: startup repair

    func testObsoleteRepeatRecordIsRemovedAtStartupWithoutTouchingEngineKeysOrFiles() throws {
        let session = UUID()
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let e = engine()
        try engineOwning(e, session, repeatArts, capturedAt: now)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        try CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
            .checkpoint(staleRepeatCheckpoint(session, repeatArts, capturedAt: now))

        // Relaunch.
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                        keyWrapper: FakeKeyWrapper())
        try svc.closeOpen()
        _ = svc.retryHeld(engine: e)
        XCTAssertNil(try store.load(session), "obsolete record removed")
        XCTAssertTrue(try svc.heldSummaries().isEmpty, "not listed as waiting")
        XCTAssertTrue(repeatArts.allSatisfy(alive), "engine-owned keys and files are untouched")
        XCTAssertEqual(e.record(session)?.artefacts.count, 3)
    }

    func testRecordWithUniqueArtefactsIsKept() throws {
        let session = UUID()
        let owned = try sealed(.neutralFace)
        let unique = try sealed(.fingertipPPG)
        let e = engine()
        try engineOwning(e, session, owned, capturedAt: now)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        try svc.checkpoint(staleRepeatCheckpoint(session, owned + unique, capturedAt: now))
        try svc.closeOpen()
        _ = svc.retryHeld(engine: e)
        XCTAssertNotNil(try store.load(session), "a record with artefacts the engine does not own is kept")
        XCTAssertTrue((owned + unique).allSatisfy(alive))
        XCTAssertEqual(try svc.heldSummaries().map { $0.sessionId }, [session])
    }

    func testRecordWithInterruptedClipsIsKept() throws {
        let session = UUID()
        let owned = try sealed(.neutralFace)
        let e = engine()
        try engineOwning(e, session, owned, capturedAt: now)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        var p = staleRepeatCheckpoint(session, owned, capturedAt: now)
        p.interruptedClips = [InterruptedClip(step: .fingertipPPG, attempt: 1, recordedSeconds: 4, interruptedAt: now,
                                              artefacts: try sealed(.fingertipPPG))]
        try svc.checkpoint(p)
        try svc.closeOpen()
        _ = svc.retryHeld(engine: e)
        XCTAssertNotNil(try store.load(session))
    }

    func testRecordWhoseSessionTheEngineDoesNotOwnIsKept() throws {
        let session = UUID()
        let arts = try sealed(.neutralFace)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        try svc.checkpoint(staleRepeatCheckpoint(session, arts, capturedAt: now))
        try svc.closeOpen()
        _ = svc.retryHeld(engine: engine())
        XCTAssertNotNil(try store.load(session), "patient unknown, but it holds the only copy: kept")
        XCTAssertTrue(arts.allSatisfy(alive))
    }

    func testSevenDayWarningIgnoresRemovedRecords() throws {
        let old = now.addingTimeInterval(-8 * 86400)
        let session = UUID()
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        let e = engine()
        try engineOwning(e, session, repeatArts, capturedAt: old)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        try svc.checkpoint(staleRepeatCheckpoint(session, repeatArts, capturedAt: old))
        try svc.closeOpen()
        _ = svc.retryHeld(engine: e)
        let warned = try svc.heldSummaries().filter { $0.unsentTooLong(now: now) }
        XCTAssertTrue(warned.isEmpty, "a removed record never carries the 7-day warning")
    }

    func testStaleRecordPointingAtDestroyedArtefactsIsRemoved() throws {
        // The engine already finished the session and destroyed its keys and files; the stale record's references
        // are gone too: nothing of its own is left on the phone.
        let session = UUID()
        let arts = try sealed(.neutralFace, attempt: 2)
        let e = engine()
        try engineOwning(e, session, [], capturedAt: now)   // engine owns the session (record only)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        try svc.checkpoint(staleRepeatCheckpoint(session, arts, capturedAt: now))
        for a in arts { try keys.destroy(id: a.sealed.keyId); try FileManager.default.removeItem(at: a.sealed.path) }
        try svc.closeOpen()
        _ = svc.retryHeld(engine: e)
        XCTAssertNil(try store.load(session))
    }
}
