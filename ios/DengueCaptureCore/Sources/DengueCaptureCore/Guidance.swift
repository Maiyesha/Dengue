import Foundation

/// Normalised offset of the face centre from the frame centre (each axis roughly -0.5...0.5).
public struct FaceCentreOffset: Equatable {
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
}

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
    /// Face centre offset from frame centre; nil when unknown (centring check skipped).
    public var faceCentreOffset: FaceCentreOffset?

    public init(yawDeg: Double, pitchDeg: Double, rollDeg: Double, faceWidthFraction: Double,
                distanceCm: Double?, estimatedLux: Double, landmarkJitter: Double,
                faceCentreOffset: FaceCentreOffset? = nil) {
        self.yawDeg = yawDeg; self.pitchDeg = pitchDeg; self.rollDeg = rollDeg
        self.faceWidthFraction = faceWidthFraction; self.distanceCm = distanceCm
        self.estimatedLux = estimatedLux; self.landmarkJitter = landmarkJitter
        self.faceCentreOffset = faceCentreOffset
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
    public var maxCentreOffset = 0.15
    public static let `default` = GuidanceThresholds()
    public init() {}
}

public enum Guidance {
    /// Cues in fixed priority order: lighting (tooDark, lightBehind) -> distance (moveCloser/moveBack)
    /// -> centreFace -> tiltPhone -> holdStill. `[.ready]` only when none apply.
    /// Distance: when `distanceCm` is present and finite, the depth-derived cue is authoritative and the
    /// face-width distance cue is suppressed (so the nurse never sees opposite instructions). Face width
    /// drives moveCloser/moveBack only when no usable depth is available.
    /// Non-finite inputs never yield `.ready`: angles -> tiltPhone, lux -> tooDark, jitter -> holdStill,
    /// width or centre offset -> centreFace. A non-finite distance is treated as absent.
    /// `backlit` is caller-computed from the glare/shadow check over the forehead and cheeks (spec 7.1).
    public static func cues(for o: FaceObservation, backlit: Bool,
                            thresholds t: GuidanceThresholds = .default) -> [GuidanceCue] {
        var out: [GuidanceCue] = []
        func add(_ c: GuidanceCue) { if !out.contains(c) { out.append(c) } }

        if !o.estimatedLux.isFinite || o.estimatedLux < t.minLux { add(.tooDark) }
        if backlit { add(.lightBehind) }

        var needsCentre = false
        if let d = o.distanceCm, d.isFinite {
            if d < t.minDistanceCm { add(.moveBack) } else if d > t.maxDistanceCm { add(.moveCloser) }
            if !o.faceWidthFraction.isFinite { needsCentre = true }
        } else if !o.faceWidthFraction.isFinite {
            needsCentre = true
        } else if o.faceWidthFraction < t.minFaceWidth {
            add(.moveCloser)
        } else if o.faceWidthFraction > t.maxFaceWidth {
            add(.moveBack)
        }
        if let c = o.faceCentreOffset {
            if !c.dx.isFinite || !c.dy.isFinite
                || abs(c.dx) > t.maxCentreOffset || abs(c.dy) > t.maxCentreOffset { needsCentre = true }
        }
        if needsCentre { add(.centreFace) }

        let angles = [o.yawDeg, o.pitchDeg, o.rollDeg]
        if angles.contains(where: { !$0.isFinite || abs($0) > t.maxAngleDeg }) { add(.tiltPhone) }
        if !o.landmarkJitter.isFinite || o.landmarkJitter > t.maxJitter { add(.holdStill) }
        return out.isEmpty ? [.ready] : out
    }
}
