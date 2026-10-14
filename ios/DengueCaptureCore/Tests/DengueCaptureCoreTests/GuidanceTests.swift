import XCTest
@testable import DengueCaptureCore

final class GuidanceTests: XCTestCase {
    private func obs(yaw: Double = 0, pitch: Double = 0, roll: Double = 0, width: Double = 0.5,
                     distance: Double? = 40, lux: Double = 400, jitter: Double = 0.01) -> FaceObservation {
        FaceObservation(yawDeg: yaw, pitchDeg: pitch, rollDeg: roll, faceWidthFraction: width,
                        distanceCm: distance, estimatedLux: lux, landmarkJitter: jitter)
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
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.39), backlit: false), [.moveCloser])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.61), backlit: false), [.moveBack])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.4), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.6), backlit: false), [.ready])
    }

    func testNilDistanceSkipsDistanceCheckButFaceWidthStillApplies() {
        XCTAssertEqual(Guidance.cues(for: obs(distance: nil), backlit: false), [.ready])
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.3, distance: nil), backlit: false), [.moveCloser])
    }

    func testDistanceAndWidthAgreeingProduceSingleCue() {
        XCTAssertEqual(Guidance.cues(for: obs(width: 0.7, distance: 15), backlit: false), [.moveBack])
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

    func testMultipleProblemsOrderedLightingDistanceFramingAngleStillness() {
        let o = obs(yaw: 20, width: 0.7, distance: 90, lux: 100, jitter: 0.1)
        // distance says moveCloser (90 cm), width says moveBack (70%): both reported, distance first.
        XCTAssertEqual(Guidance.cues(for: o, backlit: true),
                       [.tooDark, .lightBehind, .moveCloser, .moveBack, .tiltPhone, .holdStill])
    }

    func testCustomThresholds() {
        var t = GuidanceThresholds.default
        t.maxAngleDeg = 30
        XCTAssertEqual(Guidance.cues(for: obs(yaw: 20), backlit: false, thresholds: t), [.ready])
    }
}
