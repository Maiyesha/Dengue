import XCTest
import Foundation
@testable import DengueCaptureCore

/// I4: sessions where no face was ever detected (no distance / angle / lux measured).
final class NoFaceSessionTests: XCTestCase {
    var dir: URL!
    var keys: InMemoryKeyStore!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("noface-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keys = InMemoryKeyStore()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func meta(measured: Bool) -> CaptureMetadata {
        CaptureMetadata(deviceModel: "iPhone15,2", step: .fingertipPPG, attempt: 1, cameraRole: .rearFingertip, fps: 30,
                        resolution: "1080x1920", exposureDurationMs: 10, iso: 100, torchLevel: 0.1,
                        distanceCm: measured ? 45 : nil, angleDeg: measured ? 3 : nil, lux: measured ? 320 : nil,
                        mount: "holder", lightingType: "overhead", ambientTempC: nil, ambientHumidityPct: nil,
                        durationSeconds: 30, frameCount: 900, videoCodec: "hevc", videoAverageBitRate: 25_000_000)
    }

    func testScanMetadataWithoutFaceMeasurementsWhenNoFaceAttemptAccepted() throws {
        let m = try CaptureHandoff.scanMetadata(from: meta(measured: false), faceAccepted: false)
        XCTAssertNil(m.distanceCm)
        XCTAssertNil(m.angleDeg)
        XCTAssertNil(m.lightingLux)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        XCTAssertNil(obj["distance_cm"])
        XCTAssertNil(obj["angle_deg"])
        XCTAssertNil(obj["lighting_lux"])
    }

    func testAcceptedFaceStillRequiresMeasurements() {
        XCTAssertThrowsError(try CaptureHandoff.scanMetadata(from: meta(measured: false), faceAccepted: true)) {
            XCTAssertEqual($0 as? CaptureHandoffError, .metadataIncomplete(["distance_cm", "angle_deg", "lighting_lux"]))
        }
        XCTAssertThrowsError(try CaptureHandoff.scanMetadata(from: meta(measured: false)))   // default: face accepted
    }

    func testMeasuredValuesAreStillSentAndSanityCheckedWithoutAcceptedFace() throws {
        let m = try CaptureHandoff.scanMetadata(from: meta(measured: true), faceAccepted: false)
        XCTAssertEqual(m.distanceCm, 45)
        var bad = meta(measured: true)
        bad.distanceCm = 400
        XCTAssertThrowsError(try CaptureHandoff.scanMetadata(from: bad, faceAccepted: false))
    }

    func testHandoffEnqueuesAFaceFailedSessionWithoutMeasurements() throws {
        let sealedDir = dir.appendingPathComponent("sealed")
        try FileManager.default.createDirectory(at: sealedDir, withIntermediateDirectories: true)
        let sealer = ArtefactSealer(keys: keys, wrapper: FakeKeyWrapper())
        let arts: [SealedStepArtefact] = try CaptureHandoff.artefactKinds.map { kind in
            let plain = dir.appendingPathComponent(UUID().uuidString)
            try Data("\(kind)".utf8).write(to: plain)
            return SealedStepArtefact(step: .fingertipPPG, attempt: 1, kind: kind,
                                      sealed: try sealer.seal(input: plain, output: sealedDir.appendingPathComponent(UUID().uuidString)))
        }
        let p = PendingHandoff(
            sessionId: UUID(), patientId: UUID(), maskedCode: "\u{2022}\u{2022}417", capturedAt: Date(), offline: false,
            protocolVersion: "phase-a-1",
            attempts: [AttemptRecord(step: .neutralFace, attempt: 3, verdict: .unableToAcquire([.dsQG003])),
                       AttemptRecord(step: .fingertipPPG, attempt: 1, verdict: .accept)],
            vitals: [], artefacts: arts, metadata: meta(measured: false), isOpen: false)
        let svc = CaptureHandoffService(store: try FileHeldHandoffStore(directory: dir.appendingPathComponent("held"), keys: keys),
                                        keys: keys, keyWrapper: FakeKeyWrapper())
        let ob = Outbox(store: FlakyOutboxStore(), clock: TestClock())
        let e = UploadEngine(outbox: ob, api: FakeUploadAPI(log: EventLog()), sessions: InMemoryUploadSessionStore(),
                             keys: keys, uploader: FakePartUploader(log: EventLog()), notifier: FakeNotifier())
        XCTAssertEqual(svc.submit(p, engine: e), .enqueued)
        let create = try XCTUnwrap(try ob.items(sessionId: p.sessionId).first { $0.kind == .createScan })
        let req = try JSONDecoder().decode(CreateScanRequest.self, from: create.payload)
        XCTAssertNil(req.metadata.distanceCm)
    }
}
