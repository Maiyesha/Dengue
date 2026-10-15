import Foundation
import DengueCaptureCore

/// One finished recording attempt.
struct StepRecording {
    let token: UUID
    let step: CaptureStep
    let attempt: Int
    /// Lossless ROI trace extracted before compression.
    let trace: ROITrace
    /// Last minus first frame timestamp.
    let duration: Double
    /// Plaintext HEVC file (Class B); nil for the UI-test fake.
    let videoURL: URL?
    let metadata: CaptureMetadata
}

/// Source of per-step recordings: `CameraRecorder` in production, `FakeCamera` for UI tests.
protocol CaptureCameraProviding: AnyObject {
    /// Records the step for `seconds` under `rec`'s token. `onTick` fires about once per second (any queue).
    /// Throws if cancelled (pause / interruption) or the camera is not ready; the partial file is then deleted.
    func record(_ rec: RecordingSession, seconds: Double,
                onTick: @escaping (Double) -> Void) async throws -> StepRecording
    /// Discards the partial recording of exactly this attempt.
    func cancel(_ rec: RecordingSession)
    /// Stops the camera (and torch) between sessions.
    func stop()
}

/// Used when UITEST_FAKE_CAMERA=1: emits a synthetic plausible trace instantly, no video file.
final class FakeCamera: CaptureCameraProviding {
    func record(_ rec: RecordingSession, seconds: Double,
                onTick: @escaping (Double) -> Void) async throws -> StepRecording {
        let fps = 30.0
        let base: (r: Double, g: Double, b: Double) = rec.step == .fingertipPPG ? (200, 40, 30) : (120, 150, 90)
        var state: UInt64 = 7
        func noise() -> Double {   // deterministic LCG in [-1, 1]
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
        for i in 0...Int(seconds * fps) {
            let t = Double(i) / fps
            let s = sin(2 * Double.pi * 1.2 * t)
            rec.accept(sample: FrameSample(
                pts: t, meanR: base.r * (1 + 0.002 * s + 0.004 * noise()),
                meanG: base.g * (1 + 0.01 * s + 0.004 * noise()), meanB: base.b * (1 + 0.004 * s + 0.004 * noise()),
                lumaStdDev: 8, fractionRClipped: 0.1))
            if let e = rec.tickDue() { onTick(e) }
        }
        guard rec.isCurrent(token: rec.token) else { throw CancellationError() }
        let trace = rec.finish()
        let duration = (trace.timestamps.last ?? 0) - (trace.timestamps.first ?? 0)
        let meta = CaptureMetadata(
            deviceModel: "uitest", step: rec.step, attempt: rec.attempt,
            cameraRole: rec.step == .fingertipPPG ? .rearFingertip : .frontFace, fps: fps, resolution: "1080x1920",
            exposureDurationMs: 10, iso: 100, torchLevel: 0, distanceCm: nil, angleDeg: nil, lux: nil,
            mount: "holder", lightingType: "overhead", ambientTempC: nil, ambientHumidityPct: nil,
            durationSeconds: duration, frameCount: trace.samples.count, videoCodec: "none", videoAverageBitRate: 0)
        return StepRecording(token: rec.token, step: rec.step, attempt: rec.attempt, trace: trace,
                             duration: duration, videoURL: nil, metadata: meta)
    }

    func cancel(_ rec: RecordingSession) { rec.finish() }
    func stop() {}
}
