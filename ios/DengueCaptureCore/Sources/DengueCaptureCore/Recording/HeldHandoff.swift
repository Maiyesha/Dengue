import Foundation

/// A finished (or in-progress) capture session not yet owned by the upload engine.
///
/// Persisted ENCRYPTED by `FileHeldHandoffStore` (sealed with its own artefact key); it references the session's
/// sealed artefacts (already encrypted) rather than containing them. Holds only the MASKED participant code.
public struct PendingHandoff: Codable, Equatable {
    public enum Stage: String, Codable, Equatable {
        /// createScan + artefacts (+ clinical data) still to enqueue.
        case session
        /// The engine owns the session; only the clinical data is still to enqueue.
        case clinicalDataOnly
    }

    public var sessionId: UUID
    public var patientId: UUID?
    /// "••417" only.
    public var maskedCode: String
    public var capturedAt: Date
    public var offline: Bool
    public var protocolVersion: String
    public var attempts: [AttemptRecord]
    public var vitals: [VitalRecord]
    public var artefacts: [SealedStepArtefact]
    /// Face-step capture metadata (createScan metadata source).
    public var metadata: CaptureMetadata?
    /// True while the capture session is still running in this process (checkpoint); never retried while open.
    public var isOpen: Bool
    public var stage: Stage
    /// Built once (stable observation ids) before the session is enqueued.
    public var clinicalData: ClinicalDataRequest?
    /// PHI-free reason the hand-off is held (`CaptureHandoffError.diagnostic`).
    public var diagnostic: String?

    public init(sessionId: UUID, patientId: UUID?, maskedCode: String, capturedAt: Date, offline: Bool,
                protocolVersion: String, attempts: [AttemptRecord], vitals: [VitalRecord],
                artefacts: [SealedStepArtefact], metadata: CaptureMetadata?, isOpen: Bool,
                stage: Stage = .session, clinicalData: ClinicalDataRequest? = nil, diagnostic: String? = nil) {
        self.sessionId = sessionId; self.patientId = patientId; self.maskedCode = maskedCode
        self.capturedAt = capturedAt; self.offline = offline; self.protocolVersion = protocolVersion
        self.attempts = attempts; self.vitals = vitals; self.artefacts = artefacts; self.metadata = metadata
        self.isOpen = isOpen; self.stage = stage; self.clinicalData = clinicalData; self.diagnostic = diagnostic
    }
}

public enum HeldHandoffStoreError: Error, Equatable { case unreadable }

/// One sealed file per held hand-off (`<session>.<n>.held`) plus a plaintext index file (`<session>.ref`) that
/// holds only the sealed file's reference (key id, path, hashes): no PHI on disk in the clear.
/// The app puts the directory in Class C storage, excluded from backup.
public final class FileHeldHandoffStore {
    private let directory: URL
    private let keys: KeyStore
    private let sealer: ArtefactSealer
    private let lock = NSRecursiveLock()

    public init(directory: URL, keys: KeyStore) throws {
        self.directory = directory
        self.keys = keys
        self.sealer = ArtefactSealer(keys: keys)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for f in try fm.contentsOfDirectory(atPath: directory.path) where f.hasSuffix(".tmp") {
            try? fm.removeItem(at: directory.appendingPathComponent(f))   // interrupted save/load
        }
    }

    private func refURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString.lowercased()).ref") }

    public func save(_ p: PendingHandoff) throws {
        lock.lock(); defer { lock.unlock() }
        let stem = p.sessionId.uuidString.lowercased()
        let tmp = directory.appendingPathComponent("\(stem).save.tmp")
        let out = directory.appendingPathComponent("\(stem).\(UUID().uuidString.lowercased()).held")
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(p).write(to: tmp, options: .atomic)
        let sealed: SealedArtefact
        do { sealed = try CaptureHandoff.sealAndRemovePlaintext(input: tmp, output: out, sealer: sealer) }
        catch { try? FileManager.default.removeItem(at: tmp); throw error }
        let previous = try? ref(p.sessionId)
        try JSONEncoder().encode(sealed).write(to: refURL(p.sessionId), options: .atomic)
        if let previous { destroy(previous) }
    }

    public func load(_ id: UUID) throws -> PendingHandoff? {
        lock.lock(); defer { lock.unlock() }
        guard let r = try ref(id) else { return nil }
        let tmp = directory.appendingPathComponent("\(id.uuidString.lowercased()).open.tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try sealer.open(r, to: tmp)
            return try JSONDecoder().decode(PendingHandoff.self, from: Data(contentsOf: tmp))
        } catch {
            throw HeldHandoffStoreError.unreadable
        }
    }

    /// Throws if any record cannot be read (callers must then not delete anything it might reference).
    public func loadAll() throws -> [PendingHandoff] {
        lock.lock(); defer { lock.unlock() }
        return try sessionIds().compactMap { try load($0) }
    }

    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if let r = try ref(id) { destroy(r) }
        try? FileManager.default.removeItem(at: refURL(id))
    }

    /// The sealed record files themselves (their keys must survive the sweep).
    public func recordRefs() throws -> [SealedArtefact] {
        lock.lock(); defer { lock.unlock() }
        return try sessionIds().compactMap { try ref($0) }
    }

    private func sessionIds() throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".ref") }
            .compactMap { UUID(uuidString: String($0.dropLast(4))) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func ref(_ id: UUID) throws -> SealedArtefact? {
        let u = refURL(id)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try JSONDecoder().decode(SealedArtefact.self, from: Data(contentsOf: u))
    }

    private func destroy(_ s: SealedArtefact) {
        try? keys.destroy(id: s.keyId)
        try? FileManager.default.removeItem(at: s.path)
    }
}

public enum HandoffOutcome: Equatable {
    /// The upload engine owns the session now.
    case enqueued
    /// Persisted encrypted; retried on launch / foreground / config change.
    case held(CaptureHandoffError)
}

/// The only reasons a held hand-off may be shredded.
public enum DiscardReason: String, Equatable {
    case nurseDiscard, consentStop, quarantine
}

public struct HeldHandoffSummary: Equatable {
    public var sessionId: UUID
    public var maskedCode: String
    public var diagnostic: String?
    public var isOpen: Bool
}

public struct SweepReport: Equatable {
    public var deletedPlaintext = 0
    public var deletedSealed = 0
    public var destroyedKeys = 0
    /// True when ownership could not be established (no engine, unreadable records): nothing sealed was touched.
    public var sealedSweepSkipped = false
}

/// Hand-off from a finished capture to the upload engine, with the held fallback, the explicit discard and the
/// relaunch sweep. Rules (T13 rulings):
/// - Recoverable failures (no engine, unknown patient, metadata incomplete, outbox write error) HOLD the session;
///   nothing is ever auto-shredded. Shredding happens only via `discard(sessionId:reason:)`.
/// - Once `enqueueSession` succeeds the engine owns the artefacts: they are never destroyed here afterwards.
///   A later clinical-data enqueue failure holds only that remaining item.
public final class CaptureHandoffService {
    private let store: FileHeldHandoffStore
    private let keys: KeyStore
    private let handoff: CaptureHandoff
    private let lock = NSRecursiveLock()

    public init(store: FileHeldHandoffStore, keys: KeyStore, handoff: CaptureHandoff = CaptureHandoff()) {
        self.store = store; self.keys = keys; self.handoff = handoff
    }

    /// Persists an in-progress session (call after each sealed step) so a crash never orphans its artefacts.
    public func checkpoint(_ p: PendingHandoff) throws {
        lock.lock(); defer { lock.unlock() }
        var q = p
        q.isOpen = true
        try store.save(q)
    }

    /// Session finished: enqueue it, or hold it.
    public func submit(_ p: PendingHandoff, engine: UploadEngine?) -> HandoffOutcome {
        lock.lock(); defer { lock.unlock() }
        var q = p
        q.isOpen = false
        return process(q, engine: engine)
    }

    /// Retries every closed held hand-off.
    public func retryHeld(engine: UploadEngine?) -> [UUID: HandoffOutcome] {
        lock.lock(); defer { lock.unlock() }
        var out: [UUID: HandoffOutcome] = [:]
        for p in (try? store.loadAll()) ?? [] where !p.isOpen {
            out[p.sessionId] = process(p, engine: engine)
        }
        return out
    }

    /// At launch: sessions left open by a previous process are over; they become retryable (uploaded as captured).
    public func closeOpen() throws {
        lock.lock(); defer { lock.unlock() }
        for var p in try store.loadAll() where p.isOpen {
            p.isOpen = false
            try store.save(p)
        }
    }

    /// Explicit nurse discard, consent stop (DS_REG_*) or quarantine: crypto-shreds the held session.
    public func discard(sessionId: UUID, reason: DiscardReason) throws {
        lock.lock(); defer { lock.unlock() }
        guard let p = try store.load(sessionId) else { return }
        for a in p.artefacts { destroy(a.sealed) }
        try store.remove(sessionId)
    }

    public func heldSummaries() throws -> [HeldHandoffSummary] {
        lock.lock(); defer { lock.unlock() }
        return try store.loadAll().map {
            HeldHandoffSummary(sessionId: $0.sessionId, maskedCode: $0.maskedCode, diagnostic: $0.diagnostic,
                               isOpen: $0.isOpen)
        }
    }

    // MARK: processing

    private func process(_ input: PendingHandoff, engine: UploadEngine?) -> HandoffOutcome {
        var p = input
        guard let engine else { return hold(p, .uploadNotConfigured) }
        guard let patientId = p.patientId else { return hold(p, .patientUnknown) }

        if p.stage == .session {
            if engine.record(p.sessionId) == nil {
                let plan: CaptureSessionPlan
                do {
                    guard let meta = p.metadata else {
                        throw CaptureHandoffError.metadataIncomplete(["distance_cm", "angle_deg", "lighting_lux"])
                    }
                    plan = try handoff.makeSessionPlan(
                        sessionId: p.sessionId, patientId: patientId, capturedAt: p.capturedAt, offline: p.offline,
                        protocolVersion: p.protocolVersion, metadata: try CaptureHandoff.scanMetadata(from: meta),
                        attempts: p.attempts, vitals: p.vitals, artefacts: p.artefacts)
                } catch let e as CaptureHandoffError {
                    return hold(p, e)
                } catch {
                    return hold(p, .enqueueFailed(error))
                }
                if p.clinicalData == nil { p.clinicalData = plan.clinicalData }
                // Persist the stable clinical-data ids before the engine takes the session.
                do { try store.save(p) } catch { return .held(.enqueueFailed(error)) }
                do {
                    try engine.enqueueSession(sessionId: p.sessionId, participantCode: p.maskedCode,
                                              createScan: plan.createScan, scanId: nil, artefacts: plan.artefacts)
                } catch {
                    // A record means the engine registered the session: it owns the artefacts now.
                    if engine.record(p.sessionId) == nil { return hold(p, .enqueueFailed(error)) }
                }
                for s in plan.discarded { destroy(s) }   // non-accepted attempts: never uploaded, owned by nobody
            }
            p.stage = .clinicalDataOnly
            p.artefacts = []
        }

        if let cd = p.clinicalData {
            do {
                try engine.enqueueClinicalData(sessionId: p.sessionId, patientId: patientId, request: cd)
            } catch {
                return hold(p, .enqueueFailed(error))
            }
        }
        try? store.remove(p.sessionId)   // the record only: the artefacts belong to the engine
        return .enqueued
    }

    private func hold(_ p: PendingHandoff, _ e: CaptureHandoffError) -> HandoffOutcome {
        var q = p
        q.diagnostic = e.diagnostic
        try? store.save(q)   // on failure the previous record (if any) and every sealed file stay on disk
        return .held(e)
    }

    private func destroy(_ s: SealedArtefact) {
        try? keys.destroy(id: s.keyId)
        try? FileManager.default.removeItem(at: s.path)
    }

    // MARK: relaunch sweep

    /// Launch only (before any capture starts):
    /// 1. deletes every plaintext file in `captureDirectory`;
    /// 2. deletes sealed files in `sealedDirectory` referenced neither by the engine nor by a held hand-off;
    /// 3. destroys artefact keys (UUID-shaped ids only) referenced by neither, nor by a held record itself.
    /// Steps 2-3 are skipped entirely when ownership cannot be established (no engine, unreadable records).
    public func sweep(captureDirectory: URL, sealedDirectory: URL, engine: UploadEngine?) -> SweepReport {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var report = SweepReport()
        for name in (try? fm.contentsOfDirectory(atPath: captureDirectory.path)) ?? [] {
            if (try? fm.removeItem(at: captureDirectory.appendingPathComponent(name))) != nil {
                report.deletedPlaintext += 1
            }
        }
        guard let engine, let owned = engine.referencedArtefacts(),
              let held = try? store.loadAll(), let records = try? store.recordRefs() else {
            report.sealedSweepSkipped = true
            return report
        }
        let referenced = owned + held.flatMap { $0.artefacts.map { $0.sealed } }
        let names = Set(referenced.map { $0.path.lastPathComponent })
        for name in (try? fm.contentsOfDirectory(atPath: sealedDirectory.path)) ?? [] where !names.contains(name) {
            if (try? fm.removeItem(at: sealedDirectory.appendingPathComponent(name))) != nil {
                report.deletedSealed += 1
            }
        }
        if let enumerable = keys as? KeyEnumerating, let ids = try? enumerable.allKeyIds() {
            let keep = Set(referenced.map { $0.keyId } + records.map { $0.keyId })
            for id in ids where !keep.contains(id) && UUID(uuidString: id) != nil {
                if (try? keys.destroy(id: id)) != nil { report.destroyedKeys += 1 }
            }
        }
        return report
    }
}
