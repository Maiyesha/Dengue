import SwiftUI
import DengueCaptureCore

/// App root (C2): sign-in gate, idle lock overlay, screen-capture blur, app-switcher privacy cover, and the
/// foreground needs-repeat banner. Every screen keeps the RUO banner.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
struct AppRootView: View {
    @StateObject private var session = SessionModel()
    @StateObject private var captureGuard = ScreenCaptureGuard(sink: LocalDeviceEventSink())
    @Environment(\.scenePhase) private var scenePhase
    @State private var repeatBanner: String?
    @State private var showOutbox = false

    var body: some View {
        ZStack {
            switch session.gate {
            case .signInRequired:
                SignInView(session: session)
            case .open, .locked:
                FlowRootView()
                    .simultaneousGesture(TapGesture().onEnded { session.activity() })
                if session.gate == .locked { LockOverlay(session: session) }
            }
            if let text = repeatBanner, session.gate == .open {
                VStack {
                    Spacer().frame(height: 60)
                    Button { showOutbox = true; repeatBanner = nil } label: {
                        Text(text).font(.headline).padding().frame(maxWidth: .infinity)
                            .background(Color.orange.opacity(0.95)).foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal).accessibilityIdentifier("repeat-banner")
                    Spacer()
                }
            }
            // Minor: hide the study ID and vitals in the app switcher.
            if scenePhase != .active { PrivacyCover() }
        }
        .blurWhenCaptured(captureGuard)
        .sheet(isPresented: $showOutbox) { OutboxView() }
        .task { await session.start() }
        .onAppear { captureGuard.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { captureGuard.refresh(); session.evaluate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dsRepeatRequested)) { n in
            repeatBanner = n.userInfo?["text"] as? String
        }
    }
}

struct SignInView: View {
    @ObservedObject var session: SessionModel
    var body: some View {
        BannerScreen {
            VStack(spacing: 20) {
                Text(NurseCopy.titleSignIn).font(.title2)
                if let m = session.message { Text(m).foregroundColor(.red).accessibilityIdentifier("sign-in-message") }
                if session.busy {
                    ProgressView()
                } else {
                    Button(NurseCopy.buttonSignIn) { Task { await session.signIn() } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("sign-in-button")
                }
            }.padding()
        }
    }
}

/// 10 min idle: covers everything until LAContext device-owner authentication succeeds.
struct LockOverlay: View {
    @ObservedObject var session: SessionModel
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                RUOBanner()
                Spacer()
                Text(NurseCopy.lockedIdle).font(.title3)
                Button(NurseCopy.buttonUnlock) { Task { await session.unlock() } }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("unlock-button")
                Spacer()
            }
        }
    }
}

/// Shown while the scene is inactive / in the background (app switcher snapshot).
struct PrivacyCover: View {
    var body: some View {
        Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "lock.fill").font(.largeTitle))
    }
}

/// `device_event` audit for screen capture. Local-only for now: there is no `POST /v1/devices/events` endpoint
/// yet (open item in ios/App/README.md). Keeps the last events in memory; never any patient data.
final class LocalDeviceEventSink: DeviceEventSink {
    private(set) var events: [(event: String, at: Date)] = []
    func record(event: String, detail: [String: String], at: Date) {
        events.append((event, at))
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
}
