import XCTest
@testable import DengueCaptureCore

final class CameraConfiguratorTests: XCTestCase {
    func testFrontConfigSets30fps10msHDROffStabilizationOff() throws {
        let d = FakeDeviceControl()
        let s = try CameraConfigurator().configure(d, role: .frontFace, preferExposureMs: 10)
        XCTAssertEqual(s.fps, 30, accuracy: 0.01)
        XCTAssertEqual(s.exposureMs, 10, accuracy: 0.01)
        XCTAssertFalse(s.hdr)
        XCTAssertEqual(s.stabilization, "off")
        XCTAssertEqual(s.torch, 0)
        XCTAssertTrue(d.whiteBalanceLocked)
        XCTAssertTrue(d.focusLocked)
        XCTAssertFalse(d.centerStageEnabled)
        XCTAssertFalse(d.automaticallyAdjustsVideoHDR)
    }

    func testDeviceIgnoringHDROffThrowsNotReady() {
        let d = FakeDeviceControl()
        d.ignoresHDROff = true
        XCTAssertThrowsError(try CameraConfigurator().configure(d, role: .frontFace, preferExposureMs: 10)) {
            XCTAssertEqual($0 as? CameraError, .notReady(setting: "videoHDR"))
        }
    }

    func testExposure15msThrowsInvalidExposure() {
        let d = FakeDeviceControl()
        XCTAssertThrowsError(try CameraConfigurator().configure(d, role: .frontFace, preferExposureMs: 15)) {
            XCTAssertEqual($0 as? CameraError, .invalidExposure)
        }
    }

    func testExposure20msAccepted() throws {
        let s = try CameraConfigurator().configure(FakeDeviceControl(), role: .frontFace, preferExposureMs: 20)
        XCTAssertEqual(s.exposureMs, 20, accuracy: 0.01)
    }

    func testFingertipTurnsTorchOn() throws {
        let d = FakeDeviceControl()
        let s = try CameraConfigurator().configure(d, role: .rearFingertip, preferExposureMs: 20)
        XCTAssertGreaterThanOrEqual(s.torch, 0.1)
        XCTAssertEqual(d.torchLevel, s.torch)
    }

    func testFingertipTorchUsesLowestAcceptedLevel() throws {
        let d = FakeDeviceControl()
        d.minAcceptedTorch = 0.35
        let s = try CameraConfigurator().configure(d, role: .rearFingertip, preferExposureMs: 10)
        XCTAssertGreaterThanOrEqual(s.torch, 0.35)
        XCTAssertLessThan(s.torch, 0.5)
    }

    func testFingertipTorchRejectedEverywhereThrows() {
        let d = FakeDeviceControl()
        d.minAcceptedTorch = 2
        XCTAssertThrowsError(try CameraConfigurator().configure(d, role: .rearFingertip, preferExposureMs: 10)) {
            XCTAssertEqual($0 as? CameraError, .notReady(setting: "torch"))
        }
    }

    func testFrontDoesNotTurnTorchOn() throws {
        let d = FakeDeviceControl()
        _ = try CameraConfigurator().configure(d, role: .frontFace, preferExposureMs: 10)
        XCTAssertEqual(d.torchLevel, 0)
    }

    func testEachReadBackMismatchThrowsNamedSetting() {
        let cases: [(String, (FakeDeviceControl) -> Void)] = [
            ("frameRate", { $0.ignoresFrameDuration = true }),
            ("exposure", { $0.ignoresExposure = true }),
            ("whiteBalance", { $0.ignoresWhiteBalanceLock = true }),
            ("focus", { $0.ignoresFocusLock = true }),
            ("centerStage", { $0.ignoresCenterStageOff = true }),
            ("stabilization", { $0.ignoresStabilizationOff = true }),
            ("videoHDR", { $0.ignoresAutoHDROff = true }),
        ]
        for (name, tweak) in cases {
            let d = FakeDeviceControl()
            tweak(d)
            XCTAssertThrowsError(try CameraConfigurator().configure(d, role: .frontFace, preferExposureMs: 10), name) {
                XCTAssertEqual($0 as? CameraError, .notReady(setting: name))
            }
        }
    }

    func testFrameRateDriftAfterExposureThrowsNotReady() {
        let d = FakeDeviceControl()
        d.exposureDriftsFrameDuration = true
        XCTAssertThrowsError(try CameraConfigurator().configure(d, role: .frontFace, preferExposureMs: 10)) {
            XCTAssertEqual($0 as? CameraError, .notReady(setting: "frameRate"))
        }
    }

    func testSettingsCodableRoundTrip() throws {
        let s = AppliedCameraSettings(fps: 30, exposureMs: 10, iso: 100, hdr: false, stabilization: "off", torch: 0)
        let back = try JSONDecoder().decode(AppliedCameraSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
