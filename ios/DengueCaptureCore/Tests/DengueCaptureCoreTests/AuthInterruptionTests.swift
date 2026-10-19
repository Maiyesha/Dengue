import XCTest
import Foundation
@testable import DengueCaptureCore

/// R-2: the nurse's session expires while a step is recording. Sign-in is an overlay above the live flow:
/// - past the step minimum the recording is finished and evaluated like any completed recording;
/// - below it the partial clip is sealed and kept (encrypted, never uploaded) as an `interruptedClips` entry of the
///   session's held record, and the attempt is NOT consumed;
/// - the session's accepted attempts are checkpointed to the held store before re-auth.
final class AuthInterruptionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let okPreflight = Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8)
    var dir: URL!
    var keys: InMemoryKeyStore!
    var sealedDir: URL { dir.appendingPathComponent("sealed") }
    var heldDir: URL { dir.appendingPathComponent("held") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("r2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keys = InMemoryKeyStore()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: helpers

    func flowAtCapture() -> CaptureFlow {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-2026-00417", bedLabel: "B3")
        f.submitConsent(ConsentStatus(primaryResearch: true, consentVersion: "v1", currentVersion: "v1", withdrawn: false,
                                      captureAllowed: true, blockCode: nil, checkedAt: "2026-10-15T00:00:00Z"),
                        snapshotAt: now, online: true, now: now)
        f.giveAssent()
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        f.submitVitals([.hr: VitalEntry(text: "88")], now: now)
        return f
    }

    func meta(_ step: CaptureStep = .neutralFace, attempt: Int = 1, duration: Double = 40) -> CaptureMetadata {
        CaptureMetadata(deviceModel: "iPhone15,2", step: step, attempt: attempt, cameraRole: .frontFace, fps: 30,
                        resolution: "1080x1920", exposureDurationMs: 10, iso: 200, torchLevel: 0, distanceCm: 45,
                        angleDeg: 3, lux: 320, mount: "holder", lightingType: "overhead", ambientTempC: nil,
                        ambientHumidityPct: nil, durationSeconds: duration, frameCount: Int(duration * 30),
                        videoCodec: "hevc", videoAverageBitRate: 25_000_000)
    }

    func sealed(_ step: CaptureStep, attempt: Int = 1) throws -> [SealedStepArtefact] {
        try FileManager.default.createDirectory(at: sealedDir, withIntermediateDirectories: true)
        let sealer = ArtefactSealer(keys: keys)
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
        UploadEngine(outbox: Outbox(store: FlakyOutboxStore(), clock: TestClock()), api: FakeUploadAPI(log: EventLog()),
                     sessions: InMemoryUploadSessionStore(), keys: keys, uploader: FakePartUploader(log: EventLog()),
                     notifier: FakeNotifier())
    }

    func pending(_ session: UUID, attempts: [AttemptRecord], artefacts: [SealedStepArtefact],
                 clips: [InterruptedClip] = []) -> PendingHandoff {
        var p = PendingHandoff(sessionId: session, patientId: UUID(), maskedCode: NurseCopy.maskedStudyID("DS-2026-00417"),
                               capturedAt: now, offline: false, protocolVersion: "phase-a-1", attempts: attempts,
                               vitals: [], artefacts: artefacts, metadata: meta(), isOpen: true)
        p.interruptedClips = clips
        return p
    }

    // MARK: flow decision

    func testAuthRequiredPastMinimumFinishesAndIsEvaluatedAsANormalRecording() {
        let f = flowAtCapture()
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
        f.authRequired()
        XCTAssertTrue(f.authPending)
        XCTAssertFalse(f.canCapture, "nothing new may start under the sign-in overlay")
        // The recorder was stopped at 31 s (minimum 30 s): finish and evaluate.
        XCTAssertEqual(f.recordingStoppedForAuth(recordedSeconds: 31), .finishAndEvaluate(step: .neutralFace, attempt: 1))
        f.stepRecorded(duration: 31)
        f.verdict(.accept)
        XCTAssertEqual(f.attemptLog, [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)],
                       "consumed as a normal recording")
        XCTAssertEqual(f.machineState, .positioning(.fingertipPPG))
        f.authRestored()
        XCTAssertFalse(f.authPending)
        XCTAssertTrue(f.canCapture)
    }

    func testAuthRequiredBelowMinimumKeepsPartialClipAndDoesNotConsumeTheAttempt() {
        let f = flowAtCapture()
        f.positionedForTest()
        f.authRequired()
        XCTAssertEqual(f.recordingStoppedForAuth(recordedSeconds: 12), .keepPartialClip(step: .neutralFace, attempt: 1))
        XCTAssertTrue(f.attemptLog.isEmpty, "interruption does not use an attempt")
        XCTAssertEqual(f.machineState, .positioning(.neutralFace), "back to the same step")
        XCTAssertEqual(f.screen, .capture)
        // Under the overlay nothing can start.
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        // After re-auth the nurse records the same step again, as attempt 1.
        f.authRestored()
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
    }

    func testAuthRequiredWhileNotRecordingChangesNothingButBlocksStart() {
        let f = flowAtCapture()
        f.authRequired()
        XCTAssertEqual(f.recordingStoppedForAuth(recordedSeconds: 50), .notRecording)
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        f.authRestored()
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
    }

    func testFingertipMinimumIsTheStepsOwn() {
        let f = flowAtCapture()
        f.positionedForTest(); f.stepRecorded(duration: 40); f.verdict(.accept)
        f.positionedForTest()
        f.authRequired()
        XCTAssertEqual(f.recordingStoppedForAuth(recordedSeconds: 29.9), .keepPartialClip(step: .fingertipPPG, attempt: 1))
        XCTAssertEqual(f.attemptLog.count, 1)
    }

    // MARK: held store bookkeeping

    func testPartialClipIsPreservedInTheHeldRecordAndListed() throws {
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let session = UUID()
        let accepted = try sealed(.neutralFace)
        let partial = try sealed(.fingertipPPG)
        let clip = InterruptedClip(step: .fingertipPPG, attempt: 1, recordedSeconds: 12, interruptedAt: now,
                                   artefacts: partial)
        try svc.checkpointForReauth(pending(session, attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)],
                                            artefacts: accepted, clips: [clip]))
        let held = try XCTUnwrap(try store.load(session))
        XCTAssertEqual(held.interruptedClips, [clip])
        XCTAssertTrue(held.isOpen)
        let summary = try XCTUnwrap(try svc.heldSummaries().first { $0.sessionId == session })
        XCTAssertEqual(summary.interruptedClipCount, 1)
        XCTAssertEqual(NurseCopy.interruptedClipKept, "Interrupted recording kept on phone")
        XCTAssertTrue(NurseCopy.allStrings.contains(NurseCopy.interruptedClipKept))
        XCTAssertTrue(partial.allSatisfy(alive))
    }

    func testAcceptedAttemptsCheckpointIsWrittenBeforeReauthAndSurvivesAKill() throws {
        let f = flowAtCapture()
        f.positionedForTest(); f.stepRecorded(duration: 40); f.verdict(.accept)   // face accepted
        f.positionedForTest()                                                    // fingertip recording
        let session = UUID()
        let accepted = try sealed(.neutralFace)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        f.authRequired()
        // Checkpoint at once, before the recorder result or any re-auth.
        try svc.checkpointForReauth(pending(session, attempts: f.attemptLog, artefacts: accepted))
        XCTAssertEqual(try store.load(session)?.attempts, [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)])

        // The app is killed during sign-in: the next launch closes the open record and queues it.
        let reopened = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                             keyWrapper: FakeKeyWrapper())
        try reopened.closeOpen()
        let e = engine()
        XCTAssertEqual(reopened.retryHeld(engine: e), [session: .enqueued])
        XCTAssertEqual(e.record(session)?.artefacts.count, 3)
        XCTAssertTrue(accepted.allSatisfy(alive))
    }

    func testCheckpointWithNothingRecordedWritesNothing() throws {
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: nil)
        let session = UUID()
        try svc.checkpointForReauth(pending(session, attempts: [], artefacts: []))
        XCTAssertNil(try store.load(session))
    }

    func testInterruptedClipsSurviveReopenAndAreReferencedBySweep() throws {
        let session = UUID()
        let partial = try sealed(.neutralFace)
        let clip = InterruptedClip(step: .neutralFace, attempt: 1, recordedSeconds: 8, interruptedAt: now, artefacts: partial)
        do {
            let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                            keyWrapper: FakeKeyWrapper())
            try svc.checkpointForReauth(pending(session, attempts: [], artefacts: [], clips: [clip]))
        }
        let unrelated = try sealed(.fingertipPPG)   // orphan: must still be swept
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDir, keys: keys), keys: keys,
                                        keyWrapper: FakeKeyWrapper())
        try svc.closeOpen()
        XCTAssertEqual(try svc.heldSummaries().first?.interruptedClipCount, 1)
        let e = engine()
        _ = svc.retryHeld(engine: e)
        let report = svc.sweep(captureDirectory: dir.appendingPathComponent("capture"), sealedDirectory: sealedDir, engine: e)
        XCTAssertFalse(report.sealedSweepSkipped)
        XCTAssertTrue(partial.allSatisfy(alive), "interrupted clips are referenced, never swept")
        XCTAssertTrue(unrelated.allSatisfy { !alive($0) })
        XCTAssertNil(e.record(session), "interrupted clips are never uploaded")
        XCTAssertEqual(try svc.heldSummaries().first { $0.sessionId == session }?.interruptedClipCount, 1)
    }

    func testEnqueuedSessionKeepsItsInterruptedClipsHeldUntilNurseDiscard() throws {
        let session = UUID()
        let accepted = try sealed(.neutralFace) + sealed(.fingertipPPG)
        let partial = try sealed(.fingertipPPG, attempt: 2)
        let clip = InterruptedClip(step: .fingertipPPG, attempt: 2, recordedSeconds: 5, interruptedAt: now, artefacts: partial)
        let store = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        let svc = CaptureHandoffService(store: store, keys: keys, keyWrapper: FakeKeyWrapper())
        let e = engine()
        var p = pending(session, attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept),
                                            AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .accept)],
                        artefacts: accepted, clips: [clip])
        p.isOpen = false
        XCTAssertEqual(svc.submit(p, engine: e), .enqueued)
        XCTAssertEqual(e.record(session)?.artefacts.count, 6, "the clip is not uploaded")
        let kept = try XCTUnwrap(try store.load(session))
        XCTAssertEqual(kept.interruptedClips, [clip])
        XCTAssertTrue(kept.artefacts.isEmpty, "the engine owns the accepted artefacts")
        XCTAssertTrue(partial.allSatisfy(alive))
        // Retrying never re-enqueues a clip-only record.
        _ = svc.retryHeld(engine: e)
        XCTAssertNotNil(try store.load(session))
        // Only an explicit nurse discard deletes the clip; the engine's artefacts are untouched.
        try svc.discard(sessionId: session, reason: .nurseDiscard, engine: e)
        XCTAssertTrue(partial.allSatisfy { !alive($0) })
        XCTAssertTrue(accepted.allSatisfy(alive))
        XCTAssertNil(try store.load(session))
    }

    func testOlderHeldRecordsWithoutInterruptedClipsStillDecode() throws {
        let p = pending(UUID(), attempts: [], artefacts: [])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "interruptedClips")
        let decoded = try JSONDecoder().decode(PendingHandoff.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.interruptedClips, [])
        XCTAssertEqual(decoded.sessionId, p.sessionId)
    }
}
