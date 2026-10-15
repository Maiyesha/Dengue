import SwiftUI
import DengueCaptureCore

/// Consent lookup used by the consent screen. Real implementation wraps DengueAPI + the roster cache.
protocol ConsentSource {
    /// `patientId` is the server patient id (needed for createScan); nil when unknown.
    func consent(for participantCode: String) async
        -> (status: ConsentStatus, snapshotAt: Date, online: Bool, patientId: UUID?)
}

/// Deterministic consent source for UI tests (UITEST_CONSENT = ok | blocked | stale).
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
    /// Seal + enqueue after the quality result (off for UI tests: the fake camera writes no video).
    private let handoffEnabled: Bool

    // Per patient session (cleared by reset()).
    private var sessionId = UUID()
    private var patientId: UUID?
    private var offline = false
    private var capturedAt: Date?
    /// Per-attempt token: only this attempt may record, tick or deliver a result.
    private var currentRecording: RecordingSession?
    /// Sealing of accepted attempts (video + roi_trace + metadata), awaited before the hand-off.
    private var sealTasks: [Task<[SealedStepArtefact], Never>] = []
    private var acceptedMetadata: [CaptureStep: CaptureMetadata] = [:]
    /// Latest attempt's metadata (createScan metadata when no attempt was accepted).
    private var lastMetadata: CaptureMetadata?
    private var handedOff = false
    private lazy var keys: KeyStore = SecureEnclaveKeyStore()

    /// Bumped after every flow mutation so SwiftUI re-reads the (non-observable) CaptureFlow.
    @Published private(set) var revision = 0
    @Published var experimental: ExperimentalResponse?
    /// "Camera not ready — try again" after a failed attempt (not consumed).
    @Published var cameraMessage: String?

    init(flow: CaptureFlow, consentSource: ConsentSource, camera: CaptureCameraProviding,
         experimentalEnabled: Bool = false, handoffEnabled: Bool = true) {
        self.flow = flow
        self.consentSource = consentSource
        self.camera = camera
        self.experimentalEnabled = experimentalEnabled
        self.handoffEnabled = handoffEnabled
    }

    static func make() -> FlowCoordinator {
        let env = ProcessInfo.processInfo.environment
        let preflight = Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8)
        let flow = CaptureFlow(preflight: preflight)
        if env["UITEST_FAKE_CAMERA"] == "1" {
            return FlowCoordinator(
                flow: flow, consentSource: FakeConsentSource(mode: env["UITEST_CONSENT"] ?? "ok"),
                camera: FakeCamera(), experimentalEnabled: env["UITEST_EXPERIMENTAL"] == "1", handoffEnabled: false)
        }
        // Production: real AVFoundation recorder (Task 13). The consent source is still the blocking placeholder
        // (DengueAPI consent/roster wiring was not part of Tasks 10-12).
        return FlowCoordinator(
            flow: flow, consentSource: FakeConsentSource(mode: "blocked"), camera: CameraRecorder())
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
    func submitVitals(_ e: [VitalField: VitalEntry]) { flow.submitVitals(e, now: Date()); refresh() }
    func skipVitals(_ r: VitalsSkipReason?) { flow.skipVitals(reason: r); refresh() }

    /// Pause button, lock, app switch: discards the partial recording; the attempt is not consumed.
    func pause() {
        if let rec = currentRecording { currentRecording = nil; camera.cancel(rec) }
        flow.pause(); refresh()
    }

    func thermalChanged(_ l: ThermalLevel) { flow.thermalChanged(l); refresh() }

    func reset() {
        if let rec = currentRecording { currentRecording = nil; camera.cancel(rec) }
        camera.stop()
        if !handedOff { discardSealed() }   // abandoned session: crypto-shred anything already sealed
        sealTasks = []; acceptedMetadata = [:]; lastMetadata = nil; handedOff = false
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
        guard let step = flow.currentStep,
              let cfg = flow.steps.first(where: { $0.step == step }) else { return }
        syncThermal()
        flow.positioned()
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
        Task { [weak self] in
            do {
                let result = try await camera.record(rec, seconds: cfg.targetSeconds) { elapsed in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentRecording === rec else { return }
                        self.recordingTick(elapsed: elapsed)
                    }
                }
                guard let self else { return }
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
        guard currentRecording === rec, isRecording(rec) else { Self.deletePlaintext(r); return }
        // Provisional on-device verdict off the main thread (the pulse gate is a DFT). Never yields a pulse rate.
        let verdict = await Task.detached { StepQualityInput(trace: r.trace, config: config).verdict() }.value
        guard currentRecording === rec, isRecording(rec) else { Self.deletePlaintext(r); refresh(); return }
        currentRecording = nil
        lastMetadata = r.metadata
        flow.stepRecorded(duration: r.duration)
        if case .reviewingStep? = flow.machineState { flow.verdict(verdict) }
        let accepted = flow.attemptLog.last.map {
            $0.step == rec.step && $0.attempt == rec.attempt && $0.verdict == .accept
        } ?? false
        if accepted, handoffEnabled, r.videoURL != nil {
            acceptedMetadata[r.step] = r.metadata
            let keys = self.keys
            sealTasks.append(Task.detached { Self.seal(r, keys: keys) })
        } else {
            Self.deletePlaintext(r)
        }
        if flow.screen == .qualityResult { handOff() }
        refresh()
    }

    nonisolated private static func deletePlaintext(_ r: StepRecording) {
        if let url = r.videoURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: sealing and hand-off

    /// Class C directory, excluded from backup, for sealed artefacts.
    nonisolated private static func sealedDirectory() throws -> URL {
        let fm = FileManager.default
        var dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DengueSense/sealed", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try dir.setResourceValues(rv)
        return dir
    }

    /// Writes the trace and metadata plaintext (Class B) beside the video, seals all three (Class C) and deletes
    /// the plaintext. Any failure discards the attempt's files and keys (fail closed) and returns [].
    nonisolated private static func seal(_ r: StepRecording, keys: KeyStore) -> [SealedStepArtefact] {
        guard let video = r.videoURL else { return [] }
        let captureDir = video.deletingLastPathComponent()
        let stem = r.token.uuidString.lowercased()
        let traceURL = captureDir.appendingPathComponent("\(stem).roi.json")
        let metaURL = captureDir.appendingPathComponent("\(stem).meta.json")
        let plaintexts: [(ArtefactKind, URL)] = [(.video, video), (.roiTrace, traceURL), (.metadata, metaURL)]
        var out: [SealedStepArtefact] = []
        do {
            try r.trace.encoded().write(to: traceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try r.metadata.encoded().write(to: metaURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            let dir = try sealedDirectory()
            let sealer = ArtefactSealer(keys: keys)
            for (kind, url) in plaintexts {
                let dest = dir.appendingPathComponent("\(stem).\(kind.rawValue).sealed")
                let s = try CaptureHandoff.sealAndRemovePlaintext(input: url, output: dest, sealer: sealer)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dest.path)
                out.append(SealedStepArtefact(step: r.step, attempt: r.attempt, kind: kind, sealed: s))
            }
            return out
        } catch {
            for (_, url) in plaintexts { try? FileManager.default.removeItem(at: url) }
            destroy(out.map { $0.sealed }, keys: keys)
            return []
        }
    }

    nonisolated private static func destroy(_ sealed: [SealedArtefact], keys: KeyStore) {
        for s in sealed {
            try? keys.destroy(id: s.keyId)
            try? FileManager.default.removeItem(at: s.path)
        }
    }

    private func discardSealed() {
        let tasks = sealTasks
        guard !tasks.isEmpty else { return }
        let keys = self.keys
        Task.detached {
            for t in tasks { Self.destroy(await t.value.map { $0.sealed }, keys: keys) }
        }
    }

    /// When the session completes: wait for sealing, build the core `CaptureHandoff` plan (createScan with every
    /// attempt, clinical data, declare/upload/complete per accepted artefact) and enqueue it.
    /// Fails closed: if anything required is missing, every sealed artefact of the session is crypto-shredded.
    private func handOff() {
        guard handoffEnabled, !handedOff else { return }
        handedOff = true
        camera.stop()
        let tasks = sealTasks
        let keys = self.keys
        let attempts = flow.attemptLog
        let vitals = flow.vitalRecords
        let code = flow.participantCode ?? ""
        let sessionId = self.sessionId, patientId = self.patientId, offline = self.offline
        let capturedAt = self.capturedAt ?? Date()
        let meta = acceptedMetadata[.neutralFace] ?? acceptedMetadata.values.first ?? lastMetadata
        Task.detached {
            var sealed: [SealedStepArtefact] = []
            for t in tasks { sealed += await t.value }
            do {
                guard let patientId, let meta, let uploads = UploadCoordinator.shared else {
                    throw CaptureHandoffError.noAttempts
                }
                let plan = try CaptureHandoff().makeSessionPlan(
                    sessionId: sessionId, patientId: patientId, capturedAt: capturedAt, offline: offline,
                    protocolVersion: CaptureProtocol.phaseADefault.version,
                    metadata: try CaptureHandoff.scanMetadata(from: meta),
                    attempts: attempts, vitals: vitals, artefacts: sealed)
                try uploads.enqueue(plan: plan, participantCode: code)
                Self.destroy(plan.discarded, keys: keys)
            } catch {
                Self.destroy(sealed.map { $0.sealed }, keys: keys)
            }
        }
    }
}
