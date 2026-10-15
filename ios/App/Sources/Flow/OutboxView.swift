import SwiftUI
import DengueCaptureCore

/// Per-session upload status. No patient identifiers are shown here.
struct OutboxView: View {
    var body: some View {
        BannerScreen {
            VStack {
                Text(NurseCopy.titleOutbox).font(.title2)
                Text(NurseCopy.outboxEmpty)  // Task 12 binds this to Outbox items.
            }.padding()
        }
    }
}