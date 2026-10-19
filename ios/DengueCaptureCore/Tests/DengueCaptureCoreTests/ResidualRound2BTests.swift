import XCTest
import Foundation
@testable import DengueCaptureCore

/// Residual fix round 2, new core API: I1 camera ownership, I3 single destroy funnel, I4 repeat-pending records,
/// M3 clips never revive an obsolete record.
final class ResidualRound2BTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var dir: URL!
    var keys: InMemoryKeyStore!
    var clock: TestClock!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rr2b-\(UUID().uuidString)")
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

    func engine() -> UploadEngine {
        UploadEngine(outbox: Outbox(store: FlakyOutboxStore(), clock: clock), api: FakeUploadAPI(log: EventLog()),
                     sessions: InMemoryUploadSessionStore(), keys: keys, uploader: FakePartUploader(log: EventLog()),
                     notifier: FakeNotifier(), now: { [clock] in clock!.wallNow })
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
                             artefacts: arts.map {
                                 ArtefactUpload(step: CaptureStepName(rawValue: $0.step.rawValue)!, attempt: $0.attempt,
                                                kind: $0.kind, deviceVerdict: .accept, sealed: $0.sealed)
                             })
    }

    func service() throws -> CaptureHandoffService {
        CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                              keyWrapper: FakeKeyWrapper())
    }

    // MARK: I1 camera ownership

    func testOnlyTheCoordinatorThatOwnsTheCameraMayStopIt() {
        let camera = CameraOwnership()
        let root = UUID(), repeatFlow = UUID()
        XCTAssertTrue(camera.mayStop(root), "nobody owns it: stopping is harmless")
        camera.claim(root)
        camera.claim(repeatFlow)   // the repeat flow starts positioning / recording on the shared camera
        XCTAssertFalse(camera.mayStop(root), "the root flow must not stop the repeat flow's recording")
        XCTAssertFalse(camera.release(root))
        XCTAssertTrue(camera.mayStop(repeatFlow))
        XCTAssertTrue(camera.release(repeatFlow))
        XCTAssertNil(camera.owner)
        XCTAssertTrue(camera.mayStop(root))
    }

    // MARK: I3 destroy funnel

    func testDataDestructionPolicyTable() {
        let rows: [(DestroyCause, Bool)] = [
            (.createScanRejected(.duplicateRecent), true),
            (.createScanRejected(.invalid(code: "DS_VALIDATION_001")), true),
            (.createScanRejected(.invalid(code: "DS_NOT_FOUND")), true),
            (.createScanRejected(.invalid(code: "DS_FOO_999")), false),
            (.createScanRejected(.needsRepeat([])), false),
            (.createScanRejected(.networkRestricted(httpStatus: 403)), false),
            (.consentStop(code: "DS_REG_001"), true),
            (.consentStop(code: "DS_REG_002"), true),
            (.consentStop(code: "DS_REG_901"), false),
            (.quarantineResume, true),
            (.allVerified, true),
            (.repeatWindowExpired, true),
            (.recaptureExhausted, true),
        ]
        for (cause, expected) in rows { XCTAssertEqual(DataDestructionPolicy.permits(cause), expected, "\(cause)") }
    }

    /// Fails if any engine path destroys keys or files outside the guarded `destroyLocal(_:cause:)` funnel.
    func testEveryEngineDestroyPathGoesThroughTheGuardedFunnel() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DengueCaptureCore/Upload/UploadEngine.swift").path
        let src = try String(contentsOfFile: path, encoding: .utf8)
        func count(_ s: String) -> Int { src.components(separatedBy: s).count - 1 }
        XCTAssertEqual(count("keys.destroy("), 1, "only the funnel destroys keys")
        XCTAssertEqual(count("removeItem("), 1, "only the funnel deletes sealed files")
        XCTAssertEqual(count("outbox.quarantine("), count("outbox.quarantine(sessionId: sessionId, keys: keys, sealedPaths: [])"),
                       "the outbox never destroys on the engine's behalf")
        for line in src.components(separatedBy: .newlines) where line.contains("destroyLocal(") {
            XCTAssertTrue(line.contains("cause:"), "every funnel call names its cause: \(line)")
        }
        XCTAssertTrue(src.contains("DataDestructionPolicy.permits(cause)"))
    }

    // MARK: I4 repeat-pending records

    func testRepeatCheckpointSurvivesAKillAndIsKeptByTheSweep() throws {
        let session = UUID()
        let e = engine()
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        try service().checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                       reason: "DS_QG_002", accepted: [.neutralFace], sealed: repeatArts)
        // Killed under the sign-in overlay; relaunch.
        let svc = try service()
        try svc.closeOpen()
        let report = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir, engine: e)
        XCTAssertFalse(report.sealedSweepSkipped)
        XCTAssertTrue(repeatArts.allSatisfy(alive), "the repeat-pending record references them")
        let held = try XCTUnwrap(try FileHeldHandoffStore(directory: heldDir, keys: keys).load(PendingHandoff.repeatSlot(for: session)))   // round 4: own slot
        XCTAssertEqual(held.stage, .repeatPending)
        XCTAssertEqual(held.repeatReason, "DS_QG_002")
        XCTAssertEqual(held.repeatAcceptedSteps, [.neutralFace])
    }

    func testRetryRoutesARepeatPendingRecordToSubmitRepeat() throws {
        let session = UUID()
        let e = engine()
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now)
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        try service().checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                       reason: "DS_QG_002", accepted: [.neutralFace], sealed: repeatArts)
        let svc = try service()
        try svc.closeOpen()
        XCTAssertEqual(svc.retryHeld(engine: e), [session: .enqueued])
        XCTAssertEqual(e.record(session)?.artefacts.count, 6, "queued as a recapture")
        XCTAssertNil(try FileHeldHandoffStore(directory: heldDir, keys: keys).load(session), "removed once queued")
        XCTAssertTrue(repeatArts.allSatisfy(alive))
    }

    func testRepeatPendingPastTheWindowIsDestroyedAndRemoved() throws {
        let session = UUID()
        let e = engine()
        try engineOwning(e, session, try sealed(.neutralFace), capturedAt: now.addingTimeInterval(-3 * 3600))
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        try service().checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                       reason: "DS_QG_002", accepted: [.neutralFace], sealed: repeatArts)
        let svc = try service()
        try svc.closeOpen()
        _ = svc.retryHeld(engine: e)
        XCTAssertNil(try FileHeldHandoffStore(directory: heldDir, keys: keys).load(session))
        XCTAssertTrue(repeatArts.allSatisfy { !alive($0) })
    }

    func testRepeatPendingWithoutAnEngineIsKept() throws {
        let session = UUID()
        let repeatArts = try sealed(.neutralFace, attempt: 2)
        try service().checkpointRepeat(sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                       reason: "DS_QG_002", accepted: [.neutralFace], sealed: repeatArts)
        let svc = try service()
        try svc.closeOpen()
        _ = svc.retryHeld(engine: nil)
        XCTAssertNotNil(try FileHeldHandoffStore(directory: heldDir, keys: keys).load(PendingHandoff.repeatSlot(for: session)))   // round 4: own slot
        XCTAssertTrue(repeatArts.allSatisfy(alive))
    }

    // MARK: M3 a clip never revives an obsolete record

    func testClipForAnObsoleteRecordStartsAFreshInterruptedOnlyRecord() throws {
        let session = UUID()
        let e = engine()
        let owned = try sealed(.neutralFace, attempt: 2)
        try engineOwning(e, session, owned, capturedAt: now)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let stale = PendingHandoff(sessionId: session, patientId: nil, maskedCode: "\u{2022}\u{2022}417", capturedAt: now,
                                   offline: false, protocolVersion: "phase-a-1",
                                   attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)], vitals: [],
                                   artefacts: owned, metadata: nil, isOpen: false)
        try store.save(stale)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let clip = InterruptedClip(step: .fingertipPPG, attempt: 1, recordedSeconds: 5, interruptedAt: now,
                                   artefacts: try sealed(.fingertipPPG))
        try svc.keepInterruptedClip(clip, sessionId: session, maskedCode: "\u{2022}\u{2022}417", capturedAt: now, engine: e)
        let kept = try XCTUnwrap(try store.load(session))
        XCTAssertEqual(kept.stage, .interruptedOnly)
        XCTAssertTrue(kept.artefacts.isEmpty)
        XCTAssertTrue(kept.attempts.isEmpty)
        XCTAssertEqual(kept.interruptedClips, [clip])
        XCTAssertEqual(try svc.heldSummaries(engine: e).first?.isInterruptedOnly, true)
        XCTAssertTrue(owned.allSatisfy(alive), "engine-owned artefacts untouched")
    }
}
