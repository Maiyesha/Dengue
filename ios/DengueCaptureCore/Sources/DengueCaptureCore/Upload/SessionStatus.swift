import Foundation

/// Retention and repeat-window rules (spec section 12; final review I2/I3).
public enum RetentionPolicy {
    /// A server-requested repeat is offered only within this time of `captured_at`.
    public static let repeatWindow: TimeInterval = 2 * 3600
    /// Sessions or held records not fully sent this long after capture are flagged in the outbox.
    public static let unsentWarningAge: TimeInterval = 7 * 86400

    /// Unknown capture time: offered (the server still enforces its own attempt limits).
    public static func repeatOffered(capturedAt: Date?, now: Date) -> Bool {
        guard let c = capturedAt else { return true }
        return now.timeIntervalSince(c) <= repeatWindow
    }

    public static func isUnsentTooLong(capturedAt: Date?, now: Date) -> Bool {
        guard let c = capturedAt else { return false }
        return now.timeIntervalSince(c) > unsentWarningAge
    }
}

/// Per-session read model for the Saved and Uploads screens (I2).
public enum SessionStatus: Equatable {
    /// Nothing has reached the server yet.
    case queued
    case uploading
    /// Every artefact received_verified (waiting for, or past, the server verdict).
    case sent
    /// The server asked for these steps again (within the 2 h window).
    case needsRepeat(steps: [CaptureStepName], reasons: [ReasonCode])
    /// Terminal: nothing more will be sent or asked. `notice` is nurse copy (may be nil).
    case closed(notice: String?)

    /// Nurse-facing status line.
    public func text(maskedCode: String) -> String {
        switch self {
        case .queued: return NurseCopy.statusQueued
        case .uploading: return NurseCopy.statusUploading
        case .sent: return NurseCopy.statusSent
        case .needsRepeat(_, let reasons):
            return NurseCopy.repeatNotice(maskedStudyID: maskedCode,
                                          reason: reasons.first?.nurseInstruction ?? NurseCopy.reasonOtherQuality)
        case .closed(let notice): return notice ?? NurseCopy.statusClosed
        }
    }
}

public struct SessionSummary: Equatable {
    public var sessionId: UUID
    /// "••417" only.
    public var maskedCode: String
    public var capturedAt: Date?
    public var status: SessionStatus
    /// Queued or uploading more than 7 days after capture (outbox warning, `NurseCopy.unsentWarning`).
    public var unsentTooLong: Bool
}

extension HeldHandoffSummary {
    /// Held records are by definition not sent: flagged 7 days after capture.
    public func unsentTooLong(now: Date) -> Bool { RetentionPolicy.isUnsentTooLong(capturedAt: capturedAt, now: now) }
}
