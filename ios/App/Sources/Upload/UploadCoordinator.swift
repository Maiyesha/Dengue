import Foundation
import UIKit
import UserNotifications
import Security
import DengueCaptureCore

/// Posts "A recording for ••123 needs repeating" as a local notification, only while the app is not active
/// (in the foreground the outbox screen shows the step-level reason instead). The text carries nothing but
/// the masked participant code; no userInfo is attached.
final class LocalRepeatNotifier: RepeatNotifier {
    func postRepeatNotice(_ text: String) {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else {
                // I2: foreground -> in-app banner (RepeatBanner at the app root) instead of a notification.
                NotificationCenter.default.post(name: .dsRepeatRequested, object: nil, userInfo: ["text": text])
                return
            }
            let content = UNMutableNotificationContent()
            content.body = text
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }
    }
}

/// Device credential and interrupted-enrolment progress in the Keychain (`AfterFirstUnlockThisDeviceOnly`,
/// so background wakes can read the device token while the phone is locked).
final class DeviceCredentialStore: @unchecked Sendable {   // Keychain calls are thread-safe
    struct Stored: Codable, Equatable {
        var deviceId: UUID
        var keyId: String
        var deviceToken: String
        var issuedAt: Date
        var expiresIn: TimeInterval
    }

    private let service = "ai.reainmaker.denguecapture.device"

    func loadCredential() -> Stored? { load(Stored.self, account: "credential") }
    func saveCredential(_ c: Stored) { save(c, account: "credential") }
    func clearCredential() { delete(account: "credential") }

    func loadProgress() -> EnrolmentProgress? { load(EnrolmentProgress.self, account: "enrolment-progress") }
    func saveProgress(_ p: EnrolmentProgress) { save(p, account: "enrolment-progress") }
    func clearProgress() { delete(account: "enrolment-progress") }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func load<T: Decodable>(_ t: T.Type, account: String) -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }
    private func save<T: Encodable>(_ v: T, account: String) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        var q = query(account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    private func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}


/// One `beginBackgroundTask` window. The expiration handler ends the task (exactly once) and flips
/// `isExpired`, which the engine checks before starting each outbox item.
private final class BackgroundWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var expired = false
    private var ended = false

    var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expired }

    /// Main thread only.
    @MainActor func begin() {
        let tid = UIApplication.shared.beginBackgroundTask(withName: "denguesense.upload") { [weak self] in
            self?.expire()   // runs on the main thread
        }
        lock.lock(); id = tid; lock.unlock()
    }

    private func expire() {
        lock.lock(); expired = true; lock.unlock()
        end()
    }

    /// Ends the background task once; safe from any thread and from the expiration handler.
    func end() {
        lock.lock()
        guard !ended, id != .invalid else { lock.unlock(); return }
        ended = true
        let tid = id
        lock.unlock()
        if Thread.isMainThread {
            UIApplication.shared.endBackgroundTask(tid)
        } else {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(tid) }
        }
    }
}

/// App composition root for uploads: background part uploader, core `UploadEngine`, device token
/// (enrol / `renewIfDue`, single-flight), APNs registration, verdict refresh, retry wake-ups.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
final class UploadCoordinator: @unchecked Sendable {
    private static let sharedLock = NSLock()
    private static var instance: UploadCoordinator?

    /// Created on first access once MDM has provisioned `api_base_url`; nil until then and re-tried on every
    /// access, so a managed-config change enables uploads (and held hand-offs) without a relaunch.
    static var shared: UploadCoordinator? {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if instance == nil { instance = try? UploadCoordinator() }
        return instance
    }

    let uploader: BackgroundPartUploader
    let engine: UploadEngine
    let outbox: Outbox
    /// C2: DengueAPI-backed consent with the offline roster cache.
    let consent: ConsentService
    private let api: URLSessionDengueAPI
    private let enrolment: DeviceEnrolment
    private let credentials: DeviceCredentialStore
    /// Concurrent wakes (launch, push, part completion, foreground) share one renew/enrol.
    private let tokenFlight = SingleFlight<Bool>()
    private let lock = NSLock()
    private var tokenState: DeviceTokenState?
    private var tokenRefused = false
    private var launched = false
    private var pendingPushToken: String?
    private var wakeTask: Task<Void, Never>?
    private var renewTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) throws {
        let fm = FileManager.default
        var base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DengueSense", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try base.setResourceValues(rv)

        let managed = defaults.dictionary(forKey: "com.apple.configuration.managed") ?? [:]
        guard let s = managed["api_base_url"] as? String, let baseURL = URL(string: s), baseURL.scheme == "https" else {
            throw CocoaError(.featureUnsupported)   // not provisioned by MDM yet
        }
        let clock = SystemClock()
        outbox = try Outbox.makeDefault(directory: base, clock: clock)   // store choice lives in core (fix 5)
        uploader = try BackgroundPartUploader(baseDirectory: base)   // creates the background session
        let sessions = try FileUploadSessionStore(directory: base.appendingPathComponent("upload-sessions"))

        let creds = DeviceCredentialStore()
        credentials = creds
        // I7: dedicated TLS 1.3 session (pinned via NSPinnedDomains), never `.shared`.
        api = URLSessionDengueAPI(baseURL: baseURL, session: NetworkSecurity.apiSession(),
                                  tokenProvider: { kind in UploadCoordinator.bearer(for: kind, credentials: creds) })
        consent = ConsentService(api: api, cache: ConsentCache(storage: FileConsentCacheStorage(
            url: base.appendingPathComponent("consent-roster.json"))), wardId: managed["ward_id"] as? String)
        enrolment = DeviceEnrolment(api: api, attest: AppAttestService(), clock: clock)
        engine = UploadEngine(outbox: outbox, api: api, sessions: sessions, keys: SecureEnclaveKeyStore(),
                              uploader: uploader, notifier: LocalRepeatNotifier())

        engine.onDeviceAuthFailure = { [weak self] e in self?.deviceTokenRefused(e) }
        engine.onUserAuthFailure = {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .dsUserAuthFailed, object: nil) }
        }
        uploader.onPartFinished = { [weak self] in
            // Background relaunch: nobody is waiting on the part; drain to consume it and start the next part.
            guard let self else { return }
            Task { await self.withBackgroundTime { sc in await self.drain(shouldContinue: sc) } }
        }
    }

    // MARK: lifecycle

    /// First call per process: renew/enrol the device token, recover the outbox (recoverInFlight, interrupted
    /// quarantines), drain, poll verdicts. Later calls just drain.
    func launch() async {
        let first: Bool = { lock.lock(); defer { lock.unlock() }; let f = !launched; launched = true; return f }()
        guard first else {
            await withBackgroundTime { sc in await self.drain(shouldContinue: sc) }
            return
        }
        await withBackgroundTime { sc in
            _ = await self.prepareDeviceToken()
            let wake = await self.engine.launch(shouldContinue: sc)
            self.scheduleWake(wake)
            if sc() { await self.redrainIfTokenRefused(shouldContinue: sc) }
            await self.engine.refreshVerdicts()
        }
    }

    /// App became active.
    func foreground() async {
        await launch()
        await engine.refreshVerdicts()
        engine.expireRepeatWindows()
        await consent.refreshRoster()
    }

    /// C2: after a successful sign-in: enrol the device (first sign-in) or renew, drain, refresh the roster.
    func signedIn() {
        Task {
            await withBackgroundTime { sc in await self.drain(shouldContinue: sc) }
            await self.consent.refreshRoster()
        }
    }

    /// C2: renew the device token before it expires (renewal window starts 4 h before expiry), also while
    /// the app stays in the foreground. Rescheduled after every token change.
    private func scheduleRenewal(_ state: DeviceTokenState) {
        lock.lock(); defer { lock.unlock() }
        renewTask?.cancel()
        let delay = max(60, state.renewAt.timeIntervalSinceNow)
        renewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.withBackgroundTime { sc in await self.drain(shouldContinue: sc) }
        }
    }

    /// Renew/enrol if needed, drain, then schedule the next wake-up for pending retries.
    func drain(shouldContinue: @escaping () -> Bool = { true }) async {
        _ = await prepareDeviceToken()
        let wake = await engine.drain(shouldContinue: shouldContinue)
        scheduleWake(wake)
        if shouldContinue() { await redrainIfTokenRefused(shouldContinue: shouldContinue) }
    }

    /// The engine stopped on a refused device token: renew (or re-enrol) now and, if that produced a token,
    /// drain again instead of waiting for the item's backoff.
    private func redrainIfTokenRefused(shouldContinue: @escaping () -> Bool) async {
        let refused: Bool = { lock.lock(); defer { lock.unlock() }; let r = tokenRefused; tokenRefused = false; return r }()
        guard refused, await prepareDeviceToken() else { return }
        scheduleWake(await engine.drain(shouldContinue: shouldContinue))
    }

    /// Silent APNs push; the payload carries only `scan_id`, which is not needed beyond triggering a poll.
    func handleSilentPush(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard userInfo["scan_id"] is String else { return .noData }
        await withBackgroundTime { sc in
            if await self.prepareDeviceToken(), sc() {   // a fresh token may unblock waiting uploads
                self.scheduleWake(await self.engine.drain(shouldContinue: sc))
            }
            await self.engine.refreshVerdicts()
        }
        return .newData
    }

    // MARK: retry wake-ups

    /// Re-drains at the engine's `nextWakeAt` (earliest retry backoff). In the background the app is usually
    /// suspended before this fires; launch, pushes and background-session events drain then.
    ///
    /// `.skipped` (another drain is running and will report) leaves the schedule untouched. A wake task removes
    /// itself from `wakeTask` under the lock before it drains, so a later reschedule can never cancel a
    /// wake task mid-drain (a cancelled task would turn every request into a retryable error).
    private func scheduleWake(_ result: DrainResult) {
        guard case .done(let at) = result else { return }
        lock.lock(); defer { lock.unlock() }
        wakeTask?.cancel()
        wakeTask = nil
        guard let at else { return }
        let delay = max(1.0, at.timeIntervalSinceNow)   // never a hot loop on already-due work
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            let stillScheduled: Bool = {
                self.lock.lock(); defer { self.lock.unlock() }
                // Not cancelled => still the current wakeTask (rescheduling cancels under this same lock).
                guard !Task.isCancelled else { return false }
                self.wakeTask = nil
                return true
            }()
            guard stillScheduled else { return }
            await self.withBackgroundTime { sc in await self.drain(shouldContinue: sc) }
        }
    }

    // MARK: APNs

    func registerPushToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        lock.lock(); pendingPushToken = hex; lock.unlock()
        Task { await sendPendingPushToken() }
    }

    private func sendPendingPushToken() async {
        let token: String? = { lock.lock(); defer { lock.unlock() }; return pendingPushToken }()
        guard let token, let cred = credentials.loadCredential() else { return }   // retried after enrolment
        do {
            try await api.registerPushToken(deviceId: cred.deviceId, apnsToken: token, idempotencyKey: UUID().uuidString)
            lock.lock(); if pendingPushToken == token { pendingPushToken = nil }; lock.unlock()
        } catch {}
    }

    // MARK: device token

    /// Artefact routes and verdict polls get the device token; only user routes get the nurse's token.
    private static func bearer(for kind: AuthKind, credentials: DeviceCredentialStore) -> String? {
        switch kind {
        case .none: return nil
        case .device: return credentials.loadCredential()?.deviceToken
        case .user: return Self.userAccessToken()
        }
    }

    /// Reads the OIDC access token stored by `OIDCSignIn` (same Keychain item) without hopping to the main actor.
    private static func userAccessToken() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "ai.reainmaker.denguecapture.oidc",
                                kSecAttrAccount as String: "tokens",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let t = try? JSONDecoder().decode(OIDCTokens.self, from: d) else { return nil }
        return t.accessToken
    }

    /// Single-flight (core `SingleFlight`): concurrent callers await the same renew/enrol.
    /// Returns true when a new device token was obtained (renewed or enrolled).
    private func prepareDeviceToken() async -> Bool {
        await tokenFlight.run { [weak self] in await self?.prepareDeviceTokenOnce() ?? false }
    }

    /// Renews the device token when due (`DeviceEnrolment.renewIfDue`); enrols (or resumes an interrupted
    /// enrolment from the Keychain-persisted `EnrolmentProgress`) when there is no usable credential.
    private func prepareDeviceTokenOnce() async -> Bool {
        if let cred = credentials.loadCredential() {
            var state: DeviceTokenState = {
                lock.lock(); defer { lock.unlock() }
                return tokenState ?? DeviceTokenState(issuedAt: cred.issuedAt, expiresIn: cred.expiresIn)
            }()
            var renewed = false
            if let r = try? await enrolment.renewIfDue(state: &state, deviceId: cred.deviceId, keyId: cred.keyId) {
                credentials.saveCredential(.init(deviceId: cred.deviceId, keyId: cred.keyId, deviceToken: r.deviceToken,
                                                 issuedAt: r.state.issuedAt, expiresIn: r.state.expiresIn))
                renewed = true
            }
            lock.lock(); tokenState = state; lock.unlock()
            if !state.reEnrolRequired { scheduleRenewal(state) }
            guard state.reEnrolRequired else { return renewed }
            credentials.clearCredential()   // revoked / DS_DEVICE_001: fall through to a fresh enrolment
            lock.lock(); tokenState = nil; lock.unlock()
        }
        let managed = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") ?? [:]
        guard Self.userAccessToken() != nil, let ward = managed["ward_id"] as? String else { return false }
        let resume = credentials.loadProgress()
        do {
            let c = try await enrolment.enrol(wardId: ward, resume: resume,
                                              persist: { [credentials] in credentials.saveProgress($0) })
            credentials.saveCredential(.init(deviceId: c.deviceId, keyId: c.keyId, deviceToken: c.deviceToken,
                                             issuedAt: c.state.issuedAt, expiresIn: c.state.expiresIn))
            credentials.clearProgress()
            lock.lock(); tokenState = c.state; lock.unlock()
            scheduleRenewal(c.state)
            await sendPendingPushToken()
            return true
        } catch APIError.reEnrol {
            credentials.clearProgress()   // the attested key was refused: start over next time
            return false
        } catch {
            return false
        }
    }

    /// The engine kept the item and stopped; make the next `prepareDeviceToken` renew (or re-enrol) and flag
    /// a re-drain (`redrainIfTokenRefused`).
    private func deviceTokenRefused(_ e: APIError) {
        lock.lock(); defer { lock.unlock() }
        tokenRefused = true
        if e == .reEnrol {
            var s = tokenState ?? DeviceTokenState(issuedAt: .distantPast, expiresIn: 0)
            s.recordFailure(.reEnrol, at: Date())
            tokenState = s
        } else {
            tokenState = DeviceTokenState(issuedAt: .distantPast, expiresIn: 0)   // due now
        }
    }

    // MARK: background time

    /// Runs `work` inside a background-task window. `work` receives `shouldContinue`, false once iOS signals
    /// expiry; the expiration handler ends the task immediately (once), so the watchdog never kills the app.
    private func withBackgroundTime(_ work: @escaping (_ shouldContinue: @escaping () -> Bool) async -> Void) async {
        let window = BackgroundWindow()
        await window.begin()
        await work { !window.isExpired }
        window.end()
    }

    // MARK: capture hand-off

    /// Task 13: a capture hand-off was enqueued by `CaptureStorage` (core `CaptureHandoffService`); drain now.
    func drainSoon() {
        Task { await withBackgroundTime { sc in await self.drain(shouldContinue: sc) } }
    }

    /// Called by the capture flow once a session's artefacts are sealed.
    func enqueue(sessionId: UUID, participantCode: String, createScan: CreateScanRequest?, scanId: UUID?,
                 artefacts: [ArtefactUpload]) throws {
        try engine.enqueueSession(sessionId: sessionId, participantCode: participantCode, createScan: createScan,
                                  scanId: scanId, artefacts: artefacts)
        Task { await withBackgroundTime { sc in await self.drain(shouldContinue: sc) } }
    }
}
