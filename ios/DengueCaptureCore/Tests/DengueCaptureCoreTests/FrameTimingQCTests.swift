import XCTest
@testable import DengueCaptureCore

final class FrameTimingQCTests: XCTestCase {
    /// Frames at `fps` for `seconds`, skipping indices for which `drop` is true (endpoints are always kept).
    private func frames(fps: Double = 30, seconds: Double = 40, drop: (Int) -> Bool = { _ in false }) -> [Double] {
        let n = Int((seconds * fps).rounded())
        return (0...n).filter { $0 == 0 || $0 == n || !drop($0) }.map { Double($0) / fps }
    }

    func testPerfect30fps40sPasses() {
        let r = FrameTimingQC.evaluate(timestamps: frames(), minimumSeconds: 30)
        XCTAssertTrue(r.passed)
        XCTAssertNil(r.reason)
        XCTAssertEqual(r.measuredFPS, 30, accuracy: 0.01)
        XCTAssertEqual(r.durationSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(r.missingFraction, 0, accuracy: 1e-9)
    }

    func testSingleGapOf0Point6SecondsFailsDSQG004() {
        var ts = frames()
        ts = ts.filter { $0 < 20 || $0 >= 20.6 }   // remove 18 frames, leaving a ~0.6 s gap
        let r = FrameTimingQC.evaluate(timestamps: ts, minimumSeconds: 30)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.reason, .dsQG004)
        XCTAssertGreaterThan(r.maxGapSeconds, 0.5)
    }

    func testSixPercentEvenlyDroppedFails() {
        let r = FrameTimingQC.evaluate(timestamps: frames(drop: { $0 % 16 == 8 }), minimumSeconds: 30)
        XCTAssertGreaterThan(r.missingFraction, 0.05)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.reason, .dsQG004)
    }

    func testFourPercentDroppedPasses() {
        let r = FrameTimingQC.evaluate(timestamps: frames(drop: { $0 % 25 == 12 }), minimumSeconds: 30)
        XCTAssertLessThan(r.missingFraction, 0.05)
        XCTAssertTrue(r.passed)
    }

    func testEighteenFPSFails() {
        let r = FrameTimingQC.evaluate(timestamps: frames(fps: 18), minimumSeconds: 30)
        XCTAssertEqual(r.measuredFPS, 18, accuracy: 0.01)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.reason, .dsQG004)
    }

    func test29sDurationWithMinimum30Fails() {
        let r = FrameTimingQC.evaluate(timestamps: frames(seconds: 29), minimumSeconds: 30)
        XCTAssertEqual(r.durationSeconds, 29, accuracy: 0.001)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.reason, .dsQG004)
    }

    func testUnsortedInputIsSortedFirst() {
        let r = FrameTimingQC.evaluate(timestamps: frames().reversed(), minimumSeconds: 30)
        XCTAssertTrue(r.passed)
        XCTAssertEqual(r.durationSeconds, 40, accuracy: 0.001)
        var shuffled = frames()
        shuffled.swapAt(100, 900)
        XCTAssertTrue(FrameTimingQC.evaluate(timestamps: shuffled, minimumSeconds: 30).passed)
    }

    func testEmptyAndSingleTimestampFail() {
        for ts in [[Double](), [1.0]] {
            let r = FrameTimingQC.evaluate(timestamps: ts, minimumSeconds: 30)
            XCTAssertFalse(r.passed)
            XCTAssertEqual(r.reason, .dsQG004)
        }
    }
}
