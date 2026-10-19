import SwiftUI
import DengueCaptureCore

struct PatientSelectView: View {
    @ObservedObject var c: FlowCoordinator
    @State private var code = ""
    @State private var bed = ""
    @State private var showOutbox = false
    var body: some View {
        VStack(spacing: 16) {
            TextField(NurseCopy.labelStudyID, text: $code)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("study-id-field")
            TextField(NurseCopy.labelBed, text: $bed).textFieldStyle(.roundedBorder)
            Button(NurseCopy.buttonLookUp) { c.selectPatient(code: code, bed: bed.isEmpty ? nil : bed) }
                .buttonStyle(.borderedProminent).disabled(code.isEmpty)
                .accessibilityIdentifier("lookup-button")
            // I2: uploads, needs-repeat sessions and the 7-day warnings are reachable from the start screen.
            Button(NurseCopy.buttonOutbox) { showOutbox = true }.accessibilityIdentifier("outbox-button")
        }
        .padding()
        .sheet(isPresented: $showOutbox) { OutboxView() }
    }
}
