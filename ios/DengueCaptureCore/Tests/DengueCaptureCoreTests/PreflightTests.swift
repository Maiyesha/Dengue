import XCTest
@testable import DengueCaptureCore

/// I5: real preflight thresholds — warn below 15 % battery, block below 5 %, block below 2 GB free.
final class PreflightTests: XCTestCase {
    func testBatteryWarnBelow15Percent() {
        XCTAssertEqual(Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.149).warning, .lowBattery)
        XCTAssertNil(Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.15).warning)
        XCTAssertTrue(Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.10).canStartCapture, "warn only")
        XCTAssertEqual(NurseCopy.lowBatteryWarning.isEmpty, false)
        XCTAssertTrue(NurseCopy.forbiddenTerms(in: NurseCopy.lowBatteryWarning).isEmpty)
    }

    func testBatteryBlockBelow5Percent() {
        XCTAssertEqual(Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.049).blockReason, .lowBattery)
        XCTAssertNil(Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.05).blockReason)
    }

    func testStorageBlockBelow2GB() {
        XCTAssertEqual(Preflight(freeBytes: 1_999_999_999, batteryLevel: 0.9).blockReason, .lowStorage)
        XCTAssertNil(Preflight(freeBytes: 2_000_000_000, batteryLevel: 0.9).blockReason)
    }

    /// UIDevice reports -1 when battery monitoring is off / unknown (simulator): never a block or a warning.
    func testUnknownBatteryIsNotLow() {
        let p = Preflight(freeBytes: 10_000_000_000, batteryLevel: -1)
        XCTAssertNil(p.blockReason)
        XCTAssertNil(p.warning)
    }

    func testCaptureScreenShowsTheWarning() {
        let f = CaptureFlow(preflight: Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.10))
        f.selectPatient(participantCode: "DS-1", bedLabel: nil)
        f.submitConsent(ConsentStatus(primaryResearch: true, consentVersion: "v", currentVersion: "v", withdrawn: false,
                                      captureAllowed: true, blockCode: nil, checkedAt: "x"),
                        snapshotAt: Date(), online: true, now: Date())
        f.giveAssent()
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        f.skipVitals(reason: .monitorUnavailable)
        XCTAssertEqual(f.screen, .capture)
        XCTAssertEqual(f.preflightWarning, NurseCopy.lowBatteryWarning)
    }
}
