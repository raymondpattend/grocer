import SwiftUI
import WebKit

/// Minimal in-app browser used for off-platform (Stripe) checkout. Renders a
/// single web page with no chrome — no URL bar, no navigation. The background
/// matches the app's default theme so the view feels native while the page
/// loads.
struct WebCheckoutView: View {
    let url: URL
    var onClose: (Bool) -> Void = { _ in }

    private static let checkoutSafeAreaTop = Color(
        red: 104.0 / 255.0,
        green: 205.0 / 255.0,
        blue: 102.0 / 255.0
    )

    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    @State private var didCompleteCheckout = false
    @State private var isLoading = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Self.checkoutSafeAreaTop
                    .frame(height: 0)
                    .ignoresSafeArea(edges: .top)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            // Fill under the home indicator while leaving the top safe area
            // visible for Stripe's hosted checkout chrome.
            WebView(url: url, onLoadingChange: { loading in
                isLoading = loading
            }) {
                checkoutDidComplete()
            }
                .opacity(isLoading ? 0 : 1)
                .ignoresSafeArea(edges: .bottom)

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

//            Button {
//                close()
//            } label: {
//                Image(systemName: "xmark")
//                    .font(.system(size: 14, weight: .bold))
//                    .foregroundStyle(Color.secondary)
//                    .frame(width: 34, height: 34)
//                    .background(Color.primary.opacity(0.06), in: Circle())
//            }
//            .accessibilityLabel("Close")
//            .padding(.leading, 16)
//            .padding(.top, 8)
        }
        // Checkout always renders in light theme regardless of the device's
        // appearance, so the Stripe page styling stays consistent.
        .preferredColorScheme(.light)
    }

    private func checkoutDidComplete() {
        guard !didCompleteCheckout else { return }
        didCompleteCheckout = true
        Task {
            await subscriptions.refresh()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await subscriptions.refresh()
        }
    }

    private func close() {
        Haptics.selection()
        Task {
            await subscriptions.refresh()
            onClose(didCompleteCheckout)
            dismiss()
        }
    }
}

/// Lightweight `WKWebView` wrapper. Intentionally exposes no navigation
/// controls — the hosting view owns dismissal.
private struct WebView: UIViewRepresentable {
    let url: URL
    var onLoadingChange: (Bool) -> Void = { _ in }
    let onCheckoutSuccess: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        // Force light appearance so the page's `prefers-color-scheme` resolves
        // light to match the rest of the forced-light checkout flow.
        webView.overrideUserInterfaceStyle = .light
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadingChange: onLoadingChange, onCheckoutSuccess: onCheckoutSuccess)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoadingChange: (Bool) -> Void
        private let onCheckoutSuccess: () -> Void

        init(onLoadingChange: @escaping (Bool) -> Void,
             onCheckoutSuccess: @escaping () -> Void) {
            self.onLoadingChange = onLoadingChange
            self.onCheckoutSuccess = onCheckoutSuccess
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if Self.isCheckoutSuccess(navigationAction.request.url) {
                onCheckoutSuccess()
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
            if Self.isCheckoutSuccess(webView.url) {
                onCheckoutSuccess()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }

        private static func isCheckoutSuccess(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.path.contains("/checkout/success")
        }
    }
}
