import Foundation

public enum FlowScreen: Equatable, CaseIterable {
    case patientSelect, consent, assent, patientDeclined, comeBackLater, checklist
    case referenceVitals, capture, blocked, qualityResult, saved

    /// Spec section 10: every screen carries the RUO banner.
    public var showsBanner: Bool { true }
}

public enum FlowChecklistItem: CaseIterable, Equatable {
    case resting, glasses, light, holder, colourCard

    public var text: String {
        switch self {
        case .resting: return NurseCopy.checklistResting
        case .glasses: return NurseCopy.checklistGlasses
        case .light: return NurseCopy.checklistLight
        case .holder: return NurseCopy.checklistHolder
        case .colourCard: return NurseCopy.checklistColourCard
        }
    }
}

public enum VitalsSkipReason: CaseIterable, Equatable {
    case monitorUnavailable, patientNotOnMonitor

    public var text: String {
        switch self {
        case .monitorUnavailable: return NurseCopy.skipMonitorUnavailable
        case .patientNotOnMonitor: return NurseCopy.skipPatientNotOnMonitor
        }
    }
}

public enum ThermalLevel: Equatable { case nominal, fair, serious, critical }

public enum VitalField: String, Codable, CaseIterable, Hashable {
    case hr, spo2, sbp, dbp, tempC, rr, crtS

    /// Spec 6.5 plausibility ranges. Values outside are flagged and need confirmation.
    public var range: ClosedRange<Double> {
        switch self {
        case .hr: return 30...220
        case .spo2: return 50...100
        case .sbp: return 40...250
        case .dbp: return 20...150
        case .tempC: return 32...42
        case .rr: return 4...60
        case .crtS: return 0...10
        }
    }

    public var label: String {
        switch self {
        case .hr: return NurseCopy.labelHeartRate
        case .spo2: return NurseCopy.labelSpO2
        case .sbp: return NurseCopy.labelSystolic
        case .dbp: return NurseCopy.labelDiastolic
        case .tempC: return NurseCopy.labelTemperature
        case .rr: return NurseCopy.labelRespRate
        case .crtS: return NurseCopy.labelCapRefill
        }
    }
}

public enum VitalSourceDevice: String, Codable, CaseIterable, Equatable {
    case bedsideMonitor = "bedside_monitor"
    case pulseOximeter = "pulse_oximeter"
    case thermometer
    case manualSphygmomanometer = "manual_sphygmomanometer"
    case other

    public var text: String {
        switch self {
        case .bedsideMonitor: return NurseCopy.sourceBedsideMonitor
        case .pulseOximeter: return NurseCopy.sourcePulseOximeter
        case .thermometer: return NurseCopy.sourceThermometer
        case .manualSphygmomanometer: return NurseCopy.sourceManualSphygmomanometer
        case .other: return NurseCopy.sourceOther
        }
    }
}

public enum VitalIssue: Equatable {
    case unparseable      // must be corrected
    case outOfRange       // may be confirmed, then kept and flagged INVALID

    public var text: String {
        switch self {
        case .unparseable: return NurseCopy.vitalUnparseable
        case .outOfRange: return NurseCopy.vitalOutOfRange
        }
    }
}

public struct VitalEntry: Equatable {
    public var text: String
    public var source: VitalSourceDevice
    /// nil means "now" at submission time.
    public var measuredAt: Date?
    /// The nurse confirmed an out-of-range value is what the device showed.
    public var confirmed: Bool

    public init(text: String, source: VitalSourceDevice = .bedsideMonitor,
                measuredAt: Date? = nil, confirmed: Bool = false) {
        self.text = text; self.source = source; self.measuredAt = measuredAt; self.confirmed = confirmed
    }
}

public struct VitalRecord: Codable, Equatable {
    public var field: VitalField
    public var value: Double
    public var source: VitalSourceDevice
    public var measuredAt: Date
    /// Confirmed out-of-range value: kept, flagged INVALID, never dropped.
    public var isInvalid: Bool
}

public enum StepStatus: Equatable {
    case passed, recordAgain, couldNotRecord

    public var text: String {
        switch self {
        case .passed: return NurseCopy.stepPassed
        case .recordAgain: return NurseCopy.stepRecordAgain
        case .couldNotRecord: return NurseCopy.statusCouldNotRecord
        }
    }
}

public extension CaptureStep {
    var nurseName: String {
        switch self {
        case .neutralFace: return NurseCopy.stepNameFace
        case .fingertipPPG: return NurseCopy.stepNameFingertip
        case .ocularCapture: return NurseCopy.stepNameEye
        case .dorsalTongue: return NurseCopy.stepNameTongue
        }
    }
}
/// Pure screen-order and gating logic for spec section 6. UI-framework free; the app wraps it in an
/// ObservableObject. Inputs that are invalid for the current screen are ignored.
public final class CaptureFlow {
    public static let bannerText = NurseCopy.banner
    public static let maxSnapshotAge: TimeInterval = 24 * 3600

    public private(set) var screen: FlowScreen = .patientSelect
    public private(set) var participantCode: String?
    public private(set) var bedLabel: String?
    public private(set) var monitorHR: Int?
    public private(set) var vitalsSkipReason: VitalsSkipReason?
    public private(set) var checklist: Set<FlowChecklistItem> = []
    public private(set) var thermalHold = false
    public private(set) var vitalRecords: [VitalRecord] = []
    public private(set) var vitalIssues: [VitalField: VitalIssue] = [:]
    /// One-shot nurse prompt (spec 6.5), e.g. note the monitor HR at 20 s of the face step.
    public private(set) var pendingPrompt: String?
    private var monitorPromptFired = false
    /// Text each flagged field had when it was flagged; a confirmation only counts for that exact text.
    private var flaggedText: [VitalField: String] = [:]
    public static let monitorPromptSeconds: Double = 20
    public static let maxSnapshotFutureSkew: TimeInterval = 300

    // I1 positioning sub-state (face step): recording may start only after Guidance returned exactly
    // `[.ready]` continuously for `positioningHoldSeconds`.
    public static let positioningHoldSeconds: Double = 2
    /// Latest guidance cues while positioning a face step (nil otherwise); the UI shows them.
    public private(set) var positioningCues: [GuidanceCue]?
    /// Monotonic time (seconds) of the latest guidance update, if any.
    public private(set) var lastGuidanceTime: Double?
    private var readySince: Double?

    private var consentMessage: String?
    private var assentGiven = false
    private var showedSaved = false
    private var preflight: Preflight
    private let captureProtocol: CaptureProtocol
    private var machine: CaptureSessionMachine?

    public init(protocol captureProtocol: CaptureProtocol = .phaseADefault, preflight: Preflight) {
        self.captureProtocol = captureProtocol
        self.preflight = preflight
    }

    public func updatePreflight(_ p: Preflight) { preflight = p }

    // MARK: Derived state

    public var machineState: SessionState? { machine?.state }

    public var currentStep: CaptureStep? {
        guard screen == .capture, let state = machine?.state else { return nil }
        switch state {
        case .positioning(let s), .recording(let s, _), .reviewingStep(let s, _): return s
        case .completed, .blocked: return nil
        }
    }

    public var steps: [StepConfig] { captureProtocol.steps }

    /// Spec 8 overall status: good / record step N again / could not record.
    public var statusMessage: String? {
        guard let state = machine?.state else { return nil }
        switch state {
        case .completed(.accepted): return NurseCopy.statusGood
        case .completed: return NurseCopy.statusCouldNotRecord
        case .positioning(let s):
            guard !stepReasons(s).isEmpty,
                  let i = captureProtocol.steps.firstIndex(where: { $0.step == s }) else { return nil }
            return NurseCopy.recordStepAgain(i + 1)
        default: return nil
        }
    }

    /// Reason shown when a step is being repeated (attempt > 1).
    public var retryInstruction: String? {
        guard screen == .capture, case .positioning(let s)? = machine?.state else { return nil }
        return stepReasons(s).first?.nurseInstruction
    }

    /// A step with reasons that we have moved past (or finished) ended UNABLE_TO_ACQUIRE.
    public func stepStatus(_ step: CaptureStep) -> StepStatus {
        guard !stepReasons(step).isEmpty else { return .passed }
        switch machine?.state {
        case .positioning(let s)?, .recording(let s, _)?, .reviewingStep(let s, _)?:
            return s == step ? .recordAgain : .couldNotRecord
        default: return .couldNotRecord
        }
    }

    /// Changes whenever anything a view can show changes (lets the coordinator skip no-op refreshes).
    public var stateSignature: String {
        "\(screen)|\(String(describing: machine?.state))|\(thermalHold)|\(checklistSignature)|"
            + "\(issuesSignature)|\(pendingPrompt ?? "")|\(consentMessage ?? "")|"
            + "\(positioningCues.map { "\($0)" } ?? "")|\(positioningReady)"
    }

    private var checklistSignature: String {
        FlowChecklistItem.allCases.map { checklist.contains($0) ? "1" : "0" }.joined()
    }

    private var issuesSignature: String {
        VitalField.allCases.map { f in vitalIssues[f].map { "\(f):\($0)" } ?? "" }.joined(separator: ",")
    }

    /// Every consumed attempt of the current session (createScan `device_attempts`).
    public var attemptLog: [AttemptRecord] { machine?.attemptLog ?? [] }

    /// Current recording attempt number, while recording.
    public var recordingAttempt: Int? {
        guard case .recording(_, let a)? = machine?.state else { return nil }
        return a
    }

    public func stepReasons(_ step: CaptureStep) -> [ReasonCode] { machine?.lastReasons[step] ?? [] }

    public var canCapture: Bool { screen == .capture && !thermalHold }

    /// I5: non-blocking warning on the capture screen (battery below 15 %).
    public var preflightWarning: String? {
        guard screen == .capture, preflight.warning == .lowBattery else { return nil }
        return NurseCopy.lowBatteryWarning
    }

    /// The current step needs the face positioning gate (Vision guidance).
    public var needsPositioningGate: Bool {
        if case .positioning(.neutralFace)? = machine?.state, screen == .capture { return true }
        return false
    }

    /// Exactly `[.ready]` continuously for at least `positioningHoldSeconds`, up to the latest update.
    public var positioningReady: Bool {
        guard needsPositioningGate, let since = readySince, let last = lastGuidanceTime else { return false }
        return last - since >= Self.positioningHoldSeconds
    }

    /// Feed every guidance evaluation while positioning (`t`: monotonic seconds). Ignored outside a face
    /// step's positioning. Any other cue set, a non-finite time or time going backwards restarts the hold.
    public func guidanceUpdate(_ cues: [GuidanceCue], at t: Double) {
        guard needsPositioningGate else { return }
        positioningCues = cues
        guard t.isFinite, lastGuidanceTime.map({ t >= $0 }) ?? true else {
            readySince = nil
            lastGuidanceTime = t.isFinite ? t : nil
            return
        }
        lastGuidanceTime = t
        if cues == [.ready] {
            if readySince == nil { readySince = t }
        } else {
            readySince = nil
        }
    }

    private func resetPositioning() {
        positioningCues = nil
        lastGuidanceTime = nil
        readySince = nil
    }

    public var checklistComplete: Bool { checklist.count == FlowChecklistItem.allCases.count }

    public var blockingMessage: String? {
        switch screen {
        case .consent: return consentMessage
        case .patientDeclined: return NurseCopy.patientDeclined
        case .comeBackLater: return NurseCopy.comeBackLater
        case .blocked:
            if case .blocked(let r)? = machine?.state { return Self.message(for: r) }
            return nil
        case .capture: return thermalHold ? NurseCopy.phoneWarm : nil
        default: return nil
        }
    }

    /// Saved-screen headline. A partial outcome is shown as an acquisition failure (T1 ruling).
    public var savedMessage: String {
        if case .completed(.accepted)? = machine?.state { return NurseCopy.saved }
        return NurseCopy.acquisitionFailure
    }

    private static func message(for r: BlockReason) -> String {
        switch r {
        case .lowStorage: return NurseCopy.lowStorage
        case .lowBattery: return NurseCopy.lowBattery
        case .consentInvalid: return NurseCopy.consentBlocked
        case .cameraPermissionDenied: return NurseCopy.cameraDenied
        case .unsupportedDevice: return NurseCopy.cameraNotReady
        }
    }

    // MARK: Inputs

    public func selectPatient(participantCode: String, bedLabel: String?) {
        guard screen == .patientSelect, !participantCode.isEmpty else { return }
        self.participantCode = participantCode
        self.bedLabel = bedLabel
        screen = .consent
    }

    /// Capture is allowed only when the server says so. Offline, the cached snapshot must be at most 24 h old.
    public func submitConsent(_ status: ConsentStatus, snapshotAt: Date, online: Bool, now: Date) {
        guard screen == .consent else { return }
        if !status.captureAllowed {
            consentMessage = status.blockCode == ReasonCode.dsREG002.rawValue
                ? NurseCopy.consentRenewal : NurseCopy.consentBlocked
            return
        }
        if snapshotAt.timeIntervalSince(now) > Self.maxSnapshotFutureSkew
            || (!online && now.timeIntervalSince(snapshotAt) > Self.maxSnapshotAge) {
            consentMessage = NurseCopy.consentBlocked
            return
        }
        consentMessage = nil
        screen = .assent
    }

    public func giveAssent() {
        guard screen == .assent else { return }
        assentGiven = true
        screen = .checklist
    }

    public func declineAssent() {
        guard screen == .assent else { return }
        screen = .patientDeclined
    }

    public func setChecklist(_ item: FlowChecklistItem, ticked: Bool) {
        guard screen == .checklist else { return }
        if ticked { checklist.insert(item) } else { checklist.remove(item) }
    }

    public func comeBackLater() {
        guard screen == .checklist else { return }
        screen = .comeBackLater
    }

    public func proceedFromChecklist() {
        guard screen == .checklist, assentGiven, checklistComplete else { return }
        screen = .referenceVitals
    }

    /// Blank entries are ignored. Unparseable values must be corrected; out-of-range values must be
    /// confirmed and are then kept, flagged. Nothing is silently dropped.
    public func submitVitals(_ entries: [VitalField: VitalEntry], now: Date, locale: Locale = .current) {
        guard screen == .referenceVitals else { return }
        var issues: [VitalField: VitalIssue] = [:]
        var records: [VitalRecord] = []
        for field in VitalField.allCases {
            guard let e = entries[field],
                  !e.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let v = Self.parse(e.text, locale: locale) else {
                issues[field] = .unparseable; flaggedText[field] = e.text; continue
            }
            let inRange = field.range.contains(v)
            let confirmed = e.confirmed && (flaggedText[field] == nil || flaggedText[field] == e.text)
            if !inRange && !confirmed { issues[field] = .outOfRange; flaggedText[field] = e.text; continue }
            records.append(VitalRecord(field: field, value: v, source: e.source,
                                       measuredAt: e.measuredAt ?? now, isInvalid: !inRange))
        }
        vitalIssues = issues
        guard issues.isEmpty, !records.isEmpty else { return }
        vitalRecords = records
        monitorHR = records.first { $0.field == .hr }.map { Int($0.value.rounded()) }
        vitalsSkipReason = nil
        startCapture()
    }

    /// Locale-aware decimal parsing; digits and one separator only (no hex, nan, exponents).
    static func parse(_ text: String, locale: Locale) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        let sep = locale.decimalSeparator ?? "."
        if sep != "." && t.contains(sep) { t = t.replacingOccurrences(of: sep, with: ".") }
        else if sep == "." && t.contains(",") && !t.contains(".") { t = t.replacingOccurrences(of: ",", with: ".") }
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              t.filter({ $0 == "." }).count <= 1, t.contains(where: { $0.isNumber }),
              let v = Double(t), v.isFinite else { return nil }
        return v
    }
    public func skipVitals(reason: VitalsSkipReason?) {
        guard screen == .referenceVitals, let reason else { return }
        monitorHR = nil
        vitalsSkipReason = reason
        startCapture()
    }

    private func startCapture() {
        let m = CaptureSessionMachine(protocol: captureProtocol, preflight: preflight)
        machine = m
        syncScreen()
    }

    // MARK: Step events (delegated to CaptureSessionMachine)

    /// Starts recording. For a face step only once `positioningReady` (I1); other steps start directly.
    public func positioned() {
        guard screen == .capture, !thermalHold else { return }
        if needsPositioningGate && !positioningReady { return }
        machine?.positioned()
        resetPositioning()
        syncScreen()
    }

    public func stepRecorded(duration: Double) {
        guard screen == .capture else { return }
        machine?.stepRecorded(duration: duration)
        syncScreen()
    }

    public func verdict(_ v: StepVerdict) {
        guard screen == .capture else { return }
        machine?.verdict(v)
        syncScreen()
    }

    /// Pause button, phone lock or app switch: discards the partial recording, no attempt consumed.
    public func pause() {
        guard screen == .capture else { return }
        machine?.interrupted()
        resetPositioning()   // re-position after any interruption
        syncScreen()
    }

    public func thermalChanged(_ level: ThermalLevel) {
        switch level {
        case .serious, .critical:
            thermalHold = true
            if screen == .capture { machine?.interrupted() }
        case .nominal, .fair:
            thermalHold = false
        }
    }

    /// Called by the recording timer. Fires the monitor-HR prompt once, 20 s into the face step.
    public func recordingElapsed(_ seconds: Double) {
        guard screen == .capture, !monitorPromptFired, vitalsSkipReason == nil,
              case .recording(.neutralFace, _)? = machine?.state,
              seconds >= Self.monitorPromptSeconds else { return }
        monitorPromptFired = true
        pendingPrompt = NurseCopy.noteMonitorHR
    }

    public func consumePrompt() { pendingPrompt = nil }

    public func continueFromQuality() {
        guard screen == .qualityResult else { return }
        screen = .saved
    }

    /// Back to patient selection. Clears everything about the previous patient.
    public func reset() {
        screen = .patientSelect
        participantCode = nil; bedLabel = nil; monitorHR = nil; vitalsSkipReason = nil
        checklist = []; vitalRecords = []; vitalIssues = [:]
        pendingPrompt = nil; monitorPromptFired = false; flaggedText = [:]
        // thermalHold is device state, not patient state: deliberately kept.
        consentMessage = nil; assentGiven = false; machine = nil
        resetPositioning()
    }

    private func syncScreen() {
        guard let state = machine?.state else { return }
        if case .positioning = state {} else { resetPositioning() }
        switch state {
        case .blocked: screen = .blocked
        case .completed: screen = .qualityResult
        default: screen = .capture
        }
    }
}
