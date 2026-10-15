import SwiftUI
import DengueCaptureCore

/// Per-session upload status. Only the masked study ID (••417) is shown; no other patient identifier.
/// Held hand-offs (saved on the phone, not yet queued) can only be removed here, by an explicit nurse delete.
/// Unreadable held records are listed as such and can be deleted too.
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
                            if !h.isUnreadable { Text(h.maskedCode).font(.headline) }
                            Text(h.isUnreadable ? NurseCopy.heldUnreadable : NurseCopy.heldWaiting)
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
                let target = pendingDelete
                pendingDelete = nil
                Task.detached(priority: .userInitiated) {
                    if let target { CaptureStorage.shared?.discard(target.sessionId, reason: .nurseDiscard) }
                    let summaries = CaptureStorage.shared?.heldSummaries() ?? []
                    await MainActor.run { held = summaries }
                }
            }
        }
    }

    /// Retry and listing decrypt every held record: kept off the main thread.
    private func reload() {
        Task.detached(priority: .userInitiated) {
            CaptureStorage.shared?.retryHeld()
            let summaries = CaptureStorage.shared?.heldSummaries() ?? []
            await MainActor.run { held = summaries }
        }
    }
}
