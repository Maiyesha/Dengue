import Foundation
import DengueCaptureCore

/// Source of per-step recordings. Task 11 supplies the AVFoundation implementation.
protocol CaptureCameraProviding {
    /// Records `seconds` of the step and returns the measured duration.
    func record(step: CaptureStep, seconds: Double) async -> Double
}

/// Used when UITEST_FAKE_CAMERA=1: emits synthetic timestamps and RGB traces instantly.
struct FakeCamera: CaptureCameraProviding {
    func record(step: CaptureStep, seconds: Double) async -> Double {
        // Synthetic 30 fps timestamps; no real wait so UI tests stay fast.
        let frames = Int(seconds * 30)
        _ = (0..<frames).map { i in
            (t: Double(i) / 30.0, r: 150 + 5 * sin(Double(i) / 30.0 * 2 * .pi * 1.2), g: 90.0, b: 80.0)
        }
        return seconds
    }
}