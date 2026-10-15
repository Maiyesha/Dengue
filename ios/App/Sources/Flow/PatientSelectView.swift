import SwiftUI
import DengueCaptureCore

struct PatientSelectView: View {
    @ObservedObject var c: FlowCoordinator
    @State private var code = ""
    @State private var bed = ""
    var body: some View {
        VStack(spacing: 16) {
            TextField(NurseCopy.labelStudyID, text: $code)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("study-id-field")
            TextField(NurseCopy.labelBed, text: $bed).textFieldStyle(.roundedBorder)
            Button(NurseCopy.buttonLookUp) { c.selectPatient(code: code, bed: bed.isEmpty ? nil : bed) }
                .buttonStyle(.borderedProminent).disabled(code.isEmpty)
                .accessibilityIdentifier("lookup-button")
        }.padding()
    }
}