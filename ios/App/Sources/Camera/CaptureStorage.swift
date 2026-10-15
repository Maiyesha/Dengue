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
        let results = handoffs.retryHeld(engine: engine)
        if results.values.contains(.enqueued) { UploadCoordinator.shared?.drainSoon() }
    }

    func checkpoint(_ p: PendingHandoff) { try? handoffs.checkpoint(p) }

    @discardableResult
    func submit(_ p: PendingHandoff) -> HandoffOutcome {
        let outcome = handoffs.submit(p, engine: engine)
        if outcome == .enqueued { UploadCoordinator.shared?.drainSoon() }
        return outcome
    }

    func heldSummaries() -> [HeldHandoffSummary] { (try? handoffs.heldSummaries()) ?? [] }

    /// Explicit nurse discard (or consent stop / quarantine): the only path that shreds a held session.
    func discard(_ sessionId: UUID, reason: DiscardReason) { try? handoffs.discard(sessionId: sessionId, reason: reason) }

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
