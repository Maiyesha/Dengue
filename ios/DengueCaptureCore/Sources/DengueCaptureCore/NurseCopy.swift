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
    public static let reasonOtherQuality = "Please record this step again"
    public static let reasonPulseSignal = "Keep still for the full time; check lighting"
    public static let reasonSegmentation = "Ask patient to look up; show the colour card"
    public static let consentRenewal = "Study consent needs renewing before recording. Contact the study coordinator."
    public static let regulatoryHold = "Recordings for this patient are on hold. Contact the study coordinator."

    // Additional nurse strings (spec 6.3, 6.4, 7.1-7.4, 11)
    public static let holdStillPatient = "Ask the patient to rest still and not talk"
    public static let fingertipGuidance = "Cover the camera and light completely with the fingertip. Rest the hand on the bed. Don't press hard."
    public static let cameraNotReady = "Camera not ready — try again"
    public static let showColourCard = "Show the colour card next to the eye/tongue"
    public static let comeBackLater = "Come back later"
    public static let patientDeclined = "Patient declined today"
    public static let disinfectReminder = "Wipe the phone with the ward's approved disinfectant before the next patient."
    public static let phoneWarm = "Phone is warm — wait a minute"

    // Quality screen (spec 8)
    public static let statusGood = "Good recording"
    public static let recordAgainLead = "Please record step"
    public static let recordAgainTail = "again"
    public static let statusCouldNotRecord = "Could not record — reason saved"
    public static let stepPassed = "Passed"
    public static let stepRecordAgain = "Record again"

    // Errors and states (spec 11)
    public static let cameraDenied = "The camera is needed to record. Open Settings to allow camera access."
    public static let lowStorage = "Storage is low. Let uploads finish to free space before recording."
    public static let lowBattery = "Battery is too low to record. Please charge the phone."
    public static let lowBatteryWarning = "Battery is low. Charge the phone after this patient."
    public static let interrupted = "Recording was interrupted. This step will be repeated."
    public static let offlineQueued = "Will upload when connected"
    public static let recentScan = "This patient was recorded in the last 30 min"
    public static let repeatNoticeLead = "Recording for study ID"
    public static let repeatNoticeTail = "needs repeating"
    public static let repeatNotificationLead = "A recording for"
    /// I3: a session the server refused permanently (validation / unknown patient); its data was removed.
    public static let uploadRejected = "This recording could not be sent and has been removed from the phone."
    /// I3 / spec 12: not fully sent 7 days after capture.
    public static let unsentWarning = "Not sent for 7 days. Connect the phone to the ward network or tell the study coordinator."
    // I2: per-session upload status (Saved / Uploads screens)
    public static let statusQueued = "Waiting to send"
    public static let statusUploading = "Sending"
    public static let statusSent = "Sent"
    public static let statusClosed = "Finished"
    public static let buttonRecordAgain = "Record again"

    // Reference / experimental display
    public static let monitorPrefix = "Monitor pulse"
    public static let experimentalChip = "EXPERIMENTAL"
    public static let cameraPulseFacePrefix = "Camera pulse (face)"
    public static let cameraPulseFingertipPrefix = "Camera pulse (fingertip)"
    public static let bpmUnit = "bpm"

    // UI labels (flow screens)
    public static let skipMonitorUnavailable = "Monitor unavailable"
    public static let skipPatientNotOnMonitor = "Patient not on a monitor"
    public static let labelStudyID = "Study ID"
    public static let labelBed = "Bed"
    public static let buttonLookUp = "Look up"
    public static let buttonContinue = "Continue"
    public static let buttonAgree = "Patient agrees"
    public static let buttonDecline = "Patient declined today"
    public static let buttonStart = "Start"
    public static let buttonPause = "Pause"
    public static let buttonSkip = "Skip"
    public static let buttonDone = "Done"
    public static let buttonNextPatient = "Next patient"
    public static let titleOutbox = "Uploads"
    public static let labelSkipReason = "Reason for skipping"
    public static let labelHeartRate = "Monitor heart rate"
    public static let labelSpO2 = "SpO2"
    public static let labelRespRate = "Breathing rate"
    public static let labelTemperature = "Temperature"
    public static let labelCapRefill = "Capillary refill"
    public static let labelSystolic = "Systolic BP"
    public static let labelDiastolic = "Diastolic BP"
    public static let stepNameFace = "Neutral face"
    public static let stepNameFingertip = "Fingertip"
    public static let stepNameEye = "Eye"
    public static let stepNameTongue = "Tongue"
    public static let outboxEmpty = "Nothing waiting to upload"
    /// Outbox row for a held hand-off (kept on the phone until it can be queued for upload).
    public static let heldWaiting = "Saved on this phone. Waiting to send."
    public static let heldUnreadable = "Saved recording cannot be opened on this phone."
    public static let buttonDeleteRecording = "Delete this recording"
    public static let confirmDeleteRecording = "Delete this recording from the phone? It cannot be recovered."
    public static let noteMonitorHR = "Note the monitor heart rate now"
    public static let sourceBedsideMonitor = "Bedside monitor"
    public static let sourcePulseOximeter = "Pulse oximeter"
    public static let sourceThermometer = "Thermometer"
    public static let sourceManualSphygmomanometer = "Manual sphygmomanometer"
    public static let sourceOther = "Other device"
    public static let labelSource = "Measured with"
    public static let labelMeasuredAt = "Time measured"
    public static let vitalUnparseable = "Value not understood — correct it"
    public static let vitalOutOfRange = "Value is out of the expected range — confirm or correct"
    public static let vitalConfirm = "Value is correct"
    public static let buttonOutbox = "Uploads"
    public static let buttonOK = "OK"

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
        "\(recordAgainLead) \(n) \(recordAgainTail)"
    }

    public static func monitorLine(_ bpm: Int) -> String { "\(monitorPrefix): \(bpm) \(bpmUnit)" }

    public static func cameraPulseLine(fingertip: Bool, bpm: Int) -> String {
        "\(fingertip ? cameraPulseFingertipPrefix : cameraPulseFacePrefix): \(bpm) \(bpmUnit)"
    }

    /// e.g. "Recording for study ID ••417 needs repeating (lighting)."
    public static func repeatNotice(maskedStudyID: String, reason: String) -> String {
        "\(repeatNoticeLead) \(maskedStudyID) \(repeatNoticeTail) (\(reason))."
    }

    /// "••" + the last 3 characters of the participant code. Nothing else of the code is ever shown.
    public static func maskedStudyID(_ participantCode: String) -> String {
        "\u{2022}\u{2022}" + String(participantCode.suffix(3))
    }

    /// Local notification text, e.g. "A recording for ••417 needs repeating". No other identifier.
    public static func repeatNotification(maskedStudyID: String) -> String {
        "\(repeatNotificationLead) \(maskedStudyID) \(repeatNoticeTail)"
    }

    /// The two strings exempt from the forbidden-word lint.
    public static let allowlisted: [String] = [banner, experimentalNotice]

    public static var allStrings: [String] {
        let constants: [String] = [
            banner, consentBlocked, assentPrompt, saved, acquisitionFailure, experimentalNotice,
            checklistResting, checklistGlasses, checklistLight, checklistHolder, checklistColourCard,
            cueMoveCloser, cueMoveBack, cueCentreFace, cueTiltPhone, cueTooDark, cueLightBehind,
            cueHoldStill, cueReady,
            reasonMotion, reasonLighting, reasonFaceLost, reasonFrames,
            reasonOtherQuality, reasonPulseSignal, reasonSegmentation, consentRenewal,
            regulatoryHold,
            holdStillPatient, fingertipGuidance, cameraNotReady, showColourCard, comeBackLater,
            patientDeclined, disinfectReminder, phoneWarm,
            statusGood, recordAgainLead, recordAgainTail, statusCouldNotRecord, stepPassed, stepRecordAgain,
            cameraDenied, lowStorage, lowBattery, lowBatteryWarning, interrupted, offlineQueued,
            recentScan, repeatNoticeLead, repeatNoticeTail, repeatNotificationLead,
            uploadRejected, unsentWarning, statusQueued, statusUploading, statusSent, statusClosed, buttonRecordAgain,
            monitorPrefix, experimentalChip, cameraPulseFacePrefix, cameraPulseFingertipPrefix, bpmUnit,
            skipMonitorUnavailable, skipPatientNotOnMonitor, labelStudyID, labelBed, buttonLookUp,
            buttonContinue, buttonAgree, buttonDecline, buttonStart, buttonPause, buttonSkip, buttonDone,
            buttonNextPatient, titleOutbox, labelSkipReason, labelHeartRate, labelSpO2, labelRespRate,
            labelTemperature, labelCapRefill, labelSystolic, labelDiastolic, stepNameFace,
            stepNameFingertip, stepNameEye, stepNameTongue, outboxEmpty, heldWaiting, heldUnreadable, buttonDeleteRecording,
            confirmDeleteRecording,
            noteMonitorHR, sourceBedsideMonitor, sourcePulseOximeter, sourceThermometer,
            sourceManualSphygmomanometer, sourceOther, labelSource, labelMeasuredAt, vitalUnparseable,
            vitalOutOfRange, vitalConfirm, buttonOutbox, buttonOK,
        ]
        var all = constants
        for cue in allCues { all.append(text(for: cue)) }
        for code in ReasonCode.allCases { all.append(code.nurseInstruction) }
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    // MARK: Forbidden-word lint (spec 4)
    //
    // Rule: text is split into lowercase letter-only words. A word is forbidden when
    //  - it starts with "diagnos" (diagnose, diagnosed, diagnoses, diagnosis, diagnostic), or
    //  - it equals a listed stem plus an optional inflection suffix (s, es, ed, d, ing, ly,
    //    ies), e.g. results, risks, positives, safely, abnormal.
    // Stems match only a whole word plus those suffixes, never as a substring or arbitrary
    // prefix: "unsafe", "safety", "riskless", "normalise" are NOT flagged.
    // The phrase "detect dengue" also matches detects/detected/detecting dengue.

    public static let forbiddenStems: [String] = [
        "result", "risk", "positive", "negative", "severity", "severe", "normal", "abnormal", "safe",
    ]
    public static let forbiddenPrefixes: [String] = ["diagnos"]
    private static let inflections: [String] = ["", "s", "es", "ed", "d", "ing", "ly", "ies"]
    private static let detectForms: Set<String> = ["detect", "detects", "detected", "detecting"]

    /// Forbidden terms present in `s` (case-insensitive): the offending words, plus
    /// "detect dengue" for the phrase.
    public static func forbiddenTerms(in s: String) -> [String] {
        let words = s.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        var found: [String] = []
        for w in words {
            let hit = forbiddenPrefixes.contains { w.hasPrefix($0) }
                || forbiddenStems.contains { stem in inflections.contains { w == stem + $0 } }
            if hit, !found.contains(w) { found.append(w) }
        }
        for (a, b) in zip(words, words.dropFirst()) where detectForms.contains(a) && b == "dengue" {
            if !found.contains("detect dengue") { found.append("detect dengue") }
        }
        return found
    }
}
