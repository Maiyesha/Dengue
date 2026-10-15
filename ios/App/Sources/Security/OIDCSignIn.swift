import Foundation
import UIKit
import AuthenticationServices
import LocalAuthentication
import CryptoKit
import Security
import DengueCaptureCore

public struct OIDCConfig: Equatable {
    public let issuer: URL
    public let clientId: String
    public let redirectURI: String

    /// Managed App Config (MDM) keys `oidc_issuer` and `oidc_client_id`.
    public static func fromManagedConfig(
        _ defaults: UserDefaults = .standard,
        redirectURI: String = "ai.reainmaker.denguecapture:/oauth2redirect"
    ) -> OIDCConfig? {
        guard let dict = defaults.dictionary(forKey: "com.apple.configuration.managed"),
              let iss = dict["oidc_issuer"] as? String, let url = URL(string: iss), url.scheme == "https",
              let cid = dict["oidc_client_id"] as? String, !cid.isEmpty else { return nil }
        return OIDCConfig(issuer: url, clientId: cid, redirectURI: redirectURI)
    }
}

public struct OIDCTokens: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
}

public enum OIDCError: Error { case notConfigured, cancelled, badCallback, state, tokenExchange(Int), keychain(OSStatus), cannotStart }

/// OIDC authorisation-code + PKCE (S256) via ASWebAuthenticationSession. Tokens live in the Keychain with
/// `AfterFirstUnlockThisDeviceOnly`. Idle / offline timing is decided by core `SessionPolicy`; this class
/// performs the LAContext device-owner re-authentication it asks for.
/// UNVERIFIED: compiled by ios.yml; needs a real IdP to exercise.
@MainActor
public final class OIDCSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let config: OIDCConfig
    private let session: URLSession
    private let policy: SessionPolicy
    private let keychainService = "ai.reainmaker.denguecapture.oidc"
    private var web: ASWebAuthenticationSession?

    public init(config: OIDCConfig, policy: SessionPolicy, session: URLSession = .shared) {
        self.config = config; self.policy = policy; self.session = session
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    // MARK: Sign-in

    public func signIn() async throws -> OIDCTokens {
        let disco = try await discovery()
        let verifier = Self.randomURLSafe(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(16)

        var comps = URLComponents(url: disco.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "scope", value: "openid offline_access"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let scheme = URL(string: config.redirectURI)?.scheme
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: scheme) { url, err in
                if let url { cont.resume(returning: url) }
                else if (err as? ASWebAuthenticationSessionError)?.code == .canceledLogin { cont.resume(throwing: OIDCError.cancelled) }
                else { cont.resume(throwing: err ?? OIDCError.badCallback) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = true
            web = s
            if !s.start() {   // presentation failed: the completion handler will never run
                web = nil
                cont.resume(throwing: OIDCError.cannotStart)
            }
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw OIDCError.state }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw OIDCError.badCallback }

        let tokens = try await exchange(disco.tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": config.redirectURI,
            "client_id": config.clientId, "code_verifier": verifier,
        ])
        try store(tokens)
        policy.signedIn()
        return tokens
    }

    /// Refresh with the stored refresh token; success counts as server validation of the session.
    public func refresh() async throws -> OIDCTokens {
        guard let old = try loadTokens(), let rt = old.refreshToken else { throw OIDCError.notConfigured }
        let disco = try await discovery()
        var t = try await exchange(disco.tokenEndpoint, form: [
            "grant_type": "refresh_token", "refresh_token": rt, "client_id": config.clientId])
        if t.refreshToken == nil { t.refreshToken = rt }
        try store(t)
        policy.validatedWithServer()
        return t
    }

    public func signOut() {
        SecItemDelete(baseQuery() as CFDictionary)
        policy.signedOut()
    }

    // MARK: Device-owner re-authentication

    /// Called when `SessionPolicy.evaluate()` returns `.reauthRequired`.
    public func reauthenticate() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: "Unlock DengueSense")
            if ok { policy.reauthenticated() }
            return ok
        } catch { return false }
    }

    // MARK: Plumbing

    private struct Discovery: Decodable {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint", tokenEndpoint = "token_endpoint"
        }
    }

    private func discovery() async throws -> Discovery {
        let url = config.issuer.appendingPathComponent(".well-known/openid-configuration")
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw OIDCError.tokenExchange((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return try JSONDecoder().decode(Discovery.self, from: data)
    }

    private func exchange(_ endpoint: URL, form: [String: String]) async throws -> OIDCTokens {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "+&=")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OIDCError.tokenExchange(status) }
        struct Raw: Decodable {
            let access_token: String; let refresh_token: String?; let id_token: String?
        }
        let r = try JSONDecoder().decode(Raw.self, from: data)
        return OIDCTokens(accessToken: r.access_token, refreshToken: r.refresh_token, idToken: r.id_token)
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "tokens"]
    }

    private func store(_ t: OIDCTokens) throws {
        var q = baseQuery()
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = try JSONEncoder().encode(t)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw OIDCError.keychain(s) }
    }

    public func loadTokens() throws -> OIDCTokens? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let d = out as? Data else { throw OIDCError.keychain(s) }
        return try JSONDecoder().decode(OIDCTokens.self, from: d)
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64URL(Data(b))
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
