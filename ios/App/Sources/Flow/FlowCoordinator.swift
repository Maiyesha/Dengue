import SwiftUI
import AVFoundation
import DengueCaptureCore

/// Consent lookup used by the consent screen. Real implementation wraps DengueAPI + the roster cache.
protocol ConsentSource {
    /// `patientId` is the server patient id (needed for createScan); nil when unknown.
    func consent(for participantCode: String) async
        -> (status: ConsentStatus, snapshotAt: Date, online: Bool, patientId: UUID?)
}

/// C2 production consent: core `ConsentService` (online lookup + consent status; 24 h roster cache offline).
/// A refused nurse session (`signInRequired`) also asks the app root to show sign-in.
struct APIConsentSource: ConsentSource {
    let service: ConsentService
    func consent(for participantCode: String) async
        -> (status: ConsentStatus, snapshotAt: Date, online: Bool, patientId: UUID?) {
        let r = await service.resolve(participantCode: participantCode)
        if r.outcome == .signInRequired {
            await MainActor.run { NotificationCenter.default.post(name: .dsUserAuthFailed, object: nil) }
        }
        return (r.status, r.snapshotAt, r.online, r.patientId)
    }
}

/// Uploads (and therefore the API) not provisioned by MDM yet: capture is blocked (fail closed).
struct UnconfiguredConsentSource: ConsentSource {
    func consent(for participantCode: String) async
        -> (status: ConsentStatus, snapshotAt: Date, online: Bool, patientId: UUID?) {
        (ConsentStatus(primaryResearch: false, consentVersion: "", currentVersion: "", withdrawn: false,
                       captureAllowed: false, blockCode: nil, checkedAt: WireDate.string(from: Date())),
         Date(), true, nil)
    }
}

/// A server-requested repeat (I2): only the masked code and the listed steps are known on the phone.
struct RepeatRequest: Identifiable, Equatable {
    let sessionId: UUID
    let maskedCode: String
    let steps: [CaptureStepName]
    let reasons: [ReasonCode]
    var id: UUID { sessionId }
}

/// Deterministic consent source for UI tests ONLY (UITEST_CONSENT = ok | blocked | stale).
struct FakeConsentSource: ConsentSource {
    let mode: String
    func consent(for participantCode: String) async
        -> (status: ConsentStatus, snapshotAt: Date, online: Bool, patientId: UUID?) {
        let blocked = mode == "blocked"
        let status = ConsentStatus(
            primaryResearch: !blocked, consentVersion: "v1", currentVersion: "v1", withdrawn: blocked,
            captureAllowed: !blocked, blockCode: blocked ? "DS_REG_001" : nil,
            checkedAt: "2026-10-15T00:00:00Z")
        let snapshot = mode == "stale" ? Date().addingTimeInterval(-25 * 3600) : Date()
        return (status, snapshot, mode != "stale", UUID())
    }
}

@MainActor
final class FlowCoordinator: ObservableObject {
    let flow: CaptureFlow
    private let consentSource: ConsentSource
    private let camera: CaptureCameraProviding
    private let experimentalEnabled: Bool
    /// Hand-off to uploads (off for UI tests: the fake camera seals nothing).
    private let handoffEnabled: Bool
    /// I2: set when this coordinator records a server-requested repeat.
    let repeatRequest: RepeatRequest?
    /// Step whose positioning the camera is currently running (I1).
    private var positioningStep: CaptureStep?

    // Per patient session (cleared by reset()).
    private var sessionId = UUID()
    private var patientId: UUID?
    private var offline = false
    private var capturedAt: Date?
    /// Per-attempt token: only this attempt may record, tick or deliver a result.
    private var currentRecording: RecordingSession?
    /// Sealing of ACCEPTED attempts, awaited before the hand-off.
    private var acceptedSealing: [Task<[SealedStepArtefact], Never>] = []
    /// Accepted artefacts sealed so far (checkpointed so a crash never orphans them).
    private var sealedSoFar: [SealedStepArtefact] = []
    /// Latest face-step positioning medians; the fingertip step reuses them.
    private var faceSummary: PositioningSummary?
    private var acceptedFaceMetadata: CaptureMetadata?
    private var lastMetadata: CaptureMetadata?
    private var handedOff = false

    /// Bumped after every flow mutation so SwiftUI re-reads the (non-observable) CaptureFlow.
    @Published private(set) var revision = 0
    @Published var experimental: ExperimentalResponse?
    /// "Camera not ready — try again" after a failed attempt (not consumed).
    @Published var cameraMessage: String?

    init(flow: CaptureFlow, consentSource: ConsentSource, camera: CaptureCameraProviding,
         experimentalEnabled: Bool = false, handoffEnabled: Bool = true, repeatRequest: RepeatRequest? = nil) {
        self.flow = flow
        self.consentSource = consentSource
        self.camera = camera
        self.experimentalEnabled = experimentalEnabled
        self.handoffEnabled = handoffEnabled
        self.repeatRequest = repeatRequest
        if let r = repeatRequest {
            sessionId = r.sessionId
            flow.beginRepeat(maskedCode: r.maskedCode)
        }
    }

    static var isUITest: Bool { ProcessInfo.processInfo.environment["UITEST_FAKE_CAMERA"] == "1" }

    static func make() -> FlowCoordinator {
        let env = ProcessInfo.processInfo.environment
        let flow = CaptureFlow(preflight: DevicePreflight.current(supportsDepthCapture: true))
        if isUITest {
            return FlowCoordinator(
                flow: flow, consentSource: FakeConsentSource(mode: env["UITEST_CONSENT"] ?? "ok"),
                camera: FakeCamera(), experimentalEnabled: env["UITEST_EXPERIMENTAL"] == "1", handoffEnabled: false)
        }
        // Production (C2): DengueAPI-backed consent; blocked until MDM provisions the API.
        let consent: ConsentSource = UploadCoordinator.shared.map { APIConsentSource(service: $0.consent) }
            ?? UnconfiguredConsentSource()
        return FlowCoordinator(flow: flow, consentSource: consent, camera: CameraRecorder.shared)
    }

    /// I2: a repeat recording of `r.steps` for an existing session (ends in `UploadEngine.enqueueRecapture`).
    static func makeRepeat(_ r: RepeatRequest) -> FlowCoordinator {
        let flow = CaptureFlow(protocol: .repeatProtocol(steps: r.steps),
                               preflight: DevicePreflight.current(supportsDepthCapture: true))
        return FlowCoordinator(flow: flow, consentSource: UnconfiguredConsentSource(), camera: CameraRecorder.shared,
                               repeatRequest: r)
    }

    /// Bumps `revision` only when something a view can show actually changed (no remount loops).
    private var lastSignature = ""
    private func refresh() {
        // Any interruption path (pause, thermal, scene phase) that left .recording discards the live attempt.
        if let rec = currentRecording, !isRecording(rec) {
            currentRecording = nil
            camera.cancel(rec)
        }
        let sig = flow.stateSignature + "|\(cameraMessage ?? "")"
        guard sig != lastSignature else { return }
        lastSignature = sig
        revision += 1
    }

    @Published var showOutbox = false
    private var injectedThermal = false

    /// Seeds and tracks the OS thermal state (call on appear and from the notification).
    func syncThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: flow.thermalChanged(.serious)
        case .critical: flow.thermalChanged(.critical)
        case .fair: flow.thermalChanged(.fair)
        default: if !injectedThermal { flow.thermalChanged(.nominal) }
        }
        refresh()
    }

    /// Recording timer hook (~1 Hz from the recorder); fires the 20 s monitor-HR prompt.
    func recordingTick(elapsed: Double) { flow.recordingElapsed(elapsed); refresh() }
    func dismissPrompt() { flow.consumePrompt(); refresh() }

    var screen: FlowScreen { flow.screen }
    var blockingMessage: String? { flow.blockingMessage ?? cameraMessage }

    func selectPatient(code: String, bed: String?) {
        flow.selectPatient(participantCode: code, bedLabel: bed)
        refresh()
        Task {
            let c = await consentSource.consent(for: code)
            patientId = c.patientId
            offline = !c.online
            flow.submitConsent(c.status, snapshotAt: c.snapshotAt, online: c.online, now: Date())
            refresh()
        }
    }

    func giveAssent() { flow.giveAssent(); refresh() }
    func declineAssent() { flow.declineAssent(); refresh() }
    func toggle(_ item: FlowChecklistItem, _ on: Bool) { flow.setChecklist(item, ticked: on); refresh() }
    func proceedFromChecklist() { flow.proceedFromChecklist(); refresh() }
    func comeBackLater() { flow.comeBackLater(); refresh() }
    func submitVitals(_ e: [VitalField: VitalEntry]) { enteringCapture(); flow.submitVitals(e, now: Date()); refresh() }
    func skipVitals(_ r: VitalsSkipReason?) { enteringCapture(); flow.skipVitals(reason: r); refresh() }

    /// Capture-screen entry: devices without a depth-capable TrueDepth front format are blocked before capture
    /// (`BlockReason.unsupportedDevice`, copy "Camera not ready — try again").
    /// I5: real free space (`volumeAvailableCapacityForImportantUsage`) and battery (`UIDevice.batteryLevel`).
    private func enteringCapture() {
        let depth = handoffEnabled ? CameraRecorder.supportsDepthCapture() : true   // UI tests: fake camera
        flow.updatePreflight(Self.isUITest ? Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8)
                                           : DevicePreflight.current(supportsDepthCapture: depth))
    }

    // MARK: positioning (I1)

    /// Runs the camera's positioning (preview, auto exposure, guidance) for the step being positioned.
    /// Called by the capture screen on appear and after every change.
    func ensurePositioning() {
        guard flow.screen == .capture, case .positioning(let step)? = flow.machineState, !flow.thermalHold else {
            if currentRecording == nil { positioningStep = nil }
            return
        }
        guard positioningStep != step else { return }
        positioningStep = step
        camera.startPositioning(step: step) { [weak self] cues, t in
            Task { @MainActor [weak self] in
                guard let self, self.positioningStep == step else { return }
                self.flow.guidanceUpdate(cues, at: t)
                self.refresh()
            }
        }
    }

    /// Start is possible only once the face has been positioned for 2 s (core gate); other steps directly.
    var canStart: Bool { flow.canCapture && (!flow.needsPositioningGate || flow.positioningReady) }

    /// Current guidance line for the face oval (NurseCopy).
    var guidanceText: String? { flow.positioningCues?.first.map(NurseCopy.text(for:)) }

    var previewSession: AVCaptureSession? { camera.previewSession }

    /// I2: live upload status of the session just recorded (nil before the hand-off or in UI tests).
    var sessionStatus: SessionStatus? {
        guard handoffEnabled else { return nil }
        return UploadCoordinator.shared?.engine.status(sessionId)
    }

    /// Pause button, lock, app switch: discards the partial recording; the attempt is not consumed.
    func pause() {
        if let rec = currentRecording { currentRecording = nil; camera.cancel(rec) }
        flow.pause(); refresh()
    }

    func thermalChanged(_ l: ThermalLevel) { flow.thermalChanged(l); refresh() }

    /// Next patient. A session that recorded anything but was not handed off yet is handed off now (held if it
    /// cannot be queued): nothing captured is ever shredded here.
    func reset() {
        if let rec = currentRecording { currentRecording = nil; camera.cancel(rec) }
        camera.stop()
        if !flow.attemptLog.isEmpty { handOff() }
        acceptedSealing = []; sealedSoFar = []; faceSummary = nil
        acceptedFaceMetadata = nil; lastMetadata = nil; handedOff = false
        sessionId = UUID(); patientId = nil; offline = false; capturedAt = nil; cameraMessage = nil
        flow.reset(); experimental = nil; showOutbox = false; refresh()
    }

    func continueFromQuality() {
        flow.continueFromQuality()
        if experimentalEnabled {
            // Real values come from GET /v1/scans/:id/experimental once the server has computed them.
            experimental = ExperimentalResponse(enabled: false, items: [])
        }
        refresh()
    }

    // MARK: recording

    /// Starts and records the current step under a fresh per-attempt token. The result is used only while that
    /// token is still the current recording (a paused attempt's late result is discarded).
    func startCurrentStep() {
        guard let step = flow.currentStep, case .positioning? = flow.machineState,
              let cfg = flow.steps.first(where: { $0.step == step }) else { return }
        syncThermal()
        flow.positioned()   // the core gate refuses a face step that has not been ready for 2 s
        positioningStep = nil
        // UI-test hook: simulate thermal pressure once, while recording.
        if ProcessInfo.processInfo.environment["UITEST_THERMAL_SERIOUS"] == "1", !injectedThermal,
           case .recording? = flow.machineState {
            injectedThermal = true
            flow.thermalChanged(.serious)
        }
        guard case .recording(_, let attempt)? = flow.machineState else { refresh(); return }
        if capturedAt == nil { capturedAt = Date() }
        cameraMessage = nil
        let rec = RecordingSession(step: step, attempt: attempt)
        currentRecording = rec
        refresh()
        let camera = self.camera
        let positioning = step == .neutralFace ? nil : faceSummary
        Task { [weak self] in
            do {
                let result = try await camera.record(rec, seconds: cfg.targetSeconds, positioning: positioning) { elapsed in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentRecording === rec else { return }
                        self.recordingTick(elapsed: elapsed)
                    }
                }
                guard let self else { Self.discardSealing(result); return }
                await self.finishStep(result, rec: rec, config: cfg)
            } catch {
                guard let self, self.currentRecording === rec else { return }   // paused: already handled
                self.currentRecording = nil
                self.flow.pause()   // attempt not consumed; the nurse retries
                self.cameraMessage = NurseCopy.cameraNotReady
                self.refresh()
            }
        }
    }

    private func isRecording(_ rec: RecordingSession) -> Bool {
        if case .recording(let s, let a)? = flow.machineState { return s == rec.step && a == rec.attempt }
        return false
    }

    private func finishStep(_ r: StepRecording, rec: RecordingSession, config: StepConfig) async {
        guard currentRecording === rec, isRecording(rec) else { Self.discardSealing(r); return }
        // Provisional on-device verdict off the main thread (the pulse gate is a DFT). Never yields a pulse rate.
        let verdict = await Task.detached { StepQualityInput(trace: r.trace, config: config).verdict() }.value
        guard currentRecording === rec, isRecording(rec) else { Self.discardSealing(r); refresh(); return }
        currentRecording = nil
        lastMetadata = r.metadata
        if r.step == .neutralFace, let p = r.positioning { faceSummary = p }
        flow.stepRecorded(duration: r.duration)
        if case .reviewingStep? = flow.machineState { flow.verdict(verdict) }
        let accepted = flow.attemptLog.last.map {
            $0.step == rec.step && $0.attempt == rec.attempt && $0.verdict == .accept
        } ?? false
        if accepted, handoffEnabled, let sealing = r.sealing {
            if r.step == .neutralFace { acceptedFaceMetadata = r.metadata }
            acceptedSealing.append(sealing)
            let session = sessionId
            Task { [weak self] in
                let arts = await sealing.value
                guard let self, self.sessionId == session, !self.handedOff else { return }
                self.sealedSoFar += arts
                CaptureStorage.shared?.checkpoint(self.pending(artefacts: self.sealedSoFar))
            }
        } else {
            Self.discardSealing(r)   // not accepted: never uploaded
        }
        if flow.screen == .qualityResult { handOff() }
        refresh()
    }

    /// Destroys the sealed artefacts of an attempt nobody will upload (rejected, paused meanwhile, or stale).
    nonisolated private static func discardSealing(_ r: StepRecording) {
        guard let sealing = r.sealing else { return }
        Task.detached { CaptureStorage.shared?.destroy(await sealing.value) }
    }

    // MARK: hand-off

    private func pending(artefacts: [SealedStepArtefact]) -> PendingHandoff {
        PendingHandoff(
            sessionId: sessionId, patientId: patientId,
            maskedCode: NurseCopy.maskedStudyID(flow.participantCode ?? ""),
            capturedAt: capturedAt ?? Date(), offline: offline,
            protocolVersion: CaptureProtocol.phaseADefault.version,
            attempts: flow.attemptLog, vitals: flow.vitalRecords, artefacts: artefacts,
            metadata: acceptedFaceMetadata ?? lastMetadata, isOpen: true)
    }

    /// Session over: wait for sealing, then `CaptureStorage.submit` (enqueued, or held; never shredded).
    private func handOff() {
        if repeatRequest != nil { handOffRepeat(); return }
        guard handoffEnabled, !handedOff, let storage = CaptureStorage.shared else { return }
        handedOff = true
        camera.stop()
        let tasks = acceptedSealing
        let base = pending(artefacts: [])
        Task.detached {
            var p = base
            for t in tasks { p.artefacts += await t.value }
            storage.submit(p)
        }
    }

    /// I2: the repeat's accepted steps become a recapture of the existing session: `enqueueRecapture` with the
    /// server's next attempt number per step. Device-rejected local attempts are not server attempts and are
    /// destroyed. If the repeat cannot be queued (window passed, no KMS key) its artefacts are destroyed: the
    /// session itself is already on the server.
    private func handOffRepeat() {
        guard let r = repeatRequest, handoffEnabled, !handedOff, let storage = CaptureStorage.shared else { return }
        handedOff = true
        camera.stop()
        let tasks = acceptedSealing
        let accepted = flow.attemptLog.filter { $0.verdict == .accept }.map { $0.step }
        Task.detached {
            var sealed: [SealedStepArtefact] = []
            for t in tasks { sealed += await t.value }
            guard let engine = UploadCoordinator.shared?.engine else { storage.destroy(sealed); return }
            sealed = storage.wrapMissingKeys(sealed)
            var uploads: [ArtefactUpload] = []
            var steps: [CaptureStepName] = []
            for a in sealed {
                guard let name = CaptureStepName(rawValue: a.step.rawValue), accepted.contains(a.step),
                      let attempt = engine.recaptureAttempt(sessionId: r.sessionId, step: name) else { continue }
                if !steps.contains(name) { steps.append(name) }
                uploads.append(ArtefactUpload(step: name, attempt: attempt, kind: a.kind, deviceVerdict: .accept,
                                              sealed: a.sealed))
            }
            let used = Set(uploads.map { $0.sealed.keyId })
            do {
                guard !uploads.isEmpty else { throw UploadEngineError.noScan }
                try engine.enqueueRecapture(sessionId: r.sessionId, steps: steps,
                                            reason: r.reasons.first?.rawValue ?? "nurse_repeat", artefacts: uploads)
                storage.destroy(sealed.filter { !used.contains($0.sealed.keyId) })
                UploadCoordinator.shared?.drainSoon()
            } catch {
                storage.destroy(sealed)
            }
        }
    }
}
