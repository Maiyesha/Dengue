import SwiftUI
import DengueCaptureCore

/// Capture blocked (low storage / battery / camera). No Start or Pause; Done and Uploads only.
struct BlockedView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(spacing: 16) {
            if let m = c.blockingMessage { BlockingMessage(text: m) }
            Button(NurseCopy.buttonOutbox) { c.showOutbox = true }.accessibilityIdentifier("outbox-button")
            Button(NurseCopy.buttonDone) { c.reset() }.accessibilityIdentifier("blocked-done-button")
        }
        .padding()
        .sheet(isPresented: $c.showOutbox) { OutboxView() }
    }
}