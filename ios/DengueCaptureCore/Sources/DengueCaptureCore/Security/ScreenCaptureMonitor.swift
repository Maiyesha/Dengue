import Foundation

/// Sink for the audit post (`device_event`). The app implementation enqueues it through the outbox.
public protocol DeviceEventSink {
    func record(event: String, detail: [String: String], at: Date)
}

/// Pure screen-capture state: while the screen is being recorded or mirrored the UI must be blurred,
/// and each transition into a captured state produces one audit event.
public final class ScreenCaptureMonitor {
    public static let eventName = "screen_capture_detected"

    public private(set) var blurred = false
    private let sink: DeviceEventSink
    private let clock: OutboxClock

    public init(sink: DeviceEventSink, clock: OutboxClock) {
        self.sink = sink; self.clock = clock
    }

    /// Feed the current `UIScreen.isCaptured` / scene capture state. Idempotent for repeated values.
    public func captureStateChanged(isCaptured: Bool) {
        guard isCaptured != blurred else { return }
        blurred = isCaptured
        sink.record(event: isCaptured ? Self.eventName : "screen_capture_ended", detail: [:],
                    at: clock.wallNow.addingTimeInterval(clock.serverOffset))
    }
}
