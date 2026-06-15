import SwiftUI
import WebKit

/// Minimal in-app browser used for off-platform (Stripe) checkout. Renders a
/// single web page with no chrome — no URL bar, no navigation — just a close
/// button in the top-left corner. The background matches the app's default
/// theme so the view feels native while the page loads.
struct WebCheckoutView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground).ignoresSafeArea()

            WebView(url: url)
                .ignoresSafeArea(edges: .bottom)

            Button {
                Haptics.selection()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Close")
            .padding(.leading, 16)
            .padding(.top, 8)
        }
    }
}

/// Lightweight `WKWebView` wrapper. Intentionally exposes no navigation
/// controls — the hosting view owns dismissal.
private struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
