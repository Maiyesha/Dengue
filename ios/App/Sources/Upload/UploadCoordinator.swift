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
            guard UIApplication.shared.applicationState != .active else { return }
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

/// App composition root for uploads: background part uploader, core `UploadEngine`, device token
/// (enrol / `renewIfDue`), APNs registration, verdict refresh.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
final class UploadCoordinator: @unchecked Sendable {
    static let shared: UploadCoordinator? = {
        do { return try UploadCoordinator() } catch { return nil }
    }()

    let uploader: BackgroundPartUploader
    let engine: UploadEngine
    let outbox: Outbox
    private let api: URLSessionDengueAPI
    private let enrolment: DeviceEnrolment
    private let credentials: DeviceCredentialStore
    private let lock = NSLock()
    private var tokenState: DeviceTokenState?
    private var launched = false
    private var pendingPushToken: String?

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
        #if canImport(GRDB)
        outbox = try Outbox(dbPath: base.appendingPathComponent("outbox.sqlite").path, clock: clock)
        #else
        outbox = Outbox(store: try FileOutboxStore(directory: base.appendingPathComponent("outbox")), clock: clock)
        #endif
        uploader = try BackgroundPartUploader(baseDirectory: base)
        let sessions = try FileUploadSessionStore(directory: base.appendingPathComponent("upload-sessions"))

        let creds = DeviceCredentialStore()
        credentials = creds
        api = URLSessionDengueAPI(baseURL: baseURL, session: .shared,
                                  tokenProvider: { kind in UploadCoordinator.bearer(for: kind, credentials: creds) })
        enrolment = DeviceEnrolment(api: api, attest: AppAttestService(), clock: clock)
        engine = UploadEngine(outbox: outbox, api: api, sessions: sessions, keys: SecureEnclaveKeyStore(),
                              uploader: uploader, notifier: LocalRepeatNotifier())

        engine.onDeviceAuthFailure = { [weak self] e in self?.deviceTokenRefused(e) }
        uploader.onPartFinished = { [weak self] in
            // Background relaunch: nobody is waiting on the part; drain to consume it and start the next part.
            guard let self else { return }
            Task { await self.withBackgroundTime { await self.drain() } }
        }
    }

    // MARK: lifecycle

    /// First call per process: recreate the background session, renew/enrol the device token, recover the
    /// outbox (recoverInFlight, interrupted quarantines), drain, poll verdicts. Later calls just drain.
    func launch() async {
        let first: Bool = { lock.lock(); defer { lock.unlock() }; let f = !launched; launched = true; return f }()
        guard first else { await drain(); return }
        uploader.activate()
        await withBackgroundTime {
            await self.prepareDeviceToken()
            await self.engine.launch()
            await self.engine.refreshVerdicts()
        }
    }

    /// App became active.
    func foreground() async {
        await launch()
        await engine.refreshVerdicts()
    }

    func drain() async {
        await prepareDeviceToken()
        await engine.drain()
    }

    /// Silent APNs push; the payload carries only `scan_id`, which is not needed beyond triggering a poll.
    func handleSilentPush(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard userInfo["scan_id"] is String else { return .noData }
        await prepareDeviceToken()
        await engine.refreshVerdicts()
        return .newData
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

    /// Renews the device token when due (`DeviceEnrolment.renewIfDue`); enrols (or resumes an interrupted
    /// enrolment from the Keychain-persisted `EnrolmentProgress`) when there is no usable credential.
    private func prepareDeviceToken() async {
        if let cred = credentials.loadCredential() {
            var state: DeviceTokenState = {
                lock.lock(); defer { lock.unlock() }
                return tokenState ?? DeviceTokenState(issuedAt: cred.issuedAt, expiresIn: cred.expiresIn)
            }()
            if let r = try? await enrolment.renewIfDue(state: &state, deviceId: cred.deviceId, keyId: cred.keyId) {
                credentials.saveCredential(.init(deviceId: cred.deviceId, keyId: cred.keyId, deviceToken: r.deviceToken,
                                                 issuedAt: r.state.issuedAt, expiresIn: r.state.expiresIn))
            }
            lock.lock(); tokenState = state; lock.unlock()
            guard state.reEnrolRequired else { return }
            credentials.clearCredential()   // revoked / DS_DEVICE_001: fall through to a fresh enrolment
            lock.lock(); tokenState = nil; lock.unlock()
        }
        let managed = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") ?? [:]
        guard Self.userAccessToken() != nil, let ward = managed["ward_id"] as? String else { return }
        let resume = credentials.loadProgress()
        do {
            let c = try await enrolment.enrol(wardId: ward, resume: resume,
                                              persist: { [credentials] in credentials.saveProgress($0) })
            credentials.saveCredential(.init(deviceId: c.deviceId, keyId: c.keyId, deviceToken: c.deviceToken,
                                             issuedAt: c.state.issuedAt, expiresIn: c.state.expiresIn))
            credentials.clearProgress()
            lock.lock(); tokenState = c.state; lock.unlock()
            await sendPendingPushToken()
        } catch APIError.reEnrol {
            credentials.clearProgress()   // the attested key was refused: start over next time
        } catch {}
    }

    /// The engine kept the item; make the next `prepareDeviceToken` renew (or re-enrol).
    private func deviceTokenRefused(_ e: APIError) {
        lock.lock(); defer { lock.unlock() }
        if e == .reEnrol {
            var s = tokenState ?? DeviceTokenState(issuedAt: .distantPast, expiresIn: 0)
            s.recordFailure(.reEnrol, at: Date())
            tokenState = s
        } else {
            tokenState = DeviceTokenState(issuedAt: .distantPast, expiresIn: 0)   // due now
        }
    }

    // MARK: background time

    private func withBackgroundTime(_ work: @escaping () async -> Void) async {
        let id = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "denguesense.upload", expirationHandler: nil)
        }
        await work()
        await MainActor.run { UIApplication.shared.endBackgroundTask(id) }
    }

    // MARK: capture hand-off

    /// Called by the capture flow once a session's artefacts are sealed.
    func enqueue(sessionId: UUID, participantCode: String, createScan: CreateScanRequest?, scanId: UUID?,
                 artefacts: [ArtefactUpload]) throws {
        try engine.enqueueSession(sessionId: sessionId, participantCode: participantCode, createScan: createScan,
                                  scanId: scanId, artefacts: artefacts)
        Task { await withBackgroundTime { await self.drain() } }
    }
}
