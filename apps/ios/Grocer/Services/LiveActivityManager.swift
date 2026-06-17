import ActivityKit
import Foundation
import Observation

/// Coordinates ActivityKit Live Activities and the APNs token registration
/// that powers family-wide push-to-start behavior.
///
/// Two token streams matter:
///  1. **push-to-start token** (iOS 17.2+): lets the backend START a Live
///     Activity on this device via APNs even when the app isn't running. We
///     register it whenever it changes (and when the family setting is on).
///  2. **per-activity update token**: produced once a specific activity is
///     running, lets the backend UPDATE/END that activity. We post it back so
///     update/end pushes can target it.
///
/// The shopper's own device also starts the activity locally for immediate
/// feedback; family devices rely on the push-to-start fan-out from the API.
@Observable
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private let api = APIClient.shared
    private let settings = SettingsStore.shared

    /// Whether ActivityKit Live Activities are allowed by the user/system.
    private(set) var areActivitiesEnabled: Bool = false

    /// Context needed to register tokens. A device can belong to multiple groups,
    /// so the same push-to-start token needs one backend row per group.
    private var memberIdsByHouseholdId: [String: String] = [:]

    /// The local activity the shopper started (if any). This in-memory
    /// reference is lost if iOS kills the app during a trip — later calls recover
    /// the matching session from `Activity.activities`.
    private var currentActivity: Activity<GroceryActivityAttributes>?
    private var currentSessionId: String?

    private var observationTasks: [Task<Void, Never>] = []
    private var observedActivityIds: Set<String> = []

    func configure(householdId: String, memberId: String) {
        configure(householdMemberships: [householdId: memberId])
    }

    func configure(householdMemberships: [String: String]) {
        let removedMemberships = memberIdsByHouseholdId.filter { householdMemberships[$0.key] == nil }
        let changed = memberIdsByHouseholdId != householdMemberships
        self.memberIdsByHouseholdId = householdMemberships
        areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

        guard changed || observationTasks.isEmpty else { return }
        startObservingTokens()

        if !removedMemberships.isEmpty {
            Task { [weak self, removedMemberships] in
                await self?.unregisterPushToStart(for: removedMemberships)
            }
        }
    }

    // MARK: - Token observation

    /// Observe push-to-start and (later) update tokens, posting them to the API.
    private func startObservingTokens() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
        observedActivityIds.removeAll()

        // Push-to-start token (iOS 17.2+). Only register if the family setting is on.
        if #available(iOS 17.2, *) {
            let task = Task { [weak self] in
                for await tokenData in Activity<GroceryActivityAttributes>.pushToStartTokenUpdates {
                    await self?.registerPushToStart(token: tokenData.hexString)
                }
            }
            observationTasks.append(task)

            // Register the current token immediately if one already exists.
            if let data = Activity<GroceryActivityAttributes>.pushToStartToken {
                Task { await registerPushToStart(token: data.hexString) }
            }
        }

        // Watch any already-running activities for their update tokens.
        for activity in Activity<GroceryActivityAttributes>.activities {
            observeUpdateToken(for: activity)
        }

        let updates = Task { [weak self] in
            for await activity in Activity<GroceryActivityAttributes>.activityUpdates {
                self?.observeUpdateToken(for: activity)
            }
        }
        observationTasks.append(updates)
    }

    private func registerPushToStart(token: String?) async {
        let memberships = memberIdsByHouseholdId
        guard !memberships.isEmpty else { return }

        for (householdId, memberId) in memberships {
            await api.registerPushToStart(
                RegisterTokenPayload(
                    householdId: householdId,
                    memberId: memberId,
                    deviceId: settings.deviceId,
                    pushToStartToken: settings.familyLiveActivitiesEnabled ? token : nil,
                    pushNotificationToken: nil,
                    familyLiveActivitiesEnabled: settings.familyLiveActivitiesEnabled,
                    notificationsEnabled: nil,
                    appVersion: settings.appVersion
                )
            )
        }
    }

    private func unregisterPushToStart(for memberships: [String: String]) async {
        for (householdId, memberId) in memberships {
            await api.registerPushToStart(
                RegisterTokenPayload(
                    householdId: householdId,
                    memberId: memberId,
                    deviceId: settings.deviceId,
                    pushToStartToken: nil,
                    pushNotificationToken: nil,
                    familyLiveActivitiesEnabled: false,
                    notificationsEnabled: nil,
                    appVersion: settings.appVersion
                )
            )
        }
    }

    /// Called when the family Live Activity setting changes — re-registers so the
    /// backend stops/starts targeting this device.
    func familyPreferenceChanged() {
        if #available(iOS 17.2, *) {
            Task { await registerPushToStart(token: Activity<GroceryActivityAttributes>.pushToStartToken?.hexString) }
        } else {
            Task { await registerPushToStart(token: nil) }
        }
    }

    private func observeUpdateToken(for activity: Activity<GroceryActivityAttributes>) {
        guard observedActivityIds.insert(activity.id).inserted else { return }
        let householdId = activity.attributes.householdId
        let sessionId = activity.attributes.sessionId
        let task = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                await self?.registerUpdateToken(
                    token: tokenData.hexString,
                    householdId: householdId,
                    sessionId: sessionId
                )
            }
        }
        observationTasks.append(task)
    }

    private func registerUpdateToken(token: String, householdId: String, sessionId: String) async {
        guard let memberId = memberIdsByHouseholdId[householdId] else { return }
        await api.registerUpdateToken(
            RegisterUpdateTokenPayload(
                householdId: householdId,
                memberId: memberId,
                deviceId: settings.deviceId,
                sessionId: sessionId,
                updateToken: token
            )
        )
    }

    // MARK: - Local activity lifecycle (shopper's own device)

    /// Start the Live Activity locally on the shopper's device. Family devices
    /// receive a push-to-start from the API instead (see GroceryRepository).
    func startLocalActivity(session: ShoppingSession, content: GroceryActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              settings.familyLiveActivitiesEnabled else { return }

        let attributes = GroceryActivityAttributes(
            householdId: session.householdId,
            sessionId: session.id,
            startedByMemberId: session.startedByMemberId
        )

        // The Simulator can't register for APNs, so requesting `.token` fails
        // and no activity ever appears. Start a local-only activity there (push
        // fan-out to family devices is a no-op on Simulator anyway); real
        // hardware keeps `.token` so update/end pushes can target it.
        #if targetEnvironment(simulator)
        let pushType: PushType? = nil
        #else
        let pushType: PushType? = .token
        #endif

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: content, staleDate: nil),
                pushType: pushType
            )
            currentActivity = activity
            currentSessionId = session.id
            observeUpdateToken(for: activity)
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
    }

    func updateLocalActivity(session: ShoppingSession, content: GroceryActivityAttributes.ContentState) {
        let activity = findRunningActivity(sessionId: session.id)
        guard let activity else { return }
        Task {
            await activity.update(.init(state: content, staleDate: nil))
        }
    }

    func endLocalActivity(session: ShoppingSession,
                          content: GroceryActivityAttributes.ContentState,
                          includeHouseholdFallback: Bool = false) {
        var activities = runningActivities(sessionId: session.id)
        if activities.isEmpty, includeHouseholdFallback {
            activities = runningActivities(householdId: session.householdId)
        }
        guard !activities.isEmpty else {
            print("[LiveActivity] endLocalActivity — no running activity found for session \(session.id)")
            return
        }
        print("[LiveActivity] ending \(activities.count) activity(s) for session \(session.id)")
        end(activities, content: content)
    }

    func reconcileEndedActivities(_ sessions: [ShoppingSession],
                                  content: (ShoppingSession) -> GroceryActivityAttributes.ContentState) {
        var endedSessionsById: [String: ShoppingSession] = [:]
        for session in sessions where session.status != .active {
            endedSessionsById[session.id] = session
        }
        guard !endedSessionsById.isEmpty else { return }

        let staleActivities = Activity<GroceryActivityAttributes>.activities.filter {
            ($0.activityState == .active || $0.activityState == .stale)
                && endedSessionsById[$0.attributes.sessionId] != nil
        }
        guard !staleActivities.isEmpty else { return }

        print("[LiveActivity] reconciling \(staleActivities.count) ended activity(s)")
        for activity in staleActivities {
            guard let session = endedSessionsById[activity.attributes.sessionId] else { continue }
            end([activity], content: content(session))
        }
    }

    /// Find a running activity that matches the given session. We avoid falling
    /// back to an arbitrary activity here because stale ActivityKit instances
    /// can survive app relaunches and must not receive another trip's updates.
    private func findRunningActivity(sessionId: String) -> Activity<GroceryActivityAttributes>? {
        runningActivities(sessionId: sessionId).first
    }

    private func runningActivities(sessionId: String) -> [Activity<GroceryActivityAttributes>] {
        Activity<GroceryActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }.filter {
            $0.attributes.sessionId == sessionId
        }
    }

    private func runningActivities(householdId: String) -> [Activity<GroceryActivityAttributes>] {
        Activity<GroceryActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }.filter {
            $0.attributes.householdId == householdId
        }
    }

    private func end(_ activities: [Activity<GroceryActivityAttributes>],
                     content: GroceryActivityAttributes.ContentState) {
        for activity in activities {
            Task {
                await activity.end(.init(state: content, staleDate: nil), dismissalPolicy: .after(.now + 60 * 5))
                if currentActivity?.id == activity.id {
                    currentActivity = nil
                    currentSessionId = nil
                }
            }
        }
    }
}

private extension Data {
    /// Hex string used to transmit ActivityKit/APNs tokens to the backend.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
