import Foundation
import SwiftUI
import DengueCaptureCore

/// C2: the nurse session at the app root. Decisions come from core `SessionGate` / `SessionPolicy`:
/// - no tokens, or 12 h without server validation -> SignInView (expiry signs out and deletes the tokens);
/// - 10 min idle -> lock overlay; LAContext device-owner re-authentication unlocks;
/// - a refused user token (`onUserAuthFailure`, consent lookup 401) -> sign out, SignInView.
/// After a relaunch the stored tokens are trusted again only after a successful refresh (server validation).
/// UI tests (UITEST_FAKE_CAMERA=1) bypass sign-in.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var gate: SessionGateState = .signInRequired(clearTokens: false)
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    let policy = SessionPolicy(clock: SystemClock())
    private var oidc: OIDCSignIn?
    private var oidcConfig: OIDCConfig?
    private var timer: Timer?
    private var authObserver: NSObjectProtocol?
    private let uiTest = ProcessInfo.processInfo.environment["UITEST_FAKE_CAMERA"] == "1"

    var isConfigured: Bool { uiTest || currentOIDC() != nil }

    /// The OIDC client for the current Managed App Config (rebuilt when MDM changes it).
    private func currentOIDC() -> OIDCSignIn? {
        let cfg = OIDCConfig.fromManagedConfig()
        if cfg != oidcConfig {
            oidcConfig = cfg
            oidc = cfg.map { OIDCSignIn(config: $0, policy: policy, session: NetworkSecurity.authSession()) }
        }
        return oidc
    }

    func start() async {
        if authObserver == nil {
            authObserver = NotificationCenter.default.addObserver(forName: .dsUserAuthFailed, object: nil,
                                                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userAuthFailed() }
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        guard !uiTest else { gate = .open; return }
        if let o = currentOIDC(), policy.evaluate() == .expired, (try? o.loadTokens()) != nil {
            busy = true
            if (try? await o.refresh()) != nil { policy.signedIn() }   // server-validated: session restored
            busy = false
        }
        evaluate()
    }

    func evaluate() {
        guard !uiTest else { gate = .open; return }
        let o = currentOIDC()
        let hasTokens = ((try? o?.loadTokens()) ?? nil) != nil
        let g = SessionGate.evaluate(hasTokens: hasTokens, policy: policy)
        if case .signInRequired(true) = g { o?.signOut() }   // 12 h / unvalidated: delete the tokens
        if g != gate { gate = g }
    }

    /// Any user interaction (root gesture): resets the 10 min idle timer while unlocked.
    func activity() { policy.recordActivity() }

    func signIn() async {
        guard let o = currentOIDC() else { message = NurseCopy.signInNotConfigured; return }
        busy = true
        defer { busy = false }
        do {
            _ = try await o.signIn()
            message = nil
            evaluate()
            UploadCoordinator.shared?.signedIn()   // enrol on first sign-in (or renew), drain, refresh roster
        } catch {
            message = NurseCopy.signInFailed
        }
    }

    func unlock() async {
        guard let o = currentOIDC() else { return }
        _ = await o.reauthenticate()
        evaluate()
    }

    func userAuthFailed() {
        guard !uiTest else { return }
        currentOIDC()?.signOut()
        evaluate()
    }
}
