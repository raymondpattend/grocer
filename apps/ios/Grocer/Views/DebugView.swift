import CloudKit
import RevenueCat
import SwiftUI
import UIKit

// MARK: - Shake to present

extension Notification.Name {
    static let deviceDidShake = Notification.Name("org.narro.grocer.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

private struct ShakeDetector: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            action()
        }
    }
}

extension View {
    /// Calls `action` when the device is physically shaken.
    func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeDetector(action: action))
    }
}

// MARK: - Report model

private struct DebugRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    var mono: Bool = false
}

private struct DebugSection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [DebugRow]
}

// MARK: - Debug screen

/// Engineer-facing diagnostics, presented by shaking the device. Surfaces the
/// live state of every subsystem (RevenueCat, iCloud/CloudKit sync, local data,
/// settings, push) plus a captured log feed that can be exported/shared.
struct DebugView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SettingsStore.self) private var settings
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

    @State private var accountStatus: String = "Checking…"
    @State private var userRecordName: String = "Checking…"
    @State private var logText: String = ""
    @State private var actionMessage: String?
    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var logRefreshTimer: Timer?

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            row.view
                        }
                    }
                }

                actionsSection
                logsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportReport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .task {
                await loadCloudKitInfo()
            }
            .onAppear { startLogRefresh() }
            .onDisappear { stopLogRefresh() }
            .sheet(isPresented: $showShareSheet) {
                if let exportURL {
                    ActivityView(items: [exportURL])
                }
            }
        }
    }

    // MARK: Sections

    private var sections: [DebugSection] {
        [appSection, syncSection, revenueCatSection, dataSection, groupsSection, settingsSection]
    }

    private var appSection: DebugSection {
        let info = Bundle.main.infoDictionary
        return DebugSection(title: "App", rows: [
            DebugRow(key: "Version", value: settings.appVersion),
            DebugRow(key: "Build", value: info?["CFBundleVersion"] as? String ?? "—"),
            DebugRow(key: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "—", mono: true),
            DebugRow(key: "Configuration", value: Self.buildConfiguration),
            DebugRow(key: "CloudKit env", value: CloudKitEnvironment.current),
            DebugRow(key: "Device", value: Self.deviceModelIdentifier),
            DebugRow(key: "System", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"),
            DebugRow(key: "Locale", value: Locale.current.identifier),
        ])
    }

    private var syncSection: DebugSection {
        DebugSection(title: "iCloud / Sync", rows: [
            DebugRow(key: "Account status", value: accountStatus),
            DebugRow(key: "Using CloudKit", value: repo.usingCloudKit ? "Yes" : "No"),
            DebugRow(key: "Container available", value: CloudKitService.shared.isAvailable ? "Yes" : "No"),
            DebugRow(key: "Container ID", value: CK.containerIdentifier, mono: true),
            DebugRow(key: "User record", value: userRecordName, mono: true),
            DebugRow(key: "Sync state", value: Self.describe(repo.syncState)),
            DebugRow(key: "Initial load done", value: repo.hasCompletedInitialLoad ? "Yes" : "No"),
            DebugRow(key: "Pending writes", value: "\(repo.pendingCloudWriteCount)"),
            DebugRow(key: "Private zone sub", value: repo.subscriptionStatus.privateZoneRegistered ? "Subscribed" : "No"),
            DebugRow(key: "Shared DB sub", value: repo.subscriptionStatus.sharedDatabaseRegistered ? "Subscribed" : "No"),
            DebugRow(key: "Subscription errors",
                     value: repo.subscriptionStatus.errors.isEmpty ? "None" : repo.subscriptionStatus.errors.joined(separator: " · ")),
        ])
    }

    private var revenueCatSection: DebugSection {
        var rows: [DebugRow] = [
            DebugRow(key: "Configured", value: Purchases.isConfigured ? "Yes" : "No"),
            DebugRow(key: "API key", value: Self.maskedAPIKey, mono: true),
            DebugRow(key: "Entitlement ID", value: RevenueCatConfig.grocerProEntitlementID, mono: true),
            DebugRow(key: "Has Grocer Pro", value: subscriptions.hasGrocerPro ? "Yes" : "No"),
            DebugRow(key: "Status", value: subscriptions.displayStatus),
        ]

        if Purchases.isConfigured {
            rows.append(DebugRow(key: "App user ID", value: Purchases.shared.appUserID, mono: true))
            rows.append(DebugRow(key: "Anonymous", value: Purchases.shared.isAnonymous ? "Yes" : "No"))
        }

        if let info = subscriptions.customerInfo {
            rows.append(DebugRow(key: "Original user ID", value: info.originalAppUserId, mono: true))
            rows.append(DebugRow(key: "First seen", value: Self.date(info.firstSeen)))
            rows.append(DebugRow(key: "Request date", value: Self.date(info.requestDate)))
            rows.append(DebugRow(key: "Active subs",
                                 value: info.activeSubscriptions.isEmpty ? "None" : info.activeSubscriptions.sorted().joined(separator: ", ")))
            rows.append(DebugRow(key: "Purchased products",
                                 value: info.allPurchasedProductIdentifiers.isEmpty ? "None" : info.allPurchasedProductIdentifiers.sorted().joined(separator: ", ")))
            rows.append(DebugRow(key: "Latest expiration", value: Self.date(info.latestExpirationDate)))

            if let pro = info.entitlements.all[RevenueCatConfig.grocerProEntitlementID] {
                rows.append(DebugRow(key: "Pro · active", value: pro.isActive ? "Yes" : "No"))
                rows.append(DebugRow(key: "Pro · will renew", value: pro.willRenew ? "Yes" : "No"))
                rows.append(DebugRow(key: "Pro · product", value: pro.productIdentifier, mono: true))
                rows.append(DebugRow(key: "Pro · expires", value: Self.date(pro.expirationDate)))
                rows.append(DebugRow(key: "Pro · store", value: "\(pro.store)"))
            }
            if let url = info.managementURL {
                rows.append(DebugRow(key: "Management URL", value: url.absoluteString, mono: true))
            }
        } else {
            rows.append(DebugRow(key: "Customer info", value: "Not loaded"))
        }

        rows.append(DebugRow(key: "Offerings", value: "\(subscriptions.offerings?.all.count ?? 0)"))
        rows.append(DebugRow(key: "Current offering", value: subscriptions.currentOffering?.identifier ?? "None"))
        for package in subscriptions.availablePackages {
            rows.append(DebugRow(
                key: "  • \(package.identifier)",
                value: "\(package.storeProduct.productIdentifier) — \(package.storeProduct.localizedPriceString)",
                mono: true
            ))
        }
        if let error = subscriptions.lastErrorMessage {
            rows.append(DebugRow(key: "Last error", value: error))
        }

        return DebugSection(title: "RevenueCat", rows: rows)
    }

    private var dataSection: DebugSection {
        DebugSection(title: "Data", rows: [
            DebugRow(key: "Households", value: "\(repo.households.count)"),
            DebugRow(key: "Members", value: "\(repo.members.count)"),
            DebugRow(key: "Lists", value: "\(repo.lists.count)"),
            DebugRow(key: "Items", value: "\(repo.items.count)"),
            DebugRow(key: "Sessions", value: "\(repo.sessions.count)"),
            DebugRow(key: "Trip items", value: "\(repo.tripItems.count)"),
            DebugRow(key: "Events", value: "\(repo.events.count)"),
            DebugRow(key: "Selected list", value: repo.selectedHouseholdId ?? "None", mono: true),
            DebugRow(key: "Joined list", value: repo.joinedHouseholdId ?? "None", mono: true),
        ])
    }

    private var groupsSection: DebugSection {
        var rows: [DebugRow] = []
        if repo.households.isEmpty {
            rows.append(DebugRow(key: "No lists", value: ""))
        }
        for household in repo.households {
            let memberCount = repo.members.filter { $0.householdId == household.id }.count
            let listCount = repo.lists.filter { $0.householdId == household.id }.count
            let itemCount = repo.items.filter { $0.householdId == household.id }.count
            let scope = (household.recordOwnerName == nil || household.recordOwnerName == CKCurrentUserDefaultName)
                ? "private" : "shared"
            rows.append(DebugRow(key: household.name,
                                 value: "\(scope) · \(listCount) list · \(itemCount) items · \(memberCount) members"))
            rows.append(DebugRow(key: "  ID", value: household.id, mono: true))
            if let zone = household.recordZoneName {
                rows.append(DebugRow(key: "  Zone", value: "\(zone) / \(household.recordOwnerName ?? "—")", mono: true))
            }
        }
        return DebugSection(title: "Lists", rows: rows)
    }

    private var settingsSection: DebugSection {
        DebugSection(title: "Settings", rows: [
            DebugRow(key: "Device ID", value: settings.deviceId, mono: true),
            DebugRow(key: "Member ID", value: Self.storedMemberId.isEmpty ? "—" : Self.storedMemberId, mono: true),
            DebugRow(key: "Display name", value: repo.displayName),
            DebugRow(key: "Notifications", value: settings.notificationsEnabled ? "On" : "Off"),
            DebugRow(key: "Family Live Activities", value: settings.familyLiveActivitiesEnabled ? "On" : "Off"),
            DebugRow(key: "Profile image", value: settings.profileImageData != nil ? "Set" : "None"),
            DebugRow(key: "App Group", value: GrocerAppGroup.identifier, mono: true),
        ])
    }

    // MARK: Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section("Actions") {
            if let actionMessage {
                Text(actionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            actionButton("Force Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                await repo.manualRefresh()
                await loadCloudKitInfo()
                return "Sync finished"
            }
            actionButton("Flush Pending Writes", systemImage: "tray.and.arrow.up") {
                await repo.flushOutboxNow()
                return "Flushed — \(repo.pendingCloudWriteCount) remaining"
            }
            actionButton("Refresh RevenueCat", systemImage: "creditcard") {
                await subscriptions.refresh()
                return "RevenueCat refreshed"
            }
            actionButton("Re-register Subscriptions", systemImage: "bell.badge") {
                let result = await CloudKitService.shared.registerSubscriptions(force: true)
                return result.statusText
            }
            Button {
                UIPasteboard.general.string = reportText()
                actionMessage = "Report copied to clipboard"
            } label: {
                Label("Copy Report", systemImage: "doc.on.clipboard")
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String,
                              _ work: @escaping () async -> String) -> some View {
        Button {
            guard !isWorking else { return }
            isWorking = true
            actionMessage = "\(title)…"
            Task {
                let result = await work()
                await MainActor.run {
                    actionMessage = result
                    isWorking = false
                    refreshLog()
                }
            }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isWorking { ProgressView() }
            }
        }
        .disabled(isWorking)
    }

    // MARK: Logs

    @ViewBuilder
    private var logsSection: some View {
        Section {
            ScrollView {
                Text(logText.isEmpty ? "No logs captured yet." : logText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(height: 240)

            Button {
                exportReport()
            } label: {
                Label("Export Logs", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                LogStore.shared.clear()
                refreshLog()
            } label: {
                Label("Clear Logs", systemImage: "trash")
            }
        } header: {
            Text("Logs")
        } footer: {
            Text("Captured stdout/stderr (\(LogStore.shared.snapshot().count) lines).")
        }
    }

    // MARK: Loading

    private func loadCloudKitInfo() async {
        let status = await CloudKitService.shared.accountStatus()
        let record = await CloudKitService.shared.currentUserRecordName()
        await MainActor.run {
            accountStatus = Self.describe(status)
            userRecordName = record ?? "Unavailable"
            refreshLog()
        }
    }

    private func startLogRefresh() {
        refreshLog()
        logRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in refreshLog() }
        }
    }

    private func stopLogRefresh() {
        logRefreshTimer?.invalidate()
        logRefreshTimer = nil
    }

    private func refreshLog() {
        // Show the tail so the newest output is in view without rendering 4k lines.
        let lines = LogStore.shared.snapshot().suffix(400)
        logText = lines.joined(separator: "\n")
    }

    // MARK: Export

    private func exportReport() {
        let text = reportText() + "\n\n===== LOGS =====\n" + LogStore.shared.text()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "grocer-debug-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            exportURL = url
            showShareSheet = true
        } catch {
            actionMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func reportText() -> String {
        var out = "Grocer Debug Report\n\(ISO8601DateFormatter().string(from: Date()))\n"
        for section in sections {
            out += "\n## \(section.title)\n"
            for row in section.rows {
                if row.value.isEmpty {
                    out += "\(row.key)\n"
                } else {
                    out += "\(row.key): \(row.value)\n"
                }
            }
        }
        return out
    }

    // MARK: Helpers

    private static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }

    private static var maskedAPIKey: String {
        let key = RevenueCatConfig.apiKey
        guard key.count > 8 else { return "•••" }
        return "\(key.prefix(8))…\(key.suffix(4))"
    }

    private static var storedMemberId: String {
        GrocerAppGroup.defaults.string(forKey: "grocer.memberId") ?? ""
    }

    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "Simulator" : identifier
    }

    private static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func describe(_ state: GroceryRepository.SyncState) -> String {
        switch state {
        case .idle: return "Idle"
        case .syncing: return "Syncing"
        case .offline: return "Offline"
        case .error(let message): return "Error: \(message)"
        }
    }

    private static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: return "Available"
        case .noAccount: return "No iCloud account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could not determine"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        @unknown default: return "Unknown (\(status.rawValue))"
        }
    }
}

// MARK: - Row view

private extension DebugRow {
    @ViewBuilder
    var view: some View {
        if value.isEmpty {
            Text(key)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(mono ? .system(.caption, design: .monospaced) : .subheadline)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Share sheet

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
