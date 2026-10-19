import Foundation

public struct FrameStats: Equatable {
    /// Channel means, 0-255.
    public var meanR: Double, meanG: Double, meanB: Double
    public var lumaStdDev: Double
    public var fractionRClipped: Double

    public init(meanR: Double, meanG: Double, meanB: Double, lumaStdDev: Double, fractionRClipped: Double) {
        self.meanR = meanR; self.meanG = meanG; self.meanB = meanB
        self.lumaStdDev = lumaStdDev; self.fractionRClipped = fractionRClipped
    }
}

public struct FingertipThresholds: Equatable {
    public var minMeanR = 120.0
    public var maxGreenRatio = 0.6
    public var maxBlueRatio = 0.6
    /// Strictly less than.
    public var maxLumaStdDev = 25.0
    public var maxFractionRClipped = 0.5
    public static let `default` = FingertipThresholds()
    public init() {}
}

public enum FingertipCoverage {
    public static func evaluate(_ s: FrameStats, thresholds t: FingertipThresholds = .default)
        -> (covered: Bool, reason: ReasonCode?) {
        let covered = s.meanR >= t.minMeanR
            && s.meanG / s.meanR <= t.maxGreenRatio
            && s.meanB / s.meanR <= t.maxBlueRatio
            && s.lumaStdDev < t.maxLumaStdDev
            && s.fractionRClipped <= t.maxFractionRClipped
        return covered ? (true, nil) : (false, .dsQG005)
    }
}
