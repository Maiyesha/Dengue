import XCTest
import Foundation
@testable import DengueCaptureCore

/// Deterministic SplitMix64 + Box-Muller (tests never depend on the system RNG).
private struct RecRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / 9_007_199_254_740_992.0 }
    mutating func gaussian() -> Double {
        let u1 = uniform(), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

final class RecordingTests: XCTestCase {
    typealias Px = (r: UInt8, g: UInt8, b: UInt8)

    // MARK: helpers

    /// Skin-like trace with a 1.2 Hz pulse; `gapAt` drops one second of frames; `base` sets the channel means.
    private func trace(step: CaptureStep, seconds: Double = 40, fps: Double = 30,
                       base: (r: Double, g: Double, b: Double) = (120, 150, 90),
                       gapAt: Double? = nil, seed: UInt64 = 7) -> ROITrace {
        var rng = RecRNG(state: seed)
        let n = Int(seconds * fps)
        var samples: [FrameSample] = []
        for i in 0..<n {
            let t = Double(i) / fps
            if let g = gapAt, t >= g, t < g + 1 { continue }
            let s = sin(2 * Double.pi * 1.2 * t)
            samples.append(FrameSample(
                pts: 1000 + t,
                meanR: base.r * (1 + 0.002 * s + 0.004 * rng.gaussian()),
                meanG: base.g * (1 + 0.01 * s + 0.004 * rng.gaussian()),
                meanB: base.b * (1 + 0.004 * s + 0.004 * rng.gaussian()),
                lumaStdDev: 8, fractionRClipped: 0.1))
        }
        return ROITrace(step: step, fps: fps, samples: samples)
    }

    private let face = StepConfig(step: .neutralFace, isCore: true, targetSeconds: 40, minimumSeconds: 30)
    private let finger = StepConfig(step: .fingertipPPG, isCore: true, targetSeconds: 30, minimumSeconds: 30)

    // MARK: ROI samples

    func testFaceSampleMeansOverROIPixels() {
        let px: [Px] = [(r: 100, g: 50, b: 10), (r: 200, g: 150, b: 30), (r: 150, g: 100, b: 20)]
        let s = ROITraceBuilder.faceSample(pixels: px, pts: 12.5)
        XCTAssertEqual(s.pts, 12.5)
        XCTAssertEqual(s.meanR, 150, accuracy: 1e-9)
        XCTAssertEqual(s.meanG, 100, accuracy: 1e-9)
        XCTAssertEqual(s.meanB, 20, accuracy: 1e-9)
        XCTAssertEqual(s.fractionRClipped, 0)
    }

    func testFingertipSampleClipFractionAndLumaStd() {
        // Two saturated-red pixels and two dark pixels.
        let px: [Px] = [(r: 255, g: 0, b: 0), (r: 255, g: 0, b: 0), (r: 0, g: 0, b: 0), (r: 0, g: 0, b: 0)]
        let s = ROITraceBuilder.fingertipSample(pixels: px, pts: 0)
        XCTAssertEqual(s.fractionRClipped, 0.5, accuracy: 1e-12)
        // BT.601 luma: 0.299 * 255 = 76.245 for red pixels, 0 for dark ones -> population std = 38.1225.
        XCTAssertEqual(s.lumaStdDev, 0.299 * 255 / 2, accuracy: 1e-9)
        XCTAssertEqual(s.meanR, 127.5, accuracy: 1e-9)
    }

    func testEmptyROIGivesZeroSample() {
        let s = ROITraceBuilder.faceSample(pixels: [Px](), pts: 3)
        XCTAssertEqual(s, FrameSample.invalid(pts: 3))
        XCTAssertFalse(s.roiValid)
    }

    func testBGRARegionReadsOnlyTheRectsWithStride() {
        // 4x2 BGRA image with 4 bytes row padding; pixel (x, y) has r = 10*y + x, g = 100, b = 200.
        let width = 4, height = 2, bytesPerRow = 20
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let o = y * bytesPerRow + x * 4
                bytes[o] = 200; bytes[o + 1] = 100; bytes[o + 2] = UInt8(10 * y + x); bytes[o + 3] = 255
            }
        }
        bytes.withUnsafeBytes { raw in
            let region = BGRAPixelRegion(base: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                         rects: [PixelRect(x: 1, y: 0, width: 2, height: 2)], step: 1)
            XCTAssertEqual(region.map { $0.r }, [1, 2, 11, 12])
            XCTAssertTrue(region.allSatisfy { $0.g == 100 && $0.b == 200 })
            let strided = BGRAPixelRegion(base: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                          rects: [PixelRect(x: 0, y: 0, width: 4, height: 2)], step: 2)
            XCTAssertEqual(strided.map { $0.r }, [0, 2])
            // Rects are clipped to the image.
            let clipped = BGRAPixelRegion(base: raw, width: width, height: height, bytesPerRow: bytesPerRow,
                                          rects: [PixelRect(x: 3, y: 1, width: 5, height: 5)], step: 1)
            XCTAssertEqual(clipped.map { $0.r }, [13])
        }
    }

    func testFaceROIRectsLieInsideFaceBox() {
        let rects = FaceROI.rects(faceBox: PixelRect(x: 100, y: 200, width: 400, height: 500),
                                  imageWidth: 1080, imageHeight: 1920)
        XCTAssertEqual(rects.count, 3)   // forehead + two cheeks
        for r in rects {
            XCTAssertGreaterThan(r.width, 0); XCTAssertGreaterThan(r.height, 0)
            XCTAssertGreaterThanOrEqual(r.x, 100); XCTAssertLessThanOrEqual(r.x + r.width, 500)
            XCTAssertGreaterThanOrEqual(r.y, 200); XCTAssertLessThanOrEqual(r.y + r.height, 700)
        }
        XCTAssertEqual(rects[0].y, 200 + 500 / 10)   // forehead band near the top
    }

    // MARK: trace encoding

    func testTraceRGBTimestampsRoundTripLossless() throws {
        let t = trace(step: .neutralFace, seconds: 5)
        XCTAssertEqual(t.rgb.count, t.samples.count)
        XCTAssertEqual(t.timestamps, t.samples.map { $0.pts })
        XCTAssertEqual(t.rgb[3], RGBSample(r: t.samples[3].meanR, g: t.samples[3].meanG, b: t.samples[3].meanB))
        let decoded = try ROITrace.decode(t.encoded())
        XCTAssertEqual(decoded, t)   // bit-exact doubles
    }

    func testEncodedTraceFor45sAt30fpsIsUnder2MB() throws {
        let t = trace(step: .neutralFace, seconds: 45)
        XCTAssertEqual(t.samples.count, 1350)
        let size = try t.encoded().count
        XCTAssertLessThan(size, 2_000_000)
        // Documented estimate: ~180 bytes per frame (see ROITrace.encoded).
        XCTAssertLessThan(size, 1350 * 260)
    }

    // MARK: verdict

    func testVerdictTimingFailureReportsDSQG004First() {
        let v = StepQualityInput(trace: trace(step: .neutralFace, gapAt: 10), config: face).verdict()
        guard case .recapture(let reasons) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(reasons.first, .dsQG004)
    }

    func testVerdictGoodSyntheticPulsePasses() {
        XCTAssertEqual(StepQualityInput(trace: trace(step: .neutralFace), config: face).verdict(), .accept)
    }

    func testVerdictShortRecordingFailsTiming() {
        let v = StepQualityInput(trace: trace(step: .neutralFace, seconds: 20), config: face).verdict()
        guard case .recapture(let reasons) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(reasons.first, .dsQG004)
    }

    func testVerdictFingertipCoveredPasses() {
        let t = trace(step: .fingertipPPG, seconds: 31, base: (200, 40, 30))
        XCTAssertEqual(StepQualityInput(trace: t, config: finger).verdict(), .accept)
    }

    func testVerdictFingertipLightLeakDSQG005() {
        // Pulse and timing fine, but green/blue light leaks around the finger.
        let t = trace(step: .fingertipPPG, seconds: 31, base: (180, 150, 140))
        XCTAssertEqual(StepQualityInput(trace: t, config: finger).verdict(), .recapture([.dsQG005]))
    }

    func testVerdictCollectsAllReasonsInOrder() {
        let t = trace(step: .fingertipPPG, seconds: 31, base: (180, 150, 140), gapAt: 10)
        let v = StepQualityInput(trace: t, config: finger).verdict()
        guard case .recapture(let reasons) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(reasons.first, .dsQG004)
        XCTAssertEqual(reasons.last, .dsQG005)
    }

    func testMedianFrameStats() {
        var t = trace(step: .fingertipPPG, seconds: 1)
        t.samples = [
            FrameSample(pts: 0, meanR: 1, meanG: 10, meanB: 5, lumaStdDev: 3, fractionRClipped: 0.1),
            FrameSample(pts: 1, meanR: 3, meanG: 30, meanB: 1, lumaStdDev: 1, fractionRClipped: 0.3),
            FrameSample(pts: 2, meanR: 2, meanG: 20, meanB: 9, lumaStdDev: 2, fractionRClipped: 0.2),
        ]
        XCTAssertEqual(t.medianStats, FrameStats(meanR: 2, meanG: 20, meanB: 5, lumaStdDev: 2, fractionRClipped: 0.2))
    }

    // MARK: recording session token

    func testStaleTokenSamplesIgnoredAfterFinish() {
        let first = RecordingSession(step: .neutralFace, attempt: 1)
        let staleToken = first.token
        first.accept(sample: FrameSample(pts: 0, meanR: 1, meanG: 1, meanB: 1, lumaStdDev: 0, fractionRClipped: 0))
        XCTAssertTrue(first.isCurrent(token: staleToken))
        let t = first.finish()
        XCTAssertEqual(t.samples.count, 1)
        XCTAssertFalse(first.isCurrent(token: staleToken))
        first.accept(sample: FrameSample(pts: 1, meanR: 1, meanG: 1, meanB: 1, lumaStdDev: 0, fractionRClipped: 0))
        XCTAssertEqual(first.finish().samples.count, 1)   // late sample from the paused attempt dropped

        let second = RecordingSession(step: .neutralFace, attempt: 1)
        XCTAssertNotEqual(second.token, staleToken)
        XCTAssertFalse(second.isCurrent(token: staleToken))
        XCTAssertTrue(second.isCurrent(token: second.token))
    }

    func testTickDueRoughlyOncePerSecond() {
        let s = RecordingSession(step: .neutralFace, attempt: 1)
        var ticks: [Double] = []
        for i in 0..<91 {   // 3 s at 30 fps
            s.accept(sample: FrameSample(pts: 50 + Double(i) / 30, meanR: 1, meanG: 1, meanB: 1,
                                         lumaStdDev: 0, fractionRClipped: 0))
            if let e = s.tickDue() { ticks.append(e) }
        }
        XCTAssertEqual(ticks.count, 3)
        XCTAssertEqual(ticks[0], 1, accuracy: 0.05)
        XCTAssertEqual(ticks[2], 3, accuracy: 0.05)
    }

    // MARK: attempt log

    func testMachineAttemptLogRecordsEffectiveVerdicts() {
        let m = CaptureSessionMachine(protocol: .phaseADefault, preflight: Preflight(freeBytes: 5_000_000_000, batteryLevel: 1))
        for _ in 0..<3 {
            m.positioned(); m.stepRecorded(duration: 40); m.verdict(.recapture([.dsRPPG001]))
        }
        m.positioned(); m.stepRecorded(duration: 10)   // short: recapture DS_QG_004
        m.positioned(); m.stepRecorded(duration: 31); m.verdict(.accept)
        XCTAssertEqual(m.attemptLog, [
            AttemptRecord(step: .neutralFace, attempt: 1, verdict: .recapture([.dsRPPG001])),
            AttemptRecord(step: .neutralFace, attempt: 2, verdict: .recapture([.dsRPPG001])),
            AttemptRecord(step: .neutralFace, attempt: 3, verdict: .unableToAcquire([.dsRPPG001])),
            AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .recapture([.dsQG004])),
            AttemptRecord(step: .fingertipPPG, attempt: 2, verdict: .accept),
        ])
    }

    // MARK: metadata

    func testCaptureMetadataJSONKeys() throws {
        let m = sampleMetadata(step: .neutralFace, attempt: 1)
        let obj = try JSONSerialization.jsonObject(with: m.encoded()) as? [String: Any]
        for k in ["device_model", "fps", "resolution", "exposure_duration_ms", "iso", "distance_cm", "angle_deg",
                  "lux", "mount", "lighting_type", "ambient_temp_c", "ambient_humidity_pct", "step", "attempt"] {
            XCTAssertNotNil(obj?[k], k)
        }
        XCTAssertEqual(try JSONDecoder().decode(CaptureMetadata.self, from: m.encoded()), m)
    }

    func testScanMetadataNeedsContractFields() throws {
        var m = sampleMetadata(step: .neutralFace, attempt: 1)
        let s = try CaptureHandoff.scanMetadata(from: m)
        XCTAssertEqual(s.exposureDurationMs, 10)
        XCTAssertEqual(s.exposure, 0.01, accuracy: 1e-12)
        XCTAssertEqual(s.lightingLux, 320)
        m.distanceCm = nil; m.lux = nil
        XCTAssertThrowsError(try CaptureHandoff.scanMetadata(from: m)) { e in
            XCTAssertEqual(e as? CaptureHandoffError, .metadataIncomplete(["distance_cm", "lighting_lux"]))
        }
    }

    private func sampleMetadata(step: CaptureStep, attempt: Int) -> CaptureMetadata {
        CaptureMetadata(deviceModel: "iPhone15,2", step: step, attempt: attempt, cameraRole: .frontFace,
                        fps: 30, resolution: "1080x1920", exposureDurationMs: 10, iso: 200, torchLevel: 0,
                        distanceCm: 45, angleDeg: 3, lux: 320, mount: "holder", lightingType: "fluorescent",
                        ambientTempC: 27, ambientHumidityPct: 65, durationSeconds: 40, frameCount: 1200,
                        videoCodec: "hevc", videoAverageBitRate: 20_000_000)
    }

    // MARK: hand-off

    private func sealed(_ tag: String) -> SealedArtefact {
        SealedArtefact(keyId: "k-\(tag)", path: URL(fileURLWithPath: "/tmp/\(tag).sealed"),
                       sha256OfPlaintext: "p-\(tag)", sizeBytes: 100,
                       sha256OfCiphertext: "c-\(tag)", sealedSizeBytes: 141)
    }

    private func stepArtefacts(_ step: CaptureStep, _ attempt: Int) -> [SealedStepArtefact] {
        [ArtefactKind.video, .roiTrace, .metadata].map {
            SealedStepArtefact(step: step, attempt: attempt, kind: $0, sealed: sealed("\(step.rawValue)-\(attempt)-\($0.rawValue)"))
        }
    }

    func testHandoffPlan() throws {
        let session = UUID(), patient = UUID()
        let attempts = [
            AttemptRecord(step: .neutralFace, attempt: 1, verdict: .recapture([.dsQG004, .dsRPPG001])),
            AttemptRecord(step: .neutralFace, attempt: 2, verdict: .accept),
            AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .recapture([.dsQG005])),
            AttemptRecord(step: .fingertipPPG, attempt: 2, verdict: .accept),
        ]
        let measured = Date(timeIntervalSince1970: 1_800_000_000)
        let vitals = [
            VitalRecord(field: .hr, value: 88, source: .bedsideMonitor, measuredAt: measured, isInvalid: false),
            VitalRecord(field: .tempC, value: 37.9, source: .thermometer, measuredAt: measured, isInvalid: false),
        ]
        // Artefacts of the rejected face attempt 1 were sealed too; they must not be uploaded.
        let artefacts = stepArtefacts(.neutralFace, 1) + stepArtefacts(.neutralFace, 2) + stepArtefacts(.fingertipPPG, 2)
        let plan = try CaptureHandoff().makeSessionPlan(
            sessionId: session, patientId: patient, capturedAt: measured, offline: true, protocolVersion: "phase-a-1",
            metadata: try CaptureHandoff.scanMetadata(from: sampleMetadata(step: .neutralFace, attempt: 2)),
            attempts: attempts, vitals: vitals, artefacts: artefacts)

        // createScan carries every attempt, including the offline recaptures with their reasons.
        XCTAssertEqual(plan.createScan.deviceAttempts, [
            DeviceAttempt(step: .neutralFace, attempt: 1, deviceVerdict: .recapture, reasonCodes: ["DS_QG_004", "DS_RPPG_001"]),
            DeviceAttempt(step: .neutralFace, attempt: 2, deviceVerdict: .accept, reasonCodes: []),
            DeviceAttempt(step: .fingertipPPG, attempt: 1, deviceVerdict: .recapture, reasonCodes: ["DS_QG_005"]),
            DeviceAttempt(step: .fingertipPPG, attempt: 2, deviceVerdict: .accept, reasonCodes: []),
        ])
        XCTAssertEqual(plan.createScan.captureSteps, [.neutralFace, .fingertipPPG])
        XCTAssertEqual(plan.createScan.clientSessionId, session)
        XCTAssertEqual(plan.createScan.patientId, patient)
        XCTAssertTrue(plan.createScan.offline)

        // Three kinds per accepted core step, all ACCEPT, sealed sha/size carried.
        XCTAssertEqual(plan.artefacts.count, 6)
        for step in [CaptureStepName.neutralFace, .fingertipPPG] {
            let kinds = plan.artefacts.filter { $0.step == step }.map { $0.kind }
            XCTAssertEqual(Set(kinds.map { $0.rawValue }), ["video", "roi_trace", "metadata"])
        }
        XCTAssertTrue(plan.artefacts.allSatisfy { $0.attempt == 2 && $0.deviceVerdict == .accept })
        XCTAssertEqual(plan.discarded.count, 3)
        XCTAssertTrue(plan.discarded.allSatisfy { $0.keyId.contains("neutral_face-1") })

        // Clinical data for the vitals with fixed units, linked to the session.
        XCTAssertEqual(plan.clinicalData?.observations.map { $0.vital }, [.hr, .tempC])
        XCTAssertEqual(plan.clinicalData?.observations.map { $0.unit }, ["/min", "\u{00B0}C"])
        XCTAssertEqual(plan.clinicalData?.observations.first?.sourceDeviceType, "bedside_monitor")
        XCTAssertTrue(plan.clinicalData?.observations.allSatisfy { $0.scanClientSessionId == session } ?? false)

        // Enqueue: declare items depend on createScan; declare uses the sealed sha/size.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = Outbox(store: try FileOutboxStore(directory: dir), clock: TestClock())
        let sessions = InMemoryUploadSessionStore()
        let engine = UploadEngine(outbox: outbox, api: FakeUploadAPI(log: EventLog()), sessions: sessions,
                                  keys: InMemoryKeyStore(), uploader: FakePartUploader(log: EventLog()),
                                  notifier: FakeNotifier())
        try engine.enqueueSession(sessionId: plan.sessionId, participantCode: "DS-2026-00417",
                                  createScan: plan.createScan, scanId: nil, artefacts: plan.artefacts)
        try engine.enqueueClinicalData(sessionId: plan.sessionId, patientId: plan.patientId,
                                       request: try XCTUnwrap(plan.clinicalData))

        let items = try outbox.items(sessionId: session)
        let create = try XCTUnwrap(items.first { $0.kind == .createScan })
        let declares = items.filter { $0.kind == .declareArtefact }
        XCTAssertEqual(declares.count, 6)
        XCTAssertTrue(declares.allSatisfy { $0.dependsOn == create.id })
        XCTAssertEqual(items.filter { $0.kind == .clinicalData }.count, 1)
        let rec = try XCTUnwrap(engine.record(session))
        XCTAssertEqual(rec.maskedCode, "\u{2022}\u{2022}417")
        let video = try XCTUnwrap(rec.artefacts.first { $0.step == .neutralFace && $0.kind == .video })
        XCTAssertEqual(video.sealed.sha256OfCiphertext, "c-neutral_face-2-video")
        XCTAssertEqual(video.sealed.sealedSizeBytes, 141)
    }

    func testHandoffAcceptedStepMissingAKindUploadsTheRest() throws {
        let attempts = [AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept)]
        let artefacts = Array(stepArtefacts(.neutralFace, 1).prefix(2))
        let plan = try CaptureHandoff().makeSessionPlan(
            sessionId: UUID(), patientId: UUID(), capturedAt: Date(), offline: false, protocolVersion: "p",
            metadata: try CaptureHandoff.scanMetadata(from: sampleMetadata(step: .neutralFace, attempt: 1)),
            attempts: attempts, vitals: [], artefacts: artefacts)
        XCTAssertEqual(plan.artefacts.map { $0.kind }, [.video, .roiTrace])
        XCTAssertEqual(plan.incompleteSteps, [.neutralFace])
    }

    func testHandoffUnableToAcquireStepUploadsNothingButReportsAttempts() throws {
        let attempts = [
            AttemptRecord(step: .neutralFace, attempt: 1, verdict: .accept),
            AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .recapture([.dsQG005])),
            AttemptRecord(step: .fingertipPPG, attempt: 2, verdict: .recapture([.dsQG005])),
            AttemptRecord(step: .fingertipPPG, attempt: 3, verdict: .unableToAcquire([.dsQG005])),
        ]
        let plan = try CaptureHandoff().makeSessionPlan(
            sessionId: UUID(), patientId: UUID(), capturedAt: Date(), offline: false, protocolVersion: "p",
            metadata: try CaptureHandoff.scanMetadata(from: sampleMetadata(step: .neutralFace, attempt: 1)),
            attempts: attempts, vitals: [], artefacts: stepArtefacts(.neutralFace, 1) + stepArtefacts(.fingertipPPG, 3))
        XCTAssertEqual(plan.createScan.deviceAttempts.last,
                       DeviceAttempt(step: .fingertipPPG, attempt: 3, deviceVerdict: .unableToAcquire, reasonCodes: ["DS_QG_005"]))
        XCTAssertEqual(plan.artefacts.count, 3)
        XCTAssertEqual(plan.discarded.count, 3)
        XCTAssertNil(plan.clinicalData)
    }

    func testSealAndRemovePlaintext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("trace.json")
        try Data("hello".utf8).write(to: plain)
        let keys = InMemoryKeyStore()
        let s = try CaptureHandoff.sealAndRemovePlaintext(input: plain, output: dir.appendingPathComponent("trace.sealed"),
                                                          sealer: ArtefactSealer(keys: keys))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.path.path))
        XCTAssertEqual(s.sizeBytes, 5)
    }
}
