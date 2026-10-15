import SwiftUI
import DengueCaptureCore

struct QualityResultView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(CaptureProtocol.phaseADefault.steps, id: \.step) { cfg in
                let reasons = c.flow.stepReasons(cfg.step)
                VStack(alignment: .leading) {
                    Text(name(cfg.step)).font(.headline)
                    if reasons.isEmpty {
                        Text(NurseCopy.stepPassed)
                    } else {
                        Text(NurseCopy.stepRecordAgain)
                        ForEach(reasons, id: \.self) { Text($0.nurseInstruction) }
                    }
                }
            }
            Button(NurseCopy.buttonContinue) { c.continueFromQuality() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("quality-continue")
        }.padding()
    }

    private func name(_ s: CaptureStep) -> String {
        s == .neutralFace ? NurseCopy.stepNameFace : NurseCopy.stepNameFingertip
    }
}