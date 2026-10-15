import Foundation

/// R-2: a recording stopped because the nurse's session expired before the step minimum. Its video, ROI trace and
/// metadata are sealed and kept on the phone; the server has no slot for interrupted clips, so it is never uploaded.
/// It is deleted only by an explicit nurse discard of the held record.
public struct InterruptedClip: Codable, Equatable {
    public var step: CaptureStep
    /// The attempt number it was recorded as (not consumed: the next recording of the step reuses it).
    public var attempt: Int
    public var recordedSeconds: Double
    public var interruptedAt: Date
    public var artefacts: [SealedStepArtefact]
    public init(step: CaptureStep, attempt: Int, recordedSeconds: Double, interruptedAt: Date,
                artefacts: [SealedStepArtefact]) {
        self.step = step; self.attempt = attempt; self.recordedSeconds = recordedSeconds
        self.interruptedAt = interruptedAt; self.artefacts = artefacts
    }
}

/// A finished (or in-progress) capture session that is not yet fully queued with the upload engine.
///
/// Persisted ENCRYPTED by `FileHeldHandoffStore` (sealed with its own artefact key). It references the session's
/// sealed artefacts (already encrypted) rather than containing them, and holds only the MASKED participant code.
public struct PendingHandoff: Codable, Equatable {
    public enum Stage: String, Codable, Equatable {
        /// The engine has no session record yet: this hand-off owns the sealed artefacts.
        case session
        /// The engine has the session record and owns the artefacts; `ensureSessionItems` still has to complete
        /// the outbox items. A discard removes only this record, never the artefacts.
        case engineOwned
        /// R-2: nothing left to queue; the record only keeps the session's `interruptedClips` (never uploaded)
        /// until the nurse discards them. Never retried.
        case interruptedOnly
        /// Round 2 (I4): a server-requested repeat's accepted artefacts, checkpointed when sign-in became required
        /// (`repeatReason`, `repeatAcceptedSteps`). Routed to `submitRepeat` by `retryHeld`; removed once queued.
        case repeatPending
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
    /// Built once (stable observation ids) and persisted before the session is enqueued.
    public var clinicalData: ClinicalDataRequest?
    /// PHI-free reason the hand-off is held (`CaptureHandoffError.diagnostic`).
    public var diagnostic: String?
    /// R-2: partial recordings stopped by a sign-in requirement (sealed, kept, never uploaded).
    public var interruptedClips: [InterruptedClip] = []
    /// Round 2 (I4), `.repeatPending` only: the recapture reason and the steps accepted on the device.
    public var repeatReason: String?
    public var repeatAcceptedSteps: [CaptureStep]?

    public init(sessionId: UUID, patientId: UUID?, maskedCode: String, capturedAt: Date, offline: Bool,
                protocolVersion: String, attempts: [AttemptRecord], vitals: [VitalRecord],
                artefacts: [SealedStepArtefact], metadata: CaptureMetadata?, isOpen: Bool,
                stage: Stage = .session, clinicalData: ClinicalDataRequest? = nil, diagnostic: String? = nil) {
        self.sessionId = sessionId; self.patientId = patientId; self.maskedCode = maskedCode
        self.capturedAt = capturedAt; self.offline = offline; self.protocolVersion = protocolVersion
        self.attempts = attempts; self.vitals = vitals; self.artefacts = artefacts; self.metadata = metadata
        self.isOpen = isOpen; self.stage = stage; self.clinicalData = clinicalData; self.diagnostic = diagnostic
    }

    /// Records written before R-2 have no `interruptedClips`: decoded as none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        patientId = try c.decodeIfPresent(UUID.self, forKey: .patientId)
        maskedCode = try c.decode(String.self, forKey: .maskedCode)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        offline = try c.decode(Bool.self, forKey: .offline)
        protocolVersion = try c.decode(String.self, forKey: .protocolVersion)
        attempts = try c.decode([AttemptRecord].self, forKey: .attempts)
        vitals = try c.decode([VitalRecord].self, forKey: .vitals)
        artefacts = try c.decode([SealedStepArtefact].self, forKey: .artefacts)
        metadata = try c.decodeIfPresent(CaptureMetadata.self, forKey: .metadata)
        isOpen = try c.decode(Bool.self, forKey: .isOpen)
        stage = try c.decode(Stage.self, forKey: .stage)
        clinicalData = try c.decodeIfPresent(ClinicalDataRequest.self, forKey: .clinicalData)
        diagnostic = try c.decodeIfPresent(String.self, forKey: .diagnostic)
        interruptedClips = try c.decodeIfPresent([InterruptedClip].self, forKey: .interruptedClips) ?? []
        repeatReason = try c.decodeIfPresent(String.self, forKey: .repeatReason)
        repeatAcceptedSteps = try c.decodeIfPresent([CaptureStep].self, forKey: .repeatAcceptedSteps)
    }

    /// Every sealed artefact this record references (accepted attempts and interrupted clips).
    public var allSealed: [SealedArtefact] {
        artefacts.map { $0.sealed } + interruptedClips.flatMap { $0.artefacts.map { $0.sealed } }
    }
}

public enum HeldHandoffStoreError: Error, Equatable { case unreadable }

/// Result of loading every held record one at a time.
public struct HeldLoadResult: Equatable {
    public var records: [PendingHandoff]
    /// Records whose sealed file could not be opened or decoded (e.g. key unavailable, corruption).
    public var unreadable: [UUID]
    public init(records: [PendingHandoff], unreadable: [UUID]) { self.records = records; self.unreadable = unreadable }
}

public protocol HeldHandoffStoring: AnyObject {
    func save(_ p: PendingHandoff) throws
    /// Throws `HeldHandoffStoreError.unreadable` for a record that exists but cannot be opened.
    func load(_ id: UUID) throws -> PendingHandoff?
    /// Never fails because of one bad record; throws only if the store directory itself cannot be listed.
    func loadEach() throws -> HeldLoadResult
    /// Removes the record (its own key and sealed file), readable or not.
    func remove(_ id: UUID) throws
    /// The sealed record files themselves (their keys must survive the sweep).
    func recordRefs() throws -> [SealedArtefact]
}

/// One sealed file per held hand-off (`<session>.<uuid>.held`) plus a plaintext index file (`<session>.ref`) that
/// holds only the sealed file's reference (key id, path, hashes): no PHI on disk in the clear.
/// The app puts the directory in Class C storage, excluded from backup.
public final class FileHeldHandoffStore: HeldHandoffStoring {
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
        let r: SealedArtefact
        do {
            guard let found = try ref(id) else { return nil }
            r = found
        } catch {
            throw HeldHandoffStoreError.unreadable
        }
        let tmp = directory.appendingPathComponent("\(id.uuidString.lowercased()).open.tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try sealer.open(r, to: tmp)
            return try JSONDecoder().decode(PendingHandoff.self, from: Data(contentsOf: tmp))
        } catch {
            throw HeldHandoffStoreError.unreadable
        }
    }

    public func loadEach() throws -> HeldLoadResult {
        lock.lock(); defer { lock.unlock() }
        var result = HeldLoadResult(records: [], unreadable: [])
        for id in try sessionIds() {
            do {
                if let p = try load(id) { result.records.append(p) }
            } catch {
                result.unreadable.append(id)
            }
        }
        return result
    }

    /// Readable records only (see `loadEach` for the unreadable ones).
    public func loadAll() throws -> [PendingHandoff] { try loadEach().records }

    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if let r = try? ref(id) { destroy(r) }
        try? FileManager.default.removeItem(at: refURL(id))
    }

    public func recordRefs() throws -> [SealedArtefact] {
        lock.lock(); defer { lock.unlock() }
        return try sessionIds().compactMap { try? ref($0) }
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
    /// The upload engine has the session and every outbox item.
    case enqueued
    /// Persisted encrypted; retried on launch / foreground / config change.
    case held(CaptureHandoffError)
    /// Could not be persisted: kept in memory (referenced by the sweep) and retried; the caller should surface it.
    case holdFailed(CaptureHandoffError)
}

/// The only reasons a held hand-off may be shredded.
public enum DiscardReason: String, Equatable {
    case nurseDiscard, consentStop, quarantine
}

public struct HeldHandoffSummary: Equatable {
    public var sessionId: UUID
    /// Empty for an unreadable record.
    public var maskedCode: String
    public var diagnostic: String?
    public var isOpen: Bool
    /// The record exists but cannot be opened; the outbox shows it as unreadable and offers a delete.
    public var isUnreadable: Bool
    /// nil for an unreadable record.
    public var capturedAt: Date? = nil
    /// R-2: interrupted partial recordings kept on the phone (`NurseCopy.interruptedClipKept`).
    public var interruptedClipCount = 0
    /// R-2: the record only keeps interrupted clips (nothing to send).
    public var isInterruptedOnly = false

    /// R-3: the record still has something to send (or to fix). A clip-only record is listed but needs no action.
    public var needsAction: Bool { !isInterruptedOnly }
}

/// R-3 / I2: result of handing a server-requested repeat to the upload engine.
public enum RepeatHandoffOutcome: Equatable {
    /// `enqueueRecapture` took the accepted artefacts.
    case enqueued
    /// Round 2 (M2): an unexpected error; nothing destroyed. Kept as a `.repeatPending` record (retried), or, when
    /// the engine record already references the artefacts, left to the engine.
    case held
    /// Nothing could be queued (window passed, nothing accepted, no KMS key...): the repeat's artefacts were
    /// destroyed (the session itself is already on the server).
    case notQueued
}

public struct SweepReport: Equatable {
    public var deletedPlaintext = 0
    public var deletedSealed = 0
    public var destroyedKeys = 0
    /// Held records that could not be opened during this sweep.
    public var unreadableRecords = 0
    /// True when ownership could not be established (no engine, unreadable session records, or an unreadable
    /// held record whose artefact references are unknown): nothing sealed was touched.
    public var sealedSweepSkipped = false
}

/// Hand-off from a finished capture to the upload engine, with the held fallback, the explicit discard and the
/// relaunch sweep. Rules (T13 rulings):
/// - Recoverable failures HOLD the session; nothing is auto-shredded. Shredding happens only via `discard`.
/// - A hold that cannot be persisted is kept in memory, reported as `.holdFailed` and retried.
/// - Whenever the engine has a session record, `UploadEngine.ensureSessionItems` completes the outbox items
///   idempotently (also after a crash inside `enqueueSession`).
/// - Sessions being submitted, and in-memory holds, count as referenced in the sweep.
public final class CaptureHandoffService {
    private let store: HeldHandoffStoring
    private let keys: KeyStore
    private let handoff: CaptureHandoff
    private let lock = NSRecursiveLock()
    /// Holds whose save failed; retried by `retryHeld`.
    private var memoryHolds: [UUID: PendingHandoff] = [:]
    /// Sessions inside `process` right now.
    private var inProgress: [UUID: PendingHandoff] = [:]
    private var wrapper: KeyWrapper?

    /// `keyWrapper`: wraps artefact data keys for the server KMS (C1). nil (KMS config missing) holds every
    /// hand-off whose accepted artefacts are not wrapped yet with `KMS_KEY_MISSING`.
    public init(store: HeldHandoffStoring, keys: KeyStore, keyWrapper: KeyWrapper?,
                handoff: CaptureHandoff = CaptureHandoff()) {
        self.store = store; self.keys = keys; self.wrapper = keyWrapper; self.handoff = handoff
    }

    /// Managed-config change: the next `retryHeld` wraps with the new key.
    public var keyWrapper: KeyWrapper? {
        get { lock.lock(); defer { lock.unlock() }; return wrapper }
        set { lock.lock(); wrapper = newValue; lock.unlock() }
    }

    /// Persists an in-progress session (call after each sealed step) so a crash never orphans its artefacts.
    public func checkpoint(_ p: PendingHandoff) throws {
        lock.lock(); defer { lock.unlock() }
        var q = p
        q.isOpen = true
        try store.save(q)
    }

    /// R-2: sign-in became required during capture. Persists the session's accepted attempts (and any interrupted
    /// clips) AT ONCE as an open checkpoint, before any re-auth, so nothing is lost if the app is killed meanwhile
    /// (the next launch closes and queues it). A session with nothing recorded writes nothing.
    public func checkpointForReauth(_ p: PendingHandoff) throws {
        guard !p.attempts.isEmpty || !p.artefacts.isEmpty || !p.interruptedClips.isEmpty else { return }
        try checkpoint(p)
    }

    /// R-2: keeps an interrupted clip of a session this process does not checkpoint itself (a server-requested
    /// repeat, whose session the engine already owns): merged into the session's held record, or kept in a new
    /// `.interruptedOnly` record.
    /// Round 2 (M3): with `engine`, an existing record that is obsolete (`isObsolete`) is never revived by a clip:
    /// it is replaced by a fresh clip-only record (the engine's artefacts are untouched).
    public func keepInterruptedClip(_ clip: InterruptedClip, sessionId: UUID, maskedCode: String,
                                    capturedAt: Date, engine: UploadEngine? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if var existing = try store.load(sessionId), !(engine.map { isObsolete(existing, engine: $0) } ?? false) {
            existing.interruptedClips.append(clip)
            try store.save(existing)
            return
        }
        var p = PendingHandoff(sessionId: sessionId, patientId: nil, maskedCode: maskedCode, capturedAt: capturedAt,
                               offline: false, protocolVersion: "", attempts: [], vitals: [], artefacts: [],
                               metadata: nil, isOpen: false, stage: .interruptedOnly)
        p.interruptedClips = [clip]
        try store.save(p)
    }

    /// Round 2 (I4): a repeat flow's accepted artefacts, persisted when sign-in becomes required, so a kill under
    /// the overlay loses nothing (the sweep keeps them; the next `retryHeld` routes the record to `submitRepeat`).
    /// Interrupted clips already kept for the session are preserved.
    public func checkpointRepeat(sessionId: UUID, maskedCode: String, capturedAt: Date, reason: String,
                                 accepted: [CaptureStep], sealed: [SealedStepArtefact]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !sealed.isEmpty else { return }
        var p = PendingHandoff(sessionId: sessionId, patientId: nil, maskedCode: maskedCode, capturedAt: capturedAt,
                               offline: false, protocolVersion: "", attempts: [], vitals: [], artefacts: sealed,
                               metadata: nil, isOpen: true, stage: .repeatPending)
        p.repeatReason = reason
        p.repeatAcceptedSteps = accepted
        if let existing = (try? store.load(sessionId)) ?? nil { p.interruptedClips = existing.interruptedClips }
        try store.save(p)
    }

    /// Session finished: enqueue it, or hold it.
    public func submit(_ p: PendingHandoff, engine: UploadEngine?) -> HandoffOutcome {
        lock.lock(); defer { lock.unlock() }
        var q = p
        q.isOpen = false
        return process(q, original: nil, engine: engine)
    }

    /// Retries every closed, readable held hand-off and every in-memory hold (after the R-3 obsolete-record repair).
    public func retryHeld(engine: UploadEngine?) -> [UUID: HandoffOutcome] {
        lock.lock(); defer { lock.unlock() }
        if let engine { removeObsolete(engine: engine) }
        var out: [UUID: HandoffOutcome] = [:]
        let loaded = (try? store.loadEach()) ?? HeldLoadResult(records: [], unreadable: [])
        for p in loaded.records where !p.isOpen && p.stage != .interruptedOnly && p.stage != .repeatPending {
            out[p.sessionId] = process(p, original: p, engine: engine)
        }
        // Round 2 (I4): repeat-pending records go to submitRepeat (window and KMS rules apply there).
        if let engine {
            for p in loaded.records where !p.isOpen && p.stage == .repeatPending {
                switch submitRepeat(sessionId: p.sessionId, reason: p.repeatReason ?? "nurse_repeat",
                                    accepted: p.repeatAcceptedSteps ?? [], sealed: p.artefacts, engine: engine,
                                    maskedCode: p.maskedCode, capturedAt: p.capturedAt) {
                case .enqueued: out[p.sessionId] = .enqueued
                case .held: out[p.sessionId] = .held(.enqueueFailed("REPEAT_PENDING"))
                case .notQueued: break
                }
            }
        }
        for (id, p) in memoryHolds where out[id] == nil {
            out[id] = process(p, original: nil, engine: engine)
        }
        return out
    }

    /// At launch: sessions left open by a previous process are over; they become retryable (uploaded as captured).
    public func closeOpen() throws {
        lock.lock(); defer { lock.unlock() }
        for var p in try store.loadEach().records where p.isOpen {
            p.isOpen = false
            try store.save(p)
        }
    }

    /// Explicit nurse discard, consent stop (DS_REG_*) or quarantine.
    ///
    /// Ownership is decided from the ENGINE, not from the stored stage (which can lag: a failed `.engineOwned`
    /// save, or a crash between the engine's record save and the end of `process`): if `engine` has a record for
    /// the session, or any copy of the hold (memory or store) says `.engineOwned`, the artefacts are kept and only
    /// the held record is removed. Otherwise the session's artefacts are shredded. An unreadable record is removed;
    /// its artefacts, now unreferenced, are reclaimed by the next sweep (which only runs with an engine).
    public func discard(sessionId: UUID, reason: DiscardReason, engine: UploadEngine?) throws {
        lock.lock(); defer { lock.unlock() }
        let memory = memoryHolds.removeValue(forKey: sessionId)
        let stored = try? store.load(sessionId)
        let engineOwned = engine?.record(sessionId) != nil
            || memory?.stage == .engineOwned || stored?.stage == .engineOwned
            || memory?.stage == .interruptedOnly || stored?.stage == .interruptedOnly
        var seen = Set<String>()
        // Round 2 (I4): a repeat-pending record owns the artefacts the engine has not taken yet.
        let engineKeys = Set(engine?.record(sessionId)?.artefacts.map { $0.sealed.keyId } ?? [])
        for p in [memory, stored].compactMap({ $0 }) where p.stage == .repeatPending {
            for a in p.artefacts where !engineKeys.contains(a.sealed.keyId) && seen.insert(a.sealed.keyId).inserted {
                destroy(a.sealed)
            }
        }
        if !engineOwned {
            for a in (memory?.artefacts ?? []) + (stored?.artefacts ?? []) where seen.insert(a.sealed.keyId).inserted {
                destroy(a.sealed)
            }
        }
        // R-2: interrupted clips belong to the held record alone, never to the engine: an explicit discard
        // deletes them.
        let clips = (memory?.interruptedClips ?? []) + (stored?.interruptedClips ?? [])
        for a in clips.flatMap({ $0.artefacts }) where seen.insert(a.sealed.keyId).inserted {
            destroy(a.sealed)
        }
        try store.remove(sessionId)
    }

    /// Held records for the Uploads list. R-3: with `engine`, obsolete records (see `isObsolete`) are left out.
    public func heldSummaries(engine: UploadEngine? = nil) throws -> [HeldHandoffSummary] {
        lock.lock(); defer { lock.unlock() }
        let loaded = try store.loadEach()
        let records = engine.map { e in loaded.records.filter { !isObsolete($0, engine: e) } } ?? loaded.records
        var out = records.map {
            HeldHandoffSummary(sessionId: $0.sessionId, maskedCode: $0.maskedCode, diagnostic: $0.diagnostic,
                               isOpen: $0.isOpen, isUnreadable: false, capturedAt: $0.capturedAt,
                               interruptedClipCount: $0.interruptedClips.count,
                               isInterruptedOnly: $0.stage == .interruptedOnly)
        }
        out += loaded.unreadable.map {
            HeldHandoffSummary(sessionId: $0, maskedCode: "", diagnostic: "HELD_RECORD_UNREADABLE", isOpen: false,
                               isUnreadable: true)
        }
        let known = Set(out.map { $0.sessionId })
        out += memoryHolds.values.filter { !known.contains($0.sessionId) }.map {
            HeldHandoffSummary(sessionId: $0.sessionId, maskedCode: $0.maskedCode, diagnostic: $0.diagnostic,
                               isOpen: false, isUnreadable: false, capturedAt: $0.capturedAt,
                               interruptedClipCount: $0.interruptedClips.count,
                               isInterruptedOnly: $0.stage == .interruptedOnly)
        }
        return out
    }

    // MARK: R-3 repeats and obsolete records

    /// I2/R-3: a server-requested repeat's accepted artefacts become a recapture of the existing session
    /// (`UploadEngine.enqueueRecapture`, with the server's next attempt number per step). Device-rejected attempts
    /// are not server attempts and are destroyed; if nothing can be queued (2 h window passed, nothing accepted,
    /// no KMS key) every artefact of the repeat is destroyed. A repeat never leaves a held hand-off of the original
    /// session: any obsolete record for it (e.g. a checkpoint written by an older version) is removed.
    ///
    /// Round 2 (M2): artefacts are destroyed ONLY when the repeat can never be queued: the 2 h window passed
    /// (`repeatWindowExpired`), no KMS key (`kmsKeyMissing`), nothing accepted, or the server's attempts for the
    /// steps are used up. Any other error holds them (`.repeatPending` record, retried) and destroys nothing; and
    /// nothing is ever destroyed once the engine record references the artefacts.
    public func submitRepeat(sessionId: UUID, reason: String, accepted: [CaptureStep], sealed input: [SealedStepArtefact],
                             engine: UploadEngine, maskedCode: String? = nil,
                             capturedAt: Date? = nil) -> RepeatHandoffOutcome {
        lock.lock(); defer { lock.unlock() }
        var sealed = input
        // C1: wrap data keys sealed before a KMS key was configured (the device key still exists).
        if let wrapper {
            for i in sealed.indices where sealed[i].sealed.wrappedKey == nil {
                if let k = try? keys.key(id: sealed[i].sealed.keyId) { sealed[i].sealed.wrappedKey = try? wrapper.wrap(k) }
            }
        }
        defer { removeObsolete(engine: engine, only: sessionId) }
        func giveUp() -> RepeatHandoffOutcome {
            for a in sealed { destroy(a.sealed) }
            finishRepeatRecord(sessionId)
            return .notQueued
        }
        func hold() -> RepeatHandoffOutcome {
            let rec = engine.record(sessionId)
            let owned = Set(rec?.artefacts.map { $0.sealed.keyId } ?? [])
            if sealed.contains(where: { owned.contains($0.sealed.keyId) }) { return .held }   // the engine has them
            var p = PendingHandoff(sessionId: sessionId, patientId: nil,
                                   maskedCode: maskedCode ?? rec?.maskedCode ?? "",
                                   capturedAt: capturedAt ?? rec?.capturedAt ?? Date(), offline: false,
                                   protocolVersion: "", attempts: [], vitals: [], artefacts: sealed, metadata: nil,
                                   isOpen: false, stage: .repeatPending)
            p.repeatReason = reason
            p.repeatAcceptedSteps = accepted
            if let existing = (try? store.load(sessionId)) ?? nil { p.interruptedClips = existing.interruptedClips }
            if (try? store.save(p)) == nil { memoryHolds[sessionId] = p }
            return .held
        }
        let acceptedArts = sealed.filter { accepted.contains($0.step) }
        guard !acceptedArts.isEmpty else { return giveUp() }
        guard engine.record(sessionId) != nil else { return hold() }   // unknown to the engine: keep, retry
        var uploads: [ArtefactUpload] = []
        var steps: [CaptureStepName] = []
        for a in acceptedArts {
            guard let name = CaptureStepName(rawValue: a.step.rawValue),
                  let attempt = engine.recaptureAttempt(sessionId: sessionId, step: name) else { continue }
            if !steps.contains(name) { steps.append(name) }
            uploads.append(ArtefactUpload(step: name, attempt: attempt, kind: a.kind, deviceVerdict: .accept,
                                          sealed: a.sealed))
        }
        guard !uploads.isEmpty else { return giveUp() }   // the server's attempts for these steps are used up
        do {
            try engine.enqueueRecapture(sessionId: sessionId, steps: steps, reason: reason, artefacts: uploads)
        } catch UploadEngineError.repeatWindowExpired {
            return giveUp()
        } catch UploadEngineError.kmsKeyMissing {
            return giveUp()
        } catch {
            return hold()
        }
        let used = Set(uploads.map { $0.sealed.keyId })
        for a in sealed where !used.contains(a.sealed.keyId) { destroy(a.sealed) }
        finishRepeatRecord(sessionId)
        return .enqueued
    }

    /// The repeat is settled: its `.repeatPending` record goes (kept as clip-only if it holds interrupted clips).
    private func finishRepeatRecord(_ sessionId: UUID) {
        memoryHolds[sessionId] = nil
        guard let p = (try? store.load(sessionId)) ?? nil, p.stage == .repeatPending else { return }
        if p.interruptedClips.isEmpty {
            try? store.remove(sessionId)
        } else {
            var q = p
            q.stage = .interruptedOnly
            q.artefacts = []
            q.isOpen = false
            try? store.save(q)
        }
    }

    /// R-3 startup repair (run by `retryHeld`, so at launch and on foreground): removes held records that are
    /// obsolete (`isObsolete`). Only the RECORD is removed; artefacts the engine owns are never touched.
    @discardableResult
    public func removeObsolete(engine: UploadEngine) -> [UUID] {
        removeObsolete(engine: engine, only: nil)
    }

    @discardableResult
    private func removeObsolete(engine: UploadEngine, only: UUID?) -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        guard let loaded = try? store.loadEach() else { return [] }
        var removed: [UUID] = []
        for p in loaded.records where (only == nil || p.sessionId == only) && isObsolete(p, engine: engine) {
            if (try? store.remove(p.sessionId)) != nil {
                memoryHolds[p.sessionId] = nil
                removed.append(p.sessionId)
            }
        }
        return removed
    }

    /// R-3: a held record is obsolete when
    /// - it is closed (not a capture still running in this process) and keeps no interrupted clips;
    /// - the engine already owns its session;
    /// - it has no artefact of its own: every artefact is in the engine's record, or no longer on the phone;
    /// - and it can never complete itself: no patient id (always HANDOFF_PATIENT_UNKNOWN; the signature of the
    ///   old repeat checkpoint). A record WITH a patient id is processed instead: `ensureSessionItems` may still
    ///   have outbox items (e.g. clinical data) to add, and a successful pass removes the record.
    func isObsolete(_ p: PendingHandoff, engine: UploadEngine) -> Bool {
        guard !p.isOpen, p.interruptedClips.isEmpty, p.stage != .interruptedOnly, p.patientId == nil,
              let rec = engine.record(p.sessionId) else { return false }
        let owned = Set(rec.artefacts.map { $0.sealed.keyId })
        let fm = FileManager.default
        return !p.artefacts.contains { !owned.contains($0.sealed.keyId) && fm.fileExists(atPath: $0.sealed.path.path) }
    }

    // MARK: processing

    private func process(_ input: PendingHandoff, original: PendingHandoff?, engine: UploadEngine?) -> HandoffOutcome {
        var p = mergingKeptClips(input)
        inProgress[p.sessionId] = p
        defer { inProgress[input.sessionId] = nil }
        if p.attempts.isEmpty, !p.interruptedClips.isEmpty {
            // R-2: only interrupted clips (nothing accepted or consumed): nothing to queue; keep them held.
            return keepInterruptedOnly(p, original: original)
        }
        guard let engine else { return hold(p, .uploadNotConfigured, original) }
        guard let patientId = p.patientId else { return hold(p, .patientUnknown, original) }

        // C1: every artefact that will be uploaded needs its data key wrapped for the server KMS. Keys sealed
        // without a configured KMS key are wrapped now (the device key still exists until received_verified).
        let accepted = Set(p.attempts.filter { $0.verdict == .accept }.map { "\($0.step.rawValue)#\($0.attempt)" })
        for i in p.artefacts.indices where p.artefacts[i].sealed.wrappedKey == nil
            && accepted.contains("\(p.artefacts[i].step.rawValue)#\(p.artefacts[i].attempt)") {
            guard let wrapper else { return hold(p, .kmsKeyMissing, original) }
            do {
                p.artefacts[i].sealed.wrappedKey = try wrapper.wrap(try keys.key(id: p.artefacts[i].sealed.keyId))
            } catch {
                return hold(p, .enqueueFailed(error), original)
            }
        }
        inProgress[p.sessionId] = p

        var plan: CaptureSessionPlan
        do {
            guard let meta = p.metadata else {
                throw CaptureHandoffError.metadataIncomplete(["distance_cm", "angle_deg", "lighting_lux"])
            }
            plan = try handoff.makeSessionPlan(
                sessionId: p.sessionId, patientId: patientId, capturedAt: p.capturedAt, offline: p.offline,
                protocolVersion: p.protocolVersion,
                metadata: try CaptureHandoff.scanMetadata(
                    from: meta, faceAccepted: p.attempts.contains { $0.step == .neutralFace && $0.verdict == .accept }),
                attempts: p.attempts, vitals: p.vitals, artefacts: p.artefacts)
        } catch let e as CaptureHandoffError {
            return hold(p, e, original)
        } catch {
            return hold(p, .enqueueFailed(error), original)
        }
        if p.clinicalData == nil { p.clinicalData = plan.clinicalData }
        plan.clinicalData = p.clinicalData
        inProgress[p.sessionId] = p

        if engine.record(p.sessionId) == nil {
            // Persist the stable clinical-data ids before the engine takes the session (skip if unchanged).
            if p != original {
                do { try store.save(p) } catch { return hold(p, .enqueueFailed(error), original) }
            }
            do {
                try engine.enqueueSession(sessionId: p.sessionId, participantCode: p.maskedCode,
                                          createScan: plan.createScan, scanId: nil, artefacts: plan.artefacts)
            } catch {
                if engine.record(p.sessionId) == nil { return hold(p, .enqueueFailed(error), original) }
                // The record was saved before the throw: ensureSessionItems below completes the items.
            }
        }
        p.stage = .engineOwned
        do {
            try engine.ensureSessionItems(plan, participantCode: p.maskedCode)
        } catch {
            return hold(p, .enqueueFailed(error), original)
        }
        for s in plan.discarded { destroy(s) }   // non-accepted attempts: never uploaded, owned by nobody
        memoryHolds[p.sessionId] = nil
        if !p.interruptedClips.isEmpty {
            // R-2: the engine owns the session's artefacts; the record stays only for its interrupted clips.
            var residual = p
            residual.stage = .interruptedOnly
            residual.artefacts = []
            residual.diagnostic = nil
            if (try? store.save(residual)) == nil { memoryHolds[p.sessionId] = residual }
            return .enqueued
        }
        try? store.remove(p.sessionId)           // the record only: the artefacts belong to the engine
        return .enqueued
    }

    /// Round 2 (I2): interrupted clips merged into the stored record (or an in-memory hold) after this submission
    /// was built are carried along (union by sealed key id), so a save never overwrites them and the record is
    /// never removed while it holds clips.
    private func mergingKeptClips(_ p: PendingHandoff) -> PendingHandoff {
        var q = p
        var have = Set(q.interruptedClips.flatMap { $0.artefacts.map { $0.sealed.keyId } })
        let stored = (try? store.load(p.sessionId)) ?? nil
        for c in (stored?.interruptedClips ?? []) + (memoryHolds[p.sessionId]?.interruptedClips ?? [])
            where !c.artefacts.contains(where: { have.contains($0.sealed.keyId) }) {
            q.interruptedClips.append(c)
            for a in c.artefacts { have.insert(a.sealed.keyId) }
        }
        return q
    }

    /// R-2: a record holding only interrupted clips. Kept (persisted, or in memory if that fails), never queued.
    private func keepInterruptedOnly(_ p: PendingHandoff, original: PendingHandoff?) -> HandoffOutcome {
        var q = p
        q.stage = .interruptedOnly
        q.isOpen = false
        q.diagnostic = CaptureHandoffError.noAttempts.diagnostic
        if let original, original == q {
            memoryHolds[q.sessionId] = nil
            return .held(.noAttempts)
        }
        do {
            try store.save(q)
            memoryHolds[q.sessionId] = nil
            return .held(.noAttempts)
        } catch {
            memoryHolds[q.sessionId] = q
            return .holdFailed(.noAttempts)
        }
    }

    /// Persists the hold unless it is identical to what is already stored (no re-seal on every retry).
    private func hold(_ p: PendingHandoff, _ e: CaptureHandoffError, _ original: PendingHandoff?) -> HandoffOutcome {
        var q = p
        q.diagnostic = e.diagnostic
        if let original, original == q {
            memoryHolds[q.sessionId] = nil
            return .held(e)
        }
        do {
            try store.save(q)
            memoryHolds[q.sessionId] = nil
            return .held(e)
        } catch {
            memoryHolds[q.sessionId] = q
            return .holdFailed(e)
        }
    }

    private func destroy(_ s: SealedArtefact) {
        try? keys.destroy(id: s.keyId)
        try? FileManager.default.removeItem(at: s.path)
    }

    // MARK: relaunch sweep

    /// Launch only (before any capture starts):
    /// 1. deletes every plaintext file in `captureDirectory`;
    /// 2. deletes sealed files in `sealedDirectory` referenced by none of: the engine, a held hand-off, an
    ///    in-memory hold, a session being submitted;
    /// 3. destroys artefact keys (UUID-shaped ids only) referenced by none of those, nor by a held record itself.
    /// Steps 2-3 are skipped when ownership cannot be established: no engine, unreadable engine records, or an
    /// unreadable held record (its references are unknown; e.g. Keychain not yet available after a reboot).
    public func sweep(captureDirectory: URL, sealedDirectory: URL, engine: UploadEngine?) -> SweepReport {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var report = SweepReport()
        for name in (try? fm.contentsOfDirectory(atPath: captureDirectory.path)) ?? [] {
            if (try? fm.removeItem(at: captureDirectory.appendingPathComponent(name))) != nil {
                report.deletedPlaintext += 1
            }
        }
        let loaded = try? store.loadEach()
        report.unreadableRecords = loaded?.unreadable.count ?? 0
        guard let engine, let owned = engine.referencedArtefacts(), let loaded, loaded.unreadable.isEmpty,
              let records = try? store.recordRefs() else {
            report.sealedSweepSkipped = true
            return report
        }
        let referenced = owned
            + loaded.records.flatMap { $0.allSealed }       // R-2: including interrupted clips
            + memoryHolds.values.flatMap { $0.allSealed }
            + inProgress.values.flatMap { $0.allSealed }
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
