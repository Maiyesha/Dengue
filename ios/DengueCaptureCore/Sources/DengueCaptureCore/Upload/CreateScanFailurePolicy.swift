import Foundation

/// R-1: what a failed createScan may do to the session's local data. The ONLY place that decides it.
///
/// Only an explicit DengueSense server decision may close the session and destroy its keys and sealed files:
/// - `DS_SCAN_001` (the patient was recorded in the last 30 min) → `NurseCopy.recentScan`;
/// - `DS_VALIDATION_*` and `DS_NOT_FOUND` → `NurseCopy.uploadRejected`.
///
/// Everything else keeps the data:
/// - a response without a DengueSense error envelope (captive portal, WAF/CDN, proxy, gateway: `.networkRestricted`),
///   transport failures, 5xx, 401, an unrecognised `DS_*` code and any local error → `.retry` (outbox backoff, same
///   idempotency key);
/// - a recognised contract code that is not a destroy code (e.g. DS_SCAN_002, DS_AUTH_002, DS_IDEMPOTENCY_001)
///   → `.hold(diagnostic:)`: kept and retried with backoff; the code is recorded for support;
/// - DS_REG_* (quarantine), DS_QG_* (repeat) and DS_QG_099 → `.serverDirective`: the existing regulatory and repeat
///   paths handle them.
public enum CreateScanFailurePolicy {
    public enum Decision: Equatable {
        case closeAndDestroy(notice: String)
        case retry
        case hold(diagnostic: String)
        case serverDirective
    }

    /// Codes the contract documents (contracts/openapi-v1.json). A `DS_*` code outside this set is unrecognised.
    public static let recognisedCodes: Set<String> = [
        "DS_AUD_001", "DS_AUD_002", "DS_AUTH_001", "DS_AUTH_002", "DS_AUTH_003", "DS_CLINICAL_001",
        "DS_DEVICE_001", "DS_DEVICE_002", "DS_DEVICE_003", "DS_DEVICE_004", "DS_DEVICE_005",
        "DS_IDEMPOTENCY_001", "DS_IDEMPOTENCY_002", "DS_IDEMPOTENCY_003", "DS_INTERNAL_001", "DS_NOT_FOUND",
        "DS_QG_000", "DS_QG_099", "DS_RATE_001", "DS_REG_001", "DS_REG_002", "DS_SCAN_001", "DS_SCAN_002",
        "DS_STATE_001", "DS_STATE_002", "DS_STATE_003", "DS_UPLOAD_001", "DS_UPLOAD_002", "DS_UPLOAD_003",
        "DS_UPLOAD_004", "DS_UPLOAD_005", "DS_VALIDATION_001", "DS_VALIDATION_002",
    ]

    public static func decide(error: APIError) -> Decision {
        switch error {
        case .duplicateRecent:
            return .closeAndDestroy(notice: NurseCopy.recentScan)
        case .invalid(let code):
            if isDestroyCode(code) { return .closeAndDestroy(notice: NurseCopy.uploadRejected) }
            if recognisedCodes.contains(code) { return .hold(diagnostic: code) }
            return .retry   // unrecognised DS_*, an empty code, or a local LOCAL_* / KMS_* failure
        case .uploadHashMismatch:
            return .hold(diagnostic: "DS_UPLOAD_001")
        case .reEnrol:
            return .hold(diagnostic: "DS_DEVICE_001")
        case .retryable, .uploadIncomplete, .networkRestricted, .unauthorized:
            return .retry
        case .stopAndQuarantine, .needsRepeat, .recaptureExhausted:
            return .serverDirective
        }
    }

    /// The guard every createScan destroy path checks: true only for DS_SCAN_001, DS_VALIDATION_*, DS_NOT_FOUND.
    public static func permitsDestroy(_ error: APIError) -> Bool {
        switch error {
        case .duplicateRecent: return true
        case .invalid(let code): return isDestroyCode(code)
        default: return false
        }
    }

    private static func isDestroyCode(_ code: String) -> Bool {
        code == "DS_NOT_FOUND" || (code.hasPrefix("DS_VALIDATION_") && code.count > "DS_VALIDATION_".count)
    }
}
