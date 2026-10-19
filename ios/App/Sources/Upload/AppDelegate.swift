import UIKit
import UserNotifications
import DengueCaptureCore

/// Upload-related application hooks: background URLSession events, APNs registration, silent pushes,
/// foreground verdict refresh.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var activeObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    /// Last seen managed app configuration; retries run only when it actually changes.
    private var lastManagedConfig: NSDictionary?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Minor: no system permission prompt during UI tests (it would cover the app).
        if ProcessInfo.processInfo.environment["UITEST_FAKE_CAMERA"] == nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        application.registerForRemoteNotifications()
        // T13: capture storage first (plaintext sweep, close sessions left open, reconcile sealed files), then
        // held hand-offs are retried on launch, foreground and managed-config change.
        DispatchQueue.global(qos: .utility).async { CaptureStorage.shared?.launch() }
        if let c = UploadCoordinator.shared { Task { await c.launch() } }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let c = UploadCoordinator.shared { Task { await c.foreground() } }
            DispatchQueue.global(qos: .utility).async { CaptureStorage.shared?.retryHeld() }
        }
        lastManagedConfig = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") as NSDictionary?
        configObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Only react to a change of the MDM managed configuration (`com.apple.configuration.managed`),
            // not to every UserDefaults write. `UploadCoordinator.shared` is re-tried on access.
            let now = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") as NSDictionary?
            guard let self, now != self.lastManagedConfig else { return }
            self.lastManagedConfig = now
            if let c = UploadCoordinator.shared { Task { await c.launch() } }
            DispatchQueue.global(qos: .utility).async { CaptureStorage.shared?.retryHeld() }
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
