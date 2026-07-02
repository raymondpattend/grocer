import PostHog
import SwiftUI
import UIKit

// MARK: - Joined Group Sheet

/// Confirmation sheet shown by `RootView` right after CloudKit finishes
/// accepting a share invite, summarizing the list the shopper just joined and
/// who else is on it.
struct JoinedGroupSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    private var household: Household? {
        repo.joinedHouseholdId.flatMap { id in repo.households.first { $0.id == id } }
    }

    private var groupMembers: [HouseholdMember] {
        guard let id = repo.joinedHouseholdId else { return [] }
        return repo.members
            .filter { $0.householdId == id }
            .sorted(by: HouseholdMember.stableDisplayOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                if let household {
                    groupIcon(household)

                    VStack(spacing: 8) {
                        Text("You\u{2019}ve joined \u{201c}\(household.name)\u{201d}")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        if let store = household.storeName {
                            Text(store)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !groupMembers.isEmpty {
                        membersRow
                    }
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                Haptics.tap()
                repo.dismissJoinedHousehold()
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(household?.tint ?? .green)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .presentationDetents([.medium])
        .postHogScreenView("Joined List")
    }

    private func groupIcon(_ household: Household) -> some View {
        FAImage(household.icon, size: 32)
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(household.tint.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: household.tint.opacity(0.3), radius: 12, y: 6)
    }

    private var membersRow: some View {
        VStack(spacing: 12) {
            Text("Members")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(groupMembers) { member in
                    HStack(spacing: 12) {
                        memberAvatar(member)
                        Text(member.displayName)
                            .font(.body)
                        Spacer()
                        Text(member.role.localizedName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if member.id != groupMembers.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func memberAvatar(_ member: HouseholdMember) -> some View {
        Group {
            if let data = member.profileImageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                FAImage("person.crop.circle.fill", size: 28)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }
}

#if DEBUG
#Preview("Joined List") {
    @Previewable @State var isPresented = true
    Color.clear
        .sheet(isPresented: $isPresented) {
            JoinedGroupSheetPreview()
        }
}

private struct JoinedGroupSheetPreview: View {
    var body: some View {
        let household = Household(
            id: "preview", name: "Family Groceries", ownerMemberId: "m1",
            storeName: "Whole Foods", icon: "cart.fill",
            colorTheme: .green, createdAt: .now, updatedAt: .now
        )
        let members = [
            HouseholdMember(id: "m1", householdId: "preview", displayName: "Sarah",
                            role: .owner, joinedAt: .now),
            HouseholdMember(id: "m2", householdId: "preview", displayName: "You",
                            role: .member, joinedAt: .now),
        ]
        JoinedGroupSheet()
            .grocerPreviewEnvironment(
                repository: GrocerPreview.repository(
                    households: [household],
                    members: members,
                    joinedHouseholdId: "preview"
                )
            )
    }
}
#endif
