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

    public static func from(code: String, httpStatus: Int, reasonCodes: [ReasonCode] = []) -> APIError {
        if code.hasPrefix("DS_REG_") { return .stopAndQuarantine(code: code) }
        if code.hasPrefix("DS_QG_") || code.hasPrefix("DS_RPPG_") || code.hasPrefix("DS_SEG_") {
            if !reasonCodes.isEmpty { return .needsRepeat(reasonCodes) }
            if let rc = ReasonCode(rawValue: code) { return .needsRepeat([rc]) }
            return .needsRepeat([])
        }
        switch code {
        case "DS_SCAN_001": return .duplicateRecent
        case "DS_UPLOAD_001": return .uploadHashMismatch
        case "DS_UPLOAD_005", "DS_RATE_001", "DS_AUD_001": return .retryable
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
