import SwiftUI
import DengueCaptureCore

struct CaptureStepView: View {
    @ObservedObject var c: FlowCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            Text(c.flow.currentStep?.nurseName ?? "").font(.title2)
            if let status = c.flow.statusMessage {
                Text(status).font(.headline).accessibilityIdentifier("status-message")
            }
            if let reason = c.flow.retryInstruction {
                Text(reason).accessibilityIdentifier("retry-instruction")
            }
            if c.flow.currentStep == .fingertipPPG {
                Text(NurseCopy.fingertipGuidance)
            } else {
                Text(NurseCopy.holdStillPatient)
            }
            if let prompt = c.flow.pendingPrompt {
                Button(prompt) { c.dismissPrompt() }.accessibilityIdentifier("monitor-prompt")
            }
            if let m = c.blockingMessage { BlockingMessage(text: m) }
            Button(NurseCopy.buttonStart) { c.startCurrentStep() }
                .buttonStyle(.borderedProminent).font(.title)
                .disabled(!c.flow.canCapture).accessibilityIdentifier("start-button")
            Button(NurseCopy.buttonPause) { c.pause() }.accessibilityIdentifier("pause-button")
        }
        .padding()
        .onAppear { c.syncThermal() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in c.syncThermal() }
        // Spec Review Focus 1: lock / app switch mid-recording discards the partial, no attempt consumed.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { c.pause() }
        }
    }
}