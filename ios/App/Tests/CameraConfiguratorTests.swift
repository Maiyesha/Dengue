import XCTest
import DengueCaptureCore
@testable import DengueCapture

/// Thin check only: the substantive configure/read-back tests live in the core
/// package (CameraConfiguratorTests) where they run against FakeDeviceControl.
final class AVCaptureDeviceControlConformanceTests: XCTestCase {
    func testAdapterConformsToProtocol() {
        let type: CaptureDeviceControl.Type = AVCaptureDeviceControl.self
        XCTAssertNotNil(type)
    }
}
