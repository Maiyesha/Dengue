import XCTest
@testable import DengueCaptureCore

final class CaptureSessionMachineTests: XCTestCase {
    private let ok = Preflight(freeBytes: 5_000_000_000, batteryLevel: 0.8)

    private func make() -> CaptureSessionMachine {
        CaptureSessionMachine(protocol: .phaseADefault, preflight: ok)
    }

    private func record(_ m: CaptureSessionMachine, duration: Double = 40) {
        m.positioned()
        m.stepRecorded(duration: duration)
    }

    func testStartsPositioningNeutralFace() {
        XCTAssertEqual(make().state, .positioning(.neutralFace))
    }

    func testRecordingShorterThanMinimumYieldsRecaptureDSQG004Automatically() {
        let m = make()
        record(m, duration: 10)
        XCTAssertEqual(m.state, .positioning(.neutralFace))
        XCTAssertEqual(m.attempts(for: .neutralFace), 1)
        XCTAssertEqual(m.lastReasons[.neutralFace], [.dsQG004])
    }

    func testShortRecordingOnLastAttemptYieldsUnableToAcquire() {
        let m = make()
        for _ in 0..<3 { record(m, duration: 10) }
        XCTAssertEqual(m.attempts(for: .neutralFace), 3)
        XCTAssertEqual(m.state, .positioning(.fingertipPPG))
    }

    func testAcceptFaceMovesToPositioningFingertip() {
        let m = make()
        record(m)
        XCTAssertEqual(m.state, .reviewingStep(.neutralFace, attempt: 1))
        m.verdict(.accept)
        XCTAssertEqual(m.state, .positioning(.fingertipPPG))
    }

    func testThirdRecaptureOfFingertipYieldsUnableToAcquireAndAcquisitionFailure() {
        let m = make()
        for _ in 0..<3 { record(m); m.verdict(.recapture([.dsQG001])) }   // face fails
        XCTAssertEqual(m.state, .positioning(.fingertipPPG))
        record(m); m.verdict(.recapture([.dsQG001]))
        XCTAssertEqual(m.state, .positioning(.fingertipPPG))
        record(m); m.verdict(.recapture([.dsQG001]))
        XCTAssertEqual(m.state, .positioning(.fingertipPPG))
        record(m); m.verdict(.recapture([.dsQG001]))
        XCTAssertEqual(m.attempts(for: .fingertipPPG), 3)
        XCTAssertEqual(m.state, .completed(.acquisitionFailure))
    }

    func testInterruptionDiscardsPartialWithoutConsumingAttempt() {
        let m = make()
        m.positioned()
        XCTAssertEqual(m.state, .recording(.neutralFace, attempt: 1))
        m.interrupted()
        XCTAssertEqual(m.state, .positioning(.neutralFace))
        XCTAssertEqual(m.attempts(for: .neutralFace), 0)
        m.positioned()
        XCTAssertEqual(m.state, .recording(.neutralFace, attempt: 1))
    }

    func testFaceFailsCoreFingertipAcceptedYieldsPartial() {
        let m = make()
        record(m); m.verdict(.unableToAcquire([.dsQG001]))
        record(m); m.verdict(.accept)
        XCTAssertEqual(m.state, .completed(.partial(failedCore: [.neutralFace])))
    }

    func testAllAcceptedYieldsAccepted() {
        let m = make()
        record(m); m.verdict(.accept)
        record(m); m.verdict(.accept)
        XCTAssertEqual(m.state, .completed(.accepted))
    }

    func testLowStorageBlocksWithLowStorage() {
        let p = Preflight(freeBytes: 1_999_999_999, batteryLevel: 0.9)
        XCTAssertFalse(p.canStartCapture)
        XCTAssertEqual(p.blockReason, .lowStorage)
        let m = CaptureSessionMachine(protocol: .phaseADefault, preflight: p)
        XCTAssertEqual(m.state, .blocked(.lowStorage))
    }

    func testLowBatteryBlocks() {
        let m = CaptureSessionMachine(protocol: .phaseADefault,
                                      preflight: Preflight(freeBytes: 5_000_000_000, batteryLevel: 0.04))
        XCTAssertEqual(m.state, .blocked(.lowBattery))
    }

    func testPhaseADefaultHasCoreStepsOnly() {
        let p = CaptureProtocol.phaseADefault
        XCTAssertEqual(p.steps.map { $0.step }, [.neutralFace, .fingertipPPG])
        XCTAssertTrue(p.steps.allSatisfy { $0.isCore })
        XCTAssertEqual(p.maxRecapturesPerStep, 2)
    }
}
