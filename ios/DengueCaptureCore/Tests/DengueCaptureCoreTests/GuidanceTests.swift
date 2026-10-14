import XCTest
@testable import DengueCaptureCore

final class GuidanceTests: XCTestCase {
    private func obs(yaw: Double = 0, pitch: Double = 0, roll: Double = 0, width: Double = 0.5,
                     distance: Double? = 40, lux: Double = 400, jitter: Double = 0.01,
                     centre: FaceCentreOffset? = nil) -> FaceObservation {
        FaceObservation(yawDeg: yaw, pitchDeg: pitch, rollDeg: roll, faceWidthFraction: width,
                        distanceCm: distance, estimatedLux: lux, landmarkJitter: jitter,
                        faceCentreOffset: centre)
    }

    func testAllGoodGivesReady() {
        XCTAssertEqual(Guidance.cues(for: obs(), backlit: false), [.ready])
    }

    func testYaw16GivesTiltPhone() {
        XCTAssertEqual(Guidance.cues(for: obs(yaw: 16), backlit: false), [.tiltPhone])
    }

    func testAngleBoundaryInclusive() {
        XCTAssertEqual(Guidance.cues(for: obs(yaw: 15, pitch: -15, roll: 15), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(pitch: -15.1), backlit: false), [.tiltPhone])
        XCTAssertEqual(Guidance.cues(for: obs(roll: 15.1), backlit: false), [.tiltPhone])
    }

    func testDistance15GivesMoveBack() {
        XCTAssertEqual(Guidance.cues(for: obs(distance: 15), backlit: false), [.moveBack])
    }

    func testDistanceAbove80GivesMoveCloser() {
        XCTAssertEqual(Guidance.cues(for: obs(distance: 85), backlit: false), [.moveCloser])
    }

    func testDistanceBoundariesInclusive() {
        XCTAssertEqual(Guidance.cues(for: obs(distance: 20), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(distance: 80), backlit: false), [.ready])
    }

    func testFaceWidthBounds() {
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.39, distance: nil), backlit: false), [.moveCloser])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.61, distance: nil), backlit: false), [.moveBack])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.4, distance: nil), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.6, distance: nil), backlit: false), [.ready])
    }

    func testNilDistanceSkipsDistanceCheckButFaceWidthStillApplies() {
        XCTAssertEqual(Guidance.cues(for: obs(distance: nil), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.3, distance: nil), backlit: false), [.moveCloser])
    }

    func testDepthCueWinsOverConflictingFaceWidth() {
        // width 0.7 says moveBack, depth 90 cm says moveCloser: only the depth cue is emitted.
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.7, distance: 90), backlit: false), [.moveCloser])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.3, distance: 15), backlit: false), [.moveBack])
        // Depth in range suppresses width distance cues entirely.
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.7, distance: 40), backlit: false), [.ready])
    }

    func testCentreOffsetBoundary() {
        XCTAssertEqual(Guidance.cues(for: obs(centre: .init(dx: 0.15, dy: -0.15)), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(centre: .init(dx: 0.16, dy: 0)), backlit: false), [.centreFace])
        XCTAssertEqual(Guidance.cues(for: obs(centre: .init(dx: 0, dy: -0.16)), backlit: false), [.centreFace])
        XCTAssertEqual(Guidance.cues(for: obs(centre: nil), backlit: false), [.ready])
    }

    func testNonFiniteInputsNeverReady() {
        let nan = Double.nan
        XCTAssertEqual(Guidance.cues(for: obs(yaw: nan), backlit: false), [.tiltPhone])
        XCTAssertEqual(Guidance.cues(for: obs(pitch: .infinity), backlit: false), [.tiltPhone])
        XCTAssertEqual(Guidance.cues(for: obs(roll: nan), backlit: false), [.tiltPhone])
        XCTAssertEqual(Guidance.cues(for: obs(lux: nan), backlit: false), [.tooDark])
        XCTAssertEqual(Guidance.cues(for: obs(jitter: nan), backlit: false), [.holdStill])
        XCTAssertEqual(Guidance.cues(for: obs(width: nan), backlit: false), [.centreFace])
        XCTAssertEqual(Guidance.cues(for: obs(width: nan, distance: nil), backlit: false), [.centreFace])
        XCTAssertEqual(Guidance.cues(for: obs(centre: .init(dx: nan, dy: 0)), backlit: false), [.centreFace])
        XCTAssertEqual(Guidance.cues(for: obs(distance: nan), backlit: false), Guidance.cues(for: obs(distance: nil), backlit: false))  // non-finite distance treated as absent
    }

    func testLux150GivesTooDark() {
        XCTAssertEqual(Guidance.cues(for: obs(lux: 150), backlit: false), [.tooDark])
    }

    func testLuxBoundaryInclusive() {
        XCTAssertEqual(Guidance.cues(for: obs(lux: 200), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(lux: 199.9), backlit: false), [.tooDark])
    }

    func testBacklitGivesLightBehind() {
        XCTAssertEqual(Guidance.cues(for: obs(), backlit: true), [.lightBehind])
    }

    func testJitterBoundary() {
        XCTAssertEqual(Guidance.cues(for: obs(jitter: 0.02), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(jitter: 0.021), backlit: false), [.holdStill])
    }

    func testMultipleProblemsOrderedLightingDistanceCentreAngleStillness() {
        let o = obs(yaw: 20, width: 0.7, distance: 90, lux: 100, jitter: 0.1, centre: .init(dx: 0.3, dy: 0))
        XCTAssertEqual(Guidance.cues(for: o, backlit: true),
                       [.tooDark, .lightBehind, .moveCloser, .centreFace, .tiltPhone, .holdStill])
    }

    func testCustomThresholds() {
        var t = GuidanceThresholds.default
        t.maxAngleDeg = 30
        XCTAssertEqual(Guidance.cues(for: obs(yaw: 20), backlit: false, thresholds: t), [.ready])
    }
}
