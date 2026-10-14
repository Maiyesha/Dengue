import XCTest
@testable import DengueCaptureCore

final class FingertipCoverageTests: XCTestCase {
    private func stats(r: Double = 200, g: Double = 60, b: Double = 40, std: Double = 10, clipped: Double = 0.1) -> FrameStats {
        FrameStats(meanR: r, meanG: g, meanB: b, lumaStdDev: std, fractionRClipped: clipped)
    }

    func testFingerRedDominantUniformFrameCovered() {
        let r = FingertipCoverage.evaluate(stats())
        XCTAssertTrue(r.covered)
        XCTAssertNil(r.reason)
    }

    func testLightLeakHighLumaStdNotCovered() {
        let r = FingertipCoverage.evaluate(stats(std: 40))
        XCTAssertFalse(r.covered)
        XCTAssertEqual(r.reason, .dsQG005)
    }

    func testSixtyPercentClippedNotCovered() {
        let r = FingertipCoverage.evaluate(stats(clipped: 0.6))
        XCTAssertFalse(r.covered)
        XCTAssertEqual(r.reason, .dsQG005)
    }

    func testBoundariesInclusiveWhereBriefSays() {
        XCTAssertTrue(FingertipCoverage.evaluate(stats(r: 120, g: 72, b: 72, clipped: 0.5)).covered)
        XCTAssertFalse(FingertipCoverage.evaluate(stats(std: 25)).covered)   // strictly < 25
        XCTAssertFalse(FingertipCoverage.evaluate(stats(r: 119.9, g: 10, b: 10)).covered)
        XCTAssertFalse(FingertipCoverage.evaluate(stats(r: 200, g: 121, b: 40)).covered)  // G/R > 0.6
        XCTAssertFalse(FingertipCoverage.evaluate(stats(r: 200, g: 60, b: 121)).covered)  // B/R > 0.6
    }

    func testZeroRedIsNotCoveredWithoutDividing() {
        XCTAssertFalse(FingertipCoverage.evaluate(stats(r: 0, g: 0, b: 0)).covered)
    }
}
