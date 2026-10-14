import Foundation

public struct FaceObservation: Equatable {
    public var yawDeg: Double
    public var pitchDeg: Double
    public var rollDeg: Double
    /// Face width as a fraction of frame width (0...1).
    public var faceWidthFraction: Double
    /// Depth-derived distance; nil when no depth data is available.
    public var distanceCm: Double?
    public var estimatedLux: Double
    /// RMS landmark jitter as a fraction of face width.
    public var landmarkJitter: Double

    public init(yawDeg: Double, pitchDeg: Double, rollDeg: Double, faceWidthFraction: Double,
                distanceCm: Double?, estimatedLux: Double, landmarkJitter: Double) {
        self.yawDeg = yawDeg; self.pitchDeg = pitchDeg; self.rollDeg = rollDeg
        self.faceWidthFraction = faceWidthFraction; self.distanceCm = distanceCm
        self.estimatedLux = estimatedLux; self.landmarkJitter = landmarkJitter
    }
}

public enum GuidanceCue: Equatable {
    case moveCloser, moveBack, centreFace, tiltPhone, tooDark, lightBehind, holdStill, ready
}

public struct GuidanceThresholds: Equatable {
    public var minDistanceCm = 20.0
    public var maxDistanceCm = 80.0
    public var minFaceWidth = 0.40
    public var maxFaceWidth = 0.60
    public var maxAngleDeg = 15.0
    public var minLux = 200.0
    public var maxJitter = 0.02
    public static let `default` = GuidanceThresholds()
    public init() {}
}

public enum Guidance {
    /// Cues in fixed priority order: lighting (tooDark, lightBehind) -> distance -> framing
    /// (face width) -> angle (tiltPhone) -> stillness (holdStill). `[.ready]` only when none apply.
    /// Distance and face width can each emit a move cue; an identical cue is not repeated.
    /// `distanceCm == nil` (no depth data) skips the distance check; face width still applies.
    /// `centreFace` is reserved: FaceObservation carries no face position, so it is not produced yet.
    public static func cues(for o: FaceObservation, backlit: Bool,
                            thresholds t: GuidanceThresholds = .default) -> [GuidanceCue] {
        var out: [GuidanceCue] = []
        func add(_ c: GuidanceCue) { if !out.contains(c) { out.append(c) } }

        if o.estimatedLux < t.minLux { add(.tooDark) }
        if backlit { add(.lightBehind) }
        if let d = o.distanceCm {
            if d < t.minDistanceCm { add(.moveBack) } else if d > t.maxDistanceCm { add(.moveCloser) }
        }
        if o.faceWidthFraction < t.minFaceWidth { add(.moveCloser) }
        else if o.faceWidthFraction > t.maxFaceWidth { add(.moveBack) }
        if abs(o.yawDeg) > t.maxAngleDeg || abs(o.pitchDeg) > t.maxAngleDeg || abs(o.rollDeg) > t.maxAngleDeg {
            add(.tiltPhone)
        }
        if o.landmarkJitter > t.maxJitter { add(.holdStill) }
        return out.isEmpty ? [.ready] : out
    }
}
