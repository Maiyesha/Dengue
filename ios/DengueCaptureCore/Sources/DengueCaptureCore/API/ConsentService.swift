import Foundation

/// Persistence for the roster snapshot (the app supplies a protected, backup-excluded file).
public protocol ConsentCacheStorage: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

/// Offline consent: the ward roster snapshot, usable for at most 24 h (spec 6.3; C2).
///
/// The snapshot time is the server's `generated_at` (falls back to the fetch time). A snapshot older than
/// `CaptureFlow.maxSnapshotAge` or dated more than `CaptureFlow.maxSnapshotFutureSkew` in the future is never used.
public final class ConsentCache {
    private struct Snapshot: Codable {
        var roster: Roster
        var snapshotAt: Date
    }

    private let storage: ConsentCacheStorage?
    private let lock = NSLock()
    private var snapshot: Snapshot?

    public init(storage: ConsentCacheStorage? = nil) {
        self.storage = storage
        if let d = storage?.load() { snapshot = try? JSONDecoder().decode(Snapshot.self, from: d) }
    }

    public func update(_ roster: Roster, fetchedAt: Date) {
        let s = Snapshot(roster: roster, snapshotAt: WireDate.date(from: roster.generatedAt) ?? fetchedAt)
        lock.lock(); snapshot = s; lock.unlock()
        if let d = try? JSONEncoder().encode(s) { storage?.save(d) }
    }

    /// The participant's roster row and the snapshot time, only within the 24 h rule.
    public func entry(participantCode: String, now: Date) -> (item: RosterItem, snapshotAt: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = snapshot,
              s.snapshotAt.timeIntervalSince(now) <= CaptureFlow.maxSnapshotFutureSkew,
              now.timeIntervalSince(s.snapshotAt) <= CaptureFlow.maxSnapshotAge,
              let item = s.roster.items.first(where: { $0.participantCode == participantCode }) else { return nil }
        return (item, s.snapshotAt)
    }
}

public struct ConsentResolution: Equatable {
    public enum Outcome: Equatable {
        case ok
        /// The server does not know the participant code (or it is not on this site).
        case unknownParticipant
        /// The nurse's session was refused: sign in again.
        case signInRequired
        /// Offline and no usable (<= 24 h) roster row.
        case offlineNoSnapshot
    }
    public var status: ConsentStatus
    public var snapshotAt: Date
    public var online: Bool
    public var patientId: UUID?
    public var outcome: Outcome
}

/// DengueAPI-backed consent source (C2): online `lookup` -> `consentStatus`; on a transport / server failure the
/// cached roster (24 h rule). Anything else blocks capture (fail closed).
public final class ConsentService {
    private let api: DengueAPI
    private let cache: ConsentCache
    private let wardId: String?
    private let now: () -> Date

    public init(api: DengueAPI, cache: ConsentCache, wardId: String?, now: @escaping () -> Date = Date.init) {
        self.api = api; self.cache = cache; self.wardId = wardId; self.now = now
    }

    /// Refreshes the offline roster snapshot (call on foreground and after sign-in).
    public func refreshRoster() async {
        guard let wardId, let r = try? await api.roster(wardId: wardId) else { return }
        cache.update(r, fetchedAt: now())
    }

    public func resolve(participantCode: String) async -> ConsentResolution {
        do {
            let p = try await api.lookup(participantCode: participantCode)
            let s = try await api.consentStatus(patientId: p.patientId)
            return ConsentResolution(status: s, snapshotAt: now(), online: true, patientId: p.patientId, outcome: .ok)
        } catch APIError.retryable {
            return offline(participantCode)
        } catch APIError.networkRestricted {
            return offline(participantCode)   // R-1: captive portal / filtering network: use the roster snapshot
        } catch APIError.unauthorized {
            return blocked(.signInRequired)
        } catch APIError.invalid(code: "DS_NOT_FOUND") {
            return blocked(.unknownParticipant)
        } catch let APIError.stopAndQuarantine(code) {
            return blocked(.ok, code: code)   // DS_REG_*: consent block from the server
        } catch {
            return blocked(.unknownParticipant)
        }
    }

    private func offline(_ code: String) -> ConsentResolution {
        guard let e = cache.entry(participantCode: code, now: now()) else { return blocked(.offlineNoSnapshot) }
        return ConsentResolution(status: e.item.consent, snapshotAt: e.snapshotAt, online: false,
                                 patientId: e.item.patientId, outcome: .ok)
    }

    private func blocked(_ outcome: ConsentResolution.Outcome, code: String? = nil) -> ConsentResolution {
        let s = ConsentStatus(primaryResearch: false, consentVersion: "", currentVersion: "", withdrawn: false,
                              captureAllowed: false, blockCode: code, checkedAt: WireDate.string(from: now()))
        return ConsentResolution(status: s, snapshotAt: now(), online: outcome != .offlineNoSnapshot, patientId: nil,
                                 outcome: outcome)
    }
}

/// Which screen the app root shows (C2). Pure; the app supplies whether OIDC tokens exist.
public enum SessionGateState: Equatable {
    /// Show SignInView. `clearTokens`: the stored tokens must be deleted first (12 h expiry, or no session in
    /// this process: tokens from a previous process are only trusted again after a successful refresh/sign-in).
    case signInRequired(clearTokens: Bool)
    /// 10 min idle: overlay requiring LAContext device-owner re-authentication.
    case locked
    case open
}

public enum SessionGate {
    public static func evaluate(hasTokens: Bool, policy: SessionPolicy) -> SessionGateState {
        guard hasTokens else { return .signInRequired(clearTokens: false) }
        switch policy.evaluate() {
        case .expired: return .signInRequired(clearTokens: true)
        case .reauthRequired: return .locked
        case .active: return .open
        }
    }
}
