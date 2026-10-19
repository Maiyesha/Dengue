import Foundation

/// Pure geometry used by the recorder to read TrueDepth depth at the face found in rotated video buffers.
public enum SensorGeometry {
    /// Maps a normalised point (top-left origin) in a buffer rotated clockwise by `rotationDegrees` (0/90/180/270)
    /// back to normalised sensor coordinates (the unrotated depth map).
    public static func sensorPoint(rotatedU u: Double, rotatedV v: Double, rotationDegrees: Int) -> (x: Double, y: Double) {
        switch ((rotationDegrees % 360) + 360) % 360 {
        case 90: return (v, 1 - u)
        case 180: return (1 - u, 1 - v)
        case 270: return (1 - v, u)
        default: return (u, v)
        }
    }

    /// Median of the finite, positive depths (metres), in centimetres; nil when none.
    public static func medianDepthCm(meters: [Float]) -> Double? {
        let v = meters.filter { $0.isFinite && $0 > 0 }.map { Double($0) * 100 }.sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }
}
