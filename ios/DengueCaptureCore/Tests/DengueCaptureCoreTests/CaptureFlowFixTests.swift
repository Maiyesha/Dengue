import XCTest
@testable import DengueCaptureCore

final class CaptureFlowFixTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let okPreflight = Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8)

    func consent() -> ConsentStatus {
        ConsentStatus(primaryResearch: true, consentVersion: "v1", currentVersion: "v1",
                      withdrawn: false, captureAllowed: true, blockCode: nil,
                      checkedAt: "2026-10-15T00:00:00Z")
    }

    func flowAtVitals() -> CaptureFlow {
        let f = CaptureFlow(preflight: okPreflight)
        f.selectPatient(participantCode: "DS-417", bedLabel: "B3")
        f.submitConsent(consent(), snapshotAt: now, online: true, now: now)
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
        f.positioned(); f.stepRecorded(duration: duration); f.verdict(.accept)
    }

    func testResetKeepsThermalHold() {
        let f = flowAtCapture()
        f.thermalChanged(.serious)
        f.reset()
        XCTAssertTrue(f.thermalHold)
        f.thermalChanged(.fair)
        XCTAssertFalse(f.thermalHold)
    }

    func testPauseDuringRecordingConsumesNoAttempt() {
        let f = flowAtCapture()
        f.positioned()
        f.pause()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        f.positioned()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
    }

    func testSnapshotMoreThanFiveMinutesInFutureFailsClosed() {
        for online in [true, false] {
            let f = CaptureFlow(preflight: okPreflight)
            f.selectPatient(participantCode: "DS-417", bedLabel: nil)
            f.submitConsent(consent(), snapshotAt: now.addingTimeInterval(301), online: online, now: now)
            XCTAssertEqual(f.screen, .consent)
            XCTAssertEqual(f.blockingMessage, NurseCopy.consentBlocked)
        }
        let ok = CaptureFlow(preflight: okPreflight)
        ok.selectPatient(participantCode: "DS-417", bedLabel: nil)
        ok.submitConsent(consent(), snapshotAt: now.addingTimeInterval(299), online: true, now: now)
        XCTAssertEqual(ok.screen, .assent)
    }

    // Vitals (spec 6.5)

    func testVitalsDecimalCommaLocale() {
        let f = flowAtVitals()
        f.submitVitals([.tempC: VitalEntry(text: "36,8")], now: now, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(f.screen, .capture)
        XCTAssertEqual(f.vitalRecords.first?.value, 36.8)
        let g = flowAtVitals()
        g.submitVitals([.tempC: VitalEntry(text: "36.8")], now: now, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(g.vitalRecords.first?.value, 36.8)
    }

    func testUnparseableVitalBlocksAndCannotBeConfirmed() {
        let f = flowAtVitals()
        for bad in ["abc", "nan", "0x10", "1.2.3", "36,8,1"] {
            f.submitVitals([.hr: VitalEntry(text: bad, confirmed: true)], now: now,
                           locale: Locale(identifier: "en_US"))
            XCTAssertEqual(f.screen, .referenceVitals, bad)
            XCTAssertEqual(f.vitalIssues[.hr], .unparseable, bad)
        }
    }

    func testOutOfRangeNeedsConfirmationAndIsFlaggedNotDropped() {
        let f = flowAtVitals()
        f.submitVitals([.hr: VitalEntry(text: "250"), .spo2: VitalEntry(text: "97")], now: now)
        XCTAssertEqual(f.screen, .referenceVitals)
        XCTAssertEqual(f.vitalIssues, [.hr: .outOfRange])
        f.submitVitals([.hr: VitalEntry(text: "250", confirmed: true), .spo2: VitalEntry(text: "97")], now: now)
        XCTAssertEqual(f.screen, .capture)
        XCTAssertEqual(f.vitalRecords.count, 2)
        XCTAssertEqual(f.vitalRecords.first { $0.field == .hr }?.isInvalid, true)
        XCTAssertEqual(f.vitalRecords.first { $0.field == .spo2 }?.isInvalid, false)
    }

    func testVitalRanges() {
        let r: [(VitalField, Double, Double)] = [
            (.hr, 30, 220), (.spo2, 50, 100), (.sbp, 40, 250), (.dbp, 20, 150),
            (.tempC, 32, 42), (.rr, 4, 60), (.crtS, 0, 10)]
        for (field, lo, hi) in r {
            XCTAssertEqual(field.range, lo...hi, "\(field)")
        }
    }

    func testVitalSourceAndMeasuredAtDefaults() {
        let f = flowAtVitals()
        let earlier = now.addingTimeInterval(-120)
        f.submitVitals([.hr: VitalEntry(text: "90"),
                        .tempC: VitalEntry(text: "37", source: .thermometer, measuredAt: earlier)], now: now)
        let hr = f.vitalRecords.first { $0.field == .hr }
        XCTAssertEqual(hr?.source, .bedsideMonitor)
        XCTAssertEqual(hr?.measuredAt, now)
        let t = f.vitalRecords.first { $0.field == .tempC }
        XCTAssertEqual(t?.source, .thermometer)
        XCTAssertEqual(t?.measuredAt, earlier)
        XCTAssertEqual(VitalSourceDevice.allCases.map { $0.rawValue },
            ["bedside_monitor", "pulse_oximeter", "thermometer", "manual_sphygmomanometer", "other"])
    }

    func testMonitorHRPromptFiresOnceAt20sOfFaceStep() {
        XCTAssertEqual(NurseCopy.noteMonitorHR, "Note the monitor heart rate now")
        let f = flowAtCapture()
        f.recordingElapsed(20)
        XCTAssertNil(f.pendingPrompt, "not recording yet")
        f.positioned()
        f.recordingElapsed(19.9)
        XCTAssertNil(f.pendingPrompt)
        f.recordingElapsed(20)
        XCTAssertEqual(f.pendingPrompt, NurseCopy.noteMonitorHR)
        f.consumePrompt()
        f.recordingElapsed(25)
        XCTAssertNil(f.pendingPrompt, "one-shot")
    }

    func testMonitorHRPromptNotOnFingertipOrWhenVitalsSkipped() {
        let f = flowAtCapture()
        runStep(f)
        f.positioned()
        f.recordingElapsed(25)
        XCTAssertNil(f.pendingPrompt)
        let g = flowAtVitals()
        g.skipVitals(reason: .monitorUnavailable)
        g.positioned(); g.recordingElapsed(25)
        XCTAssertNil(g.pendingPrompt)
    }

    // Status copy (spec 8)

    func testOverallStatusGood() {
        let f = flowAtCapture()
        runStep(f); runStep(f, duration: 30)
        XCTAssertEqual(f.statusMessage, NurseCopy.statusGood)
        XCTAssertEqual(f.stepStatus(.neutralFace), .passed)
    }

    func testRecordStepAgainAndRetryInstruction() {
        let f = flowAtCapture()
        XCTAssertNil(f.retryInstruction)
        f.positioned(); f.stepRecorded(duration: 40); f.verdict(.recapture([.dsQG002]))
        XCTAssertEqual(f.statusMessage, NurseCopy.recordStepAgain(1))
        XCTAssertEqual(f.retryInstruction, ReasonCode.dsQG002.nurseInstruction)
        XCTAssertEqual(f.stepStatus(.neutralFace), .recordAgain)
    }

    func testUnableToAcquireShowsCouldNotRecordNotRecordAgain() {
        let f = flowAtCapture()
        for _ in 0..<3 { f.positioned(); f.stepRecorded(duration: 40); f.verdict(.recapture([.dsQG002])) }
        XCTAssertEqual(f.stepStatus(.neutralFace), .couldNotRecord, "advanced past, so failed")
        runStep(f, duration: 30)
        XCTAssertEqual(f.screen, .qualityResult)
        XCTAssertEqual(f.statusMessage, NurseCopy.statusCouldNotRecord)
        XCTAssertEqual(f.stepStatus(.neutralFace), .couldNotRecord)
        XCTAssertEqual(f.stepStatus(.fingertipPPG), .passed)
        XCTAssertEqual(StepStatus.couldNotRecord.text, NurseCopy.statusCouldNotRecord)
        XCTAssertEqual(StepStatus.recordAgain.text, NurseCopy.stepRecordAgain)
    }

    func testFlowExposesProtocolStepsAndNames() {
        let f = flowAtCapture()
        XCTAssertEqual(f.steps.map { $0.step }, [.neutralFace, .fingertipPPG])
        XCTAssertEqual(CaptureStep.neutralFace.nurseName, NurseCopy.stepNameFace)
        XCTAssertEqual(CaptureStep.dorsalTongue.nurseName, NurseCopy.stepNameTongue)
    }

    func testStateSignatureChangesOnlyWhenStateChanges() {
        let f = flowAtCapture()
        let a = f.stateSignature
        f.pause()
        XCTAssertEqual(f.stateSignature, a, "no-op pause leaves the signature unchanged")
        f.positioned()
        XCTAssertNotEqual(f.stateSignature, a)
    }
}
