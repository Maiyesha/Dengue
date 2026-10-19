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
/// - DS_REG_001 / DS_REG_002 (consent stop) → `.serverDirective`: the quarantine path (an intended destroy).
///   Round 2: every other DS_REG_*, DS_QG_*, DS_RPPG_*, DS_SEG_* and DS_QG_099 on createScan → `.hold`: data kept.
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
        case .stopAndQuarantine(let code):
            // Round 2 (I3): only the consent stops are a server directive (quarantine: the intended destroy
            // exception, spec 6.3/11). Any other DS_REG_* is held: data kept.
            return consentStopCodes.contains(code) ? .serverDirective : .hold(diagnostic: code)
        case .needsRepeat(let reasons):
            // A DS_QG_* / DS_RPPG_* / DS_SEG_* on createScan names no recording: never a repeat or a close here.
            return .hold(diagnostic: reasons.first?.rawValue ?? "DS_QG_UNNAMED")
        case .recaptureExhausted:
            return .hold(diagnostic: "DS_QG_099")
        }
    }

    /// The consent stops (spec 6.3/11): the only quarantine codes that may destroy local data.
    public static let consentStopCodes: Set<String> = ["DS_REG_001", "DS_REG_002"]

    /// The guard every createScan destroy path checks: true only for DS_SCAN_001, DS_VALIDATION_*, DS_NOT_FOUND
    /// and the consent stops DS_REG_001 / DS_REG_002.
    public static func permitsDestroy(_ error: APIError) -> Bool {
        switch error {
        case .duplicateRecent: return true
        case .invalid(let code): return isDestroyCode(code)
        case .stopAndQuarantine(let code): return consentStopCodes.contains(code)
        default: return false
        }
    }

    private static func isDestroyCode(_ code: String) -> Bool {
        code == "DS_NOT_FOUND" || (code.hasPrefix("DS_VALIDATION_") && code.count > "DS_VALIDATION_".count)
    }
}

/// Round 2 (I3): why the upload engine wants to destroy a session's local keys and sealed files.
public enum DestroyCause: Equatable {
    /// createScan refused for good (`CreateScanFailurePolicy.permitsDestroy`).
    case createScanRejected(APIError)
    /// DS_REG_* quarantine (only the consent stops DS_REG_001 / DS_REG_002 are permitted).
    case consentStop(code: String)
    /// Finishing a quarantine that was already decided and persisted before a relaunch.
    case quarantineResume
    /// Every artefact received_verified (or abandoned).
    case allVerified
    /// A server-requested repeat could not be offered within 2 h of capture.
    case repeatWindowExpired
    /// DS_QG_099: the server takes no more attempts for these steps.
    case recaptureExhausted
}

/// Round 2 (I3): the single rule every engine destroy path checks.
public enum DataDestructionPolicy {
    public static func permits(_ cause: DestroyCause) -> Bool {
        switch cause {
        case .createScanRejected(let e): return CreateScanFailurePolicy.permitsDestroy(e)
        case .consentStop(let code): return CreateScanFailurePolicy.consentStopCodes.contains(code)
        case .quarantineResume, .allVerified, .repeatWindowExpired, .recaptureExhausted: return true
        }
    }
}
