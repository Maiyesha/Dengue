import Foundation

public enum OutboxAction: Equatable {
    case retryScheduled
    case needsRepeat
    /// Caller must run `quarantine(sessionId:keys:sealedPaths:)` with its KeyStore.
    case quarantineRequired(sessionId: UUID)
    case failed
    /// The server committed (e.g. DS_QG_099); the item is done and the caller must GET the scan to learn the outcome.
    case refetchScan(sessionId: UUID)
    /// The item is frozen (quarantined, quarantinePending, needsRepeat, or finished); nothing changed.
    case ignoredFrozen
}

public final class Outbox {
    public static let maxBackoff: TimeInterval = 900

    private let store: OutboxStore
    private let clock: OutboxClock
    private let lock = NSRecursiveLock()

    public init(store: OutboxStore, clock: OutboxClock) {
        self.store = store
        self.clock = clock
    }

    @discardableResult
    public func enqueue(_ kind: OutboxKind, sessionId: UUID, payload: Data,
                        dependsOn: UUID? = nil) throws -> OutboxItem {
        lock.lock(); defer { lock.unlock() }
        let now = clock.wallNow
        let item = OutboxItem(
            id: UUID(), sessionId: sessionId, kind: kind, payload: payload,
            idempotencyKey: UUID(), status: .pending, attempts: 0, nextAttemptAt: now,
            dependsOn: dependsOn, createdWall: now,
            createdMonotonicNanos: clock.monotonicNanos, serverOffset: clock.serverOffset)
        try store.upsert(item)
        return item
    }

    public func item(_ id: UUID) throws -> OutboxItem? {
        lock.lock(); defer { lock.unlock() }
        return try store.loadAll().first { $0.id == id }
    }

    public func items(sessionId: UUID) throws -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        return try store.loadAll().filter { $0.sessionId == sessionId }
    }

    /// Oldest pending item that is due and whose dependency (if any) is done.
    public func nextReady() throws -> OutboxItem? {
        lock.lock(); defer { lock.unlock() }
        let all = try store.loadAll()
        let done = Set(all.filter { $0.status == .done }.map { $0.id })
        let now = clock.wallNow
        return all.enumerated()
            .filter { $0.element.status == .pending && $0.element.nextAttemptAt <= now
                && ($0.element.dependsOn.map(done.contains) ?? true) }
            .min { ($0.element.createdWall, $0.offset) < ($1.element.createdWall, $1.offset) }?
            .element
    }

    /// When the next pending item becomes due: the earliest `nextAttemptAt` among pending items whose
    /// dependency (if any) is done. Items waiting on a pending dependency are covered by that dependency;
    /// items behind a frozen or failed dependency never become ready and are ignored. nil = nothing to wake for.
    public func nextWakeAt() throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        let all = try store.loadAll()
        let done = Set(all.filter { $0.status == .done }.map { $0.id })
        return all.filter { $0.status == .pending && ($0.dependsOn.map(done.contains) ?? true) }
            .map { $0.nextAttemptAt }.min()
    }

    /// Statuses a late callback must not revive.
    private static func isFrozen(_ s: OutboxItem.Status) -> Bool {
        s == .quarantined || s == .failed || s == .needsRepeat || s == .quarantinePending
    }

    /// Sessions with interrupted quarantines (quarantinePending items); the app finishes them on launch.
    public func pendingQuarantineSessions() throws -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<UUID>()
        return try store.loadAll().filter { $0.status == .quarantinePending }
            .map { $0.sessionId }.filter { seen.insert($0).inserted }
    }

    public func markInFlight(_ id: UUID) throws {
        try mutate(id, guarded: true) { $0.status = .inFlight }
    }

    public func markDone(_ id: UUID) throws {
        try mutate(id, guarded: true) { $0.status = .done }
    }

    /// Call on launch: inFlight items were interrupted by a crash or kill. Idempotency keys are kept.
    public func recoverInFlight() throws {
        lock.lock(); defer { lock.unlock() }
        for var it in try store.loadAll() where it.status == .inFlight {
            it.status = .pending
            try store.upsert(it)
        }
    }

    public func markRetry(_ id: UUID) throws {
        let now = clock.wallNow
        try mutate(id, guarded: true) {
            $0.attempts += 1
            $0.status = .pending
            $0.nextAttemptAt = now.addingTimeInterval(Outbox.backoff(attempts: $0.attempts))
        }
    }

    public static func backoff(attempts: Int) -> TimeInterval {
        min(pow(2.0, Double(min(max(attempts, 0), 30))), maxBackoff)
    }

    public func markNeedsRepeat(sessionId: UUID, reasons: [ReasonCode]) throws {
        try mutateSession(sessionId) {
            $0.status = .needsRepeat
            $0.reasons = reasons
        }
    }

    public func quarantine(sessionId: UUID, keys: KeyStore, sealedPaths: [SealedArtefact]) throws {
        lock.lock(); defer { lock.unlock() }
        var firstError: Error?
        for a in sealedPaths {
            do { try keys.destroy(id: a.keyId) } catch { firstError = firstError ?? error }
            if FileManager.default.fileExists(atPath: a.path.path) {
                do { try FileManager.default.removeItem(at: a.path) } catch { firstError = firstError ?? error }
            }
        }
        try mutateSession(sessionId) { $0.status = .quarantined }
        if let e = firstError { throw e }
    }

    /// Wall clock at creation corrected by the server offset measured at that time.
    public func correctedCapturedAt(for item: OutboxItem) -> Date {
        item.createdWall.addingTimeInterval(item.serverOffset)
    }

    @discardableResult
    public func apply(_ e: APIError, to id: UUID) throws -> OutboxAction {
        guard let it = try item(id) else { return .failed }
        switch e {
        case .retryable, .uploadIncomplete:
            if Outbox.isFrozen(it.status) { return .ignoredFrozen }
            try markRetry(id)
            return .retryScheduled
        case .needsRepeat(let reasons):
            try markNeedsRepeat(sessionId: it.sessionId, reasons: reasons)
            return .needsRepeat
        case .stopAndQuarantine(let code):
            try mutateSession(it.sessionId) {
                if $0.status == .pending || $0.status == .inFlight || $0.status == .needsRepeat {
                    $0.status = .quarantinePending
                }
            }
            try mutate(id) { $0.failureReason = code }
            return .quarantineRequired(sessionId: it.sessionId)
        case .recaptureExhausted:
            if Outbox.isFrozen(it.status) { return .ignoredFrozen }
            try markDone(id)
            return .refetchScan(sessionId: it.sessionId)
        case .uploadHashMismatch:
            return try fail(id, "DS_UPLOAD_001")
        case .duplicateRecent:
            return try fail(id, "DS_SCAN_001")
        case .invalid(let code):
            return try fail(id, code)
        case .unauthorized:
            return try fail(id, "unauthorized")
        case .reEnrol:
            return try fail(id, "DS_DEVICE_001")
        }
    }

    private func fail(_ id: UUID, _ reason: String) throws -> OutboxAction {
        guard let it = try item(id) else { return .failed }
        switch it.status {
        case .quarantined, .quarantinePending, .needsRepeat, .done: return .ignoredFrozen
        default: break
        }
        try mutate(id) { $0.status = .failed; $0.failureReason = reason }
        try cascadeFailure(from: id)
        return .failed
    }

    /// Fails every item that transitively depends on `root` and is not already finished.
    private func cascadeFailure(from root: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var failed: Set<UUID> = [root]
        var changed = true
        while changed {
            changed = false
            for var it in try store.loadAll() {
                guard let dep = it.dependsOn, failed.contains(dep), !failed.contains(it.id) else { continue }
                failed.insert(it.id)
                changed = true
                if it.status != .done && it.status != .quarantined && it.status != .quarantinePending {
                    it.status = .failed
                    it.failureReason = "dependency failed"
                    try store.upsert(it)
                }
            }
        }
    }

    private func mutate(_ id: UUID, guarded: Bool = false, _ f: (inout OutboxItem) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard var it = try store.loadAll().first(where: { $0.id == id }) else { return }
        if guarded && Outbox.isFrozen(it.status) { return }
        f(&it)
        try store.upsert(it)
    }

    /// Applies to every item of the session that is not already done.
    private func mutateSession(_ sessionId: UUID, _ f: (inout OutboxItem) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        for var it in try store.loadAll() where it.sessionId == sessionId && it.status != .done {
            f(&it)
            try store.upsert(it)
        }
    }
}
