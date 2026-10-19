import Foundation

/// Round 2 (I1): which flow owns the shared camera. The main flow and a repeat flow share one recorder; each
/// coordinator claims the camera when it starts positioning or recording, and `stop(owner:)` acts only for the
/// current owner, so one flow's stop (e.g. on sign-in) can never cancel another flow's recording.
/// Thread-safe.
public final class CameraOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?

    public init() {}

    /// The coordinator that last started positioning or recording (nil = nobody).
    public var owner: UUID? { lock.lock(); defer { lock.unlock() }; return current }

    /// `o` starts positioning or recording: it owns the camera from now on.
    public func claim(_ o: UUID) {
        lock.lock(); current = o; lock.unlock()
    }

    /// True when a stop requested by `o` may act: `o` owns the camera, or nobody does.
    public func mayStop(_ o: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == nil || current == o
    }

    /// Releases ownership if `o` holds it. True when it did (the caller may then stop the camera).
    @discardableResult
    public func release(_ o: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current == o else { return false }
        current = nil
        return true
    }
}
