import XCTest
@testable import DengueCaptureCore

final class CaptureFlowTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let okPreflight = Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8)

    func consent(allowed: Bool = true, block: String? = nil) -> ConsentStatus {
        ConsentStatus(primaryResearch: allowed, consentVersion: "v1", currentVersion: "v1",
                      withdrawn: false, captureAllowed: allowed, blockCode: block,
                      checkedAt: "2026-10-15T00:00:00Z")
    }

    func flowAtAssent() -> CaptureFlow {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: "B3")
        f.submitConsent(consent(), snapshotAt: now, online: true, now: now)
        return f
    }

    func flowAtVitals() -> CaptureFlow {
        let f = flowAtAssent()
        f.giveAssent()
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        return f
    }

    func flowAtCapture() -> CaptureFlow {
        let f = flowAtVitals()
        f.submitVitals([.hr: VitalEntry(text: "88")], now: now)
        return f
    }

    func runStep(_ f: CaptureFlow, duration: Double = 40) {
        f.positionedForTest(); f.stepRecorded(duration: duration); f.verdict(.accept)
    }

    func testHappyPathReachesSaved() {
        let f = CaptureFlow(preflight: okPreflight)
        XCTAssertEqual(f.screen, .patientSelect)
        f.selectPatient(participantCode: "DS-417", bedLabel: "B3")
        XCTAssertEqual(f.screen, .consent)
        f.submitConsent(consent(), snapshotAt: now, online: true, now: now)
        XCTAssertEqual(f.screen, .assent)
        f.giveAssent()
        XCTAssertEqual(f.screen, .checklist)
        f.proceedFromChecklist()
        XCTAssertEqual(f.screen, .checklist, "unticked checklist cannot proceed")
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        XCTAssertEqual(f.screen, .referenceVitals)
        f.submitVitals([.hr: VitalEntry(text: "88")], now: now)
        XCTAssertEqual(f.screen, .capture)
        XCTAssertEqual(f.currentStep, .neutralFace)
        runStep(f)
        XCTAssertEqual(f.screen, .capture)
        XCTAssertEqual(f.currentStep, .fingertipPPG)
        runStep(f, duration: 30)
        XCTAssertEqual(f.screen, .qualityResult)
        f.continueFromQuality()
        XCTAssertEqual(f.screen, .saved)
        XCTAssertEqual(f.savedMessage, NurseCopy.saved)
        XCTAssertEqual(f.monitorHR, 88)
    }

    func testInvalidConsentBlocksWithNoPathToCapture() {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: nil)
        f.submitConsent(consent(allowed: false, block: "DS_REG_001"), snapshotAt: now, online: true, now: now)
        XCTAssertEqual(f.screen, .consent)
        XCTAssertEqual(f.blockingMessage, NurseCopy.consentBlocked)
        XCTAssertFalse(f.canCapture)
        f.giveAssent(); f.proceedFromChecklist(); f.submitVitals([.hr: VitalEntry(text: "80")], now: now); f.positionedForTest()
        XCTAssertEqual(f.screen, .consent)
        XCTAssertNil(f.currentStep)
    }

    func testSupersededConsentShowsRenewal() {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: nil)
        f.submitConsent(consent(allowed: false, block: "DS_REG_002"), snapshotAt: now, online: true, now: now)
        XCTAssertEqual(f.blockingMessage, NurseCopy.consentRenewal)
        XCTAssertFalse(f.canCapture)
    }

    func testBlockedWithoutCodeFallsBackToConsentBlocked() {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: nil)
        f.submitConsent(consent(allowed: false, block: nil), snapshotAt: now, online: true, now: now)
        XCTAssertEqual(f.blockingMessage, NurseCopy.consentBlocked)
    }

    func testOfflineSnapshotOlderThan24hBlocks() {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: nil)
        f.submitConsent(consent(), snapshotAt: now.addingTimeInterval(-24 * 3600 - 1), online: false, now: now)
        XCTAssertEqual(f.screen, .consent)
        XCTAssertEqual(f.blockingMessage, NurseCopy.consentBlocked)
        XCTAssertFalse(f.canCapture)
    }

    func testOfflineSnapshotWithin24hAllowed() {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: nil)
        f.submitConsent(consent(), snapshotAt: now.addingTimeInterval(-23 * 3600), online: false, now: now)
        XCTAssertEqual(f.screen, .assent)
    }

    func testOnlineIgnoresSnapshotAge() {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: nil)
        f.submitConsent(consent(), snapshotAt: now.addingTimeInterval(-99 * 3600), online: true, now: now)
        XCTAssertEqual(f.screen, .assent)
    }

    func testBannerOnEveryScreen() {
        XCTAssertEqual(CaptureFlow.bannerText,
            "Research Use Only — not for diagnosis or treatment decisions. Continue standard care and blood tests.")
        for s in FlowScreen.allCases { XCTAssertTrue(s.showsBanner, "\(s)") }
    }

    func testExperimentalAbsentWhenDisabled() {
        let r = ExperimentalResponse(enabled: false, items: [
            .init(domain: .rppgFace, pulseRateBpm: 80)])
        let p = ExperimentalPulsePresenter.present(r, monitorHR: 88)
        XCTAssertEqual(p.monitor, NurseCopy.monitorLine(88))
        XCTAssertTrue(p.experimental.isEmpty)
    }

    func testThermalSeriousDuringRecordingInterruptsAndShowsPhoneWarm() {
        let f = flowAtCapture()
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
        f.thermalChanged(.serious)
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        XCTAssertEqual(f.blockingMessage, NurseCopy.phoneWarm)
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace), "cannot start while warm")
        f.thermalChanged(.nominal)
        XCTAssertNil(f.blockingMessage)
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1), "attempt not consumed")
    }

    func testVitalsSkippableOnlyWithReason() {
        let f = flowAtVitals()
        f.submitVitals([:], now: now)
        XCTAssertEqual(f.screen, .referenceVitals, "empty vitals do not proceed")
        f.skipVitals(reason: nil)
        XCTAssertEqual(f.screen, .referenceVitals)
        f.skipVitals(reason: .monitorUnavailable)
        XCTAssertEqual(f.screen, .capture)
        XCTAssertNil(f.monitorHR)
        XCTAssertEqual(f.vitalsSkipReason, .monitorUnavailable)
    }

    func testAssentDeclinedIsTerminal() {
        let f = flowAtAssent()
        f.declineAssent()
        XCTAssertEqual(f.screen, .patientDeclined)
        XCTAssertEqual(f.blockingMessage, NurseCopy.patientDeclined)
        f.giveAssent(); f.proceedFromChecklist()
        XCTAssertEqual(f.screen, .patientDeclined)
        XCTAssertFalse(f.canCapture)
        f.reset()
        XCTAssertEqual(f.screen, .patientSelect)
    }

    func testComeBackLaterFromChecklist() {
        let f = flowAtAssent()
        f.giveAssent()
        f.comeBackLater()
        XCTAssertEqual(f.screen, .comeBackLater)
        XCTAssertEqual(f.blockingMessage, NurseCopy.comeBackLater)
    }

    func testLowStorageBlocksCapture() {
        let f = CaptureFlow(preflight: Preflight(freeBytes: 1, batteryLevel: 0.9))
        f.selectPatient(participantCode: "DS-417", bedLabel: nil)
        f.submitConsent(consent(), snapshotAt: now, online: true, now: now)
        f.giveAssent()
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        f.submitVitals([.hr: VitalEntry(text: "80")], now: now)
        XCTAssertEqual(f.screen, .blocked)
        XCTAssertEqual(f.blockingMessage, NurseCopy.lowStorage)
    }

    func testAcquisitionFailureSavedCopy() {
        let f = flowAtCapture()
        for _ in 0..<2 {
            for _ in 0..<3 {
                f.positionedForTest(); f.stepRecorded(duration: 40); f.verdict(.recapture([.dsQG002]))
            }
        }
        XCTAssertEqual(f.screen, .qualityResult)
        XCTAssertEqual(f.stepReasons(.neutralFace), [.dsQG002])
        f.continueFromQuality()
        XCTAssertEqual(f.screen, .saved)
        XCTAssertEqual(f.savedMessage, NurseCopy.acquisitionFailure)
    }

    func testPartialUsesAcquisitionFailureCopy() {
        let f = flowAtCapture()
        runStep(f)
        for _ in 0..<3 { f.positionedForTest(); f.stepRecorded(duration: 30); f.verdict(.recapture([.dsQG005])) }
        XCTAssertEqual(f.screen, .qualityResult)
        f.continueFromQuality()
        XCTAssertEqual(f.savedMessage, NurseCopy.acquisitionFailure)
    }

    func testStepEventsIgnoredOutsideCapture() {
        let f = flowAtVitals()
        f.positionedForTest(); f.verdict(.accept)
        XCTAssertEqual(f.screen, .referenceVitals)
        XCTAssertNil(f.machineState)
    }
}
