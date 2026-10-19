import XCTest
import Foundation
@testable import DengueCaptureCore

extension CaptureFlow {
    /// Test helper: satisfies the face positioning gate (2 s of `[.ready]`) and then calls `positioned()`.
    func positionedForTest() {
        if case .positioning(.neutralFace)? = machineState {
            let t = (lastGuidanceTime ?? 0) + 10
            guidanceUpdate([.ready], at: t)
            guidanceUpdate([.ready], at: t + CaptureFlow.positioningHoldSeconds)
        }
        positioned()
    }
}

/// I1: positioning phase (2 s continuous `.ready` before recording) and ExposurePlanner.
final class PositioningTests: XCTestCase {
    func flowAtFace() -> CaptureFlow {
        let f = CaptureFlow(preflight: Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8))
        f.selectPatient(participantCode: "DS-1", bedLabel: nil)
        f.submitConsent(ConsentStatus(primaryResearch: true, consentVersion: "v", currentVersion: "v", withdrawn: false,
                                      captureAllowed: true, blockCode: nil, checkedAt: "x"),
                        snapshotAt: Date(), online: true, now: Date())
        f.giveAssent()
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        f.skipVitals(reason: .monitorUnavailable)
        return f
    }

    func testRecordingStartsOnlyAfterTwoSecondsOfReady() {
        let f = flowAtFace()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        f.positioned()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace), "no guidance yet: cannot start")
        f.guidanceUpdate([.ready], at: 100)
        f.guidanceUpdate([.ready], at: 101.9)
        XCTAssertFalse(f.positioningReady)
        f.positioned()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        f.guidanceUpdate([.ready], at: 102)
        XCTAssertTrue(f.positioningReady)
        f.positioned()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
    }

    func testAnyNonReadyCueRestartsTheHold() {
        let f = flowAtFace()
        f.guidanceUpdate([.ready], at: 0)
        f.guidanceUpdate([.ready], at: 1.5)
        f.guidanceUpdate([.moveCloser], at: 1.6)
        XCTAssertEqual(f.positioningCues, [.moveCloser])
        f.guidanceUpdate([.ready], at: 1.7)
        f.guidanceUpdate([.ready], at: 3.6)
        XCTAssertFalse(f.positioningReady)
        f.guidanceUpdate([.ready, .holdStill], at: 3.65)   // not exactly [.ready]
        f.guidanceUpdate([.ready], at: 3.7)
        f.guidanceUpdate([.ready], at: 5.7)
        XCTAssertTrue(f.positioningReady)
    }

    func testNonMonotonicOrNonFiniteTimeRestartsTheHold() {
        let f = flowAtFace()
        f.guidanceUpdate([.ready], at: 10)
        f.guidanceUpdate([.ready], at: 5)          // clock went backwards
        f.guidanceUpdate([.ready], at: 6.9)
        XCTAssertFalse(f.positioningReady)
        f.guidanceUpdate([.ready], at: .nan)
        f.guidanceUpdate([.ready], at: 20)
        f.guidanceUpdate([.ready], at: 21)
        XCTAssertFalse(f.positioningReady)
    }

    func testInterruptionResetsTheHold() {
        let f = flowAtFace()
        f.positionedForTest()
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
        f.pause()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace))
        XCTAssertFalse(f.positioningReady)
        XCTAssertNil(f.positioningCues)
        f.positioned()
        XCTAssertEqual(f.machineState, .positioning(.neutralFace), "must re-position after a pause")
    }

    func testFingertipStepHasNoFaceGate() {
        let f = flowAtFace()
        f.positionedForTest(); f.stepRecorded(duration: 40); f.verdict(.accept)
        XCTAssertEqual(f.machineState, .positioning(.fingertipPPG))
        f.guidanceUpdate([.tooDark], at: 1)   // ignored outside a face step
        XCTAssertNil(f.positioningCues)
        f.positioned()
        XCTAssertEqual(f.machineState, .recording(.fingertipPPG, attempt: 1))
    }

    func testGuidanceIgnoredWhileRecording() {
        let f = flowAtFace()
        f.positionedForTest()
        f.guidanceUpdate([.tooDark], at: 999)
        XCTAssertEqual(f.machineState, .recording(.neutralFace, attempt: 1))
    }

    // MARK: I2 repeat flow

    func testBeginRepeatStartsAtAssentWithOnlyTheListedSteps() {
        let repeatProtocol = CaptureProtocol.repeatProtocol(steps: [.fingertipPPG])
        XCTAssertEqual(repeatProtocol.steps.map { $0.step }, [.fingertipPPG])
        let f = CaptureFlow(protocol: repeatProtocol, preflight: Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8))
        f.beginRepeat(maskedCode: "\u{2022}\u{2022}417")
        XCTAssertEqual(f.screen, .assent)
        XCTAssertEqual(f.participantCode, "\u{2022}\u{2022}417")
        XCTAssertTrue(f.isRepeat)
        f.giveAssent()
        FlowChecklistItem.allCases.forEach { f.setChecklist($0, ticked: true) }
        f.proceedFromChecklist()
        f.skipVitals(reason: .monitorUnavailable)
        XCTAssertEqual(f.machineState, .positioning(.fingertipPPG))
        f.reset()
        XCTAssertFalse(f.isRepeat)
        let other = CaptureFlow(preflight: Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8))
        other.selectPatient(participantCode: "DS-1", bedLabel: nil)
        other.beginRepeat(maskedCode: "x")   // only from patient select
        XCTAssertEqual(other.screen, .consent)
    }

    // MARK: ExposurePlanner

    func testISOScalesToKeepExposureAndClamps() {
        // Auto exposure settled at 1/60 s (16.67 ms) ISO 100; locking 10 ms needs ISO 166.7.
        XCTAssertEqual(ExposurePlanner.iso(currentISO: 100, currentDurationMs: 16.6667, targetDurationMs: 10,
                                           isoRange: 25...2000), 166.667, accuracy: 0.01)
        XCTAssertEqual(ExposurePlanner.iso(currentISO: 1500, currentDurationMs: 33.3, targetDurationMs: 10,
                                           isoRange: 25...2000), 2000)
        XCTAssertEqual(ExposurePlanner.iso(currentISO: 30, currentDurationMs: 5, targetDurationMs: 20,
                                           isoRange: 25...2000), 25)
        XCTAssertEqual(ExposurePlanner.iso(currentISO: 200, currentDurationMs: 20, targetDurationMs: 20,
                                           isoRange: 25...2000), 200)
    }

    func testISOInvalidInputsFallBackInsideRange() {
        XCTAssertEqual(ExposurePlanner.iso(currentISO: .nan, currentDurationMs: 10, targetDurationMs: 10,
                                           isoRange: 25...2000), 25)
        XCTAssertEqual(ExposurePlanner.iso(currentISO: 100, currentDurationMs: 0, targetDurationMs: 10,
                                           isoRange: 25...2000), 25)
        XCTAssertEqual(ExposurePlanner.iso(currentISO: 100, currentDurationMs: 10, targetDurationMs: -1,
                                           isoRange: 25...2000), 25)
    }

    func testConfiguratorUsesPlannedISO() throws {
        let d = FakeDeviceControl()
        d.isoRange = 25...2000
        let s = try CameraConfigurator().configure(d, role: .frontFace, preferExposureMs: 10, targetISO: 640)
        XCTAssertEqual(s.iso, 640)
        let clamped = try CameraConfigurator().configure(FakeDeviceControl(), role: .frontFace, preferExposureMs: 10,
                                                         targetISO: 100_000)
        XCTAssertEqual(clamped.iso, FakeDeviceControl().isoRange.upperBound)
    }
}
