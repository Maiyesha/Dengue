import Foundation

/// Applies the locked capture configuration and verifies every value by
/// reading it back. Any mismatch throws `CameraError.notReady(setting:)`.
public struct CameraConfigurator {
    public static let targetFPS: Double = 30
    public static let torchMinLevel: Float = 0.1
    public static let torchStep: Float = 0.05

    public init() {}

    public func configure(_ d: CaptureDeviceControl, role: CameraRole, preferExposureMs: Double) throws -> AppliedCameraSettings {
        guard preferExposureMs == 10 || preferExposureMs == 20 else { throw CameraError.invalidExposure }

        // Frame rate: min == max == 1/30 s.
        let frame = 1.0 / Self.targetFPS
        d.frameDurationMin = frame
        d.frameDurationMax = frame
        guard abs(d.frameDurationMin - frame) < 1e-4, abs(d.frameDurationMax - frame) < 1e-4 else {
            throw CameraError.notReady(setting: "frameRate")
        }

        // Custom exposure; ISO clamped into the device range.
        let targetISO = min(max(Self.preferredISO(for: role), d.isoRange.lowerBound), d.isoRange.upperBound)
        try d.setCustomExposure(durationSeconds: preferExposureMs / 1000, iso: targetISO)
        guard abs(d.exposureDurationSeconds * 1000 - preferExposureMs) < 0.1,
              abs(d.iso - targetISO) < 1 else {
            throw CameraError.notReady(setting: "exposure")
        }

        d.whiteBalanceLocked = true
        guard d.whiteBalanceLocked else { throw CameraError.notReady(setting: "whiteBalance") }

        d.focusLocked = true
        guard d.focusLocked else { throw CameraError.notReady(setting: "focus") }

        // HDR: disable auto-adjust first, then force off.
        d.automaticallyAdjustsVideoHDR = false
        guard !d.automaticallyAdjustsVideoHDR else { throw CameraError.notReady(setting: "videoHDR") }
        d.videoHDREnabled = false
        guard !d.videoHDREnabled else { throw CameraError.notReady(setting: "videoHDR") }

        d.centerStageEnabled = false
        guard !d.centerStageEnabled else { throw CameraError.notReady(setting: "centerStage") }

        d.stabilizationMode = .off
        guard d.stabilizationMode == .off else { throw CameraError.notReady(setting: "stabilization") }

        // Torch: rear fingertip only, lowest accepted level >= 0.1.
        if role == .rearFingertip {
            var level = Self.torchMinLevel
            var applied = false
            while level <= 1.0001 {
                if (try? d.setTorchLevel(min(level, 1))) != nil, d.torchLevel >= Self.torchMinLevel {
                    applied = true
                    break
                }
                level += Self.torchStep
            }
            guard applied else { throw CameraError.notReady(setting: "torch") }
        } else {
            try? d.setTorchLevel(0)
            guard d.torchLevel == 0 else { throw CameraError.notReady(setting: "torch") }
        }

        let fps = 1.0 / d.frameDurationMax
        return AppliedCameraSettings(
            fps: fps,
            exposureMs: d.exposureDurationSeconds * 1000,
            iso: d.iso,
            hdr: d.videoHDREnabled,
            stabilization: d.stabilizationMode.rawValue,
            torch: d.torchLevel
        )
    }

    static func preferredISO(for role: CameraRole) -> Float {
        switch role {
        case .frontFace: return 200
        case .rearFingertip: return 100
        }
    }
}
