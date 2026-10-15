import Foundation
import UIKit
import SwiftUI
import DengueCaptureCore

/// Observes screen recording / mirroring and exposes `blurred` for the root view. State and audit rules
/// live in the core `ScreenCaptureMonitor` (tested on Windows); this class only feeds it UIKit signals.
/// UNVERIFIED: compiled by ios.yml.
@MainActor
public final class ScreenCaptureGuard: ObservableObject {
    @Published public private(set) var blurred = false
    private let monitor: ScreenCaptureMonitor
    private var token: NSObjectProtocol?

    public init(sink: DeviceEventSink, clock: OutboxClock = SystemClock()) {
        monitor = ScreenCaptureMonitor(sink: sink, clock: clock)
    }

    public func start() {
        token = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    public func stop() {
        if let t = token { NotificationCenter.default.removeObserver(t) }
        token = nil
    }

    /// Re-read the capture state. Also call on scene activation.
    public func refresh() {
        let captured = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.traitCollection.sceneCaptureState == .active }
        monitor.captureStateChanged(isCaptured: captured || UIScreen.main.isCaptured)
        blurred = monitor.blurred
    }
}

public extension View {
    /// Blur and block interaction while the screen is captured.
    func blurWhenCaptured(_ guardian: ScreenCaptureGuard) -> some View {
        self.blur(radius: guardian.blurred ? 40 : 0)
            .allowsHitTesting(!guardian.blurred)
    }
}

/// Audit sink that enqueues a `device_event` post through the outbox.
/// The outbox kind for audit events is wired in Task 12; until then this holds events in memory.
public final class OutboxDeviceEventSink: DeviceEventSink {
    private let enqueue: (_ event: String, _ detail: [String: String], _ at: Date) -> Void
    public init(enqueue: @escaping (String, [String: String], Date) -> Void) { self.enqueue = enqueue }
    public func record(event: String, detail: [String: String], at: Date) { enqueue(event, detail, at) }
}
