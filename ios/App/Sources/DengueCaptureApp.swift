import SwiftUI

@main
struct DengueCaptureApp: App {
    /// Background upload session events, APNs and silent pushes (Task 12).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { FlowRootView() }
    }
}
