import SwiftUI
import DengueCaptureCore

/// Uploads screen (I2/I3). Only the masked study ID (••417) is shown; no other patient identifier.
/// - Sessions the upload engine owns, with live status (queued / sending / sent / needs repeat / finished).
///   A needs-repeat session offers "Record again" (a repeat flow for the listed steps, ending in
///   `enqueueRecapture`) while its 2 h window is open.
/// - Held hand-offs (saved on the phone, not yet queued), removable only by an explicit nurse delete;
///   unreadable held records are listed as such and can be deleted too.
/// - Anything not fully sent 7 days after capture carries the unsent warning (spec 12).
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
struct OutboxView: View {
    @State private var held: [HeldHandoffSummary] = []
    @State private var sessions: [SessionSummary] = []
    @State private var pendingDelete: HeldHandoffSummary?
    @State private var repeatRequest: RepeatRequest?
    /// R-1: the last upload attempt met a captive portal / filtering network (nothing is deleted).
    @State private var networkRestricted = false
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        BannerScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(NurseCopy.titleOutbox).font(.title2)
                    if networkRestricted {
                        Text(NurseCopy.networkNeedsSignIn).foregroundColor(.orange)
                            .accessibilityIdentifier("network-needs-sign-in")
                    }
                    if held.isEmpty && sessions.isEmpty {
                        Text(NurseCopy.outboxEmpty)
                    }
                    ForEach(sessions, id: \.sessionId) { s in sessionRow(s) }
                    ForEach(held, id: \.slotId) { h in heldRow(h) }   // round 4: a repeat hold is its own row
                }
                .padding()
            }
        }
        .signInOverlay()   // R-2
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reloadSessions() }
        .fullScreenCover(item: $repeatRequest, onDismiss: reload) { r in RepeatFlowView(request: r) }
        .confirmationDialog(NurseCopy.confirmDeleteRecording,
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(NurseCopy.buttonDeleteRecording, role: .destructive) {
                let target = pendingDelete
                pendingDelete = nil
                Task.detached(priority: .userInitiated) {
                    if let target {
                        CaptureStorage.shared?.discard(target.sessionId, reason: .nurseDiscard, repeatHold: target.isRepeat)
                    }
                    let summaries = CaptureStorage.shared?.heldSummaries() ?? []
                    await MainActor.run { held = summaries }
                }
            }
        }
    }

    @ViewBuilder private func sessionRow(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.maskedCode).font(.headline)
            Text(s.status.text(maskedCode: s.maskedCode)).accessibilityIdentifier("session-status")
            if s.unsentTooLong {
                Text(NurseCopy.unsentWarning).foregroundColor(.orange).accessibilityIdentifier("unsent-warning")
            }
            if case .needsRepeat(let steps, let reasons) = s.status {
                Button(NurseCopy.buttonRecordAgain) {
                    repeatRequest = RepeatRequest(sessionId: s.sessionId, maskedCode: s.maskedCode, steps: steps,
                                                  reasons: reasons)
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("record-again")
            }
        }
    }

    @ViewBuilder private func heldRow(_ h: HeldHandoffSummary) -> some View {
        HStack {
            VStack(alignment: .leading) {
                if !h.isUnreadable { Text(h.maskedCode).font(.headline) }
                if !h.isInterruptedOnly {
                    Text(h.isUnreadable ? NurseCopy.heldUnreadable : NurseCopy.heldWaiting)
                }
                if h.interruptedClipCount > 0 {   // R-2: kept on the phone, never uploaded
                    Text(NurseCopy.interruptedClipKept).accessibilityIdentifier("interrupted-clip")
                }
                if h.unsentTooLong(now: Date()) {
                    Text(NurseCopy.unsentWarning).foregroundColor(.orange).accessibilityIdentifier("unsent-warning")
                }
            }
            Spacer()
            if !h.isOpen {
                Button(NurseCopy.buttonDeleteRecording, role: .destructive) { pendingDelete = h }
                    .accessibilityIdentifier("held-delete")
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
        reloadSessions()
    }

    private func reloadSessions() {
        Task.detached(priority: .userInitiated) {
            let engine = UploadCoordinator.shared?.engine
            engine?.expireRepeatWindows()
            let list = engine?.sessionSummaries() ?? []
            let restricted = engine?.isNetworkRestricted ?? false
            await MainActor.run {
                sessions = list.reversed()   // newest first
                networkRestricted = restricted
            }
        }
    }
}
