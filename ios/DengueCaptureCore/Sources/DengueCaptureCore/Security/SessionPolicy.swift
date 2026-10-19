import Foundation

/// Pure session rules: 10 min idle requires device-owner re-authentication; a session that has
/// not been validated by the server for more than 12 h is invalid (and must be re-established online).
public final class SessionPolicy {
    public enum Status: Equatable { case active, reauthRequired, expired }

    public static let idleLimit: TimeInterval = 10 * 60
    public static let offlineLimit: TimeInterval = 12 * 3600

    private let clock: OutboxClock
    private let lock = NSLock()
    private var signedInFlag = false
    private var lastActivityNanos: UInt64 = 0
    private var validationWall: Date = .distantPast
    private var validationContinuous: UInt64 = 0

    public init(clock: OutboxClock) { self.clock = clock }

    public func signedIn() {
        lock.lock(); defer { lock.unlock() }
        signedInFlag = true
        lastActivityNanos = clock.continuousNanos
        validationWall = clock.wallNow
        validationContinuous = clock.continuousNanos
    }

    public func signedOut() {
        lock.lock(); defer { lock.unlock() }
        signedInFlag = false
    }

    /// Call on user interaction. Ignored once re-authentication is due (only `reauthenticated()` clears it).
    public func recordActivity() {
        lock.lock(); defer { lock.unlock() }
        guard signedInFlag, !idleExceeded() else { return }
        lastActivityNanos = clock.continuousNanos
    }

    public func reauthenticated() {
        lock.lock(); defer { lock.unlock() }
        guard signedInFlag else { return }
        lastActivityNanos = clock.continuousNanos
    }

    /// Call when a token refresh or any authenticated call succeeds against the server.
    public func validatedWithServer() {
        lock.lock(); defer { lock.unlock() }
        guard signedInFlag else { return }
        validationWall = clock.wallNow
        validationContinuous = clock.continuousNanos
    }

    public func evaluate() -> Status {
        lock.lock(); defer { lock.unlock() }
        guard signedInFlag else { return .expired }
        // Elapsed since the last server validation is the larger of wall and continuous elapsed, so
        // setting the wall clock back cannot extend the session. Either going backwards (wall edited,
        // or continuous reset by a reboot) cannot be trusted: fail closed.
        let wallElapsed = clock.wallNow.timeIntervalSince(validationWall)
        let now = clock.continuousNanos
        guard now >= validationContinuous, wallElapsed >= 0 else { return .expired }
        let contElapsed = Double(now - validationContinuous) / 1e9
        if max(wallElapsed, contElapsed) > SessionPolicy.offlineLimit { return .expired }
        return idleExceeded() ? .reauthRequired : .active
    }

    private func idleExceeded() -> Bool {
        let now = clock.continuousNanos
        guard now >= lastActivityNanos else { return true }
        return Double(now - lastActivityNanos) / 1e9 >= SessionPolicy.idleLimit
    }
}
