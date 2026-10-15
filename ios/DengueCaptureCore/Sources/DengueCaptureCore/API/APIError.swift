import Foundation

/// Client-side classification of server errors. Dispatch is on the error envelope `error.code`.
public enum APIError: Error, Equatable {
    case stopAndQuarantine(code: String)
    case needsRepeat([ReasonCode])
    case duplicateRecent
    case unauthorized
    case reEnrol
    case retryable
    case invalid(code: String)
    case uploadHashMismatch
    /// DS_UPLOAD_005 (409, retryable): the server has fewer bytes than declared. Upload the missing parts,
    /// then complete again with the same idempotency key. Outbox treats it exactly like `.retryable`.
    case uploadIncomplete
    /// DS_QG_099: max recaptures reached; the server committed (steps marked UNABLE_TO_ACQUIRE). Refetch the scan.
    case recaptureExhausted(unableToAcquire: [String], recaptured: [String], status: String)
    /// R-1: an HTTP response that is not from the DengueSense API: no parseable error envelope (captive-portal
    /// login page, WAF/CDN 403, proxy 413, gateway 429, a 2xx HTML page) or a redirect away from the API host.
    /// Never a server decision about the data: retried with backoff and the same idempotency key.
    case networkRestricted(httpStatus: Int)

    /// True for `.networkRestricted` (the phone's network needs sign-in or is filtering requests).
    public var isNetworkRestricted: Bool {
        if case .networkRestricted = self { return true }
        return false
    }

    public static func from(code: String, httpStatus: Int, reasonCodes: [ReasonCode] = [],
                             detail: [String: JSONValue]? = nil) -> APIError {
        if code == "DS_QG_099" {
            func strings(_ k: String) -> [String] {
                guard case .array(let a)? = detail?[k] else { return [] }
                return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            }
            var status = ""
            if case .string(let st)? = detail?["status"] { status = st }
            return .recaptureExhausted(unableToAcquire: strings("unable_to_acquire"),
                                       recaptured: strings("recaptured"), status: status)
        }
        if code.hasPrefix("DS_REG_") { return .stopAndQuarantine(code: code) }
        if code.hasPrefix("DS_QG_") || code.hasPrefix("DS_RPPG_") || code.hasPrefix("DS_SEG_") {
            if !reasonCodes.isEmpty { return .needsRepeat(reasonCodes) }
            if let rc = ReasonCode(rawValue: code) { return .needsRepeat([rc]) }
            return .needsRepeat([])
        }
        switch code {
        case "DS_SCAN_001": return .duplicateRecent
        case "DS_UPLOAD_001": return .uploadHashMismatch
        case "DS_UPLOAD_005": return .uploadIncomplete
        case "DS_RATE_001", "DS_AUD_001", "DS_IDEMPOTENCY_003": return .retryable
        case "DS_DEVICE_001": return .reEnrol
        case "DS_DEVICE_002", "DS_DEVICE_003", "DS_DEVICE_004", "DS_DEVICE_005", "DS_AUTH_003":
            return .unauthorized
        case "DS_SCAN_002", "DS_NOT_FOUND": return .invalid(code: code)
        default: break
        }
        if code.hasPrefix("DS_VALIDATION_") { return .invalid(code: code) }
        if (500...599).contains(httpStatus) { return .retryable }
        if httpStatus == 401 { return .unauthorized }
        return .invalid(code: code)
    }
}
