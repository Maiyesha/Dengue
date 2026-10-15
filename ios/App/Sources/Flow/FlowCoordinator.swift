import SwiftUI
import DengueCaptureCore

/// Consent lookup used by the consent screen. Real implementation wraps DengueAPI + the roster cache.
protocol ConsentSource {
    func consent(for participantCode: String) async -> (status: ConsentStatus, snapshotAt: Date, online: Bool)
}

/// Deterministic consent source for UI tests (UITEST_CONSENT = ok | blocked | stale).
struct FakeConsentSource: ConsentSource {
    let mode: String
    func consent(for participantCode: String) async -> (status: ConsentStatus, snapshotAt: Date, online: Bool) {
        let blocked = mode == "blocked"
        let status = ConsentStatus(
            primaryResearch: !blocked, consentVersion: "v1", currentVersion: "v1", withdrawn: blocked,
            captureAllowed: !blocked, blockCode: blocked ? "DS_REG_001" : nil,
            checkedAt: "2026-10-15T00:00:00Z")
        let snapshot = mode == "stale" ? Date().addingTimeInterval(-25 * 3600) : Date()
        return (status, snapshot, mode != "stale")
    }
}

@MainActor
final class FlowCoordinator: ObservableObject {
    let flow: CaptureFlow
    private let consentSource: ConsentSource
    private let camera: CaptureCameraProviding
    private let experimentalEnabled: Bool

    /// Bumped after every flow mutation so SwiftUI re-reads the (non-observable) CaptureFlow.
    @Published private(set) var revision = 0
    @Published var experimental: ExperimentalResponse?

    init(flow: CaptureFlow, consentSource: ConsentSource, camera: CaptureCameraProviding,
         experimentalEnabled: Bool = false) {
        self.flow = flow
        self.consentSource = consentSource
        self.camera = camera
        self.experimentalEnabled = experimentalEnabled
    }

    static func make() -> FlowCoordinator {
        let env = ProcessInfo.processInfo.environment
        let preflight = Preflight(freeBytes: 10_000_000_000, batteryLevel: 0.8)
        let flow = CaptureFlow(preflight: preflight)
        if env["UITEST_FAKE_CAMERA"] == "1" {
            return FlowCoordinator(
                flow: flow, consentSource: FakeConsentSource(mode: env["UITEST_CONSENT"] ?? "ok"),
                camera: FakeCamera(), experimentalEnabled: env["UITEST_EXPERIMENTAL"] == "1")
        }
        // Production wiring (DengueAPI + AVFoundation camera) lands with Task 11/12.
        return FlowCoordinator(
            flow: flow, consentSource: FakeConsentSource(mode: "blocked"), camera: FakeCamera())
    }

    private func refresh() { revision += 1 }

    var screen: FlowScreen { flow.screen }
    var blockingMessage: String? { flow.blockingMessage }

    func selectPatient(code: String, bed: String?) {
        flow.selectPatient(participantCode: code, bedLabel: bed)
        refresh()
        Task {
            let c = await consentSource.consent(for: code)
            flow.submitConsent(c.status, snapshotAt: c.snapshotAt, online: c.online, now: Date())
            refresh()
        }
    }

    func giveAssent() { flow.giveAssent(); refresh() }
    func declineAssent() { flow.declineAssent(); refresh() }
    func toggle(_ item: FlowChecklistItem, _ on: Bool) { flow.setChecklist(item, ticked: on); refresh() }
    func proceedFromChecklist() { flow.proceedFromChecklist(); refresh() }
    func comeBackLater() { flow.comeBackLater(); refresh() }
    func enterVitals(_ v: ReferenceVitalsInput) { flow.enterVitals(v); refresh() }
    func skipVitals(_ r: VitalsSkipReason?) { flow.skipVitals(reason: r); refresh() }
    func pause() { flow.pause(); refresh() }
    func thermalChanged(_ l: ThermalLevel) { flow.thermalChanged(l); refresh() }
    func reset() { flow.reset(); experimental = nil; refresh() }

    func continueFromQuality() {
        flow.continueFromQuality()
        if experimentalEnabled {
            // Real values come from GET /v1/scans/:id/experimental once the server has computed them.
            experimental = ExperimentalResponse(enabled: false, items: [])
        }
        refresh()
    }

    /// Starts and records the current step. The fake camera completes instantly; the on-device
    /// quality verdict comes from the Task 11 pipeline (accept here when the minimum was met).
    func startCurrentStep(config: CaptureProtocol = .phaseADefault) {
        guard let step = flow.currentStep,
              let cfg = config.steps.first(where: { $0.step == step }) else { return }
        flow.positioned()
        refresh()
        guard case .recording? = flow.machineState else { return }
        Task {
            let d = await camera.record(step: step, seconds: cfg.targetSeconds)
            guard case .recording? = flow.machineState else { return }  // interrupted meanwhile
            flow.stepRecorded(duration: d)
            if case .reviewingStep? = flow.machineState { flow.verdict(.accept) }
            refresh()
        }
    }
}