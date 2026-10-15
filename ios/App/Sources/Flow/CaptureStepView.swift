import SwiftUI
import DengueCaptureCore

struct CaptureStepView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(spacing: 20) {
            Text(stepName).font(.title2)
            if c.flow.currentStep == .fingertipPPG {
                Text(NurseCopy.fingertipGuidance)
            } else {
                Text(NurseCopy.holdStillPatient)
            }
            if let m = c.blockingMessage { BlockingMessage(text: m) }
            Button(NurseCopy.buttonStart) { c.startCurrentStep() }
                .buttonStyle(.borderedProminent).font(.title)
                .disabled(!c.flow.canCapture).accessibilityIdentifier("start-button")
            Button(NurseCopy.buttonPause) { c.pause() }.accessibilityIdentifier("pause-button")
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            switch ProcessInfo.processInfo.thermalState {
            case .serious: c.thermalChanged(.serious)
            case .critical: c.thermalChanged(.critical)
            case .fair: c.thermalChanged(.fair)
            default: c.thermalChanged(.nominal)
            }
        }
        .onAppear {
            // UI-test hook: simulate thermal pressure during a recording.
            if ProcessInfo.processInfo.environment["UITEST_THERMAL_SERIOUS"] == "1" {
                c.startCurrentStep()
                c.thermalChanged(.serious)
            }
        }
    }

    private var stepName: String {
        switch c.flow.currentStep {
        case .neutralFace?: return NurseCopy.stepNameFace
        case .fingertipPPG?: return NurseCopy.stepNameFingertip
        case .ocularCapture?: return NurseCopy.stepNameEye
        case .dorsalTongue?: return NurseCopy.stepNameTongue
        case nil: return ""
        }
    }
}