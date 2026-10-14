#if canImport(AVFoundation)
import AVFoundation
import DengueCaptureCore

/// AVFoundation implementation of the core `CaptureDeviceControl` protocol.
///
/// Design notes:
/// - Every mutation happens inside `lockForConfiguration()` / `unlockForConfiguration()`.
/// - Property setters cannot throw, so a failed lock or an unsupported feature is
///   swallowed; `CameraConfigurator` reads every value back and throws
///   `CameraError.notReady(setting:)` on mismatch. Getters therefore report real
///   device state and fail closed (never claim a setting that is not applied).
/// - Exposure and white balance are applied asynchronously by AVFoundation, so those
///   calls wait (bounded) for the completion handler before returning. Do not call
///   `configure` on the main thread.
/// - The caller must already have selected an `activeFormat` that supports 30 fps.
/// - No audio input and no photo output are ever created here.
public final class AVCaptureDeviceControl: CaptureDeviceControl {
    private let device: AVCaptureDevice
    private let connection: AVCaptureConnection?
    private static let completionTimeout: DispatchTimeInterval = .seconds(1)

    /// `connection` is the video data output connection (nil until the session is wired;
    /// stabilization then reads back as not-off and configuration fails closed).
    public init(device: AVCaptureDevice, connection: AVCaptureConnection?) {
        self.device = device
        self.connection = connection
    }

    private func locked(_ body: () -> Void) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            body()
        } catch {
            // Read-back by the configurator will surface this as notReady.
        }
    }

    private func lockedThrowing(_ body: () throws -> Void) throws {
        do {
            try device.lockForConfiguration()
        } catch {
            throw CameraError.lockFailed("lockForConfiguration: \(error.localizedDescription)")
        }
        defer { device.unlockForConfiguration() }
        try body()
    }

    // MARK: Frame rate

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
    }

    public var frameDurationMin: Double {
        get { CMTimeGetSeconds(device.activeVideoMinFrameDuration) }
        set { locked { device.activeVideoMinFrameDuration = cmTime(newValue) } }
    }

    public var frameDurationMax: Double {
        get { CMTimeGetSeconds(device.activeVideoMaxFrameDuration) }
        set { locked { device.activeVideoMaxFrameDuration = cmTime(newValue) } }
    }

    // MARK: Exposure

    public var exposureDurationSeconds: Double { CMTimeGetSeconds(device.exposureDuration) }
    public var iso: Float { device.iso }
    public var isoRange: ClosedRange<Float> {
        device.activeFormat.minISO...device.activeFormat.maxISO
    }

    public func setCustomExposure(durationSeconds: Double, iso: Float) throws {
        let sem = DispatchSemaphore(value: 0)
        try lockedThrowing {
            let fmt = device.activeFormat
            let minD = CMTimeGetSeconds(fmt.minExposureDuration)
            let maxD = CMTimeGetSeconds(fmt.maxExposureDuration)
            let clamped = min(max(durationSeconds, minD), maxD)
            let clampedISO = min(max(iso, fmt.minISO), fmt.maxISO)
            device.setExposureModeCustom(duration: cmTime(clamped), iso: clampedISO) { _ in sem.signal() }
        }
        // The configuration lock is released above; the completion fires once the
        // sensor has applied the values, after which the getters read back correctly.
        _ = sem.wait(timeout: .now() + Self.completionTimeout)
    }

    // MARK: White balance / focus

    public var whiteBalanceLocked: Bool {
        get { device.whiteBalanceMode == .locked }
        set {
            guard newValue else {
                locked { if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance } }
                return
            }
            guard device.isWhiteBalanceModeSupported(.locked) else { return }
            let sem = DispatchSemaphore(value: 0)
            var started = false
            locked {
                let gains = clamped(device.deviceWhiteBalanceGains)
                device.setWhiteBalanceModeLocked(with: gains) { _ in sem.signal() }
                started = true
            }
            if started { _ = sem.wait(timeout: .now() + Self.completionTimeout) }
        }
    }

    private func clamped(_ g: AVCaptureDevice.WhiteBalanceGains) -> AVCaptureDevice.WhiteBalanceGains {
        let m = device.maxWhiteBalanceGain
        func c(_ v: Float) -> Float { min(max(v, 1.0), m) }
        return AVCaptureDevice.WhiteBalanceGains(redGain: c(g.redGain), greenGain: c(g.greenGain), blueGain: c(g.blueGain))
    }

    /// A fixed-focus camera (no `.locked` mode) is inherently locked.
    public var focusLocked: Bool {
        get { device.focusMode == .locked || !device.isFocusModeSupported(.locked) }
        set {
            locked {
                if newValue {
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
        }
    }

    // MARK: HDR

    public var automaticallyAdjustsVideoHDR: Bool {
        get { device.automaticallyAdjustsVideoHDREnabled }
        set { locked { device.automaticallyAdjustsVideoHDREnabled = newValue } }
    }

    /// Setting `isVideoHDREnabled` raises an Objective-C exception while auto-adjust is on
    /// or when the format lacks HDR, so guard both. A format without HDR reads back as off.
    public var videoHDREnabled: Bool {
        get { device.activeFormat.isVideoHDRSupported ? device.isVideoHDREnabled : false }
        set {
            guard device.activeFormat.isVideoHDRSupported, !device.automaticallyAdjustsVideoHDREnabled else { return }
            locked { device.isVideoHDREnabled = newValue }
        }
    }

    // MARK: Center Stage

    /// Center Stage is a class-level (system) setting; take app control, then switch it off.
    public var centerStageEnabled: Bool {
        get { AVCaptureDevice.isCenterStageEnabled }
        set {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = newValue
        }
    }

    // MARK: Stabilization

    public var stabilizationMode: StabilizationMode {
        get {
            guard let connection else { return .auto }  // fail closed
            if !connection.isVideoStabilizationSupported { return .off }  // nothing can be applied
            switch connection.preferredVideoStabilizationMode {
            case .off: return .off
            case .standard: return .standard
            case .cinematic, .cinematicExtended, .cinematicExtendedEnhanced: return .cinematic
            case .auto: return .auto
            @unknown default: return .auto
            }
        }
        set {
            guard let connection, connection.isVideoStabilizationSupported else { return }
            switch newValue {
            case .off: connection.preferredVideoStabilizationMode = .off
            case .standard: connection.preferredVideoStabilizationMode = .standard
            case .cinematic: connection.preferredVideoStabilizationMode = .cinematic
            case .auto: connection.preferredVideoStabilizationMode = .auto
            }
        }
    }

    // MARK: Torch

    public var torchLevel: Float {
        device.hasTorch && device.torchMode == .on ? device.torchLevel : 0
    }

    public func setTorchLevel(_ level: Float) throws {
        guard device.hasTorch else { throw CameraError.lockFailed("no torch") }
        try lockedThrowing {
            if level <= 0 {
                device.torchMode = .off
            } else {
                do {
                    try device.setTorchModeOn(level: min(level, AVCaptureDevice.maxAvailableTorchLevel))
                } catch {
                    throw CameraError.lockFailed("torch level \(level): \(error.localizedDescription)")
                }
            }
        }
    }
}
#endif
