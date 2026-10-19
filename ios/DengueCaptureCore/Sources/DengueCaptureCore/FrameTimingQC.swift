/// Result of the device-side frame-timing quality check.
public struct FrameTimingReport: Equatable {
    /// (count - 1) / (last - first), over the sorted timestamps.
    public let measuredFPS: Double
    /// Largest delta between consecutive sorted timestamps.
    public let maxGapSeconds: Double
    /// max(0, 1 - count / (duration * nominalFPS + 1)): fraction of the expected frame count
    /// (a fence-post count over the duration at the nominal rate) that is absent.
    public let missingFraction: Double
    /// last - first, over the sorted timestamps.
    public let durationSeconds: Double
    public let passed: Bool
    /// `.dsQG004` when `passed` is false, otherwise nil.
    public let reason: ReasonCode?
}

public enum FrameTimingQC {
    /// Provisional device-side thresholds (the server is authoritative).
    public static let maxAllowedGapSeconds = 0.5
    public static let maxAllowedMissingFraction = 0.05
    public static let minimumFPS = 20.0

    /// `timestamps` are presentation times in seconds. They are sorted first, because
    /// presentation timestamps can arrive out of order. Fewer than two timestamps fails.
    public static func evaluate(timestamps: [Double], nominalFPS: Double = 30, minimumSeconds: Double) -> FrameTimingReport {
        let ts = timestamps.sorted()
        guard ts.count >= 2, let first = ts.first, let last = ts.last else {
            return FrameTimingReport(measuredFPS: 0, maxGapSeconds: 0, missingFraction: 1,
                                     durationSeconds: 0, passed: false, reason: .dsQG004)
        }
        let duration = last - first
        let maxGap = zip(ts, ts.dropFirst()).map { $1 - $0 }.max() ?? 0
        let fps = duration > 0 ? Double(ts.count - 1) / duration : 0
        let expected = duration * nominalFPS + 1
        let missing = max(0, 1 - Double(ts.count) / expected)
        let passed = duration >= minimumSeconds
            && maxGap <= maxAllowedGapSeconds
            && missing < maxAllowedMissingFraction
            && fps >= minimumFPS
        return FrameTimingReport(measuredFPS: fps, maxGapSeconds: maxGap, missingFraction: missing,
                                 durationSeconds: duration, passed: passed, reason: passed ? nil : .dsQG004)
    }
}
