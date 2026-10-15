import SwiftUI
import AVFoundation
import DengueCaptureCore

/// Capture step (I1): live preview with the face oval and the guidance cue while positioning. Start is enabled
/// for the face step only after the core gate saw `[.ready]` for 2 s; the camera then plans the ISO from the
/// converged auto exposure, locks and reads back every setting, and records.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
struct CaptureStepView: View {
    @ObservedObject var c: FlowCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 16) {
            Text(c.flow.currentStep?.nurseName ?? "").font(.title2)
            ZStack {
                if let session = c.previewSession {
                    CameraPreview(session: session).accessibilityHidden(true)
                } else {
                    Color.black.opacity(0.85)
                }
                if c.flow.currentStep == .neutralFace {
                    Ellipse()
                        .stroke(c.flow.positioningReady ? Color.green : Color.white, lineWidth: 4)
                        .frame(width: 220, height: 300)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let cue = c.guidanceText {
                Text(cue).font(.headline).accessibilityIdentifier("guidance-cue")
            }
            if let status = c.flow.statusMessage {
                Text(status).font(.headline).accessibilityIdentifier("status-message")
            }
            if let reason = c.flow.retryInstruction {
                Text(reason).accessibilityIdentifier("retry-instruction")
            }
            Text(c.flow.currentStep == .fingertipPPG ? NurseCopy.fingertipGuidance : NurseCopy.holdStillPatient)
            if let warning = c.flow.preflightWarning {
                Text(warning).font(.footnote).foregroundColor(.orange).accessibilityIdentifier("preflight-warning")
            }
            if let prompt = c.flow.pendingPrompt {
                Button(prompt) { c.dismissPrompt() }.accessibilityIdentifier("monitor-prompt")
            }
            if let m = c.blockingMessage { BlockingMessage(text: m) }
            Button(NurseCopy.buttonStart) { c.startCurrentStep() }
                .buttonStyle(.borderedProminent).font(.title)
                .disabled(!c.canStart).accessibilityIdentifier("start-button")
            Button(NurseCopy.buttonPause) { c.pause() }.accessibilityIdentifier("pause-button")
        }
        .padding()
        .onAppear { c.syncThermal(); c.ensurePositioning() }
        .onChange(of: c.revision) { _, _ in c.ensurePositioning() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in c.syncThermal() }
        // Spec Review Focus 1: lock / app switch mid-recording discards the partial, no attempt consumed.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { c.pause() }
        }
    }
}

/// `AVCaptureVideoPreviewLayer` host.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }
}
