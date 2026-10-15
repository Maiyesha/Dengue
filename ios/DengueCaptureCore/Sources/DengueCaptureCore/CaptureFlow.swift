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

public struct ReferenceVitalsInput: Equatable {
    public var hr: Int?
    public var spo2: Int?
    public var sbp: Int?
    public var dbp: Int?
    public var tempC: Double?
    public var rr: Int?
    public var crtS: Double?

    public init(hr: Int? = nil, spo2: Int? = nil, sbp: Int? = nil, dbp: Int? = nil,
                tempC: Double? = nil, rr: Int? = nil, crtS: Double? = nil) {
        self.hr = hr; self.spo2 = spo2; self.sbp = sbp; self.dbp = dbp
        self.tempC = tempC; self.rr = rr; self.crtS = crtS
    }

    public var isEmpty: Bool {
        hr == nil && spo2 == nil && sbp == nil && dbp == nil && tempC == nil && rr == nil && crtS == nil
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

    public func stepReasons(_ step: CaptureStep) -> [ReasonCode] { machine?.lastReasons[step] ?? [] }

    public var canCapture: Bool { screen == .capture && !thermalHold }

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
        if !online && now.timeIntervalSince(snapshotAt) > Self.maxSnapshotAge {
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

    public func enterVitals(_ v: ReferenceVitalsInput) {
        guard screen == .referenceVitals, !v.isEmpty else { return }
        monitorHR = v.hr
        vitalsSkipReason = nil
        startCapture()
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

    public func positioned() {
        guard screen == .capture, !thermalHold else { return }
        machine?.positioned()
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

    public func continueFromQuality() {
        guard screen == .qualityResult else { return }
        screen = .saved
    }

    /// Back to patient selection. Clears everything about the previous patient.
    public func reset() {
        screen = .patientSelect
        participantCode = nil; bedLabel = nil; monitorHR = nil; vitalsSkipReason = nil
        checklist = []; thermalHold = false
        consentMessage = nil; assentGiven = false; machine = nil
    }

    private func syncScreen() {
        guard let state = machine?.state else { return }
        switch state {
        case .blocked: screen = .blocked
        case .completed: screen = .qualityResult
        default: screen = .capture
        }
    }
}
