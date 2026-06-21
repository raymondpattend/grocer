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
    // Ordering contract: when several Live Activities are on screen at once, iOS
    // stacks them by relevance score (highest first). Active trips always use the
    // high score and ended trips the low one, so a newly started trip is shown
    // above any completed/cancelled trips still lingering toward their dismissal
    // date. The push side mirrors these values in apns.ts; keep them in sync.
    private static let activeRelevanceScore = 100.0
    private static let endedRelevanceScore = 0.0
    /// How long a completed/cancelled activity stays on screen before iOS removes
    /// it. Apple caps the post-end dismissal window at 4 hours; we use the max so
    /// the finished-trip summary lingers, matching the backend `sendEnd` push.
    private static let endedActivityLinger: TimeInterval = 4 * 60 * 60

    func configure(householdId: String, memberId: String) {
        configure(householdMemberships: [householdId: memberId])
    }

    func configure(householdMemberships: [String: String]) {
        // Diff against the *durably persisted* set, not the in-memory one. The
        // in-memory map resets to empty on every cold launch, so a group that
        // disappeared while the app was closed would never be detected as
        // removed and would keep receiving push-to-start fan-outs at this
        // device forever. The persisted set survives relaunches and lets us
        // tear those registrations down.
        let persisted = Self.loadPersistedMemberships()
        let removedMemberships = persisted.filter { householdMemberships[$0.key] == nil }
        let changed = persisted != householdMemberships
        self.memberIdsByHouseholdId = householdMemberships
        areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

        guard changed || observationTasks.isEmpty else { return }
        startObservingTokens()

        if removedMemberships.isEmpty {
            Self.persistMemberships(householdMemberships)
        } else {
            // Only update the persisted set *after* unregistering, so a failed
            // unregister is retried on the next launch instead of being lost.
            Task { [weak self, removedMemberships, householdMemberships] in
                await self?.unregisterPushToStart(for: removedMemberships)
                Self.persistMemberships(householdMemberships)
            }
        }
    }

    // MARK: - Durable registration ledger

    /// App-Group-scoped record of the (household → member) set this device last
    /// registered push-to-start tokens for. Environment-suffixed so Debug and
    /// Release builds don't clobber each other's ledger.
    private static let registeredMembershipsKey =
        GrocerAppGroup.scopedName("grocer.liveActivity.registeredMemberships")

    static func loadPersistedMemberships() -> [String: String] {
        guard let data = GrocerAppGroup.defaults.data(forKey: registeredMembershipsKey),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    static func persistMemberships(_ memberships: [String: String]) {
        guard let data = try? JSONEncoder().encode(memberships) else { return }
        GrocerAppGroup.defaults.set(data, forKey: registeredMembershipsKey)
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
                // A newly appeared activity can be a duplicate of one already
                // running for the same trip (push-to-start vs the alert-push
                // fallback). Collapse to one the moment the second shows up.
                self?.dedupeRunningActivities(sessionId: activity.attributes.sessionId)
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
        startActivity(
            householdId: session.householdId,
            sessionId: session.id,
            startedByMemberId: session.startedByMemberId,
            content: content
        )
    }

    func startRemoteActivity(householdId: String,
                             sessionId: String,
                             startedByMemberId: String?,
                             content: GroceryActivityAttributes.ContentState) {
        startActivity(
            householdId: householdId,
            sessionId: sessionId,
            startedByMemberId: startedByMemberId,
            content: content
        )
    }

    private func startActivity(householdId: String,
                               sessionId: String,
                               startedByMemberId: String?,
                               content: GroceryActivityAttributes.ContentState) {
        guard findRunningActivity(sessionId: sessionId) == nil else {
            updateRemoteActivity(sessionId: sessionId, content: content)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              settings.familyLiveActivitiesEnabled else { return }

        let attributes = GroceryActivityAttributes(
            householdId: householdId,
            sessionId: sessionId,
            startedByMemberId: startedByMemberId
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
                content: .init(state: content, staleDate: nil, relevanceScore: Self.activeRelevanceScore),
                pushType: pushType
            )
            currentActivity = activity
            currentSessionId = sessionId
            observeUpdateToken(for: activity)
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
    }

    func updateRemoteActivity(sessionId: String, content: GroceryActivityAttributes.ContentState) {
        let activity = findRunningActivity(sessionId: sessionId)
        guard let activity else { return }
        Task {
            await activity.update(.init(state: content, staleDate: nil, relevanceScore: Self.activeRelevanceScore))
        }
    }

    func updateLocalActivity(session: ShoppingSession, content: GroceryActivityAttributes.ContentState) {
        let activity = findRunningActivity(sessionId: session.id)
        guard let activity else { return }
        Task {
            await activity.update(.init(state: content, staleDate: nil, relevanceScore: Self.activeRelevanceScore))
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

    /// Collapse duplicate running activities for a session down to one. A family
    /// device can briefly hold two — the push-to-start activity and one created
    /// by the alert-push fallback handler — when they race before ActivityKit
    /// lists the first. We end the extras immediately so the Live Activity never
    /// renders doubled-up or blank. Only ever touches active/stale activities, so
    /// finished trips lingering toward their dismissal date are left alone.
    private func dedupeRunningActivities(sessionId: String) {
        let running = runningActivities(sessionId: sessionId)
        guard running.count > 1 else { return }
        // Prefer keeping the activity we already track locally; otherwise the first.
        let keep = running.first { $0.id == currentActivity?.id } ?? running[0]
        let extras = running.filter { $0.id != keep.id }
        print("[LiveActivity] deduping \(extras.count) duplicate activity(s) for session \(sessionId)")
        for activity in extras {
            Task {
                await activity.end(
                    .init(state: activity.content.state,
                          staleDate: nil,
                          relevanceScore: Self.endedRelevanceScore),
                    dismissalPolicy: .immediate
                )
            }
        }
    }

    private func end(_ activities: [Activity<GroceryActivityAttributes>],
                     content: GroceryActivityAttributes.ContentState) {
        let dismissAfter = Date().addingTimeInterval(Self.endedActivityLinger)
        for activity in activities {
            Task {
                await activity.end(
                    .init(state: content, staleDate: nil, relevanceScore: Self.endedRelevanceScore),
                    dismissalPolicy: .after(dismissAfter)
                )
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
