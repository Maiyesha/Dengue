import UIKit
import UserNotifications
import DengueCaptureCore

/// Upload-related application hooks: background URLSession events, APNs registration, silent pushes,
/// foreground verdict refresh.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var activeObserver: NSObjectProtocol?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        application.registerForRemoteNotifications()
        if let c = UploadCoordinator.shared {
            Task { await c.launch() }
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { await c.foreground() }
            }
        }
        return true
    }

    /// iOS relaunched (or woke) the app for the background upload session. Recreate the session with the same
    /// identifier and keep the handler until `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == UploadEngine.backgroundSessionIdentifier, let c = UploadCoordinator.shared else {
            completionHandler()
            return
        }
        c.uploader.handleEvents(identifier: identifier, completionHandler: completionHandler)
        Task { await c.launch() }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        UploadCoordinator.shared?.registerPushToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// Silent push (`content-available: 1`, payload `{"scan_id": ...}` only): poll verdicts.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let c = UploadCoordinator.shared else { completionHandler(.noData); return }
        Task {
            let r = await c.handleSilentPush(userInfo)
            completionHandler(r)
        }
    }
}
