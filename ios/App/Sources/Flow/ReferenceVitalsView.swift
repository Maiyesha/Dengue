import SwiftUI
import DengueCaptureCore

struct ReferenceVitalsView: View {
    @ObservedObject var c: FlowCoordinator
    @State private var hr = ""
    @State private var spo2 = ""
    @State private var sbp = ""
    @State private var dbp = ""
    @State private var temp = ""
    @State private var rr = ""
    @State private var crt = ""
    @State private var skipReason: VitalsSkipReason?

    var body: some View {
        Form {
            field(NurseCopy.labelHeartRate, $hr, id: "vitals-hr")
            field(NurseCopy.labelSpO2, $spo2)
            field(NurseCopy.labelSystolic, $sbp)
            field(NurseCopy.labelDiastolic, $dbp)
            field(NurseCopy.labelTemperature, $temp)
            field(NurseCopy.labelRespRate, $rr)
            field(NurseCopy.labelCapRefill, $crt)
            Button(NurseCopy.buttonContinue) {
                c.enterVitals(ReferenceVitalsInput(
                    hr: Int(hr), spo2: Int(spo2), sbp: Int(sbp), dbp: Int(dbp),
                    tempC: Double(temp), rr: Int(rr), crtS: Double(crt)))
            }.accessibilityIdentifier("vitals-continue")
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

    private func field(_ label: String, _ text: Binding<String>, id: String? = nil) -> some View {
        TextField(label, text: text).keyboardType(.decimalPad).accessibilityIdentifier(id ?? label)
    }
}