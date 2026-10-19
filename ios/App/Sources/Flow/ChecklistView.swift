import SwiftUI
import DengueCaptureCore

struct ChecklistView: View {
    @ObservedObject var c: FlowCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(FlowChecklistItem.allCases, id: \.self) { item in
                Toggle(item.text, isOn: Binding(
                    get: { c.flow.checklist.contains(item) },
                    set: { c.toggle(item, $0) }))
                    .accessibilityIdentifier("check-\(item)")
            }
            Button(NurseCopy.buttonContinue) { c.proceedFromChecklist() }
                .buttonStyle(.borderedProminent).disabled(!c.flow.checklistComplete)
                .accessibilityIdentifier("checklist-continue")
            Button(NurseCopy.comeBackLater) { c.comeBackLater() }
        }.padding()
    }
}