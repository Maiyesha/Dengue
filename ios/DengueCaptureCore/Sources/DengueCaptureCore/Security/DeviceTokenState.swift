import Foundation

/// Lifetime and renewal scheduling of the 24 h device token. Renewal starts 4 h before expiry (at 20 h).
public struct DeviceTokenState: Equatable {
    public static let renewBefore: TimeInterval = 4 * 3600
    public static let baseBackoff: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 15 * 60
    public static let maxUnauthorized = 5

    public let issuedAt: Date
    public let expiresIn: TimeInterval
    public private(set) var reEnrolRequired = false
    public private(set) var failureCount = 0
    public private(set) var unauthorizedCount = 0
    /// Renewal was refused (DS_DEVICE_002/003/004) on every one of `maxUnauthorized` attempts.
    public private(set) var renewalRejected = false
    public private(set) var nextAttemptAt: Date?

    public init(issuedAt: Date, expiresIn: TimeInterval) {
        self.issuedAt = issuedAt; self.expiresIn = expiresIn
    }

    public var expiresAt: Date { issuedAt.addingTimeInterval(expiresIn) }
    public var renewAt: Date { issuedAt.addingTimeInterval(max(0, expiresIn - DeviceTokenState.renewBefore)) }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
    public func needsRenewal(at now: Date) -> Bool { now >= renewAt }

    public func canAttemptRenewal(at now: Date) -> Bool {
        if reEnrolRequired || renewalRejected { return false }
        if let n = nextAttemptAt { return now >= n }
        return true
    }

    /// `.reEnrol` (401 DS_DEVICE_001) requires a fresh enrolment. Anything else (429 DS_RATE_001, 5xx,
    /// network) backs off exponentially: 30 s, 60 s, ... capped at 15 min.
    public mutating func recordFailure(_ error: APIError, at now: Date) {
        if error == .reEnrol { reEnrolRequired = true; return }
        if error == .unauthorized {
            unauthorizedCount += 1
            if unauthorizedCount >= DeviceTokenState.maxUnauthorized { renewalRejected = true }
        }
        failureCount += 1
        let exp = min(failureCount - 1, 10)
        let delay = min(DeviceTokenState.maxBackoff, DeviceTokenState.baseBackoff * Double(1 << exp))
        nextAttemptAt = now.addingTimeInterval(delay)
    }
}
