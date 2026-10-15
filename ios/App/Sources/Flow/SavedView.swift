import SwiftUI
import DengueCaptureCore

struct SavedView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        let presented = ExperimentalPulsePresenter.present(
            c.experimental ?? ExperimentalResponse(enabled: false, items: []), monitorHR: c.flow.monitorHR)
        VStack(alignment: .leading, spacing: 16) {
            Text(c.flow.savedMessage).font(.title2).accessibilityIdentifier("saved-message")
            // Monitor value first and larger; experimental values only via the presenter, below it.
            if let monitor = presented.monitor {
                Text(monitor).font(.largeTitle).bold().accessibilityIdentifier("monitor-hr")
            }
            if !presented.experimental.isEmpty {
                ForEach(presented.experimental, id: \.text) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(v.label).font(.caption2).padding(4)
                            .background(Color.gray.opacity(0.3)).clipShape(Capsule())
                        Text(v.text).font(.callout).foregroundColor(.gray)
                        Text(v.notice).font(.footnote)
                    }.accessibilityIdentifier("experimental-section")
                }
            }
            Text(NurseCopy.disinfectReminder).font(.footnote)
            Text(NurseCopy.offlineQueued).font(.footnote)
            Button(NurseCopy.buttonNextPatient) { c.reset() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("next-patient-button")
        }.padding()
    }
}