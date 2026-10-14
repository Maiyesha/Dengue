import Foundation

public enum CameraRole: String, Codable, Sendable {
    case frontFace
    case rearFingertip
}

public enum StabilizationMode: String, Codable, Sendable {
    case off, standard, cinematic, auto
}

public enum CameraError: Error, Equatable, Sendable {
    /// A setting did not read back as requested (device ignored or clamped it).
    case notReady(setting: String)
    /// Exposure other than 10 ms or 20 ms (50 Hz mains rule).
    case invalidExposure
    case lockFailed(String)
}

/// Abstraction over the capture device and connection. Implemented on Apple
/// platforms by `AVCaptureDeviceControl`; tests use `FakeDeviceControl`.
/// Setters take effect immediately; getters report what the device actually
/// holds, so the configurator can read every value back.
public protocol CaptureDeviceControl: AnyObject {
    /// activeVideoMin/MaxFrameDuration, in seconds.
    var frameDurationMin: Double { get set }
    var frameDurationMax: Double { get set }

    /// Custom exposure mode.
    var exposureDurationSeconds: Double { get }
    var iso: Float { get }
    var isoRange: ClosedRange<Float> { get }
    func setCustomExposure(durationSeconds: Double, iso: Float) throws

    var whiteBalanceLocked: Bool { get set }
    var focusLocked: Bool { get set }

    var automaticallyAdjustsVideoHDR: Bool { get set }
    var videoHDREnabled: Bool { get set }

    var centerStageEnabled: Bool { get set }
    var stabilizationMode: StabilizationMode { get set }

    var torchLevel: Float { get }
    /// Throws if the device rejects the level. Level 0 turns the torch off.
    func setTorchLevel(_ level: Float) throws
}

public struct AppliedCameraSettings: Codable, Equatable, Sendable {
    public var fps: Double
    public var exposureMs: Double
    public var iso: Float
    public var hdr: Bool
    public var stabilization: String
    public var torch: Float

    public init(fps: Double, exposureMs: Double, iso: Float, hdr: Bool, stabilization: String, torch: Float) {
        self.fps = fps; self.exposureMs = exposureMs; self.iso = iso
        self.hdr = hdr; self.stabilization = stabilization; self.torch = torch
    }
}

/// In-memory device for tests. Each `ignores*` flag simulates a device that
/// silently refuses one setting.
public final class FakeDeviceControl: CaptureDeviceControl {
    public var frameDurationMin: Double = 1.0 / 60 { didSet { if ignoresFrameDuration { frameDurationMin = oldValue } } }
    public var frameDurationMax: Double = 1.0 / 15 { didSet { if ignoresFrameDuration { frameDurationMax = oldValue } } }
    public private(set) var exposureDurationSeconds: Double = 0.03
    public private(set) var iso: Float = 400
    public var isoRange: ClosedRange<Float> = 50...1600
    public var whiteBalanceLocked = false { didSet { if ignoresWhiteBalanceLock { whiteBalanceLocked = oldValue } } }
    public var focusLocked = false { didSet { if ignoresFocusLock { focusLocked = oldValue } } }
    public var automaticallyAdjustsVideoHDR = true { didSet { if ignoresAutoHDROff { automaticallyAdjustsVideoHDR = oldValue } } }
    public var videoHDREnabled = true { didSet { if ignoresHDROff { videoHDREnabled = oldValue } } }
    public var centerStageEnabled = true { didSet { if ignoresCenterStageOff { centerStageEnabled = oldValue } } }
    public var stabilizationMode: StabilizationMode = .auto { didSet { if ignoresStabilizationOff { stabilizationMode = oldValue } } }
    public private(set) var torchLevel: Float = 0

    public var ignoresFrameDuration = false
    public var ignoresExposure = false
    public var ignoresWhiteBalanceLock = false
    public var ignoresFocusLock = false
    public var ignoresAutoHDROff = false
    public var ignoresHDROff = false
    public var ignoresCenterStageOff = false
    public var ignoresStabilizationOff = false
    /// Torch levels below this are rejected (throw).
    public var minAcceptedTorch: Float = 0

    public init() {}

    public func setCustomExposure(durationSeconds: Double, iso: Float) throws {
        if ignoresExposure { return }
        exposureDurationSeconds = durationSeconds
        self.iso = iso
    }

    public func setTorchLevel(_ level: Float) throws {
        if level == 0 { torchLevel = 0; return }
        guard level >= minAcceptedTorch, level <= 1 else {
            throw CameraError.lockFailed("torch level \(level) rejected")
        }
        torchLevel = level
    }
}
