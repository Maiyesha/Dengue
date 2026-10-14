import Foundation

/// Every user-facing nurse string. Add new constants here AND to `allStrings`
/// (a test scans this source file so none can be missed).
public enum NurseCopy {
    // Spec-mandated
    public static let banner = "Research Use Only — not for diagnosis or treatment decisions. Continue standard care and blood tests."
    public static let consentBlocked = "No valid study consent on record. Do not record. Contact the study coordinator."
    public static let assentPrompt = "Patient (or guardian) has been told a short research video will be recorded now and agrees."
    public static let saved = "Recording saved for research"
    public static let acquisitionFailure = "Could not get a usable recording today. This is common and not a problem for the patient. Reason saved."
    public static let experimentalNotice = "Not validated — do not use for care decisions. Use the monitor value."

    // Pre-capture checklist (spec 6.4)
    public static let checklistResting = "Patient is resting and calm, not mid-vomiting or in rigors. If not, come back later."
    public static let checklistGlasses = "Remove glasses if the patient is comfortable; hair off the forehead; mask down only if clinically appropriate."
    public static let checklistLight = "Overhead light on; no strong window light behind the patient."
    public static let checklistHolder = "Phone holder or clamp fitted (recommended)."
    public static let checklistColourCard = "Colour reference card ready (needed for the eye and tongue steps only)."

    // Guidance cues (spec 7.1)
    public static let cueMoveCloser = "Move closer"
    public static let cueMoveBack = "Move back"
    public static let cueCentreFace = "Keep the whole face in the oval"
    public static let cueTiltPhone = "Tilt the phone to match the patient's face"
    public static let cueTooDark = "Too dark — turn on overhead light"
    public static let cueLightBehind = "Bright light behind — move the phone or close the curtain"
    public static let cueHoldStill = "Hold still"
    public static let cueReady = "Ready — recording can start"

    // Reason-code instructions (spec 8 and 11)
    public static let reasonMotion = "Use the holder; ask the patient to rest still"
    public static let reasonLighting = "Turn on overhead light / avoid light behind patient"
    public static let reasonFaceLost = "Keep the whole face in the oval"
    public static let reasonFrames = "Close other apps and try again"
    public static let reasonFingerCoverage = "Cover the camera and light fully with the fingertip, then press gently"
    public static let reasonOtherQuality = "Please record this step again"
    public static let reasonPulseSignal = "Keep still for the full time; check lighting"
    public static let reasonSegmentation = "Ask patient to look up; show the colour card"
    public static let reasonConsentInvalid = "Stop. Study consent is not valid. Contact the study coordinator."
    public static let reasonRegulatoryHold = "Stop. Recordings for this patient are on hold. Notify the coordinator."

    // Quality screen (spec 8)
    public static let statusGood = "Good recording"
    public static let statusRecordAgainFormat = "Please record step %d again"
    public static let statusCouldNotRecord = "Could not record — reason saved"
    public static let stepPassed = "Passed"
    public static let stepRecordAgain = "Record again"

    // Errors and states (spec 11)
    public static let thermalWarning = "Phone is warm — wait a minute"
    public static let cameraDenied = "The camera is needed to record. Open Settings to allow camera access."
    public static let lowStorage = "Storage is low. Let uploads finish to free space before recording."
    public static let lowBattery = "Battery is too low to record. Please charge the phone."
    public static let interrupted = "Recording was interrupted. This step will be repeated."
    public static let offlineQueued = "Will upload when connected"
    public static let recentScan = "This patient was recorded in the last 30 min"
    public static let repeatNoticeFormat = "Recording for study ID %@ needs repeating (%@)."

    // Reference / experimental display
    public static let monitorFormat = "Monitor pulse: %d bpm"
    public static let experimentalChip = "EXPERIMENTAL"
    public static let cameraPulseFaceFormat = "Camera pulse (face): %d bpm"
    public static let cameraPulseFingertipFormat = "Camera pulse (fingertip): %d bpm"

    public static let allCues: [GuidanceCue] = [
        .moveCloser, .moveBack, .centreFace, .tiltPhone, .tooDark, .lightBehind, .holdStill, .ready,
    ]

    public static func text(for cue: GuidanceCue) -> String {
        switch cue {
        case .moveCloser: return cueMoveCloser
        case .moveBack: return cueMoveBack
        case .centreFace: return cueCentreFace
        case .tiltPhone: return cueTiltPhone
        case .tooDark: return cueTooDark
        case .lightBehind: return cueLightBehind
        case .holdStill: return cueHoldStill
        case .ready: return cueReady
        }
    }

    public static func recordStepAgain(_ n: Int) -> String {
        String(format: statusRecordAgainFormat, n)
    }

    /// The two strings exempt from the forbidden-word lint.
    public static let allowlisted: [String] = [banner, experimentalNotice]

    public static var allStrings: [String] {
        let constants: [String] = [
            banner, consentBlocked, assentPrompt, saved, acquisitionFailure, experimentalNotice,
            checklistResting, checklistGlasses, checklistLight, checklistHolder, checklistColourCard,
            cueMoveCloser, cueMoveBack, cueCentreFace, cueTiltPhone, cueTooDark, cueLightBehind,
            cueHoldStill, cueReady,
            reasonMotion, reasonLighting, reasonFaceLost, reasonFrames, reasonFingerCoverage,
            reasonOtherQuality, reasonPulseSignal, reasonSegmentation, reasonConsentInvalid,
            reasonRegulatoryHold,
            statusGood, statusRecordAgainFormat, statusCouldNotRecord, stepPassed, stepRecordAgain,
            thermalWarning, cameraDenied, lowStorage, lowBattery, interrupted, offlineQueued,
            recentScan, repeatNoticeFormat,
            monitorFormat, experimentalChip, cameraPulseFaceFormat, cameraPulseFingertipFormat,
        ]
        var all = constants
        for cue in allCues { all.append(text(for: cue)) }
        for code in ReasonCode.allCases { all.append(code.nurseInstruction) }
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    // MARK: Forbidden-word lint (spec 4)

    public static let forbiddenWords: [String] = [
        "diagnose", "diagnosis", "positive", "negative", "severity", "safe", "normal",
        "abnormal", "risk", "result",
    ]
    public static let forbiddenPhrases: [String] = ["detect dengue"]

    /// Forbidden terms present in `s` (whole word, case-insensitive; phrases matched on word sequence).
    public static func forbiddenTerms(in s: String) -> [String] {
        let words = s.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        var found: [String] = []
        for w in forbiddenWords where words.contains(w) { found.append(w) }
        let joined = " " + words.joined(separator: " ") + " "
        for p in forbiddenPhrases where joined.contains(" " + p + " ") { found.append(p) }
        return found
    }
}
