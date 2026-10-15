import Foundation
import DengueCaptureCore

/// I7: every API and OIDC request goes through a dedicated ephemeral session that requires TLS 1.3. Certificate
/// pinning is declarative (Info.plist `NSAppTransportSecurity` / `NSPinnedDomains` for `$(DS_API_HOST)` and
/// `$(DS_AUTH_HOST)`, SPKI SHA-256 from build settings; see ios/App/README.md). The S3 host is NOT pinned
/// (pre-signed part URLs use the background session in `BackgroundPartUploader`).
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
enum NetworkSecurity {
    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.tlsMinimumSupportedProtocolVersion = .TLSv13
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return c
    }

    /// DengueAPI (user and device tokens).
    static func apiSession() -> URLSession { URLSession(configuration: configuration()) }

    /// OIDC discovery and token endpoint.
    static func authSession() -> URLSession { URLSession(configuration: configuration()) }
}

/// C2: the offline roster snapshot (participant codes, consent flags): one JSON file, Data Protection Class C
/// (readable after first unlock), excluded from backup, written atomically. Deleted on sign-out.
final class FileConsentCacheStorage: ConsentCacheStorage {
    private let url: URL
    init(url: URL) { self.url = url }

    func load() -> Data? { try? Data(contentsOf: url) }

    func save(_ data: Data) {
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}
