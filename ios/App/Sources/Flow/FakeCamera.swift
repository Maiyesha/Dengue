import Foundation
import AVFoundation
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
    let metadata: CaptureMetadata
    /// Face step: medians of the observed distance / yaw / lux (reused by the fingertip step). nil otherwise.
    let positioning: PositioningSummary?
    /// Sealing of video + roi_trace + metadata, started at `finishWriting`; nil for the UI-test fake.
    let sealing: Task<[SealedStepArtefact], Never>?
}

/// Source of per-step recordings: `CameraRecorder` in production, `FakeCamera` for UI tests.
protocol CaptureCameraProviding: AnyObject {
    /// I1 positioning: preview running with auto exposure / white balance / focus. For the face step the camera
    /// evaluates Vision + TrueDepth + lux into `Guidance` cues (~5 Hz) and calls `onGuidance(cues, monotonicSeconds)`
    /// on any queue. Idempotent per step; replaced by the next call; ended by `record` or `stop`.
    func startPositioning(step: CaptureStep, onGuidance: @escaping ([GuidanceCue], Double) -> Void)
    /// Session for `AVCaptureVideoPreviewLayer` (nil for the UI-test fake).
    var previewSession: AVCaptureSession? { get }
    /// Records the step for `seconds` under `rec`'s token. `positioning` is the face step's summary, reused by
    /// the fingertip step's metadata. `onTick` fires about once per second (any queue).
    /// Throws if cancelled (pause / interruption) or the camera is not ready; the partial file is then deleted.
    func record(_ rec: RecordingSession, seconds: Double, positioning: PositioningSummary?,
                onTick: @escaping (Double) -> Void) async throws -> StepRecording
    /// Discards the partial recording of exactly this attempt.
    func cancel(_ rec: RecordingSession)
    /// R-2 (sign-in required while recording): ends exactly this attempt NOW but keeps what was recorded: the
    /// asset writer is finished and the torch turned off, and `record` returns the shorter `StepRecording` (with
    /// its sealing). If nothing was recorded yet, `record` throws as for `cancel`.
    func finishEarly(_ rec: RecordingSession)
    /// Stops the camera (and torch) between sessions.
    func stop()
}

/// Used when UITEST_FAKE_CAMERA=1: emits a synthetic plausible trace instantly, no video, nothing sealed.
final class FakeCamera: CaptureCameraProviding {
    var previewSession: AVCaptureSession? { nil }

    /// Face step: reports `[.ready]` for 2 s straight away so the positioning gate opens in UI tests.
    func startPositioning(step: CaptureStep, onGuidance: @escaping ([GuidanceCue], Double) -> Void) {
        guard step == .neutralFace else { return }
        let t = ProcessInfo.processInfo.systemUptime
        onGuidance([.ready], t)
        onGuidance([.ready], t + CaptureFlow.positioningHoldSeconds)
    }

    func record(_ rec: RecordingSession, seconds: Double, positioning: PositioningSummary?,
                onTick: @escaping (Double) -> Void) async throws -> StepRecording {
        let fps = 30.0
        let base: (r: Double, g: Double, b: Double) = rec.step == .fingertipPPG ? (200, 40, 30) : (120, 150, 90)
        var state: UInt64 = 7
        func noise() -> Double {   // deterministic, roughly Gaussian (Irwin-Hall of 12 uniforms)
            var s = 0.0
            for _ in 0..<12 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                s += Double(state >> 11) / Double(1 << 53)
            }
            return s - 6
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
        let summary = PositioningSummary(distanceCm: 45, angleDeg: 0, lux: 400)
        let meta = CaptureMetadata(
            deviceModel: "uitest", step: rec.step, attempt: rec.attempt,
            cameraRole: rec.step == .fingertipPPG ? .rearFingertip : .frontFace, fps: fps, resolution: "1080x1920",
            exposureDurationMs: 10, iso: 100, torchLevel: 0, distanceCm: nil, angleDeg: nil, lux: nil,
            mount: "holder", lightingType: "overhead", ambientTempC: nil, ambientHumidityPct: nil,
            durationSeconds: duration, frameCount: trace.samples.count, videoCodec: "none", videoAverageBitRate: 0)
            .withPositioning(summary)
        return StepRecording(token: rec.token, step: rec.step, attempt: rec.attempt, trace: trace,
                             duration: duration, metadata: meta,
                             positioning: rec.step == .neutralFace ? summary : nil, sealing: nil)
    }

    func cancel(_ rec: RecordingSession) { rec.finish() }
    /// The fake records synchronously: there is never a live attempt to end early.
    func finishEarly(_ rec: RecordingSession) {}
    func stop() {}
}
