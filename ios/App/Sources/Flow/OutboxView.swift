import SwiftUI
import DengueCaptureCore

/// Per-session upload status. Only the masked study ID (••417) is shown; no other patient identifier.
/// Held hand-offs (saved on the phone, not yet queued) can only be removed here, by an explicit nurse delete.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
struct OutboxView: View {
    @State private var held: [HeldHandoffSummary] = []
    @State private var pendingDelete: HeldHandoffSummary?

    var body: some View {
        BannerScreen {
            VStack(alignment: .leading, spacing: 12) {
                Text(NurseCopy.titleOutbox).font(.title2)
                if held.isEmpty {
                    Text(NurseCopy.outboxEmpty)
                }
                ForEach(held, id: \.sessionId) { h in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(h.maskedCode).font(.headline)
                            Text(NurseCopy.heldWaiting)
                        }
                        Spacer()
                        if !h.isOpen {
                            Button(NurseCopy.buttonDeleteRecording, role: .destructive) { pendingDelete = h }
                                .accessibilityIdentifier("held-delete")
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear(perform: reload)
        .confirmationDialog(NurseCopy.confirmDeleteRecording,
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(NurseCopy.buttonDeleteRecording, role: .destructive) {
                if let h = pendingDelete { CaptureStorage.shared?.discard(h.sessionId, reason: .nurseDiscard) }
                pendingDelete = nil
                reload()
            }
        }
    }

    private func reload() {
        CaptureStorage.shared?.retryHeld()
        held = CaptureStorage.shared?.heldSummaries() ?? []
    }
}
