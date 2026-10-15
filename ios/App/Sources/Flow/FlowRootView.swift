import SwiftUI
import DengueCaptureCore

struct FlowRootView: View {
    @StateObject private var c = FlowCoordinator.make()
    var body: some View { FlowScreensView(c: c) }
}

/// The flow's screens for one coordinator (main flow, or a repeat flow presented from Uploads).
struct FlowScreensView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        BannerScreen {
            switch c.screen {
            case .patientSelect: PatientSelectView(c: c)
            case .consent: ConsentView(c: c)
            case .assent: AssentView(c: c)
            case .patientDeclined, .comeBackLater: TerminalMessageView(c: c)
            case .checklist: ChecklistView(c: c)
            case .referenceVitals: NavigationStack { ReferenceVitalsView(c: c) }
            case .capture: CaptureStepView(c: c)
            case .blocked: BlockedView(c: c)
            case .qualityResult: QualityResultView(c: c)
            case .saved: SavedView(c: c)
            }
        }
    }
}

/// I2: "Record again" for a server-requested repeat. Ends (and dismisses) when the nurse taps Next patient.
///
/// UNVERIFIED: written without a macOS toolchain; compiled and run by ios.yml.
struct RepeatFlowView: View {
    @StateObject private var c: FlowCoordinator
    @Environment(\.dismiss) private var dismiss
    init(request: RepeatRequest) { _c = StateObject(wrappedValue: FlowCoordinator.makeRepeat(request)) }
    var body: some View {
        FlowScreensView(c: c)
            .onChange(of: c.revision) { _, _ in if c.screen == .patientSelect { dismiss() } }
            .signInOverlay()   // R-2: sign-in covers the repeat flow; it is never dismissed by auth state
    }
}
