/// Quality-gate and registry reason codes (wire values from doc 04 section 3.3).
public enum ReasonCode: String, Codable, CaseIterable, Equatable {
    case dsQG001 = "DS_QG_001"
    case dsQG002 = "DS_QG_002"
    case dsQG003 = "DS_QG_003"
    case dsQG004 = "DS_QG_004"
    case dsQG005 = "DS_QG_005"
    case dsQG099 = "DS_QG_099"
    case dsRPPG001 = "DS_RPPG_001"
    case dsRPPG002 = "DS_RPPG_002"
    case dsSEG001 = "DS_SEG_001"
    case dsREG001 = "DS_REG_001"
    case dsREG002 = "DS_REG_002"

    /// One-line instruction shown to the nurse (spec sections 8 and 11).
    public var nurseInstruction: String {
        switch self {
        case .dsQG001: return NurseCopy.reasonMotion
        case .dsQG002: return NurseCopy.reasonLighting
        case .dsQG003: return NurseCopy.reasonFaceLost
        case .dsQG004: return NurseCopy.reasonFrames
        case .dsQG005: return NurseCopy.reasonFingerCoverage
        case .dsQG099: return NurseCopy.reasonOtherQuality
        case .dsRPPG001, .dsRPPG002: return NurseCopy.reasonPulseSignal
        case .dsSEG001: return NurseCopy.reasonSegmentation
        case .dsREG001: return NurseCopy.reasonConsentInvalid
        case .dsREG002: return NurseCopy.reasonRegulatoryHold
        }
    }
}
