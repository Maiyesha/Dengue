import SwiftUI
import DengueCaptureCore

struct QualityResultView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = c.flow.statusMessage {
                Text(status).font(.title3).accessibilityIdentifier("status-message")
            }
            ForEach(c.flow.steps, id: \.step) { cfg in
                let status = c.flow.stepStatus(cfg.step)
                VStack(alignment: .leading) {
                    Text(cfg.step.nurseName).font(.headline)
                    Text(status.text)
                    if status != .passed {
                        ForEach(c.flow.stepReasons(cfg.step), id: \.self) { Text($0.nurseInstruction) }
                    }
                }
            }
            Button(NurseCopy.buttonContinue) { c.continueFromQuality() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("quality-continue")
        }.padding()
    }
}