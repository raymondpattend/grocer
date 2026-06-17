import SwiftUI
import WebKit

/// Minimal in-app browser used for off-platform (Stripe) checkout. Renders a
/// single web page with no chrome — no URL bar, no navigation. The background
/// matches the app's default theme so the view feels native while the page
/// loads.
struct WebCheckoutView: View {
    let url: URL
    var onClose: (Bool) -> Void = { _ in }

    /// Matches the checkout page's `--page` background in both light and dark
    /// so the safe areas and the load-time placeholder blend into the web
    /// content. Adapts with the system appearance.
    private static let pageBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x0b / 255.0, green: 0x0b / 255.0, blue: 0x0c / 255.0, alpha: 1)
            : UIColor(red: 0xf6 / 255.0, green: 0xf6 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
    }

    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    @State private var didCompleteCheckout = false
    @State private var didCloseCheckout = false
    @State private var isLoading = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: Self.pageBackground).ignoresSafeArea()

            // Render the web content edge-to-edge, including under the top
            // safe area, so the page fills the whole screen.
            WebView(
                url: url,
                backgroundColor: Self.pageBackground,
                onLoadingChange: { loading in
                    isLoading = loading
                },
                onCheckoutSuccess: {
                    checkoutDidComplete()
                },
                onCheckoutCancel: {
                    close()
                }
            )
                .opacity(isLoading ? 0 : 1)
                .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Always-on liquid-glass close button in the top-left corner so the
            // user can dismiss the sheet at any point during checkout.
            closeButton
                .padding(.leading, 16)
                .padding(.top, 8)
        }
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(GlassCircleBackground())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("Close")
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
        guard !didCloseCheckout else { return }
        didCloseCheckout = true
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
    var backgroundColor: UIColor = .white
    var onLoadingChange: (Bool) -> Void = { _ in }
    let onCheckoutSuccess: () -> Void
    let onCheckoutCancel: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        // A plain configuration with no script message handlers keeps Apple Pay
        // (the page's Express Checkout Element) available inside WKWebView.
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        // No forced appearance — the page's `prefers-color-scheme` follows the
        // system so the checkout themes light/dark alongside the rest of the app.
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLoadingChange: onLoadingChange,
            onCheckoutSuccess: onCheckoutSuccess,
            onCheckoutCancel: onCheckoutCancel
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoadingChange: (Bool) -> Void
        private let onCheckoutSuccess: () -> Void
        private let onCheckoutCancel: () -> Void

        init(onLoadingChange: @escaping (Bool) -> Void,
             onCheckoutSuccess: @escaping () -> Void,
             onCheckoutCancel: @escaping () -> Void) {
            self.onLoadingChange = onLoadingChange
            self.onCheckoutSuccess = onCheckoutSuccess
            self.onCheckoutCancel = onCheckoutCancel
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            if Self.isCheckoutCancel(url) {
                onCheckoutCancel()
                decisionHandler(.cancel)
                return
            }

            if Self.isCheckoutSuccess(url) {
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

        private static func isCheckoutCancel(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.path.contains("/checkout/cancelled")
        }
    }
}

/// Liquid glass circular background on iOS 26+, with a material fallback.
private struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}
