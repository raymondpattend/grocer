import CoreLocation
import Foundation
import Observation
import UserNotifications

/// `kind` tag on the local arrival notification. The tap is routed by
/// `householdId` in `AppDelegate.userNotificationCenter(_:didReceive:)`.
let storeArrivalNotificationKind = "storeArrival"

/// Drives "you're at the store" reminders entirely on-device via CoreLocation
/// region monitoring — no server involved. The linked store location is shared
/// on the CloudKit `Household` record; the *opt-in* to be reminded is a personal,
/// per-list preference in `SettingsStore`.
///
/// When a member arrives at a list's linked store (and has opted in), we post a
/// local notification nudging them to start a trip. Tapping it deep-links into
/// the list via `GroupNavigationCoordinator` (the existing notification routing).
@Observable
@MainActor
final class StoreReminderManager: NSObject, CLLocationManagerDelegate {
    static let shared = StoreReminderManager()

    private let manager = CLLocationManager()
    private var householdsById: [String: Household] = [:]

    /// Identifier namespace so we only ever touch regions we created.
    private static let regionPrefix = "grocer.store."
    /// Don't re-nudge for the same list more than once per window — handles
    /// boundary jitter and quick exit/re-entry near the store.
    private static let reNotifyInterval: TimeInterval = 30 * 60

    private var lastNotifiedAt: [String: Date] = [:]

    /// Published so the setup UI can react to permission changes.
    private(set) var authorizationStatus: CLAuthorizationStatus

    private override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorizedAlways: Bool { authorizationStatus == .authorizedAlways }

    /// Request **Always** authorization (required for region monitoring while the
    /// app is backgrounded/terminated). iOS gates this behind a When-In-Use grant
    /// and a later "keep using in background?" upgrade prompt.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// Reconcile monitored regions against the lists that (a) have a linked store
    /// and (b) the member has opted into. Idempotent and cheap when nothing
    /// changed — safe to call on every household update.
    func syncMonitoredRegions(households: [Household]) {
        householdsById = Dictionary(uniqueKeysWithValues: households.map { ($0.id, $0) })

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              Self.canMonitorRegions(manager.authorizationStatus) else {
            stopManagedRegions(except: [])
            return
        }

        // iOS caps an app at 20 monitored regions; prefer the most recently
        // updated lists if a power user links more than that.
        let desired = households
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap(makeRegion)
            .prefix(20)
        let desiredIds = Set(desired.map(\.identifier))
        stopManagedRegions(except: desiredIds)

        let monitoredIds = Set(manager.monitoredRegions.map(\.identifier))
        for region in desired where !monitoredIds.contains(region.identifier) {
            manager.startMonitoring(for: region)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            // Permission may have just been granted — (re)establish regions.
            self.syncMonitoredRegions(households: Array(self.householdsById.values))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor in self.handleArrival(regionIdentifier: identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        print("[StoreReminder] monitoring failed for \(region?.identifier ?? "?"): \(error)")
    }

    // MARK: - Arrival handling

    private func handleArrival(regionIdentifier: String) {
        guard let householdId = Self.householdId(from: regionIdentifier),
              SettingsStore.shared.storeRemindersEnabled(forHousehold: householdId) else {
            return
        }

        if let last = lastNotifiedAt[householdId],
           Date().timeIntervalSince(last) < Self.reNotifyInterval {
            return
        }

        // Use live repo state when available (the app may be background-launched
        // by the region event before the repo exists — then we fall back to the
        // last-synced household snapshot and notify generically).
        let repo = GroceryRepository.current
        let household = householdsById[householdId] ?? repo?.households.first { $0.id == householdId }
        let listId = household.flatMap { repo?.list(for: $0)?.id }

        // Don't nag mid-trip.
        if let listId, repo?.activeSession(for: listId) != nil { return }

        // If we can see the list and it's empty, nothing to shop for.
        let pendingCount = listId.map { repo?.pendingItems(forList: $0).count ?? 0 }
        if let pendingCount, pendingCount == 0 { return }

        lastNotifiedAt[householdId] = Date()
        scheduleArrivalNotification(
            householdId: householdId,
            listName: household?.name,
            storeName: household?.storeName,
            pendingCount: pendingCount ?? 0
        )
    }

    private func scheduleArrivalNotification(householdId: String,
                                             listName: String?,
                                             storeName: String?,
                                             pendingCount: Int) {
        Task {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: break
            default: return
            }

            let list = listName?.nilIfBlank ?? String(localized: "your list")
            let content = UNMutableNotificationContent()
            let place = storeName?.nilIfBlank ?? list
            content.title = String(localized: "You're at \(place)")
            if pendingCount > 0 {
                // `body` needs a plain String, so render the inflection through an
                // AttributedString first — `String(localized:)` would leak the raw markup.
                content.body = String(AttributedString(localized: "Start your \(list) trip — ^[\(pendingCount) item](inflect: true) waiting.").characters)
            } else {
                content.body = String(localized: "Open \(list) to start your shopping trip.")
            }
            content.sound = .default
            content.threadIdentifier = "store-arrival-\(householdId)"
            content.userInfo = [
                "kind": storeArrivalNotificationKind,
                "householdId": householdId,
            ]

            let request = UNNotificationRequest(
                identifier: "grocer.store.arrival.\(householdId)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                print("[StoreReminder] notification failed: \(error)")
            }
        }
    }

    // MARK: - Regions

    private func makeRegion(for household: Household) -> CLCircularRegion? {
        guard SettingsStore.shared.storeRemindersEnabled(forHousehold: household.id),
              let latitude = household.storeLatitude,
              let longitude = household.storeLongitude else {
            return nil
        }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let maxRadius = manager.maximumRegionMonitoringDistance > 0
            ? manager.maximumRegionMonitoringDistance
            : 1_000
        let radius = min(max(household.storeRadius ?? Household.defaultStoreRadius, 50), maxRadius)
        let region = CLCircularRegion(
            center: coordinate,
            radius: radius,
            identifier: Self.regionIdentifier(for: household.id)
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false
        return region
    }

    private func stopManagedRegions(except desiredIds: Set<String>) {
        for region in manager.monitoredRegions
            where region.identifier.hasPrefix(Self.regionPrefix)
                && !desiredIds.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
    }

    private static func canMonitorRegions(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    private static func regionIdentifier(for householdId: String) -> String {
        regionPrefix + householdId
    }

    private static func householdId(from identifier: String) -> String? {
        guard identifier.hasPrefix(regionPrefix) else { return nil }
        return String(identifier.dropFirst(regionPrefix.count))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
