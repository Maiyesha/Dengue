import Foundation

/// One recording attempt: collects ROI samples under a per-attempt token.
///
/// A camera callback captures the token when the attempt starts and checks `isCurrent(token:)` before acting.
/// Once `finish()` has run (step done, paused, or interrupted), `accept(sample:)` ignores further samples and the
/// token is no longer current, so a stale camera Task from a paused attempt can never record into a later one.
/// Thread-safe: samples arrive on the camera queue, `finish()` usually runs on the main actor.
public final class RecordingSession: @unchecked Sendable {
    public let step: CaptureStep
    public let attempt: Int
    public let fps: Double
    public let token: UUID

    private let lock = NSLock()
    private var samples: [FrameSample] = []
    private var finished = false
    private var lastTickSecond = 0

    public init(step: CaptureStep, attempt: Int, fps: Double = CameraConfigurator.targetFPS, token: UUID = UUID()) {
        self.step = step; self.attempt = attempt; self.fps = fps; self.token = token
    }

    public func accept(sample: FrameSample) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        samples.append(sample)
    }

    /// True while this attempt is live and `token` is its token.
    public func isCurrent(token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished && token == self.token
    }

    public var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    public var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    /// Seconds between the first and the latest sample.
    public var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return elapsedLocked
    }

    private var elapsedLocked: Double {
        guard let f = samples.first, let l = samples.last else { return 0 }
        return max(0, l.pts - f.pts)
    }

    /// Returns the elapsed seconds once per whole second of recording (for `CaptureFlow.recordingElapsed`),
    /// otherwise nil. Nil after `finish()`.
    public func tickDue() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        let e = elapsedLocked
        let whole = Int(e.rounded(.down))
        guard whole > lastTickSecond else { return nil }
        lastTickSecond = whole
        return e
    }

    /// Ends the attempt (idempotent) and returns the samples collected before the first call.
    @discardableResult
    public func finish() -> ROITrace {
        lock.lock(); defer { lock.unlock() }
        finished = true
        return ROITrace(step: step, fps: fps, samples: samples)
    }
}

/// Capture metadata artefact (doc 03 ContextualMetadata + spec section 16.4), one per recorded attempt.
/// Unmeasured / not-entered values are nil and omitted from the JSON.
public struct CaptureMetadata: Codable, Equatable {
    public var deviceModel: String
    public var step: CaptureStep
    public var attempt: Int
    public var cameraRole: CameraRole
    public var fps: Double
    /// "WIDTHxHEIGHT" of the recorded video.
    public var resolution: String
    public var exposureDurationMs: Double
    public var iso: Float
    public var torchLevel: Float
    public var distanceCm: Double?
    public var angleDeg: Double?
    public var lux: Double?
    /// "handheld" | "holder"
    public var mount: String
    public var lightingType: String
    public var ambientTempC: Double?
    public var ambientHumidityPct: Double?
    public var durationSeconds: Double
    public var frameCount: Int
    public var videoCodec: String
    public var videoAverageBitRate: Int

    public init(deviceModel: String, step: CaptureStep, attempt: Int, cameraRole: CameraRole, fps: Double,
                resolution: String, exposureDurationMs: Double, iso: Float, torchLevel: Float,
                distanceCm: Double?, angleDeg: Double?, lux: Double?, mount: String, lightingType: String,
                ambientTempC: Double?, ambientHumidityPct: Double?, durationSeconds: Double, frameCount: Int,
                videoCodec: String, videoAverageBitRate: Int) {
        self.deviceModel = deviceModel; self.step = step; self.attempt = attempt; self.cameraRole = cameraRole
        self.fps = fps; self.resolution = resolution; self.exposureDurationMs = exposureDurationMs
        self.iso = iso; self.torchLevel = torchLevel; self.distanceCm = distanceCm; self.angleDeg = angleDeg
        self.lux = lux; self.mount = mount; self.lightingType = lightingType; self.ambientTempC = ambientTempC
        self.ambientHumidityPct = ambientHumidityPct; self.durationSeconds = durationSeconds
        self.frameCount = frameCount; self.videoCodec = videoCodec; self.videoAverageBitRate = videoAverageBitRate
    }

    enum CodingKeys: String, CodingKey {
        case deviceModel = "device_model", step, attempt, cameraRole = "camera_role", fps, resolution
        case exposureDurationMs = "exposure_duration_ms", iso, torchLevel = "torch_level"
        case distanceCm = "distance_cm", angleDeg = "angle_deg", lux, mount, lightingType = "lighting_type"
        case ambientTempC = "ambient_temp_c", ambientHumidityPct = "ambient_humidity_pct"
        case durationSeconds = "duration_s", frameCount = "frame_count"
        case videoCodec = "video_codec", videoAverageBitRate = "video_average_bit_rate"
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}
