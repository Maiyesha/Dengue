import Foundation

/// Time source. `wallNow` may be wrong on the device; `serverOffset` (server minus device wall
/// clock) corrects stored timestamps, while `monotonicNanos` drives durations and step timers.
public protocol OutboxClock {
    var wallNow: Date { get }
    var monotonicNanos: UInt64 { get }
    var serverOffset: TimeInterval { get }
}

public final class SystemClock: OutboxClock {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    public init() {}
    public var wallNow: Date { Date() }
    public var monotonicNanos: UInt64 { DispatchTime.now().uptimeNanoseconds }
    public var serverOffset: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return offset
    }
    public func updateServerOffset(serverTime: Date) {
        lock.lock(); defer { lock.unlock() }
        offset = serverTime.timeIntervalSince(Date())
    }
}
