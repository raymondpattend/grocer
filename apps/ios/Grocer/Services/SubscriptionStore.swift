import Foundation
import Observation
import RevenueCat

enum RevenueCatConfig {
    /// RevenueCat traps with a `fatalError` if a Test Store key (`test_…`) is used
    /// in a Release build, so Release (TestFlight / App Store) must use the real
    /// App Store key from the RevenueCat dashboard. Debug keeps the Test Store key.
    #if DEBUG
    static let apiKey = "test_tSaSOTwPRseDzLdzjuGNqrnTOSb"
    #else
    static let apiKey = "appl_qQYLRddYzArxuGvGETeoYPAHlUd"
    #endif
    static let grocerProEntitlementID = "grocer_pro"

    static let lifetimeProductID = "lifetime"
    static let yearlyProductID = "yearly"
    static let monthlyProductID = "monthly"

    private static var didConfigure = false

    static func configure() {
        guard !didConfigure else { return }

        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(withAPIKey: apiKey)
        didConfigure = true
    }

    static func hasGrocerPro(_ customerInfo: CustomerInfo?) -> Bool {
        customerInfo?.entitlements.all[grocerProEntitlementID]?.isActive == true
    }
}

@Observable
final class SubscriptionStore {
    static let shared = SubscriptionStore()

    private(set) var customerInfo: CustomerInfo?
    private(set) var offerings: Offerings?
    private(set) var currentOffering: Offering?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    var lastErrorMessage: String?

    @ObservationIgnored private var customerInfoTask: Task<Void, Never>?

    var hasGrocerPro: Bool {
        RevenueCatConfig.hasGrocerPro(customerInfo)
    }

    var managementURL: URL? {
        customerInfo?.managementURL
    }

    var displayStatus: String {
        if hasGrocerPro {
            return "Active"
        }

        if isLoading && customerInfo == nil {
            return "Checking..."
        }

        return "Not active"
    }

    var availablePackages: [Package] {
        guard let offering = currentOffering else { return [] }

        let preferred = uniquePackages([
            lifetimePackage(in: offering),
            yearlyPackage(in: offering),
            monthlyPackage(in: offering),
        ])

        return preferred.isEmpty ? offering.availablePackages : preferred
    }

    @MainActor
    func start() {
        guard customerInfoTask == nil else { return }

        customerInfoTask = Task { [weak self] in
            for await customerInfo in Purchases.shared.customerInfoStream {
                self?.update(with: customerInfo)
            }
        }

        Task {
            await refresh()
        }
    }

    @MainActor
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let customerInfo = Purchases.shared.customerInfo()
            async let offerings = Purchases.shared.offerings()

            let (latestCustomerInfo, latestOfferings) = try await (customerInfo, offerings)
            update(with: latestCustomerInfo)
            self.offerings = latestOfferings
            currentOffering = latestOfferings.current
        } catch {
            recordFailure(error)
        }
    }

    @MainActor
    func purchase(_ package: Package) async {
        guard !isPurchasing else { return }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            update(with: result.customerInfo)
        } catch {
            recordFailure(error)
        }
    }

    @MainActor
    func restorePurchases() async {
        guard !isRestoring else { return }

        isRestoring = true
        defer { isRestoring = false }

        do {
            let restoredCustomerInfo = try await Purchases.shared.restorePurchases()
            update(with: restoredCustomerInfo)
        } catch {
            recordFailure(error)
        }
    }

    @MainActor
    func update(with customerInfo: CustomerInfo) {
        self.customerInfo = customerInfo
        if RevenueCatConfig.hasGrocerPro(customerInfo) {
            lastErrorMessage = nil
        }
    }

    @MainActor
    func recordFailure(_ error: Error) {
        guard !Self.isCancellation(error) else { return }

        let message = Self.userFacingMessage(for: error)
        lastErrorMessage = message
        print("[RevenueCat] \(message) \(error)")
    }

    @MainActor
    func clearError() {
        lastErrorMessage = nil
    }

    private func lifetimePackage(in offering: Offering) -> Package? {
        offering.lifetime
            ?? offering.package(identifier: RevenueCatConfig.lifetimeProductID)
            ?? package(in: offering, productID: RevenueCatConfig.lifetimeProductID)
    }

    private func yearlyPackage(in offering: Offering) -> Package? {
        offering.annual
            ?? offering.package(identifier: RevenueCatConfig.yearlyProductID)
            ?? package(in: offering, productID: RevenueCatConfig.yearlyProductID)
    }

    private func monthlyPackage(in offering: Offering) -> Package? {
        offering.monthly
            ?? offering.package(identifier: RevenueCatConfig.monthlyProductID)
            ?? package(in: offering, productID: RevenueCatConfig.monthlyProductID)
    }

    private func package(in offering: Offering, productID: String) -> Package? {
        offering.availablePackages.first { $0.storeProduct.productIdentifier == productID }
    }

    private func uniquePackages(_ packages: [Package?]) -> [Package] {
        var seen = Set<String>()

        return packages.compactMap { package in
            guard let package, !seen.contains(package.identifier) else { return nil }
            seen.insert(package.identifier)
            return package
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        errorCode(for: error) == .purchaseCancelledError
    }

    private static func errorCode(for error: Error) -> RevenueCat.ErrorCode? {
        if let code = error as? RevenueCat.ErrorCode {
            return code
        }

        let nsError = error as NSError
        return RevenueCat.ErrorCode(rawValue: nsError.code)
    }

    private static func userFacingMessage(for error: Error) -> String {
        guard let code = errorCode(for: error) else {
            return error.localizedDescription
        }

        switch code {
        case .networkError, .offlineConnectionError:
            return "Check your connection and try again."
        case .purchaseNotAllowedError:
            return "Purchases are not allowed on this device."
        case .purchaseInvalidError:
            return "The purchase could not be completed. Check the payment method and try again."
        case .productNotAvailableForPurchaseError:
            return "This product is not available for purchase yet."
        case .productAlreadyPurchasedError:
            return "This purchase is already active. Try Restore Purchases if access is missing."
        case .invalidCredentialsError, .configurationError:
            return "RevenueCat is not configured correctly. Check the API key and dashboard setup."
        case .storeProblemError:
            return "The App Store could not complete the request. Try again in a moment."
        case .paymentPendingError:
            return "The payment is pending. Access will update after Apple approves it."
        default:
            return code.description
        }
    }
}
