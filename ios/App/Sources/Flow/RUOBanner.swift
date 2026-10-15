import SwiftUI
import DengueCaptureCore

struct RUOBanner: View {
    var body: some View {
        Text(NurseCopy.banner)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.2))
            .accessibilityIdentifier("ruo-banner")
    }
}

/// Wraps a screen so the banner is attached to every one of them (spec section 10).
struct BannerScreen<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            RUOBanner()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct BlockingMessage: View {
    let text: String
    var body: some View {
        Text(text).font(.headline).foregroundColor(.red).padding()
            .accessibilityIdentifier("blocking-message")
    }
}