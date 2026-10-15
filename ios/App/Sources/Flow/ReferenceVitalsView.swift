import SwiftUI
import DengueCaptureCore

struct ReferenceVitalsView: View {
    @ObservedObject var c: FlowCoordinator
    @State private var entries: [VitalField: VitalEntry] = [:]
    @State private var skipReason: VitalsSkipReason?

    var body: some View {
        Form {
            ForEach(VitalField.allCases, id: \.self) { field in
                Section(field.label) {
                    TextField(field.label, text: binding(field).text)
                        .keyboardType(.decimalPad).accessibilityIdentifier("vitals-\(field)")
                    Picker(NurseCopy.labelSource, selection: binding(field).source) {
                        ForEach(VitalSourceDevice.allCases, id: \.self) { Text($0.text).tag($0) }
                    }
                    DatePicker(NurseCopy.labelMeasuredAt, selection: measured(field))
                    if let issue = c.flow.vitalIssues[field] {
                        Text(issue.text).foregroundColor(.red).accessibilityIdentifier("vitals-issue-\(field)")
                        if issue == .outOfRange {
                            Toggle(NurseCopy.vitalConfirm, isOn: binding(field).confirmed)
                        }
                    }
                }
            }
            Button(NurseCopy.buttonContinue) { c.submitVitals(entries) }
                .accessibilityIdentifier("vitals-continue")
            Section(NurseCopy.labelSkipReason) {
                Picker(NurseCopy.labelSkipReason, selection: $skipReason) {
                    Text(NurseCopy.buttonSkip).tag(VitalsSkipReason?.none)
                    ForEach(VitalsSkipReason.allCases, id: \.self) { Text($0.text).tag(Optional($0)) }
                }.accessibilityIdentifier("skip-reason-picker")
                Button(NurseCopy.buttonSkip) { c.skipVitals(skipReason) }
                    .disabled(skipReason == nil).accessibilityIdentifier("vitals-skip")
            }
        }
    }

    private func binding(_ f: VitalField) -> Binding<VitalEntry> {
        Binding(get: { entries[f] ?? VitalEntry(text: "") }, set: { entries[f] = $0 })
    }

    private func measured(_ f: VitalField) -> Binding<Date> {
        Binding(get: { entries[f]?.measuredAt ?? Date() },
                set: { var e = entries[f] ?? VitalEntry(text: ""); e.measuredAt = $0; entries[f] = e })
    }
}