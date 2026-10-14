import XCTest
@testable import DengueCaptureCore

/// Deterministic SplitMix64 + Box-Muller so the tests never depend on the system RNG.
private struct SeededRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { (Double(next() >> 11) + 0.5) / 9_007_199_254_740_992.0 }
    mutating func gaussian() -> Double {
        let u1 = uniform(), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

final class PulsePlausibilityTests: XCTestCase {
    private let fps = 30.0

    /// Skin-like RGB trace: a sinusoid of relative amplitude `amp` at `freq` Hz (strongest in G, weaker in R/B)
    /// plus Gaussian noise of relative std `noise` on each channel. `freq == nil` gives noise only.
    private func trace(freq: Double?, amp: Double, noise: Double, seconds: Double = 30, seed: UInt64 = 42) -> [RGBSample] {
        var rng = SeededRNG(state: seed)
        let n = Int(seconds * fps)
        return (0..<n).map { i in
            let t = Double(i) / fps
            let s = freq.map { sin(2 * Double.pi * $0 * t) } ?? 0
            let r = 120 * (1 + 0.2 * amp * s + noise * rng.gaussian())
            let g = 150 * (1 + amp * s + noise * rng.gaussian())
            let b = 90 * (1 + 0.4 * amp * s + noise * rng.gaussian())
            return RGBSample(r: r, g: g, b: b)
        }
    }

    func testPulse1p2HzWithModerateNoisePasses() {
        let result = PulsePlausibility.evaluate(trace: trace(freq: 1.2, amp: 0.01, noise: 0.004), fps: fps)
        XCTAssertTrue(result.passed)
        XCTAssertNil(result.reason)
    }

    func testWhiteNoiseFailsRPPG001() {
        for seed in UInt64(1)...5 {
            let result = PulsePlausibility.evaluate(trace: trace(freq: nil, amp: 0, noise: 0.01, seed: seed), fps: fps)
            XCTAssertFalse(result.passed, "seed \(seed)")
            XCTAssertEqual(result.reason, .dsRPPG001, "seed \(seed)")
        }
    }

    func testFiveHzFlickerAliasFailsRPPG002() {
        let result = PulsePlausibility.evaluate(trace: trace(freq: 5, amp: 0.01, noise: 0.002), fps: fps)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.reason, .dsRPPG002)
    }

    func testHalfHzSinusoidFailsRPPG002() {
        let result = PulsePlausibility.evaluate(trace: trace(freq: 0.5, amp: 0.01, noise: 0.002), fps: fps)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.reason, .dsRPPG002)
    }

    func testDegenerateInputsFailRPPG001() {
        let good = trace(freq: 1.2, amp: 0.01, noise: 0.004)
        XCTAssertEqual(PulsePlausibility.evaluate(trace: Array(good.prefix(60)), fps: fps).reason, .dsRPPG001)
        XCTAssertEqual(PulsePlausibility.evaluate(trace: [], fps: fps).reason, .dsRPPG001)
        XCTAssertEqual(PulsePlausibility.evaluate(trace: good, fps: 0).reason, .dsRPPG001)
        XCTAssertEqual(PulsePlausibility.evaluate(trace: good, fps: -30).reason, .dsRPPG001)
        // Constant trace -> sigma(S2) == 0
        let flat = [RGBSample](repeating: RGBSample(r: 100, g: 100, b: 100), count: 900)
        let r = PulsePlausibility.evaluate(trace: flat, fps: fps)
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.reason, .dsRPPG001)
    }

    func testPublicAPIExposesNoDoubleBpm() {
        // Compile-time check: the return type is exactly (passed: Bool, reason: ReasonCode?).
        let fn: ([RGBSample], Double, Double) -> (passed: Bool, reason: ReasonCode?) = { t, f, s in
            PulsePlausibility.evaluate(trace: t, fps: f, minSNRdB: s)
        }
        let result = fn([], 30, 6)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(Mirror(reflecting: result).children.count, 2)
    }
}
