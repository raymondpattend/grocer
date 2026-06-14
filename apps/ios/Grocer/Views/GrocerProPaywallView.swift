import RevenueCat
import SwiftUI

/// Full-screen Grocer Pro paywall. Renders RevenueCat offerings with a custom,
/// branded layout (hero, plan picker, feature list, testimonials, sticky CTA).
///
/// Pricing, trial length, and the package list all come straight from
/// RevenueCat so the UI always reflects what's configured in the dashboard.
struct GrocerProPaywallView: View {
    let context: GrocerProPaywallContext

    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var selectedPackageID: String?
    @State private var showAllPlans = false
    @State private var infoMessage: String?

    private let termsURL = URL(string: "https://grocer.narro.org/terms")
    private let privacyURL = URL(string: "https://grocer.narro.org/privacy")

    private var copy: GrocerProPaywallCopy {
        subscriptions.paywallCopy(for: context)
    }

    init(context: GrocerProPaywallContext = .general) {
        self.context = context
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            if subscriptions.availablePackages.isEmpty {
                loadingState
            } else {
                content
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .tint(Palette.accent)
        .task {
            if subscriptions.availablePackages.isEmpty {
                await subscriptions.refresh()
            }
        }
        .onAppear(perform: selectRecommendedIfNeeded)
        .onChange(of: subscriptions.availablePackages.map(\.identifier)) { _, _ in
            selectRecommendedIfNeeded()
        }
        .onChange(of: subscriptions.hasGrocerPro) { _, hasPro in
            if hasPro { dismiss() }
        }
        .alert("Purchase Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) { subscriptions.clearError() }
        } message: {
            Text(subscriptions.lastErrorMessage ?? "")
        }
        .alert("Restore Purchases", isPresented: infoPresented) {
            Button("OK", role: .cancel) { infoMessage = nil }
        } message: {
            Text(infoMessage ?? "")
        }
    }

    // MARK: - Scroll content

    private var content: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                headline
                planPicker
                featureList
                testimonials
                legal
                footerLinks
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 140)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Palette.accent)
            Text("Loading plans…")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: restorePurchases) {
                if subscriptions.isRestoring {
                    ProgressView().tint(Palette.accent)
                } else {
                    Text("Restore")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .disabled(subscriptions.isRestoring)

            Spacer()

            Button {
                Haptics.selection()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Palette.surface, in: Circle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Palette.background)
    }

    // MARK: - Hero

    private var hero: some View {
        PaywallHero()
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    private var headline: some View {
        VStack(spacing: 12) {
            Text(copy.headline)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.primaryText)

            Text(copy.subtitle)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Plan picker

    private var planPicker: some View {
        VStack(spacing: 14) {
            ForEach(visiblePackages, id: \.identifier) { package in
                let plan = display(for: package)
                PlanCard(
                    plan: plan,
                    isSelected: selectedPackageID == package.identifier
                ) {
                    Haptics.selection()
                    withAnimation(.snappy) { selectedPackageID = package.identifier }
                }
            }

            if orderedPackages.count > visiblePackages.count {
                Button {
                    Haptics.selection()
                    withAnimation(.snappy) { showAllPlans = true }
                } label: {
                    Text("Show all plans")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Features

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("More Features")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(Palette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Self.features) { feature in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: feature.icon)
                        .font(.title3)
                        .foregroundStyle(Palette.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(feature.title)
                            .font(.headline)
                            .foregroundStyle(Palette.primaryText)
                        Text(feature.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Testimonials

    private var testimonials: some View {
        VStack(spacing: 14) {
            ForEach(Self.quotes) { quote in
                TestimonialBubble(text: quote.text, name: quote.name, emoji: quote.emoji)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Legal + footer

    private var legal: some View {
        VStack(spacing: 14) {
            Text("Upon confirmation, the payment will be charged to your Apple Account. Your subscription automatically renews unless it is cancelled at least 24 hours before the end of the current period.")
            Text("After purchase, you can manage and turn off auto-renewal in your Apple Account settings.")
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondaryText.opacity(0.7))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var footerLinks: some View {
        HStack(spacing: 22) {
            footerLink(String(localized: "Restore"), action: restorePurchases)
            footerLink(String(localized: "Terms")) { if let termsURL { openURL(termsURL) } }
            footerLink(String(localized: "Privacy")) { if let privacyURL { openURL(privacyURL) } }
            footerLink(String(localized: "Redeem"), action: redeemCode)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.accent)
        }
    }

    // MARK: - Floating glass CTA

    @ViewBuilder
    private var bottomBar: some View {
        let stack = VStack(spacing: 12) {
            Text(ctaSubtitle ?? " ")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.secondaryText)
                .contentTransition(.numericText())
            ctaButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)

        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 18) {
                    stack.glassEffect(.regular, in: .rect(cornerRadius: 30))
                }
            } else {
                stack
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(Palette.hairline)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var ctaButton: some View {
        let label = ZStack {
            if subscriptions.isPurchasing {
                ProgressView().tint(Palette.primaryText)
            } else {
                Text(ctaTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)

        Button(action: purchaseSelected) {
            if #available(iOS 26.0, *) {
                label.glassEffect(
                    .regular.tint(Palette.accent.opacity(0.55)).interactive(),
                    in: .capsule
                )
            } else {
                label
                    .background(Palette.accent.opacity(0.85), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .disabled(subscriptions.isPurchasing || selectedPackage == nil)
    }

    // MARK: - Actions

    private func purchaseSelected() {
        guard let package = selectedPackage else { return }
        Haptics.selection()
        Task { await subscriptions.purchase(package) }
    }

    private func restorePurchases() {
        guard !subscriptions.isRestoring else { return }
        Haptics.selection()
        Task {
            await subscriptions.restorePurchases()
            // `hasGrocerPro` toggling dismisses the paywall via onChange; if the
            // restore turned up nothing (and didn't error), tell the user so the
            // tap isn't a silent no-op.
            if !subscriptions.hasGrocerPro, subscriptions.lastErrorMessage == nil {
                infoMessage = String(localized: "No previous purchases were found to restore.")
            }
        }
    }

    private func redeemCode() {
        Haptics.selection()
        Purchases.shared.presentCodeRedemptionSheet()
    }

    private func selectRecommendedIfNeeded() {
        let ids = orderedPackages.map(\.identifier)
        if let current = selectedPackageID, ids.contains(current) { return }
        selectedPackageID = recommendedPackage?.identifier
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { subscriptions.lastErrorMessage != nil },
            set: { if !$0 { subscriptions.clearError() } }
        )
    }

    private var infoPresented: Binding<Bool> {
        Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )
    }

    // MARK: - Package selection helpers

    private var orderedPackages: [Package] {
        subscriptions.availablePackages.sorted { rank($0) < rank($1) }
    }

    private func rank(_ package: Package) -> Int {
        switch package.packageType {
        case .monthly: return 0
        case .annual: return 1
        case .lifetime: return 2
        default: return 3
        }
    }

    private var visiblePackages: [Package] {
        showAllPlans ? orderedPackages : Array(orderedPackages.prefix(2))
    }

    private var recommendedPackage: Package? {
        orderedPackages.first { $0.packageType == .annual } ?? orderedPackages.first
    }

    private var selectedPackage: Package? {
        orderedPackages.first { $0.identifier == selectedPackageID } ?? recommendedPackage
    }

    // MARK: - CTA copy

    private var ctaTitle: String {
        guard let package = selectedPackage else { return String(localized: "Continue") }
        if PackagePricing.trialText(for: package) != nil { return String(localized: "Try for $0.00") }
        if package.packageType == .lifetime { return String(localized: "Unlock Lifetime") }
        return String(localized: "Subscribe")
    }

    private var ctaSubtitle: String? {
        guard let package = selectedPackage else { return nil }
        let summary = PackagePricing.priceSummary(for: package)
        if let trial = PackagePricing.trialText(for: package) {
            return String(localized: "Free trial \(trial), then \(summary)\nCancel anytime · No payment now")
        }
        if package.packageType == .lifetime {
            return String(localized: "One-time payment · No subscription")
        }
        return String(localized: "\(summary) · Cancel anytime, no commitment")
    }

    private func display(for package: Package) -> PlanDisplay {
        PlanDisplay(
            package: package,
            isRecommended: package.identifier == recommendedPackage?.identifier,
            headline: PackagePricing.trialText(for: package).map { String(localized: "Free Trial \($0), then") },
            title: PackagePricing.cardTitle(for: package),
            caption: PackagePricing.cardCaption(for: package, isRecommended: package.identifier == recommendedPackage?.identifier)
        )
    }

    // MARK: - Static content

    private struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let subtitle: String
    }

    private static let features: [Feature] = [
        Feature(icon: "list.bullet.rectangle.portrait", title: String(localized: "Unlimited Lists"),
                subtitle: String(localized: "Create as many grocery lists as you need.")),
        Feature(icon: "person.2.fill", title: String(localized: "Shared Lists"),
                subtitle: String(localized: "Share your lists with as many people as you want.")),
        Feature(icon: "bolt.horizontal.circle", title: String(localized: "Live Activities"),
                subtitle: String(localized: "Track shopping trips in real time.")),
        Feature(icon: "square.grid.2x2", title: String(localized: "Smart Categories"),
                subtitle: String(localized: "Items auto-sort by aisle as you shop.")),
        Feature(icon: "clock.arrow.circlepath", title: String(localized: "Trip History"),
                subtitle: String(localized: "Look back at past shopping trips.")),
        Feature(icon: "person.3.fill", title: String(localized: "Family Sharing"),
                subtitle: String(localized: "Your Pro plan is automatically shared with your iCloud Family.")),
        Feature(icon: "sparkles", title: String(localized: "Future Updates"),
                subtitle: String(localized: "Every new Pro feature, included.")),
    ]

    private struct Quote: Identifiable {
        let id = UUID()
        let text: String
        let name: String
        let emoji: String
    }

    private static let quotes: [Quote] = [
        Quote(text: String(localized: "Grocer keeps our whole family on the same page. No more fridge sticky notes!"),
              name: String(localized: "Sarah Johnson"), emoji: "🥰"),
        Quote(text: String(localized: "The smartest grocery app I've used. Shopping trips are so easy now."),
              name: String(localized: "Michael Thompson"), emoji: "🎉"),
        Quote(text: String(localized: "I love seeing what my family grabs in real time. Total game changer."),
              name: String(localized: "Emily Davis"), emoji: "👋"),
    ]
}

// MARK: - Plan model + card

private struct PlanDisplay {
    let package: Package
    let isRecommended: Bool
    let headline: String?
    let title: String
    let caption: String
}

private struct PlanCard: View {
    let plan: PlanDisplay
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                if let headline = plan.headline {
                    Text(headline)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Palette.accent)
                }
                Text(plan.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.primaryText)
                Text(plan.caption)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Palette.accent.opacity(0.12) : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? Palette.accent : Palette.hairline,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Testimonial bubble

private struct TestimonialBubble: View {
    let text: String
    let name: String
    let emoji: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Palette.primaryText)
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.surface)
            )

            Text(emoji)
                .font(.title)
        }
    }
}

// MARK: - Hero illustration

private struct PaywallHero: View {
    var body: some View {
        ZStack {
            Image(systemName: "cart.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Palette.accent)

            doodle("heart.fill", x: -90, y: -42, size: 16, tinted: true)
            doodle("sparkle", x: 92, y: -48, size: 20, tinted: true)
            doodle("star.fill", x: 70, y: 40, size: 13)
            doodle("dollarsign.circle", x: -96, y: 30, size: 18)
            doodle("checkmark.circle", x: -64, y: -58, size: 14, tinted: true)
            doodle("leaf.fill", x: 100, y: 8, size: 15, tinted: true)
        }
    }

    private func doodle(_ name: String, x: CGFloat, y: CGFloat, size: CGFloat,
                        tinted: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(tinted ? Palette.accent.opacity(0.8) : Palette.primaryText.opacity(0.4))
            .offset(x: x, y: y)
    }
}

// MARK: - Pricing helpers

private enum PackagePricing {
    /// The big price line shown on each plan card.
    static func cardTitle(for package: Package) -> String {
        let price = package.storeProduct.localizedPriceString
        switch package.packageType {
        case .lifetime:
            return price
        case .annual:
            if let perMonth = perMonthString(for: package) {
                return String(localized: "\(price)/yr (\(perMonth)/mo)")
            }
            return String(localized: "\(price)/yr")
        case .monthly:
            return String(localized: "\(price) / Monthly")
        case .weekly:
            return String(localized: "\(price) / Weekly")
        default:
            return price
        }
    }

    static func cardCaption(for package: Package, isRecommended: Bool) -> String {
        switch package.packageType {
        case .lifetime:
            return String(localized: "Pay once · Yours forever")
        case .annual:
            return isRecommended
                ? String(localized: "Best Value · Just \(package.storeProduct.localizedPriceString)/year")
                : String(localized: "Billed annually")
        case .monthly:
            return String(localized: "Monthly Flex · Cancel anytime")
        case .weekly:
            return String(localized: "Billed weekly")
        default:
            return String(localized: "Cancel anytime")
        }
    }

    /// Short summary used in the sticky CTA caption, e.g. "$14.99/yr".
    static func priceSummary(for package: Package) -> String {
        let price = package.storeProduct.localizedPriceString
        switch package.packageType {
        case .annual: return String(localized: "\(price)/yr")
        case .monthly: return String(localized: "\(price)/mo")
        case .weekly: return String(localized: "\(price)/wk")
        case .lifetime: return price
        default: return price
        }
    }

    /// Returns a localized trial length (e.g. "7 Days") when the product offers
    /// an introductory free trial, otherwise nil.
    static func trialText(for package: Package) -> String? {
        guard let intro = package.storeProduct.introductoryDiscount,
              intro.paymentMode == .freeTrial else { return nil }
        return periodText(intro.subscriptionPeriod)
    }

    private static func perMonthString(for package: Package) -> String? {
        guard let perMonth = package.storeProduct.pricePerMonth else { return nil }
        let formatter = package.storeProduct.priceFormatter ?? defaultCurrencyFormatter
        return formatter.string(from: perMonth)
    }

    private static func periodText(_ period: SubscriptionPeriod) -> String {
        let value = period.value
        switch period.unit {
        case .day: return value == 1 ? String(localized: "\(value) Day") : String(localized: "\(value) Days")
        case .week: return String(localized: "\(value * 7) Days")
        case .month: return value == 1 ? String(localized: "\(value) Month") : String(localized: "\(value) Months")
        case .year: return value == 1 ? String(localized: "\(value) Year") : String(localized: "\(value) Years")
        @unknown default: return "\(value)"
        }
    }

    private static let defaultCurrencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        return formatter
    }()
}

// MARK: - Palette

private enum Palette {
    /// Adaptive colors so the paywall follows the system light/dark appearance.
    static let background = Color(.systemBackground)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    /// Emerald brand accent.
    static let accent = Color(red: 0.06, green: 0.72, blue: 0.51)

    /// Subtle surface fill / hairline used by plan cards and bubbles.
    static let surface = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.12)
}

#if DEBUG
#Preview("Grocer Pro Paywall") {
    GrocerProPaywallView()
        .grocerPreviewEnvironment()
}
#endif
