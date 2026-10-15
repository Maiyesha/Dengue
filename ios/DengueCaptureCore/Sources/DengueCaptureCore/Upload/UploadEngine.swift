import Foundation

public enum UploadEngineError: Error, Equatable {
    /// `enqueueSession` needs either a createScan request or a known scan id.
    case noScan
    case unknownSession
}

/// Drains the outbox: createScan, clinical data, recapture, and per artefact declare → parts → complete.
///
/// - Declare sends the SEALED file's sha256 and size.
/// - Parts are 8 MiB byte ranges of the sealed file. Each part URL is minted just before its upload; a 403
///   (expired URL) re-mints that part's URL and retries once.
/// - Complete: `received_verified` marks the artefact verified. DS_UPLOAD_005 re-uploads the parts and
///   completes again with the same idempotency key.
/// - Keys are destroyed and sealed files deleted only when EVERY artefact of the session is verified.
/// - Artefact routes use the device token (`DengueAPI` routes them with `.device`); verdict polls use
///   `getScan(auth: .device)`.
public final class UploadEngine {
    /// Background URLSession identifier used by the app's `PartUploader`.
    public static let backgroundSessionIdentifier = "my.reainmaker.denguesense.upload"

    private let outbox: Outbox
    private let api: DengueAPI
    private let sessions: UploadSessionStore
    private let keys: KeyStore
    private let uploader: PartUploader
    private let notifier: RepeatNotifier
    private let partSize: Int64

    private let stateLock = NSLock()
    private var draining = false
    private let recordLock = NSRecursiveLock()

    /// Called when an artefact route is refused for the device token (DS_DEVICE_00x). The item is kept for
    /// retry; the app should renew the token (or re-enrol) and drain again.
    public var onDeviceAuthFailure: ((APIError) -> Void)?
    /// Called when a user-token route (createScan, recapture, clinical data) gets 401. The item is kept for
    /// retry (an offline capture often uploads after the nurse's session expired); the app should prompt
    /// sign-in. Other sessions' device-token uploads continue.
    public var onUserAuthFailure: (() -> Void)?

    public init(outbox: Outbox, api: DengueAPI, sessions: UploadSessionStore, keys: KeyStore,
                uploader: PartUploader, notifier: RepeatNotifier, partSize: Int64 = UploadPart.defaultSize) {
        self.outbox = outbox; self.api = api; self.sessions = sessions; self.keys = keys
        self.uploader = uploader; self.notifier = notifier; self.partSize = partSize
    }

    // MARK: enqueue

    /// Registers the session and enqueues createScan (if `createScan` is given) and, per artefact,
    /// declare → upload → complete. Only the masked participant code is stored.
    public func enqueueSession(sessionId: UUID, participantCode: String, createScan: CreateScanRequest?,
                               scanId: UUID?, artefacts: [ArtefactUpload]) throws {
        guard createScan != nil || scanId != nil else { throw UploadEngineError.noScan }
        let rec = UploadSessionRecord(sessionId: sessionId, maskedCode: NurseCopy.maskedStudyID(participantCode),
                                      scanId: scanId, artefacts: artefacts)
        try withRecords { try sessions.save(rec) }   // saved first: items never reference a missing record
        var dep: UUID?
        if let req = createScan {
            dep = try outbox.enqueue(.createScan, sessionId: sessionId, payload: JSONEncoder().encode(req)).id
        }
        try enqueueArtefactItems(sessionId: sessionId, artefacts, after: dep)
    }

    /// Enqueues a recapture request and the new attempt's artefacts (which wait for the recapture).
    public func enqueueRecapture(sessionId: UUID, steps: [CaptureStepName], reason: String,
                                 artefacts: [ArtefactUpload]) throws {
        try update(sessionId) {
            $0.artefacts += artefacts
            if !artefacts.isEmpty {
                $0.verdict = .uploading
                $0.localDataDestroyed = false
                $0.repeatReasons = []
            }
        }
        let payload = try JSONEncoder().encode(UploadPayload.Recapture(steps: steps, reason: reason))
        let r = try outbox.enqueue(.recapture, sessionId: sessionId, payload: payload)
        try enqueueArtefactItems(sessionId: sessionId, artefacts, after: r.id)
    }

    public func enqueueClinicalData(sessionId: UUID, patientId: UUID, request: ClinicalDataRequest) throws {
        let payload = try JSONEncoder().encode(UploadPayload.ClinicalData(patientId: patientId, request: request))
        try outbox.enqueue(.clinicalData, sessionId: sessionId, payload: payload)
    }

    private func enqueueArtefactItems(sessionId: UUID, _ artefacts: [ArtefactUpload], after dep: UUID?) throws {
        for a in artefacts {
            let p = try JSONEncoder().encode(UploadPayload.Artefact(artefactLocalId: a.localId))
            let d = try outbox.enqueue(.declareArtefact, sessionId: sessionId, payload: p, dependsOn: dep)
            let u = try outbox.enqueue(.uploadArtefact, sessionId: sessionId, payload: p, dependsOn: d.id)
            try outbox.enqueue(.completeArtefact, sessionId: sessionId, payload: p, dependsOn: u.id)
        }
    }

    public func record(_ sessionId: UUID) -> UploadSessionRecord? {
        withRecords { try? sessions.load(sessionId) }
    }

    // MARK: launch

    /// Call at app launch (after the device token is renewed if due): recovers interrupted items, finishes
    /// interrupted quarantines and local-data destruction, then drains.
    public func launch() async {
        try? outbox.recoverInFlight()
        for s in (try? outbox.pendingQuarantineSessions()) ?? [] {
            finishQuarantine(s)
        }
        for rec in (withRecords { try? sessions.loadAll() } ?? []) where !rec.localDataDestroyed {
            if rec.verdict == .quarantined {
                finishQuarantine(rec.sessionId)
            } else {
                destroyIfAllVerified(rec.sessionId)
            }
        }
        await drain()
    }

    // MARK: drain

    /// Processes ready outbox items in order until none is ready. Concurrent calls return immediately.
    public func drain() async {
        guard beginDrain() else { return }
        defer { endDrain() }
        while true {
            guard let item = try? outbox.nextReady() else { return }
            do { try outbox.markInFlight(item.id) } catch { return }
            do {
                try await process(item)
                try outbox.markDone(item.id)
            } catch let e as APIError {
                if !(await handle(e, item)) { return }
            } catch let f as LocalFailure {
                _ = await handle(.invalid(code: f.code), item)
            } catch {
                // Local storage error: try again later with backoff.
                if (try? outbox.apply(.retryable, to: item.id)) == nil { return }
            }
        }
    }

    private func beginDrain() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if draining { return false }
        draining = true
        return true
    }
    private func endDrain() {
        stateLock.lock(); defer { stateLock.unlock() }
        draining = false
    }

    enum LocalFailure: Error {
        case badPayload, missingRecord, missingArtefact, missingScanId, notDeclared, localFileMissing, tooManyParts
        var code: String {
            switch self {
            case .badPayload: return "LOCAL_BAD_PAYLOAD"
            case .missingRecord: return "LOCAL_MISSING_RECORD"
            case .missingArtefact: return "LOCAL_MISSING_ARTEFACT"
            case .missingScanId: return "LOCAL_MISSING_SCAN_ID"
            case .notDeclared: return "LOCAL_NOT_DECLARED"
            case .localFileMissing: return "LOCAL_FILE_MISSING"
            case .tooManyParts: return "LOCAL_TOO_MANY_PARTS"
            }
        }
    }

    private func process(_ item: OutboxItem) async throws {
        let key = item.idempotencyKey.uuidString
        switch item.kind {
        case .createScan:
            let req = try decode(CreateScanRequest.self, item.payload)
            let resp = try await api.createScan(req, idempotencyKey: key)
            try update(item.sessionId) { $0.scanId = resp.scan.id }
        case .clinicalData:
            let p = try decode(UploadPayload.ClinicalData.self, item.payload)
            _ = try await api.postClinicalData(patientId: p.patientId, request: p.request, idempotencyKey: key)
        case .recapture:
            let p = try decode(UploadPayload.Recapture.self, item.payload)
            let scanId = try requireScanId(item.sessionId)
            _ = try await api.recapture(scanId: scanId, steps: p.steps, reason: p.reason, idempotencyKey: key)
        case .declareArtefact:
            let (rec, a) = try artefact(for: item)
            guard let scanId = rec.scanId else { throw LocalFailure.missingScanId }
            let req = DeclareArtefactRequest(step: a.step, attempt: a.attempt, kind: a.kind,
                                             sizeBytes: a.sealed.sealedSizeBytes, sha256: a.sealed.sha256OfCiphertext,
                                             deviceVerdict: a.deviceVerdict)
            let resp = try await api.declareArtefact(scanId: scanId, request: req, idempotencyKey: key)
            try updateArtefact(item.sessionId, a.localId) {
                $0.serverArtefactId = resp.artefactId
                if $0.status == .pending { $0.status = .declared }
            }
        case .uploadArtefact:
            let (_, a) = try artefact(for: item)
            guard let artefactId = a.serverArtefactId else { throw LocalFailure.notDeclared }
            try await uploadParts(sessionId: item.sessionId, a, artefactId: artefactId, reuseExisting: true)
            try updateArtefact(item.sessionId, a.localId) { if $0.status != .verified { $0.status = .uploaded } }
        case .completeArtefact:
            let (_, a) = try artefact(for: item)
            guard let artefactId = a.serverArtefactId else { throw LocalFailure.notDeclared }
            do {
                try await complete(artefactId, key: key)
            } catch APIError.uploadIncomplete {
                // DS_UPLOAD_005 reports only a byte total, not which parts are missing: re-send every part
                // (a part PUT overwrites the same part number), then complete again with the SAME key.
                try updateArtefact(item.sessionId, a.localId) { $0.uploadedParts = [] }
                let fresh = try artefact(sessionId: item.sessionId, localId: a.localId)
                try await uploadParts(sessionId: item.sessionId, fresh, artefactId: artefactId, reuseExisting: false)
                try await complete(artefactId, key: key)
            }
            try updateArtefact(item.sessionId, a.localId) { $0.status = .verified }
            destroyIfAllVerified(item.sessionId)
        }
    }

    private func complete(_ artefactId: UUID, key: String) async throws {
        let resp = try await api.completeArtefact(id: artefactId, idempotencyKey: key)
        guard resp.status == "received_verified" else { throw APIError.retryable }
    }

    // MARK: parts

    static func partId(artefactId: UUID, part: Int) -> String { "\(artefactId.uuidString.lowercased())/\(part)" }

    private func uploadParts(sessionId: UUID, _ a: ArtefactUpload, artefactId: UUID, reuseExisting: Bool) async throws {
        let path = a.sealed.path
        guard FileManager.default.fileExists(atPath: path.path) else { throw LocalFailure.localFileMissing }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber,
           size.int64Value != a.sealed.sealedSizeBytes {
            throw LocalFailure.localFileMissing   // truncated or replaced: cannot match the declared sha
        }
        let parts = UploadPart.plan(totalSize: a.sealed.sealedSizeBytes, partSize: partSize)
        guard parts.count <= UploadPart.maxParts else { throw LocalFailure.tooManyParts }
        var done = Set(a.uploadedParts)
        for part in parts where !done.contains(part.number) {
            let pid = Self.partId(artefactId: artefactId, part: part.number)
            var ok = false
            if reuseExisting, await uploader.existingOutcome(partId: pid) == .success { ok = true }
            if !ok {
                let url = try await mintPartURL(artefactId, part.number)   // minted just before this part starts
                var outcome = await uploader.upload(file: path, part: part, to: url, partId: pid)
                if outcome == .httpStatus(403) {   // pre-signed URL expired: re-mint once
                    let fresh = try await mintPartURL(artefactId, part.number)
                    outcome = await uploader.upload(file: path, part: part, to: fresh, partId: pid)
                }
                guard outcome == .success else { throw APIError.retryable }
            }
            done.insert(part.number)
            try updateArtefact(sessionId, a.localId) {
                if !$0.uploadedParts.contains(part.number) { $0.uploadedParts.append(part.number) }
            }
        }
    }

    private func mintPartURL(_ artefactId: UUID, _ part: Int) async throws -> URL {
        let r = try await api.partURL(artefactId: artefactId, part: part)
        guard let url = URL(string: r.url) else { throw APIError.retryable }
        return url
    }

    // MARK: error handling

    /// Returns false when draining should stop.
    private func handle(_ e: APIError, _ item: OutboxItem) async -> Bool {
        if Self.isDeviceRoute(item.kind), e == .unauthorized || e == .reEnrol {
            // The device token is stale or revoked; failing the upload would strand the data. Keep it.
            _ = try? outbox.apply(.retryable, to: item.id)
            onDeviceAuthFailure?(e)
            return false
        }
        if !Self.isDeviceRoute(item.kind), e == .unauthorized {
            _ = try? outbox.apply(.retryable, to: item.id)
            onUserAuthFailure?()
            return true
        }
        guard let action = try? outbox.apply(e, to: item.id) else { return false }
        switch action {
        case .quarantineRequired(let s):
            finishQuarantine(s)
        case .refetchScan(let s):
            if item.kind == .recapture { abandonRecaptureArtefacts(recaptureItem: item.id, sessionId: s) }
            await refetch(s)
        case .needsRepeat:
            if case .needsRepeat(let reasons) = e { markRepeat(item.sessionId, reasons: reasons) }
        case .failed:
            if Self.isArtefactKind(item.kind) { markArtefactsFailed(item) }
        case .retryScheduled, .ignoredFrozen:
            break
        }
        return true
    }

    private static func isDeviceRoute(_ k: OutboxKind) -> Bool {
        k == .declareArtefact || k == .uploadArtefact || k == .completeArtefact
    }
    private static func isArtefactKind(_ k: OutboxKind) -> Bool { isDeviceRoute(k) }

    private func markArtefactsFailed(_ item: OutboxItem) {
        guard let p = try? decode(UploadPayload.Artefact.self, item.payload) else { return }
        try? updateArtefact(item.sessionId, p.artefactLocalId) { $0.status = .failed }
    }

    /// DS_QG_099: the server will take no more attempts. The new attempt's artefacts can never be uploaded:
    /// fail their items and destroy their keys/files. The nurse is never asked to repeat.
    private func abandonRecaptureArtefacts(recaptureItem: UUID, sessionId: UUID) {
        guard let items = try? outbox.items(sessionId: sessionId) else { return }
        for d in items where d.dependsOn == recaptureItem && d.kind == .declareArtefact {
            _ = try? outbox.apply(.invalid(code: "DS_QG_099"), to: d.id)
            guard let p = try? decode(UploadPayload.Artefact.self, d.payload),
                  let a = try? artefact(sessionId: sessionId, localId: p.artefactLocalId) else { continue }
            if destroyLocal([a]) {
                try? updateArtefact(sessionId, a.localId) { $0.status = .failed }
            }
        }
    }

    // MARK: quarantine and destruction

    private func finishQuarantine(_ sessionId: UUID) {
        let rec = record(sessionId)
        let sealed = rec?.artefacts.map { $0.sealed } ?? []
        var destroyed = true
        do { try outbox.quarantine(sessionId: sessionId, keys: keys, sealedPaths: sealed) } catch { destroyed = false }
        try? update(sessionId) {
            $0.verdict = .quarantined
            $0.localDataDestroyed = destroyed
        }
    }

    private func destroyIfAllVerified(_ sessionId: UUID) {
        recordLock.lock(); defer { recordLock.unlock() }
        guard let rec = record(sessionId), !rec.localDataDestroyed, !rec.artefacts.isEmpty,
              rec.artefacts.allSatisfy({ $0.status == .verified }) else { return }
        let ok = destroyLocal(rec.artefacts)
        try? update(sessionId) {
            $0.localDataDestroyed = ok
            if $0.verdict == .uploading { $0.verdict = .awaitingVerdict }
        }
    }

    /// Destroys keys ("deletion means destroying the key") and removes sealed files. True when all succeeded.
    @discardableResult
    private func destroyLocal(_ artefacts: [ArtefactUpload]) -> Bool {
        var ok = true
        let fm = FileManager.default
        for a in artefacts {
            do { try keys.destroy(id: a.sealed.keyId) } catch { ok = false }
            if fm.fileExists(atPath: a.sealed.path.path) {
                do { try fm.removeItem(at: a.sealed.path) } catch { ok = false }
            }
        }
        return ok
    }

    // MARK: verdicts

    /// Polls `getScan(auth: .device)` for every session awaiting a server verdict. Run on foreground and on a
    /// silent push (whose payload carries only a scan id).
    public func refreshVerdicts() async {
        let waiting = (withRecords { try? sessions.loadAll() } ?? []).filter { $0.verdict == .awaitingVerdict }
        for rec in waiting {
            guard let scanId = rec.scanId,
                  let r = try? await api.getScan(id: scanId, auth: .device) else { continue }
            applyVerdict(rec.sessionId, r.scan, allowRepeat: true)
        }
    }

    private func refetch(_ sessionId: UUID) async {
        guard let scanId = record(sessionId)?.scanId,
              let r = try? await api.getScan(id: scanId, auth: .device) else { return }
        applyVerdict(sessionId, r.scan, allowRepeat: false)
    }

    private static let failVerdicts: Set<String> = ["fail", "failed"]

    private func applyVerdict(_ sessionId: UUID, _ scan: ScanDetail, allowRepeat: Bool) {
        if scan.status == .qualityPending || scan.status == .capturePending {
            if !allowRepeat { try? update(sessionId) { $0.verdict = .awaitingVerdict } }
            return
        }
        // Latest attempt per step decides.
        var latest: [String: ScanStepState] = [:]
        for s in scan.steps where (latest[s.step]?.attempt ?? Int.min) <= s.attempt { latest[s.step] = s }
        let failing = latest.values.filter { Self.failVerdicts.contains(($0.serverVerdict ?? "").lowercased()) }
            .sorted { $0.step < $1.step }
        if allowRepeat, !failing.isEmpty {
            var reasons: [ReasonCode] = []
            for s in failing {
                for c in s.reasonCodes { if let rc = ReasonCode(rawValue: c), !reasons.contains(rc) { reasons.append(rc) } }
            }
            try? outbox.markNeedsRepeat(sessionId: sessionId, reasons: reasons)
            markRepeat(sessionId, reasons: reasons)
        } else {
            try? update(sessionId) { $0.verdict = allowRepeat ? .accepted : .closed }
        }
    }

    /// Records the repeat request and posts the notice once. Text: "A recording for ••123 needs repeating".
    private func markRepeat(_ sessionId: UUID, reasons: [ReasonCode]) {
        var notifyText: String?
        try? update(sessionId) {
            if $0.verdict != .needsRepeat {
                notifyText = NurseCopy.repeatNotification(maskedStudyID: $0.maskedCode)
            }
            $0.verdict = .needsRepeat
            $0.repeatReasons = reasons
        }
        if let t = notifyText { notifier.postRepeatNotice(t) }
    }

    // MARK: record helpers

    private func withRecords<T>(_ f: () throws -> T) rethrows -> T {
        recordLock.lock(); defer { recordLock.unlock() }
        return try f()
    }

    private func update(_ sessionId: UUID, _ f: (inout UploadSessionRecord) -> Void) throws {
        try withRecords {
            guard var r = try sessions.load(sessionId) else { throw LocalFailure.missingRecord }
            f(&r)
            try sessions.save(r)
        }
    }

    private func updateArtefact(_ sessionId: UUID, _ localId: UUID, _ f: (inout ArtefactUpload) -> Void) throws {
        var found = false
        try update(sessionId) { r in
            if let i = r.artefacts.firstIndex(where: { $0.localId == localId }) { f(&r.artefacts[i]); found = true }
        }
        if !found { throw LocalFailure.missingArtefact }
    }

    private func requireScanId(_ sessionId: UUID) throws -> UUID {
        guard let rec = record(sessionId) else { throw LocalFailure.missingRecord }
        guard let id = rec.scanId else { throw LocalFailure.missingScanId }
        return id
    }

    private func artefact(sessionId: UUID, localId: UUID) throws -> ArtefactUpload {
        guard let rec = record(sessionId) else { throw LocalFailure.missingRecord }
        guard let a = rec.artefacts.first(where: { $0.localId == localId }) else { throw LocalFailure.missingArtefact }
        return a
    }

    private func artefact(for item: OutboxItem) throws -> (UploadSessionRecord, ArtefactUpload) {
        let p = try decode(UploadPayload.Artefact.self, item.payload)
        guard let rec = record(item.sessionId) else { throw LocalFailure.missingRecord }
        guard let a = rec.artefacts.first(where: { $0.localId == p.artefactLocalId }) else {
            throw LocalFailure.missingArtefact
        }
        return (rec, a)
    }

    private func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(t, from: data) } catch { throw LocalFailure.badPayload }
    }
}
