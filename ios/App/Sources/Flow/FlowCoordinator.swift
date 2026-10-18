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

/// Resolves the API consent source at lookup time, so a later MDM `api_base_url` needs no relaunch.
struct LiveConsentSource: ConsentSource {
    func consent(for participantCode: String) async
        -> (status: ConsentStatus, snapshotAt: Date, online: Bool, patientId: UUID?) {
        if let c = UploadCoordinator.shared { return await APIConsentSource(service: c.consent).consent(for: participantCode) }
        return await UnconfiguredConsentSource().consent(for: participantCode)
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
    /// R-2: partial recordings stopped by a sign-in requirement before the step minimum (kept, never uploaded).
    private var interruptedClips: [InterruptedClip] = []
    /// R-2: the recording being ended early because sign-in became required.
    private var authStopping: RecordingSession?
    nonisolated(unsafe) private var authObservers: [NSObjectProtocol] = []
    /// Round 2 (I1): this coordinator's claim on the shared camera (`stop` is scoped to it).
    private let cameraOwner = UUID()
    /// Round 2 (I2): sealing of interrupted clips, awaited by the hand-off like `acceptedSealing`.
    private var clipSealing: [Task<InterruptedClip?, Never>] = []

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
        // R-2: sign-in is an overlay above this flow; the coordinator lives on and reacts to it.
        let nc = NotificationCenter.default
        authObservers = [
            nc.addObserver(forName: .dsSignInRequired, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.authRequired() }
            },
            nc.addObserver(forName: .dsSignInRestored, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.authRestored() }
            },
        ]
        if SignInOverlayModel.shared.required { flow.authRequired() }
    }

    deinit {
        for o in authObservers { NotificationCenter.default.removeObserver(o) }
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
        return FlowCoordinator(flow: flow, consentSource: LiveConsentSource(), camera: CameraRecorder.shared)
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
        guard flow.screen == .capture, case .positioning(let step)? = flow.machineState, !flow.thermalHold,
              !flow.authPending else {
            if currentRecording == nil { positioningStep = nil }
            return
        }
        guard positioningStep != step else { return }
        positioningStep = step
        camera.startPositioning(step: step, owner: cameraOwner) { [weak self] cues, t in
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

    // MARK: sign-in required (R-2)

    /// The sign-in overlay went up. The flow is kept; nothing new can start (core `CaptureFlow.authRequired`).
    /// - A live recording is ended safely: `finishEarly` finishes the asset writer and turns the torch off; its
    ///   result is decided in `finishStep` (core `recordingStoppedForAuth`: evaluated if past the step minimum,
    ///   otherwise kept as an interrupted clip without consuming the attempt).
    /// - Otherwise the camera (preview, torch) is stopped.
    /// - The session's accepted attempts are checkpointed to the held store at once.
    func authRequired() {
        flow.authRequired()
        positioningStep = nil
        if let rec = currentRecording, isRecording(rec) {
            authStopping = rec
            camera.finishEarly(rec)
        }
        camera.stop(owner: cameraOwner)   // queued after finishEarly; a no-op unless this flow owns the camera (I1)
        checkpointForReauth()
        refresh()
    }

    /// Sign-in succeeded: continue at the same step (the capture screen restarts positioning).
    func authRestored() {
        flow.authRestored()
        refresh()
    }

    /// R-2: the accepted attempts (and interrupted clips) of this session, persisted now as an open checkpoint.
    /// Not for a server-requested repeat (R-3: a repeat never writes a hand-off for the original session).
    private func checkpointForReauth() {
        guard handoffEnabled, !handedOff, let storage = CaptureStorage.shared else { return }
        if let r = repeatRequest {
            // Round 2 (I4): a repeat's accepted artefacts go to a `.repeatPending` record (never a hand-off of the
            // original session); retryHeld routes it to submitRepeat after a kill.
            let accepted = flow.attemptLog.filter { $0.verdict == .accept }.map { $0.step }
            storage.checkpointRepeat(sessionId: r.sessionId, maskedCode: r.maskedCode, capturedAt: capturedAt ?? Date(),
                                     reason: r.reasons.first?.rawValue ?? "nurse_repeat", accepted: accepted,
                                     sealed: sealedSoFar.filter { a in accepted.contains(a.step) })
            return
        }
        storage.checkpointForReauth(pending(artefacts: sealedSoFar))
    }

    /// R-2: seals nothing new (the recorder already started sealing); files the sealed partial clip as an
    /// `InterruptedClip` of this session's held record. Never uploaded; deleted only by a nurse discard.
    private func keepInterruptedClip(_ r: StepRecording, step: CaptureStep, attempt: Int) {
        guard handoffEnabled, let sealing = r.sealing, let storage = CaptureStorage.shared else {
            Self.discardSealing(r)   // UI tests: nothing was sealed
            return
        }
        let session = sessionId
        let masked = repeatRequest?.maskedCode ?? NurseCopy.maskedStudyID(flow.participantCode ?? "")
        let captured = capturedAt ?? Date()
        let repeating = repeatRequest != nil
        let seconds = r.duration
        let interruptedAt = Date()
        // Round 2 (I2): tracked like `acceptedSealing`: a hand-off started meanwhile awaits it and carries the clip.
        let task = Task<InterruptedClip?, Never> {
            let arts = await sealing.value
            return arts.isEmpty ? nil : InterruptedClip(step: step, attempt: attempt, recordedSeconds: seconds,
                                                        interruptedAt: interruptedAt, artefacts: arts)
        }
        clipSealing.append(task)
        Task { [weak self] in
            guard let clip = await task.value else { return }
            guard let self else {
                storage.keepInterruptedClip(clip, sessionId: session, maskedCode: masked, capturedAt: captured)
                return
            }
            if repeating {
                // A repeat: kept in the session's held record (or a clip-only record), never in a hand-off.
                storage.keepInterruptedClip(clip, sessionId: session, maskedCode: masked, capturedAt: captured)
                return
            }
            // Handed off meanwhile: that hand-off awaited this task and carries the clip.
            guard self.sessionId == session, !self.handedOff else { return }
            self.interruptedClips.append(clip)
            self.checkpointForReauth()
        }
    }

    /// Next patient. A session that recorded anything but was not handed off yet is handed off now (held if it
    /// cannot be queued): nothing captured is ever shredded here.
    func reset() {
        if let rec = currentRecording { currentRecording = nil; camera.cancel(rec) }
        authStopping = nil
        camera.stop(owner: cameraOwner)
        if !flow.attemptLog.isEmpty || !interruptedClips.isEmpty || !clipSealing.isEmpty { handOff() }
        acceptedSealing = []; sealedSoFar = []; faceSummary = nil; interruptedClips = []; clipSealing = []
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
        let owner = cameraOwner
        let positioning = step == .neutralFace ? nil : faceSummary
        Task { [weak self] in
            do {
                let result = try await camera.record(rec, owner: owner, seconds: cfg.targetSeconds,
                                                     positioning: positioning) { elapsed in
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
                if self.authStopping === rec {
                    // R-2: ended for sign-in before any frame was written: nothing to keep, attempt not consumed.
                    self.authStopping = nil
                    _ = self.flow.recordingStoppedForAuth(recordedSeconds: 0)
                    self.refresh()
                    return
                }
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
        if authStopping === rec {
            // R-2: ended early because sign-in became required. The core decides from the recorded duration.
            authStopping = nil
            switch flow.recordingStoppedForAuth(recordedSeconds: r.duration) {
            case .finishAndEvaluate:
                break   // past the step minimum: evaluated below like any finished recording
            case .keepPartialClip(let step, let attempt):
                currentRecording = nil   // attempt not consumed; back at the same step under the overlay
                keepInterruptedClip(r, step: step, attempt: attempt)
                refresh()
                return
            case .notRecording:
                currentRecording = nil
                Self.discardSealing(r)
                refresh()
                return
            }
        }
        // Provisional on-device verdict off the main thread (the pulse gate is a DFT). Never yields a pulse rate.
        let verdict = await Task.detached { StepQualityInput(trace: r.trace, config: config).verdict() }.value
        guard currentRecording === rec, isRecording(rec) else { Self.discardSealing(r); refresh(); return }
        currentRecording = nil
        if authStopping === rec { authStopping = nil }   // sign-in arrived after the full recording: evaluated as is
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
                // R-3: a server-requested repeat never checkpoints a standalone hand-off of the original session
                // (no patient id: it would be held as HANDOFF_PATIENT_UNKNOWN). It ends in enqueueRecapture.
                guard self.repeatRequest == nil else {
                    self.checkpointForReauth()   // round 3: repeat-pending record after every sealed step (idempotent)
                    return
                }
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
        var p = PendingHandoff(
            sessionId: sessionId, patientId: patientId,
            maskedCode: NurseCopy.maskedStudyID(flow.participantCode ?? ""),
            capturedAt: capturedAt ?? Date(), offline: offline,
            protocolVersion: CaptureProtocol.phaseADefault.version,
            attempts: flow.attemptLog, vitals: flow.vitalRecords, artefacts: artefacts,
            metadata: acceptedFaceMetadata ?? lastMetadata, isOpen: true)
        p.interruptedClips = interruptedClips   // R-2
        return p
    }

    /// Session over: wait for sealing, then `CaptureStorage.submit` (enqueued, or held; never shredded).
    private func handOff() {
        if repeatRequest != nil { handOffRepeat(); return }
        guard handoffEnabled, !handedOff, let storage = CaptureStorage.shared else { return }
        handedOff = true
        camera.stop(owner: cameraOwner)
        let tasks = acceptedSealing
        let clipTasks = clipSealing
        let base = pending(artefacts: [])
        Task.detached {
            var p = base
            for t in tasks { p.artefacts += await t.value }
            // Round 2 (I2): clips still sealing at hand-off time are carried too (union by sealed key id).
            for t in clipTasks {
                guard let c = await t.value else { continue }
                let have = Set(p.interruptedClips.flatMap { $0.artefacts.map { $0.sealed.keyId } })
                if !c.artefacts.contains(where: { have.contains($0.sealed.keyId) }) { p.interruptedClips.append(c) }
            }
            storage.submit(p)
        }
    }

    /// I2: the repeat's accepted steps become a recapture of the existing session: `enqueueRecapture` with the
    /// server's next attempt number per step. Device-rejected local attempts are not server attempts and are
    /// destroyed. If the repeat cannot be queued (window passed, no KMS key) its artefacts are destroyed: the
    /// session itself is already on the server.
    /// R-3: the logic lives in core `CaptureHandoffService.submitRepeat`, which never leaves a held hand-off of the
    /// original session (and removes an obsolete one).
    private func handOffRepeat() {
        guard let r = repeatRequest, handoffEnabled, !handedOff, let storage = CaptureStorage.shared else { return }
        handedOff = true
        camera.stop(owner: cameraOwner)
        let tasks = acceptedSealing
        let accepted = flow.attemptLog.filter { $0.verdict == .accept }.map { $0.step }
        let captured = capturedAt ?? Date()
        let reason = r.reasons.first?.rawValue ?? "nurse_repeat"
        Task.detached {
            var sealed: [SealedStepArtefact] = []
            for t in tasks { sealed += await t.value }
            guard let engine = UploadCoordinator.shared?.engine else {
                // Round 3: no upload engine (MDM not provisioned yet): hold, never destroy. retryHeld routes the
                // closed .repeatPending record to submitRepeat once the engine exists.
                storage.checkpointRepeat(sessionId: r.sessionId, maskedCode: r.maskedCode, capturedAt: captured,
                                         reason: reason, accepted: accepted, sealed: sealed, isOpen: false)
                return
            }
            storage.reloadKMSConfig()
            // Round 3: masked code and capture time make a held repeat row identifiable.
            let outcome = storage.handoffs.submitRepeat(sessionId: r.sessionId, reason: reason, accepted: accepted,
                                                        sealed: sealed, engine: engine, maskedCode: r.maskedCode,
                                                        capturedAt: captured)
            if outcome == .enqueued { UploadCoordinator.shared?.drainSoon() }
        }
    }
}
