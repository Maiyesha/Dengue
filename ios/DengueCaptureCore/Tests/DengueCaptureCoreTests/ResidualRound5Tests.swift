import XCTest
import Foundation
@testable import DengueCaptureCore

/// Residual fix round 5: a repeat hold that exists only in memory must always report `.holdFailed`, so the app's
/// backoff keeps retrying; an open (still running) repeat hold is never submitted.
final class ResidualRound5Tests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    var keys: InMemoryKeyStore!
    var clock: TestClock!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr5-\(UUID().uuidString)")
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

    func engine(_ store: FlakyOutboxStore = FlakyOutboxStore()) -> UploadEngine {
        UploadEngine(outbox: Outbox(store: store, clock: clock), api: FakeUploadAPI(log: EventLog()),
                     sessions: InMemoryUploadSessionStore(), keys: keys, uploader: FakePartUploader(log: EventLog()),
                     notifier: FakeNotifier(), now: { [clock] in clock!.wallNow })
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
                             artefacts: arts.map {
                                 ArtefactUpload(step: CaptureStepName(rawValue: $0.step.rawValue)!, attempt: $0.attempt,
                                                kind: $0.kind, deviceVerdict: .accept, sealed: $0.sealed)
                             })
    }

    // MARK: 1. .holdFailed is never masked by the session record's .held

    func testUnpersistedRepeatHoldIsNotMaskedBySessionHold() throws {
        let session = UUID()
        let st = TestHeldStore(try FileHeldHandoffStore(directory: heldDir, keys: keys))
        let svc = CaptureHandoffService(store: st, keys: keys, keyWrapper: FakeKeyWrapper())
        let p = PendingHandoff(sessionId: session, patientId: UUID(), maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                               offline: false, protocolVersion: "phase-a-1",
                               attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)], vitals: [],
                               artefacts: try sealed(.neutralFace), metadata: nil, isOpen: false)
        XCTAssertEqual(svc.submit(p, engine: nil), .held(.uploadNotConfigured))   // session record held on disk
        st.failSave = true
        try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                 reason: "DS_QG_002", accepted: [.neutralFace], sealed: try sealed(.neutralFace, attempt: 2),
                                 isOpen: false)
        XCTAssertEqual(svc.retryHeld(engine: nil)[session], .holdFailed(.uploadNotConfigured),
                       "the in-memory repeat hold keeps the backoff running")
    }

    // MARK: 2. engine present, repeat-hold save fails

    func testHandOffWithEngineAndFailedHoldSaveReportsHoldFailed() throws {
        let session = UUID()
        let obStore = FlakyOutboxStore()
        let e = engine(obStore)
        try engineOwning(e, session, try sealed(.neutralFace))
        let st = TestHeldStore(try FileHeldHandoffStore(directory: heldDir, keys: keys))
        let svc = CaptureHandoffService(store: st, keys: keys, keyWrapper: FakeKeyWrapper())
        obStore.failKinds = [.recapture]   // the recapture cannot be queued: the repeat is held
        st.failSave = true                 // ... and the hold cannot be persisted
        let outcome = svc.submitRepeat(sessionId: session, reason: "DS_QG_002", accepted: [.neutralFace],
                                       sealed: try sealed(.neutralFace, attempt: 2), engine: e)
        XCTAssertEqual(String(describing: outcome), "holdFailed", "only in memory: the caller must start the backoff")
        XCTAssertEqual(svc.retryHeld(engine: e)[session], .holdFailed(.enqueueFailed("REPEAT_PENDING")))
    }

    // MARK: 3. an open repeat hold is never submitted

    func testOpenInMemoryRepeatHoldIsNotSubmittedMidFlow() throws {
        let session = UUID()
        let e = engine()
        try engineOwning(e, session, try sealed(.neutralFace))
        let st = TestHeldStore(try FileHeldHandoffStore(directory: heldDir, keys: keys))
        let svc = CaptureHandoffService(store: st, keys: keys, keyWrapper: FakeKeyWrapper())
        st.failSave = true
        try svc.checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                 reason: "DS_QG_002", accepted: [.neutralFace], sealed: try sealed(.neutralFace, attempt: 2))
        _ = svc.retryHeld(engine: e)
        XCTAssertEqual(e.record(session)?.artefacts.count, 3, "the repeat is still recording: not submitted")
    }
}
