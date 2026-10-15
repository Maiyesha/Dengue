import XCTest
@testable import DengueCaptureCore

final class ScreenCaptureMonitorTests: XCTestCase {
    final class Sink: DeviceEventSink {
        var events: [String] = []
        func record(event: String, detail: [String: String], at: Date) { events.append(event) }
    }

    func testCapturedScreenSetsBlurred() {
        let sink = Sink()
        let m = ScreenCaptureMonitor(sink: sink, clock: FakeClock())
        XCTAssertFalse(m.blurred)
        m.captureStateChanged(isCaptured: true)
        XCTAssertTrue(m.blurred)
        XCTAssertEqual(sink.events, ["screen_capture_detected"])
    }

    func testRepeatedStateDoesNotDuplicateAuditAndUnblurs() {
        let sink = Sink()
        let m = ScreenCaptureMonitor(sink: sink, clock: FakeClock())
        m.captureStateChanged(isCaptured: true)
        m.captureStateChanged(isCaptured: true)
        m.captureStateChanged(isCaptured: false)
        XCTAssertFalse(m.blurred)
        XCTAssertEqual(sink.events, ["screen_capture_detected", "screen_capture_ended"])
    }
}
