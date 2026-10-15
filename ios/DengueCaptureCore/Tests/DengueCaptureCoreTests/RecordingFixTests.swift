import XCTest
import Foundation
@testable import DengueCaptureCore

/// In-memory outbox store that can be told to fail upserts of some item kinds.
final class FlakyOutboxStore: OutboxStore {
    var items: [UUID: OutboxItem] = [:]
    var failKinds: Set<OutboxKind> = []
    struct Injected: Error {}
    func loadAll() throws -> [OutboxItem] { items.values.sorted { $0.createdMonotonicNanos < $1.createdMonotonicNanos } }
    func upsert(_ item: OutboxItem) throws {
        if failKinds.contains(item.kind) { throw Injected() }
        items[item.id] = item
    }
    func delete(id: UUID) throws { items[id] = nil }
}

final class RecordingFixTests: XCTestCase {
    var dir: URL!
    var keys: InMemoryKeyStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("t13fix-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keys = InMemoryKeyStore()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: helpers

    private func faceTrace(seconds: Double = 40, invalidEvery: Int? = nil, garbage: Bool = false,
                           seed: UInt64 = 3) -> ROITrace {
        var state = seed
        func gauss() -> Double {   // Irwin-Hall approximation, deterministic
            var s = 0.0
            for _ in 0..<12 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                s += Double(state >> 11) / Double(1 << 53)
            }
            return s - 6
        }
        let n = Int(seconds * 30)
        let samples: [FrameSample] = (0...n).map { i in
            let t = Double(i) / 30
            if let k = invalidEvery, i % k == 0 {
                return garbage ? FrameSample(pts: t, meanR: 250, meanG: 20, meanB: 250, lumaStdDev: 0,
                                             fractionRClipped: 0, roiValid: false) : FrameSample.invalid(pts: t)
            }
            let s = sin(2 * Double.pi * 1.2 * t)
            return FrameSample(pts: t, meanR: 120 * (1 + 0.002 * s + 0.004 * gauss()),
                               meanG: 150 * (1 + 0.01 * s + 0.004 * gauss()),
                               meanB: 90 * (1 + 0.004 * s + 0.004 * gauss()), lumaStdDev: 8, fractionRClipped: 0)
        }
        return ROITrace(step: .neutralFace, fps: 30, samples: samples)
    }

    private let face = StepConfig(step: .neutralFace, isCore: true, targetSeconds: 40, minimumSeconds: 30)

    private func meta(_ step: CaptureStep = .neutralFace, distance: Double? = 45, angle: Double? = 3, lux: Double? = 320,
                      ambient: Bool = false) -> CaptureMetadata {
        CaptureMetadata(deviceModel: "iPhone15,2", step: step, attempt: 1, cameraRole: .frontFace, fps: 30,
                        resolution: "1080x1920", exposureDurationMs: 10, iso: 200, torchLevel: 0,
                        distanceCm: distance, angleDeg: angle, lux: lux, mount: "holder", lightingType: "overhead",
                        ambientTempC: ambient ? 27 : nil, ambientHumidityPct: ambient ? 60 : nil,
                        durationSeconds: 40, frameCount: 1200, videoCodec: "hevc", videoAverageBitRate: 25_000_000)
    }

    /// Really sealed artefacts (files on disk, keys in the key store).
    private func sealedArtefacts(_ step: CaptureStep, attempt: Int = 1, in sealedDir: URL) throws -> [SealedStepArtefact] {
        try FileManager.default.createDirectory(at: sealedDir, withIntermediateDirectories: true)
        let sealer = ArtefactSealer(keys: keys)
        return try [ArtefactKind.video, .roiTrace, .metadata].map { kind in
            let plain = dir.appendingPathComponent("\(UUID().uuidString).plain")
            try Data("\(step.rawValue)-\(kind.rawValue)".utf8).write(to: plain)
            let out = sealedDir.appendingPathComponent("\(UUID().uuidString).sealed")
            let s = try CaptureHandoff.sealAndRemovePlaintext(input: plain, output: out, sealer: sealer)
            return SealedStepArtefact(step: step, attempt: attempt, kind: kind, sealed: s)
        }
    }

    private func pending(session: UUID = UUID(), patient: UUID? = UUID(), artefacts: [SealedStepArtefact],
                         metadata: CaptureMetadata? = nil, open: Bool = false) -> PendingHandoff {
        PendingHandoff(
            sessionId: session, patientId: patient, maskedCode: NurseCopy.maskedStudyID("DS-2026-00417"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), offline: true, protocolVersion: "phase-a-1",
            attempts: [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept),
                       AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .accept)],
            vitals: [VitalRecord(field: .hr, value: 80, source: .bedsideMonitor,
                                 measuredAt: Date(timeIntervalSince1970: 1_800_000_000), isInvalid: false)],
            artefacts: artefacts, metadata: metadata ?? meta(), isOpen: open)
    }

    private func makeEngine(store: OutboxStore? = nil, sessions: InMemoryUploadSessionStore = InMemoryUploadSessionStore())
        -> (UploadEngine, Outbox) {
        let ob = Outbox(store: store ?? FlakyOutboxStore(), clock: TestClock())
        let e = UploadEngine(outbox: ob, api: FakeUploadAPI(log: EventLog()), sessions: sessions, keys: keys,
                             uploader: FakePartUploader(log: EventLog()), notifier: FakeNotifier())
        return (e, ob)
    }

    private func service() throws -> CaptureHandoffService {
        CaptureHandoffService(store: try FileHeldHandoffStore(directory: dir.appendingPathComponent("held"), keys: keys),
                              keys: keys)
    }

    private func alive(_ a: SealedStepArtefact) -> Bool {
        FileManager.default.fileExists(atPath: a.sealed.path.path) && (try? keys.key(id: a.sealed.keyId)) != nil
    }

    // MARK: I5 ROI validity

    func testFrameSampleRoiValidEncodedAndDefaultsTrue() throws {
        let t = ROITrace(step: .neutralFace, fps: 30, samples: [FrameSample.invalid(pts: 1),
            FrameSample(pts: 2, meanR: 1, meanG: 2, meanB: 3, lumaStdDev: 0, fractionRClipped: 0)])
        let data = try t.encoded()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"roi_valid\":false"))
        XCTAssertEqual(try ROITrace.decode(data), t)
        let legacy = #"{"pts":1,"mean_r":1,"mean_g":1,"mean_b":1,"luma_std":0,"frac_r_clipped":0}"#
        XCTAssertTrue(try JSONDecoder().decode(FrameSample.self, from: Data(legacy.utf8)).roiValid)
    }

    func testFaceROITrackerHoldsLastGoodRectsFor1p5s() {
        var tr = FaceROITracker()
        let r = [PixelRect(x: 1, y: 2, width: 3, height: 4)]
        XCTAssertNil(tr.rects(at: 0))
        tr.detected(r, at: 10)
        tr.detected([], at: 10.5)          // miss: keep last good
        XCTAssertEqual(tr.rects(at: 11.4), r)
        XCTAssertEqual(tr.rects(at: 11.5), r)
        XCTAssertNil(tr.rects(at: 11.6))   // > 1.5 s since the last good detection
        tr.detected(r, at: 12)
        XCTAssertEqual(tr.rects(at: 12.1), r)
    }

    func testVerdictUpTo10PercentInvalidStillAccepts() {
        XCTAssertEqual(StepQualityInput(trace: faceTrace(invalidEvery: 15), config: face).verdict(), .accept)
    }

    func testVerdictExcludesInvalidSamplesFromPulse() {
        // Frames flagged invalid every 7th frame carry junk (a 4.3 Hz tone): if they reached the pulse gate it
        // would add DS_RPPG_002. Excluded, only the occlusion reason remains.
        let t = faceTrace(invalidEvery: 7, garbage: true)
        let input = StepQualityInput(trace: t, config: face)
        XCTAssertEqual(input.verdict(), .recapture([.dsQG003]))
        // The pulse gate's input is exactly the valid-ROI samples, in order.
        let valid = t.samples.filter { $0.roiValid }
        XCTAssertEqual(input.pulseInput.count, valid.count)
        XCTAssertLessThan(input.pulseInput.count, t.samples.count)
        XCTAssertEqual(input.pulseInput, valid.map { RGBSample(r: $0.meanR, g: $0.meanG, b: $0.meanB) })
    }

    func testVerdictMoreThan10PercentInvalidFailsDSQG003() {
        let v = StepQualityInput(trace: faceTrace(invalidEvery: 5), config: face).verdict()
        guard case .recapture(let reasons) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(reasons.first, .dsQG003)
        XCTAssertFalse(reasons.contains(.dsQG004))   // frames themselves arrived fine
    }

    // MARK: C1(c) measured positioning

    func testPositioningSummaryMedians() {
        func o(_ yaw: Double, _ d: Double?, _ lux: Double) -> FaceObservation {
            FaceObservation(yawDeg: yaw, pitchDeg: 0, rollDeg: 0, faceWidthFraction: 0.5, distanceCm: d,
                            estimatedLux: lux, landmarkJitter: 0)
        }
        let s = PositioningSummary.from([o(-4, 40, 300), o(2, nil, 250), o(6, 50, .nan), o(1, 44, 400)])
        XCTAssertEqual(s.angleDeg, 1.5)
        XCTAssertEqual(s.distanceCm, 44)
        XCTAssertEqual(s.lux, 300)
        XCTAssertEqual(PositioningSummary.from([]), PositioningSummary(distanceCm: nil, angleDeg: nil, lux: nil))
        let m = meta(distance: nil, angle: nil, lux: nil).withPositioning(s)
        XCTAssertEqual(m.distanceCm, 44); XCTAssertEqual(m.angleDeg, 1.5); XCTAssertEqual(m.lux, 300)
    }

    func testLuxEstimate() throws {
        // Mid-grey (sRGB 118 ~ 18% linear) at f/2, 10 ms, ISO 200: pi/0.18 * 12.5 * 4 / 2 ~ 436 lx.
        let e = try XCTUnwrap(LuxEstimator.estimate(meanLuma: 118, exposureSeconds: 0.01, iso: 200, aperture: 2))
        XCTAssertEqual(e, 436, accuracy: 15)
        let brighter = try XCTUnwrap(LuxEstimator.estimate(meanLuma: 118, exposureSeconds: 0.01, iso: 100, aperture: 2))
        XCTAssertEqual(brighter / e, 2, accuracy: 1e-9)
        XCTAssertNil(LuxEstimator.estimate(meanLuma: 0, exposureSeconds: 0.01, iso: 100, aperture: 2))
        XCTAssertNil(LuxEstimator.estimate(meanLuma: 100, exposureSeconds: 0, iso: 100, aperture: 2))
    }

    // MARK: C1(b) ambient optional

    func testScanMetadataAmbientOptional() throws {
        let s = try CaptureHandoff.scanMetadata(from: meta())
        XCTAssertNil(s.ambientTempC); XCTAssertNil(s.ambientHumidityPct)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(json.contains("ambient"))
        XCTAssertEqual(try CaptureHandoff.scanMetadata(from: meta(ambient: true)).ambientTempC, 27)
        XCTAssertThrowsError(try CaptureHandoff.scanMetadata(from: meta(distance: nil))) {
            XCTAssertEqual($0 as? CaptureHandoffError, .metadataIncomplete(["distance_cm"]))
        }
    }

    func testHandoffErrorDiagnosticsAreDistinctAndPHIFree() {
        let errs: [CaptureHandoffError] = [.noAttempts, .metadataIncomplete(["lighting_lux"]), .patientUnknown,
                                           .uploadNotConfigured, .enqueueFailed("Injected")]
        XCTAssertEqual(Set(errs.map { $0.diagnostic }).count, errs.count)
        for e in errs { XCTAssertFalse(e.diagnostic.contains("DS-2026")) }
    }

    // MARK: I2 partial

    func testPlanWithOneStepMissingArtefactsKeepsCreateScanAndOtherStep() throws {
        let face = try sealedArtefacts(.neutralFace, in: dir.appendingPathComponent("sealed"))
        let p = pending(artefacts: face)   // fingertip accepted but its seal failed
        let plan = try CaptureHandoff().makeSessionPlan(
            sessionId: p.sessionId, patientId: UUID(), capturedAt: p.capturedAt, offline: true, protocolVersion: "p",
            metadata: try CaptureHandoff.scanMetadata(from: meta()), attempts: p.attempts, vitals: [], artefacts: face)
        XCTAssertEqual(plan.createScan.deviceAttempts.count, 2)
        XCTAssertEqual(plan.artefacts.count, 3)
        XCTAssertTrue(plan.artefacts.allSatisfy { $0.step == .neutralFace })
        XCTAssertEqual(plan.incompleteSteps, [.fingertipPPG])
    }

    // MARK: C1(d) held hand-off

    func testRecoverableFailuresAreHeldNeverShredded() throws {
        let sealedDir = dir.appendingPathComponent("sealed")
        let svc = try service()
        let a = try sealedArtefacts(.neutralFace, in: sealedDir) + sealedArtefacts(.fingertipPPG, in: sealedDir)
        let (engine, _) = makeEngine()

        XCTAssertEqual(svc.submit(pending(artefacts: a), engine: nil), .held(.uploadNotConfigured))
        XCTAssertEqual(svc.submit(pending(patient: nil, artefacts: a), engine: engine), .held(.patientUnknown))
        XCTAssertEqual(svc.submit(pending(artefacts: a, metadata: meta(lux: nil)), engine: engine),
                       .held(.metadataIncomplete(["lighting_lux"])))
        XCTAssertTrue(a.allSatisfy(alive))
        let held = try svc.heldSummaries()
        XCTAssertEqual(held.count, 3)
        XCTAssertTrue(held.allSatisfy { $0.maskedCode == "\u{2022}\u{2022}417" && $0.diagnostic != nil })
    }

    func testHeldRecordIsEncryptedOnDiskAndSurvivesReopen() throws {
        let sealedDir = dir.appendingPathComponent("sealed")
        let a = try sealedArtefacts(.neutralFace, in: sealedDir)
        let p = pending(artefacts: a)
        _ = try service().submit(p, engine: nil)
        let heldDir = dir.appendingPathComponent("held")
        for f in try FileManager.default.contentsOfDirectory(atPath: heldDir.path) {
            let text = String(decoding: try Data(contentsOf: heldDir.appendingPathComponent(f)), as: UTF8.self)
            XCTAssertFalse(text.contains("neutral_face"), f)
            XCTAssertFalse(text.contains("\u{2022}\u{2022}417"), f)
            XCTAssertFalse(text.contains("bedside_monitor"), f)
        }
        let reopened = try FileHeldHandoffStore(directory: heldDir, keys: keys)
        var expected = p
        expected.diagnostic = CaptureHandoffError.uploadNotConfigured.diagnostic
        XCTAssertEqual(try reopened.loadAll(), [expected])
    }

    func testRetryHeldEnqueuesWhenConditionsAreMet() throws {
        let sealedDir = dir.appendingPathComponent("sealed")
        let svc = try service()
        let a = try sealedArtefacts(.neutralFace, in: sealedDir) + sealedArtefacts(.fingertipPPG, in: sealedDir)
        let p = pending(artefacts: a)
        XCTAssertEqual(svc.submit(p, engine: nil), .held(.uploadNotConfigured))
        let (engine, outbox) = makeEngine()
        XCTAssertEqual(svc.retryHeld(engine: engine), [p.sessionId: .enqueued])
        XCTAssertEqual(try svc.heldSummaries(), [])
        XCTAssertNotNil(engine.record(p.sessionId))
        let items = try outbox.items(sessionId: p.sessionId)
        XCTAssertEqual(items.filter { $0.kind == .createScan }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .declareArtefact }.count, 6)
        XCTAssertEqual(items.filter { $0.kind == .clinicalData }.count, 1)
        XCTAssertTrue(a.allSatisfy(alive))   // the engine owns them now
    }

    func testOpenHandoffIsNotRetriedUntilClosed() throws {
        let svc = try service()
        let p = pending(artefacts: try sealedArtefacts(.neutralFace, in: dir.appendingPathComponent("sealed")), open: true)
        try svc.checkpoint(p)
        let (engine, _) = makeEngine()
        XCTAssertEqual(svc.retryHeld(engine: engine), [:])
        try svc.closeOpen()   // launch: the previous process's in-progress session is over
        XCTAssertEqual(svc.retryHeld(engine: engine), [p.sessionId: .enqueued])
    }

    func testClinicalDataFailureAfterSessionEnqueuedRetriesOnlyClinicalData() throws {
        let sealedDir = dir.appendingPathComponent("sealed")
        let svc = try service()
        let a = try sealedArtefacts(.neutralFace, in: sealedDir) + sealedArtefacts(.fingertipPPG, in: sealedDir)
        let p = pending(artefacts: a)
        let store = FlakyOutboxStore()
        store.failKinds = [.clinicalData]
        let (engine, outbox) = makeEngine(store: store)

        XCTAssertEqual(svc.submit(p, engine: engine), .held(.enqueueFailed("Injected")))
        XCTAssertNotNil(engine.record(p.sessionId))
        XCTAssertTrue(a.allSatisfy(alive))   // never destroyed once the engine owns them
        let held = try XCTUnwrap(try FileHeldHandoffStore(directory: dir.appendingPathComponent("held"), keys: keys)
            .loadAll().first)
        XCTAssertEqual(held.stage, .clinicalDataOnly)
        XCTAssertEqual(held.artefacts, [])

        store.failKinds = []
        XCTAssertEqual(svc.retryHeld(engine: engine), [p.sessionId: .enqueued])
        let items = try outbox.items(sessionId: p.sessionId)
        XCTAssertEqual(items.filter { $0.kind == .createScan }.count, 1)   // session not enqueued twice
        XCTAssertEqual(items.filter { $0.kind == .clinicalData }.count, 1)
        XCTAssertEqual(try svc.heldSummaries(), [])
    }

    func testExplicitDiscardShreds() throws {
        let svc = try service()
        let a = try sealedArtefacts(.neutralFace, in: dir.appendingPathComponent("sealed"))
        let p = pending(artefacts: a)
        _ = svc.submit(p, engine: nil)
        try svc.discard(sessionId: p.sessionId, reason: .nurseDiscard)
        XCTAssertTrue(a.allSatisfy { !alive($0) })
        XCTAssertEqual(try svc.heldSummaries(), [])
    }

    // MARK: I4 relaunch sweep

    func testSweepDeletesPlaintextAndOnlyUnreferencedSealed() throws {
        let captureDir = dir.appendingPathComponent("capture")
        let sealedDir = dir.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        try Data("plain".utf8).write(to: captureDir.appendingPathComponent("a.mov"))
        try Data("plain".utf8).write(to: captureDir.appendingPathComponent("a.roi.json"))

        let svc = try service()
        let heldA = try sealedArtefacts(.neutralFace, in: sealedDir)
        _ = svc.submit(pending(artefacts: heldA), engine: nil)
        let engineA = try sealedArtefacts(.fingertipPPG, in: sealedDir)
        let sessions = InMemoryUploadSessionStore()
        let (engine, _) = makeEngine(sessions: sessions)
        try engine.enqueueSession(sessionId: UUID(), participantCode: "DS-1", createScan: nil, scanId: UUID(),
                                  artefacts: engineA.map { ArtefactUpload(step: .fingertipPPG, attempt: 1, kind: $0.kind,
                                                                          deviceVerdict: .accept, sealed: $0.sealed) })
        let orphans = try sealedArtefacts(.neutralFace, attempt: 2, in: sealedDir)
        let foreignKey = "not-a-uuid"
        keys.insertForTesting(id: foreignKey)

        let report = svc.sweep(captureDirectory: captureDir, sealedDirectory: sealedDir, engine: engine)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: captureDir.path), [])
        XCTAssertTrue(heldA.allSatisfy(alive))
        XCTAssertTrue(engineA.allSatisfy(alive))
        XCTAssertTrue(orphans.allSatisfy { !alive($0) })
        XCTAssertNotNil(try? keys.key(id: foreignKey))
        XCTAssertEqual(report.deletedPlaintext, 2)
        XCTAssertEqual(report.deletedSealed, 3)
        XCTAssertEqual(report.destroyedKeys, 3)
        XCTAssertFalse(report.sealedSweepSkipped)
        // The held store's own record keys survive: the held hand-off still loads.
        XCTAssertEqual(try svc.heldSummaries().count, 1)
    }

    func testSweepWithoutEngineKeepsSealedAndKeys() throws {
        let captureDir = dir.appendingPathComponent("capture")
        let sealedDir = dir.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        try Data("plain".utf8).write(to: captureDir.appendingPathComponent("b.mov"))
        let orphans = try sealedArtefacts(.neutralFace, in: sealedDir)
        let report = try service().sweep(captureDirectory: captureDir, sealedDirectory: sealedDir, engine: nil)
        XCTAssertTrue(report.sealedSweepSkipped)
        XCTAssertEqual(report.deletedPlaintext, 1)
        XCTAssertTrue(orphans.allSatisfy(alive))
    }
}

final class SensorGeometryTests: XCTestCase {
    func testUnrotateMapsPortraitPointBackToSensor() {
        // 90 degrees clockwise: sensor (x, y) -> rotated (1 - y, x); inverse x = v, y = 1 - u.
        let p = SensorGeometry.sensorPoint(rotatedU: 0.25, rotatedV: 0.75, rotationDegrees: 90)
        XCTAssertEqual(p.x, 0.75, accuracy: 1e-12); XCTAssertEqual(p.y, 0.75, accuracy: 1e-12)
        let q = SensorGeometry.sensorPoint(rotatedU: 0.1, rotatedV: 0.2, rotationDegrees: 0)
        XCTAssertEqual(q.x, 0.1, accuracy: 1e-12); XCTAssertEqual(q.y, 0.2, accuracy: 1e-12)
        let r = SensorGeometry.sensorPoint(rotatedU: 0.1, rotatedV: 0.2, rotationDegrees: 180)
        XCTAssertEqual(r.x, 0.9, accuracy: 1e-12); XCTAssertEqual(r.y, 0.8, accuracy: 1e-12)
        let s = SensorGeometry.sensorPoint(rotatedU: 0.1, rotatedV: 0.2, rotationDegrees: 270)
        XCTAssertEqual(s.x, 0.8, accuracy: 1e-12); XCTAssertEqual(s.y, 0.1, accuracy: 1e-12)
    }

    func testDepthMedianCmIgnoresHolesAndNonFinite() {
        XCTAssertEqual(SensorGeometry.medianDepthCm(meters: [0.40, .nan, 0, 0.44, 0.42, -1, .infinity]) ?? 0, 42,
                       accuracy: 1e-4)
        XCTAssertNil(SensorGeometry.medianDepthCm(meters: [0, .nan]))
    }
}
