import Foundation

/// Time source. `wallNow` may be wrong on the device; `serverOffset` (server minus device wall
/// clock) corrects stored timestamps, while `monotonicNanos` drives durations and step timers.
public protocol OutboxClock {
    var wallNow: Date { get }
    var monotonicNanos: UInt64 { get }
    /// Monotonic time that keeps counting while the device sleeps; resets on reboot.
    var continuousNanos: UInt64 { get }
    var serverOffset: TimeInterval { get }
}

public extension OutboxClock {
    /// Conformers that cannot supply sleep-inclusive time fall back to uptime.
    var continuousNanos: UInt64 { monotonicNanos }
}

public final class SystemClock: OutboxClock {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    public init() {}
    public var wallNow: Date { Date() }
    public var monotonicNanos: UInt64 { DispatchTime.now().uptimeNanoseconds }
    public var continuousNanos: UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)   // counts during sleep on Apple platforms
        #else
        return DispatchTime.now().uptimeNanoseconds
        #endif
    }
    public var serverOffset: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return offset
    }
    public func updateServerOffset(serverTime: Date) {
        lock.lock(); defer { lock.unlock() }
        offset = serverTime.timeIntervalSince(Date())
    }
}
