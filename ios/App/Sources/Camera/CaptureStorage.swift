import Foundation
import UIKit
import DengueCaptureCore

/// On-device capture storage and the hand-off to uploads (T13 fix round 1).
///
/// - `capture/`: plaintext recordings, Data Protection Class B (`completeUnlessOpen`). Verified by read-back;
///   if the class cannot be applied, capture is refused (`RecorderError.notReady`); there is no fallback directory.
/// - `sealed/`: AES-GCM sealed artefacts, Class C, excluded from backup.
/// - `held/`: encrypted held hand-offs (`FileHeldHandoffStore`), Class C, excluded from backup.
/// - Launch: closes sessions left open by a previous process, sweeps (plaintext deleted; only unreferenced
///   sealed files/keys destroyed; skipped while uploads are not configured), retries held hand-offs.
///   Foreground and managed-config changes retry held hand-offs again.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
final class CaptureStorage: @unchecked Sendable {
    enum StorageError: Error { case protectionNotApplied(String) }

    static let shared: CaptureStorage? = try? CaptureStorage()

    let keys: KeyStore
    let captureDirectory: URL
    let sealedDirectory: URL
    let heldDirectory: URL
    let handoffs: CaptureHandoffService
    private let lock = NSLock()
    private var launched = false
    /// One backoff loop at a time for `.holdFailed` outcomes.
    private var retryLoopScheduled = false

    init() throws {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DengueSense", isDirectory: true)
        captureDirectory = try Self.directory(base.appendingPathComponent("capture", isDirectory: true),
                                              protection: .completeUnlessOpen)
        sealedDirectory = try Self.directory(base.appendingPathComponent("sealed", isDirectory: true),
                                             protection: .completeUntilFirstUserAuthentication)
        heldDirectory = try Self.directory(base.appendingPathComponent("held", isDirectory: true),
                                           protection: .completeUntilFirstUserAuthentication)
        let keys = SecureEnclaveKeyStore()
        self.keys = keys
        handoffs = CaptureHandoffService(store: try FileHeldHandoffStore(directory: heldDirectory, keys: keys), keys: keys)
    }

    /// Creates the directory with `protection`, excludes it from backup and reads the class back.
    private static func directory(_ url: URL, protection: FileProtectionType) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
        try fm.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try u.setResourceValues(rv)
        #if !targetEnvironment(simulator)
        let applied = try fm.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        guard applied == protection else { throw StorageError.protectionNotApplied(url.lastPathComponent) }
        #endif
        return u
    }

    private var engine: UploadEngine? { UploadCoordinator.shared?.engine }

    // MARK: lifecycle

    /// Once per process, before any capture can start.
    func launch() {
        let first: Bool = { lock.lock(); defer { lock.unlock() }; let f = !launched; launched = true; return f }()
        guard first else { retryHeld(); return }
        try? handoffs.closeOpen()
        _ = handoffs.sweep(captureDirectory: captureDirectory, sealedDirectory: sealedDirectory, engine: engine)
        retryHeld()
    }

    /// Foreground, managed-config change, and launch.
    func retryHeld() {
        handle(handoffs.retryHeld(engine: engine).values)
    }

    /// Every retry path (launch, foreground, config change, outbox, submit) ends here: drain on success, and a
    /// backoff retry loop whenever a hold could not be persisted (`.holdFailed`).
    private func handle<S: Sequence>(_ outcomes: S) where S.Element == HandoffOutcome {
        let list = Array(outcomes)
        if list.contains(.enqueued) { UploadCoordinator.shared?.drainSoon() }
        if list.contains(where: { if case .holdFailed = $0 { return true }; return false }) { scheduleRetry() }
    }

    func checkpoint(_ p: PendingHandoff) { try? handoffs.checkpoint(p) }

    @discardableResult
    func submit(_ p: PendingHandoff) -> HandoffOutcome {
        let outcome = handoffs.submit(p, engine: engine)
        handle([outcome])   // .holdFailed: kept in memory by the core service; retried with backoff
        return outcome
    }

    /// A hold could not be persisted (e.g. disk full): retry soon, with backoff, while the process lives.
    private func scheduleRetry() {
        let start: Bool = { lock.lock(); defer { lock.unlock() }; let s = !retryLoopScheduled; retryLoopScheduled = true; return s }()
        guard start else { return }   // a loop is already running; it re-checks every outcome
        retryLoop(attempt: 0)
    }

    private func retryLoop(attempt: Int) {
        let delay = min(300.0, 15.0 * pow(2.0, Double(attempt)))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let results = Array(self.handoffs.retryHeld(engine: self.engine).values)
            if results.contains(.enqueued) { UploadCoordinator.shared?.drainSoon() }
            if results.contains(where: { if case .holdFailed = $0 { return true }; return false }) {
                self.retryLoop(attempt: attempt + 1)
            } else {
                self.lock.lock(); self.retryLoopScheduled = false; self.lock.unlock()
            }
        }
    }

    func heldSummaries() -> [HeldHandoffSummary] { (try? handoffs.heldSummaries()) ?? [] }

    /// Explicit nurse discard (or consent stop / quarantine): the only path that shreds a held session.
    func discard(_ sessionId: UUID, reason: DiscardReason) {
        // Ownership is decided from the engine: never shred what the upload engine has registered.
        try? handoffs.discard(sessionId: sessionId, reason: reason, engine: engine)
    }

    /// Destroys sealed artefacts nobody will upload (attempts the device did not accept).
    func destroy(_ artefacts: [SealedStepArtefact]) {
        for a in artefacts {
            try? keys.destroy(id: a.sealed.keyId)
            try? FileManager.default.removeItem(at: a.sealed.path)
        }
    }

    // MARK: sealing

    /// Seals one attempt's video, ROI trace and metadata. Each kind is sealed independently: a failure loses only
    /// that kind (the plan uploads the rest as partial). A Class B read that fails while the device is locked is
    /// retried after `protectedDataDidBecomeAvailable`. Plaintext is always deleted at the end.
    func seal(token: UUID, step: CaptureStep, attempt: Int, video: URL, trace: ROITrace,
              metadata: CaptureMetadata) async -> [SealedStepArtefact] {
        let stem = token.uuidString.lowercased()
        let traceURL = captureDirectory.appendingPathComponent("\(stem).roi.json")
        let metaURL = captureDirectory.appendingPathComponent("\(stem).meta.json")
        // Class B allows creating new files while locked.
        try? trace.encoded().write(to: traceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? metadata.encoded().write(to: metaURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        let sealer = ArtefactSealer(keys: keys)
        var out: [SealedStepArtefact] = []
        for (kind, url) in [(ArtefactKind.video, video), (.roiTrace, traceURL), (.metadata, metaURL)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let dest = sealedDirectory.appendingPathComponent("\(stem).\(kind.rawValue).sealed")
            for _ in 0..<3 {
                do {
                    let s = try CaptureHandoff.sealAndRemovePlaintext(input: url, output: dest, sealer: sealer)
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dest.path)
                    out.append(SealedStepArtefact(step: step, attempt: attempt, kind: kind, sealed: s))
                    break
                } catch {
                    let available = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
                    guard !available else { break }   // not a lock problem: give up on this kind
                    await Self.waitForProtectedData()
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
        return out
    }

    private static func waitForProtectedData() async {
        let name = UIApplication.protectedDataDidBecomeAvailableNotification
        for await _ in NotificationCenter.default.notifications(named: name) { return }
    }
}
