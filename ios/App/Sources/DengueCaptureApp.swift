import SwiftUI

@main
struct DengueCaptureApp: App {
    /// Background upload session events, APNs and silent pushes (Task 12).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { AppRootView() }   // C2: sign-in gate, idle lock, capture blur
    }
}
