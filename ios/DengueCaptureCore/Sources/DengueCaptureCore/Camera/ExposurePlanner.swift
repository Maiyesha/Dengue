import Foundation

/// Converts the exposure auto-exposure converged on during positioning into the locked capture exposure (I1).
///
/// The locked duration is 10 or 20 ms (50 Hz mains); the sensor gain is scaled so the image brightness stays
/// what auto exposure chose: ISO' = ISO * duration / duration', then clamped into the device range.
public enum ExposurePlanner {
    /// Invalid inputs (non-finite or non-positive) fall back to the bottom of the range: under-exposed is
    /// recoverable by guidance (`tooDark`), a blown-out trace is not.
    public static func iso(currentISO: Float, currentDurationMs: Double, targetDurationMs: Double,
                           isoRange: ClosedRange<Float>) -> Float {
        guard currentISO.isFinite, currentISO > 0, currentDurationMs.isFinite, currentDurationMs > 0,
              targetDurationMs.isFinite, targetDurationMs > 0 else { return isoRange.lowerBound }
        let scaled = Double(currentISO) * currentDurationMs / targetDurationMs
        guard scaled.isFinite else { return isoRange.upperBound }
        return min(max(Float(scaled), isoRange.lowerBound), isoRange.upperBound)
    }
}
