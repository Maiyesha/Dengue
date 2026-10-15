import SwiftUI
import DengueCaptureCore

struct FlowRootView: View {
    @StateObject private var c = FlowCoordinator.make()
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