import PostHog
import SwiftUI
import UIKit

/// Top-level navigation. Defaults to the Home grid of groups; tapping a group
/// drills into its planning list, and the shopper can drill further into the
/// focused Shopping Session screen when one is active.
struct RootView: View {
    /// Flip to `true` while debugging to show onboarding even after groups exist.
    static var forceShowOnboardingForDebug = false

    @Environment(GroceryRepository.self) private var repo
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(AppUpdateGate.self) private var appUpdateGate
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if shouldShowOnboarding {
                NavigationStack {
                    OnboardingView()
                }
            } else {
                // HomeView owns its NavigationStack (it drives the push path
                // for the zoom transition into a group's list).
                HomeView()
            }
        }
        .background(KeyboardWarmer())
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 4) {
                CloudIssueChip(issue: repo.cloudIssue)
            }
        }
        .onAppear {
            repo.startForegroundRefreshLoop()
        }
        .task {
            await appUpdateGate.refresh()
        }
        .onDisappear {
            repo.stopForegroundRefreshLoop()
        }
        .onOpenURL { url in
            if let householdId = GroupDeepLink.householdId(from: url) {
                GroupNavigationCoordinator.shared.openGroup(
                    householdId: householdId,
                    showAdd: GroupDeepLink.wantsAddItem(from: url)
                )
            } else if url.scheme == "grocer", url.host == "invite",
                      let token = url.pathComponents.dropFirst().first,
                      let shareURL = ShareInviteLink.decode(token) {
                Task { await ShareCoordinator.shared.acceptShareURL(shareURL) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                repo.startForegroundRefreshLoop()
                Task {
                    await appUpdateGate.refresh()
                    await repo.refreshAfterActivation()
                    await sendRetentionHeartbeat()
                }
            } else {
                repo.stopForegroundRefreshLoop()
                // Queue a background catch-up sync for changes that arrive (or
                // whose silent push gets throttled) while we're not foreground.
                AppDelegate.scheduleBackgroundRefresh()
            }
        }
        .sheet(isPresented: Binding(
            get: { repo.joinedHouseholdId != nil },
            set: { if !$0 { repo.dismissJoinedHousehold() } }
        )) {
            JoinedGroupSheet()
        }
        .overlay {
            // While CloudKit accepts the invite (before the joined sheet is
            // ready) show a blocking spinner so the tap feels responsive.
            if repo.isAcceptingInvite && repo.joinedHouseholdId == nil {
                AcceptingInviteOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: repo.isAcceptingInvite)
        .alert("Invite Link Expired", isPresented: Binding(
            get: { repo.inviteError != nil },
            set: { if !$0 { repo.inviteError = nil } }
        )) {
            Button("OK", role: .cancel) { repo.inviteError = nil }
        } message: {
            Text(repo.inviteError ?? "")
        }
        .overlay {
            // Brief celebratory confirmation after a checkout grants Pro. A
            // richer onboarding sheet for new Pro users will replace this later.
            if subscriptions.didJustUpgradeToPro {
                UpgradedToProOverlay {
                    subscriptions.clearJustUpgradedToPro()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: subscriptions.didJustUpgradeToPro)
        .fullScreenCover(item: Binding(
            get: { appUpdateGate.requiredUpdate },
            set: { _ in }
        )) { update in
            RequiredAppUpdateView(update: update) {
                openURL(update.updateURL)
            }
            .interactiveDismissDisabled(true)
        }
    }

    private var shouldShowOnboarding: Bool {
        Self.forceShowOnboardingForDebug || (repo.hasCompletedInitialLoad && repo.households.isEmpty)
    }

    /// Tells the backend the app was opened, so the retention cron can measure
    /// inactivity. Debounced to ~once/hour and skipped before any group exists.
    private func sendRetentionHeartbeat() async {
        let settings = SettingsStore.shared
        if let last = settings.lastHeartbeatAt, Date().timeIntervalSince(last) < 3600 {
            return
        }
        let householdId = settings.selectedHouseholdId.isEmpty
            ? repo.households.first?.id
            : settings.selectedHouseholdId
        guard let householdId, !householdId.isEmpty else { return }

        settings.lastHeartbeatAt = Date()
        await APIClient.shared.reportActive(
            HeartbeatPayload(
                householdId: householdId,
                memberId: settings.memberIdOrDevice,
                deviceId: settings.deviceId
            )
        )
    }
}

// MARK: - Accepting Invite Overlay

/// Blocking spinner shown while a CloudKit share invite is being accepted, so
/// the "Join" tap feels responsive before the joined-group sheet appears.
private struct AcceptingInviteOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text("Joining list\u{2026}")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Joining list"))
    }
}

// MARK: - Upgraded To Pro Overlay

/// Brief confirmation shown after a checkout grants Grocer Pro. Mirrors the
/// joining-list overlay's look, then auto-dismisses after a couple of seconds.
private struct UpgradedToProOverlay: View {
    let onFinished: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                FAImage("checkmark.seal.fill", size: 44)
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)

                Text("You\u{2019}ve upgraded to Pro!")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You\u{2019}ve upgraded to Pro!"))
        .onAppear {
            Haptics.success()
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                onFinished()
            }
        }
    }
}

/// Forces iOS to initialize its keyboard infrastructure at app launch so the
/// first TextField focus doesn't stall while the system cold-starts the
/// keyboard process.
///
/// A short delay lets the window hierarchy settle before we trigger the
/// warm-up. `becomeFirstResponder` is followed by resign on the *next* run-loop
/// pass so the keyboard process fully spins up before we tear it down.
private struct KeyboardWarmer: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        container.alpha = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = container.window else { return }
            let field = UITextField(frame: CGRect(x: -1, y: -1, width: 1, height: 1))
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.inputAssistantItem.leadingBarButtonGroups = []
            field.inputAssistantItem.trailingBarButtonGroups = []
            window.addSubview(field)
            field.becomeFirstResponder()
            DispatchQueue.main.async {
                field.resignFirstResponder()
                field.removeFromSuperview()
            }
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

#if DEBUG
#Preview("Root — Onboarding") {
    RootView()
        .grocerPreviewEnvironment()
}
#endif

// MARK: - Shared small components

/// Compact status chip floated at the very top of the app, shown *only* for
/// severe problems (iCloud signed out, offline, or a sync error). Minor states
/// like "saving" or pending writes are intentionally silent. Tapping the chip
/// explains the cause and how to fix it.
struct CloudIssueChip: View {
    let issue: GroceryRepository.CloudIssue?

    @State private var detailIssue: CloudIssuePresentation?

    var body: some View {
        Group {
            if let issue {
                Button {
                    Haptics.tap()
                    detailIssue = CloudIssuePresentation(issue: issue)
                } label: {
                    HStack(spacing: 6) {
                        FAImage(Self.icon(for: issue))
                        Text(Self.title(for: issue))
                            .fontWeight(.semibold)
                        FAImage("info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .foregroundStyle(Self.tint(for: issue))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Self.tint(for: issue).opacity(0.35), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel(Text(Self.title(for: issue)))
                .accessibilityHint(Text("Shows how to fix this"))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: issue) { _, newIssue in
            guard detailIssue != nil else { return }
            detailIssue = newIssue.map(CloudIssuePresentation.init(issue:))
        }
        .sheet(item: $detailIssue) { presentation in
            CloudIssueDetailSheet(issue: presentation.issue)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private struct CloudIssuePresentation: Identifiable, Equatable {
        let issue: GroceryRepository.CloudIssue

        var id: String {
            switch issue {
            case .iCloudUnavailable:
                return "icloud-unavailable"
            case .offline:
                return "offline"
            case .syncError(let message):
                return "sync-error-\(message)"
            }
        }
    }

    static func icon(for issue: GroceryRepository.CloudIssue) -> String {
        switch issue {
        case .iCloudUnavailable: return "exclamationmark.icloud"
        case .offline: return "icloud.slash"
        case .syncError: return "exclamationmark.icloud"
        }
    }

    static func title(for issue: GroceryRepository.CloudIssue) -> String {
        switch issue {
        case .iCloudUnavailable: return String(localized: "iCloud")
        case .offline: return String(localized: "Offline")
        case .syncError: return String(localized: "Sync issue")
        }
    }

    static func tint(for issue: GroceryRepository.CloudIssue) -> Color {
        switch issue {
        case .iCloudUnavailable: return .orange
        case .offline: return .secondary
        case .syncError: return .red
        }
    }
}

/// Explains a `CloudIssue` and how to resolve it, with a shortcut to Settings for
/// iCloud account problems.
private struct CloudIssueDetailSheet: View {
    let issue: GroceryRepository.CloudIssue

    @Environment(GroceryRepository.self) private var repo
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            FAImage(CloudIssueChip.icon(for: issue), size: 44)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(CloudIssueChip.tint(for: issue))

            Text(heading)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Spacer()

            if showsOpenSettings {
                Button {
                    Haptics.selection()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Open Settings")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .grocerGlassButton(prominent: true)
                .controlSize(.large)
            } else {
                Button {
                    Haptics.selection()
                    retry()
                } label: {
                    HStack(spacing: 8) {
                        if isRetrying { ProgressView().controlSize(.small) }
                        Text(isRetrying ? "Checking…" : "Try Again")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .grocerGlassButton(prominent: true)
                .controlSize(.large)
                .disabled(isRetrying)
            }

            Button(role: .cancel) {
                Haptics.tap()
                dismiss()
            } label: {
                Text("Close")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .grocerGlassButton()
            .controlSize(.large)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    private func retry() {
        isRetrying = true
        Task {
            await repo.retryCloudConnection()
            isRetrying = false
            if repo.cloudIssue == nil { dismiss() }
        }
    }

    private var heading: String {
        switch issue {
        case .iCloudUnavailable: return String(localized: "iCloud is unavailable")
        case .offline: return String(localized: "You're offline")
        case .syncError: return String(localized: "Sync needs attention")
        }
    }

    private var explanation: String {
        switch issue {
        case .iCloudUnavailable:
            return String(localized: "Grocer keeps your lists in sync through iCloud. Open Settings, tap your name, and make sure you're signed in to iCloud with iCloud Drive turned on for Grocer.")
        case .offline:
            return String(localized: "Your changes are saved on this device and will sync automatically once you're back online. Check your Wi‑Fi or cellular connection.")
        case .syncError(let message):
            let base = String(localized: "Something went wrong while syncing. Pull down to refresh to try again.")
            return message.isEmpty ? base : "\(base)\n\n\(message)"
        }
    }

    private var showsOpenSettings: Bool {
        if case .iCloudUnavailable = issue { return true }
        return false
    }
}

struct CategoryHeader: View {
    let category: GroceryCategory
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            FALabel(category.localizedName, icon: category.systemImage)
            if let count {
                Text("•")
                Text("^[\(count) item](inflect: true)")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

/// Shimmer placeholder shown while the initial iCloud fetch is in progress,
/// preventing "No groups yet" from flashing before data arrives.
/// Matches the card-based ScrollView layout of the real list.
struct GroceryListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            // Quick-add skeleton
            skeletonQuickAdd
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            // Category group 1 (3 items)
            skeletonGroup(headerWidth: 72, itemCount: 3)
                .padding(.bottom, 12)

            // Category group 2 (2 items)
            skeletonGroup(headerWidth: 56, itemCount: 2)
                .padding(.bottom, 12)
        }
    }

    private var skeletonQuickAdd: some View {
        HStack(spacing: 10) {
            ShimmerCircle()
                .frame(width: 24, height: 24)
            ShimmerRect(cornerRadius: 4)
                .frame(height: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func skeletonGroup(headerWidth: CGFloat, itemCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ShimmerRect(cornerRadius: 3)
                .frame(width: headerWidth, height: 12)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(0..<itemCount, id: \.self) { index in
                    skeletonItemRow
                    if index < itemCount - 1 {
                        Divider().padding(.leading, 76)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private var skeletonItemRow: some View {
        HStack(spacing: 12) {
            ShimmerRect(cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                ShimmerRect(cornerRadius: 4)
                    .frame(width: 110, height: 14)
                ShimmerRect(cornerRadius: 3)
                    .frame(width: 70, height: 10)
            }

            Spacer()

            ShimmerCircle()
                .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
