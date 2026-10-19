import Foundation

/// One mean-RGB sample of the skin region of interest for a single video frame.
public struct RGBSample: Equatable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Pulse-signal plausibility gate using the POS rPPG projection (Wang et al., 2017).
///
/// Pass/fail only. By design (spec section 8) no heart-rate value is returned or exposed:
/// the peak frequency is computed internally and discarded.
///
/// Failure reasons:
/// - `DS_RPPG_002`: a clear spectral tone exists but lies outside 0.7-3.5 Hz (e.g. 5 Hz flicker, 0.5 Hz drift).
/// - `DS_RPPG_001`: everything else that fails, i.e. SNR below `minSNRdB`, plus degenerate input
///   (fps <= 0, non-finite samples, trace shorter than two 1.6 s windows, or sigma(S2) == 0 for every window
///   so the projection is undefined).
public enum PulsePlausibility {
    static let windowSeconds = 1.6
    static let bandLow = 0.7
    static let bandHigh = 3.5
    static let guardHz = 0.1
    /// Lowest frequency considered when looking for an out-of-band tone (below this is DC/drift).
    static let scanLow = 0.1
    static let gridStep = 0.02

    public static func evaluate(
        trace: [RGBSample],
        fps: Double,
        minSNRdB: Double = 6
    ) -> (passed: Bool, reason: ReasonCode?) {
        guard fps.isFinite, fps > 0 else { return (false, .dsRPPG001) }
        let window = Int((windowSeconds * fps).rounded())
        guard window >= 4, trace.count >= 2 * window else { return (false, .dsRPPG001) }
        guard let h = posSignal(trace: trace, window: window) else { return (false, .dsRPPG001) }

        let nyquist = fps / 2
        guard nyquist > bandHigh else { return (false, .dsRPPG001) }
        let spec = periodogram(h, fps: fps, low: scanLow, high: nyquist)
        guard !spec.power.isEmpty else { return (false, .dsRPPG001) }
        let threshold = pow(10, minSNRdB / 10)

        // 1. Clear tone outside the plausible band -> DS_RPPG_002.
        if let g = spec.power.indices.max(by: { spec.power[$0] < spec.power[$1] }) {
            let f = spec.freq[g]
            if f < bandLow || f > bandHigh {
                let (sig, noise) = split(spec, peak: f, harmonic: false, lo: scanLow, hi: nyquist)
                if sig > 0, noise <= 0 || sig / noise >= threshold { return (false, .dsRPPG002) }
            }
        }

        // 2. In-band peak and SNR.
        var bestIdx: Int?
        for i in spec.power.indices where spec.freq[i] >= bandLow && spec.freq[i] <= bandHigh {
            if bestIdx == nil || spec.power[i] > spec.power[bestIdx!] { bestIdx = i }
        }
        guard let p = bestIdx, spec.power[p] > 0 else { return (false, .dsRPPG001) }
        let (sig, noise) = split(spec, peak: spec.freq[p], harmonic: true, lo: bandLow, hi: bandHigh)
        if noise <= 0 { return (true, nil) }
        let snrDB = 10 * log10(sig / noise)
        return snrDB >= minSNRdB ? (true, nil) : (false, .dsRPPG001)
    }

    // MARK: - Internals (not public: they would reveal the pulse frequency)

    /// POS projection with 1.6 s sliding windows (hop 1) and overlap-add. Returns nil if undefined.
    static func posSignal(trace: [RGBSample], window l: Int) -> [Double]? {
        let n = trace.count
        var h = [Double](repeating: 0, count: n)
        var anyValid = false
        var s1 = [Double](repeating: 0, count: l)
        var s2 = [Double](repeating: 0, count: l)
        for start in 0...(n - l) {
            var mr = 0.0, mg = 0.0, mb = 0.0
            for i in start..<(start + l) {
                let s = trace[i]
                guard s.r.isFinite, s.g.isFinite, s.b.isFinite else { return nil }
                mr += s.r; mg += s.g; mb += s.b
            }
            let d = Double(l)
            mr /= d; mg /= d; mb /= d
            guard mr > 0, mg > 0, mb > 0 else { continue }
            for k in 0..<l {
                let s = trace[start + k]
                let r = s.r / mr, g = s.g / mg, b = s.b / mb
                s1[k] = g - b
                s2[k] = g + b - 2 * r
            }
            let sd2 = stddev(s2)
            guard sd2 > 1e-12 else { continue }
            let alpha = stddev(s1) / sd2
            var hw = (0..<l).map { s1[$0] + alpha * s2[$0] }
            let m = hw.reduce(0, +) / d
            for k in 0..<l { hw[k] -= m }
            for k in 0..<l { h[start + k] += hw[k] }
            anyValid = true
        }
        return anyValid ? h : nil
    }

    static func stddev(_ x: [Double]) -> Double {
        let m = x.reduce(0, +) / Double(x.count)
        let v = x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
        return v.squareRoot()
    }

    /// Hann-windowed periodogram on a fixed frequency grid (naive DFT; n <= ~1400 so O(n*bins) is fine).
    /// Portable path used on every platform so pass/fail is identical everywhere.
    static func periodogram(_ x: [Double], fps: Double, low: Double, high: Double) -> (freq: [Double], power: [Double]) {
        let n = x.count
        let mean = x.reduce(0, +) / Double(n)
        var w = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let hann = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n - 1)))
            w[i] = (x[i] - mean) * hann
        }
        var freqs: [Double] = []
        var powers: [Double] = []
        var f = low
        while f <= high + 1e-9 {
            let omega = 2 * Double.pi * f / fps
            var re = 0.0, im = 0.0
            for i in 0..<n {
                let a = omega * Double(i)
                re += w[i] * cos(a)
                im -= w[i] * sin(a)
            }
            freqs.append(f)
            powers.append(re * re + im * im)
            f += gridStep
        }
        return (freqs, powers)
    }

    /// Signal power (within +-0.1 Hz of `peak`, and of 2*peak if `harmonic`) vs. remaining power in [lo, hi].
    static func split(_ spec: (freq: [Double], power: [Double]), peak: Double, harmonic: Bool, lo: Double, hi: Double) -> (signal: Double, noise: Double) {
        var sig = 0.0, noise = 0.0
        for i in spec.freq.indices {
            let f = spec.freq[i]
            guard f >= lo - 1e-9, f <= hi + 1e-9 else { continue }
            if abs(f - peak) <= guardHz + 1e-9 || (harmonic && abs(f - 2 * peak) <= guardHz + 1e-9) {
                sig += spec.power[i]
            } else {
                noise += spec.power[i]
            }
        }
        return (sig, noise)
    }
}
