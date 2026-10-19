import SwiftUI
import DengueCaptureCore

/// Consent check (blocking). No capture control is ever shown when blocked.
struct ConsentView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(spacing: 16) {
            if let m = c.blockingMessage {
                BlockingMessage(text: m)
                Button(NurseCopy.buttonDone) { c.reset() }.accessibilityIdentifier("blocked-done-button")
            } else {
                ProgressView()
            }
        }.padding()
    }
}

/// Per-session assent (spec 6.3).
struct AssentView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(spacing: 16) {
            Text(NurseCopy.assentPrompt).font(.title3)
            Button(NurseCopy.buttonAgree) { c.giveAssent() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("assent-agree-button")
            Button(NurseCopy.buttonDecline) { c.declineAssent() }
                .accessibilityIdentifier("assent-decline-button")
        }.padding()
    }
}

/// Terminal screens: patient declined / come back later.
struct TerminalMessageView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(spacing: 16) {
            if let m = c.blockingMessage { Text(m).font(.title3).accessibilityIdentifier("terminal-message") }
            Button(NurseCopy.buttonNextPatient) { c.reset() }
        }.padding()
    }
}