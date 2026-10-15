import Foundation
import UIKit
import DengueCaptureCore

/// I5: the real preflight inputs. Thresholds (warn < 15 %, block < 5 %, block < 2 GB) live in core `Preflight`.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
enum DevicePreflight {
    /// Free bytes for important (user-initiated) data: `volumeAvailableCapacityForImportantUsage`
    /// (required-reason API: disk space, E174.1 / 85F4.1 declared in PrivacyInfo.xcprivacy). 0 when unknown,
    /// which blocks capture (fail closed).
    static func freeBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// `UIDevice.batteryLevel` with monitoring enabled; -1 when unknown (simulator), which core treats as not low.
    @MainActor static func batteryLevel() -> Double {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return Double(UIDevice.current.batteryLevel)
    }

    @MainActor static func current(supportsDepthCapture: Bool) -> Preflight {
        Preflight(freeBytes: freeBytes(), batteryLevel: batteryLevel(), supportsDepthCapture: supportsDepthCapture)
    }
}

extension Notification.Name {
    /// A user-token route was refused (engine `onUserAuthFailure`, consent lookup 401): show sign-in.
    static let dsUserAuthFailed = Notification.Name("ai.reainmaker.denguecapture.userAuthFailed")
    /// A server-requested repeat arrived while the app is in the foreground (in-app banner, I2).
    static let dsRepeatRequested = Notification.Name("ai.reainmaker.denguecapture.repeatRequested")
    /// R-2: the sign-in overlay went up (posted by `SessionModel` on the main thread). Live capture flows stop
    /// recording safely, keep what was recorded and wait under the overlay; they are never torn down.
    static let dsSignInRequired = Notification.Name("ai.reainmaker.denguecapture.signInRequired")
    /// R-2: sign-in succeeded after `dsSignInRequired`: the flows continue at the same step.
    static let dsSignInRestored = Notification.Name("ai.reainmaker.denguecapture.signInRestored")
}
