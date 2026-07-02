import PostHog
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
    /// Set when the page fails to load (most commonly no internet). Swaps the
    /// blank web view for a friendly, retryable error state.
    @State private var loadFailed = false
    /// Bumping this asks the `WebView` to reload — used by the Try Again button.
    @State private var reloadToken = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: Self.pageBackground).ignoresSafeArea()

            // Render the web content edge-to-edge, including under the top
            // safe area, so the page fills the whole screen.
            WebView(
                url: url,
                reloadToken: reloadToken,
                backgroundColor: Self.pageBackground,
                onLoadingChange: { loading in
                    isLoading = loading
                },
                onLoadError: {
                    handleLoadError()
                },
                onCheckoutSuccess: {
                    checkoutDidComplete()
                },
                onCheckoutCancel: {
                    close()
                }
            )
                // Keep the (blank) web view hidden behind the error state so the
                // user never sees WebKit's default failure page.
                .opacity(isLoading || loadFailed ? 0 : 1)
                .ignoresSafeArea()

            if loadFailed {
                errorState
            } else if isLoading {
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
        .postHogScreenView("Web Checkout")
    }

    /// Friendly fallback shown when the checkout page can't load — typically
    /// because the device is offline. Offers a retry instead of a blank screen.
    private var errorState: some View {
        VStack(spacing: 16) {
            FAImage("wifi.slash", size: 40)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Couldn\u{2019}t load checkout")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Check your internet connection and try again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                retry()
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func handleLoadError() {
        isLoading = false
        loadFailed = true
    }

    private func retry() {
        Haptics.selection()
        loadFailed = false
        isLoading = true
        reloadToken += 1
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            FAImage("xmark", relativeTo: .subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(GlassCircleBackground())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("Close")
    }

    /// Checkout succeeded: skip the web success page entirely and dismiss the
    /// sheet right away. The hosting paywall refreshes the entitlement (and
    /// shows the "You've upgraded to Pro!" confirmation) on dismissal.
    private func checkoutDidComplete() {
        guard !didCompleteCheckout, !didCloseCheckout else { return }
        didCompleteCheckout = true
        didCloseCheckout = true
        Haptics.selection()
        onClose(true)
        dismiss()
    }

    private func close() {
        guard !didCloseCheckout else { return }
        didCloseCheckout = true
        Haptics.selection()
        Task {
            // Force a cache-bypassing fetch in case checkout completed (e.g. the
            // user dismissed the success page manually) — the Stripe webhook
            // grants the entitlement server-side, so the cached snapshot is stale.
            await subscriptions.refresh(force: didCompleteCheckout)
            onClose(didCompleteCheckout)
            dismiss()
        }
    }
}

/// Lightweight `WKWebView` wrapper. Intentionally exposes no navigation
/// controls — the hosting view owns dismissal.
private struct WebView: UIViewRepresentable {
    let url: URL
    var reloadToken: Int = 0
    var backgroundColor: UIColor = .white
    var onLoadingChange: (Bool) -> Void = { _ in }
    var onLoadError: () -> Void = {}
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
        context.coordinator.reloadToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Reload only when the host bumps the token (Try Again). The initial
        // load happens in `makeUIView`; auto-reloading whenever `url == nil`
        // would loop forever after a failed load (which leaves `url` nil).
        guard context.coordinator.reloadToken != reloadToken else { return }
        context.coordinator.reloadToken = reloadToken
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLoadingChange: onLoadingChange,
            onLoadError: onLoadError,
            onCheckoutSuccess: onCheckoutSuccess,
            onCheckoutCancel: onCheckoutCancel
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var reloadToken = 0
        private let onLoadingChange: (Bool) -> Void
        private let onLoadError: () -> Void
        private let onCheckoutSuccess: () -> Void
        private let onCheckoutCancel: () -> Void

        init(onLoadingChange: @escaping (Bool) -> Void,
             onLoadError: @escaping () -> Void,
             onCheckoutSuccess: @escaping () -> Void,
             onCheckoutCancel: @escaping () -> Void) {
            self.onLoadingChange = onLoadingChange
            self.onLoadError = onLoadError
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
                // Cancel the load so the web success page never paints — the
                // host closes the sheet and shows a native confirmation instead.
                onCheckoutSuccess()
                decisionHandler(.cancel)
                return
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
            reportIfRealFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
            reportIfRealFailure(error)
        }

        /// Surfaces genuine load failures (e.g. no internet) to the host, but
        /// ignores the cancellations WebKit reports when we `.cancel` the
        /// success/cancel redirects ourselves.
        private func reportIfRealFailure(_ error: Error) {
            guard !Self.isCancellation(error) else { return }
            onLoadError()
        }

        private static func isCancellation(_ error: Error) -> Bool {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return true
            }
            // WebKitErrorDomain / WebKitErrorFrameLoadInterruptedByPolicyChange:
            // raised when `decidePolicyFor` cancels our success/cancel redirect.
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
                return true
            }
            return false
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
