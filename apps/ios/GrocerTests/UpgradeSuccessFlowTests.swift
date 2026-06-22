import XCTest
@testable import Grocer

/// Covers the upgrade success flow that auto-closes the confirmation overlay
/// after a checkout grants Grocer Pro (GRO-23 / GRO-24).
///
/// The visible part of the flow is a timed overlay in a SwiftUI view, which is
/// awkward to drive in a unit test. The behaviour is split into two checks:
/// the `SubscriptionStore` flag transitions that gate the overlay (exercised
/// directly), and source guardrails that pin the wiring + auto-dismiss so a
/// refactor can't silently leave the sheet stuck on screen.
final class UpgradeSuccessFlowTests: XCTestCase {

    // MARK: - Flag transitions

    @MainActor
    func testUpgradeFlagStartsClearedAndRoundTrips() {
        let store = SubscriptionStore()
        XCTAssertFalse(store.didJustUpgradeToPro, "Fresh store must not claim a just-completed upgrade")

        store.markJustUpgradedToPro()
        XCTAssertTrue(store.didJustUpgradeToPro, "Granting Pro should raise the confirmation flag")

        store.clearJustUpgradedToPro()
        XCTAssertFalse(store.didJustUpgradeToPro, "Dismissing the overlay should clear the flag")
    }

    @MainActor
    func testClearingUpgradeFlagIsIdempotent() {
        let store = SubscriptionStore()
        store.markJustUpgradedToPro()

        store.clearJustUpgradedToPro()
        store.clearJustUpgradedToPro()

        XCTAssertFalse(store.didJustUpgradeToPro)
    }

    // MARK: - Source guardrails

    /// The paywall must flag the upgrade after a completed web checkout so the
    /// root overlay has something to react to.
    func testPaywallMarksUpgradeAfterCompletedCheckout() throws {
        let paywall = try source("Grocer/Views/GrocerProPaywallView.swift")
        XCTAssertTrue(
            paywall.contains("subscriptions.markJustUpgradedToPro()"),
            "Paywall must mark the upgrade so RootView can show the success confirmation"
        )
    }

    /// RootView must render the confirmation gated on the flag and clear it when
    /// the overlay reports it has finished.
    func testRootViewWiresUpgradeOverlayToFlag() throws {
        let root = try source("Grocer/Views/RootView.swift")
        XCTAssertTrue(root.contains("if subscriptions.didJustUpgradeToPro"),
                      "Overlay must be gated on didJustUpgradeToPro")
        XCTAssertTrue(root.contains("UpgradedToProOverlay"),
                      "RootView must present the upgrade confirmation overlay")
        XCTAssertTrue(root.contains("subscriptions.clearJustUpgradedToPro()"),
                      "Overlay completion must clear the flag so it can't reappear")
    }

    /// The overlay must auto-dismiss on success rather than waiting for a tap —
    /// it schedules `onFinished()` after a short sleep in `onAppear`.
    func testUpgradeOverlayAutoDismisses() throws {
        let root = try source("Grocer/Views/RootView.swift")
        let overlay = try excerpt(
            root,
            from: "private struct UpgradedToProOverlay",
            to: "// MARK: - Joined Group Sheet"
        )
        XCTAssertTrue(overlay.contains(".onAppear"),
                      "Auto-dismiss must be kicked off when the overlay appears")
        XCTAssertTrue(overlay.contains("Task.sleep"),
                      "Overlay must wait briefly before closing")
        XCTAssertTrue(overlay.contains("onFinished()"),
                      "Overlay must call onFinished() to auto-close on success")
    }
}
