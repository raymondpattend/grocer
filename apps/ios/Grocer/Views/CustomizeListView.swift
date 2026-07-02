import PostHog
import SwiftUI

/// List customization (name, color, icon), reachable from Settings → This List → List Appearance.
///
/// Mirrors the App Settings feature screens' look — standalone rounded cards
/// with the title baked in — but edits the current household instead of device
/// preferences.
struct CustomizeListView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    /// Prominent in-card title. Uses the standard system font (bold).
    private let titleFont = Font.system(.title2, design: .default, weight: .bold)

    @State private var name = ""
    @State private var icon = GROUP_ICON_CHOICES[0]
    @State private var theme: ListColorTheme = .default
    @State private var saveError: String?

    private let columns = Array(repeating: GridItem(.flexible()), count: 6)

    private var canEdit: Bool { repo.isOwnerOfCurrentGroup }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                nameCard
                colorCard
                iconCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .disabled(!canEdit)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).bold()
                    .disabled(!canEdit || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
        .alert("Couldn't Save List", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .postHogScreenView("Customize List")
    }

    // MARK: - Cards

    private var nameCard: some View {
        featureCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("List Name")
                    .font(titleFont)
                HStack(spacing: 14) {
                    FAImage(icon, relativeTo: .title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(theme.color))
                    TextField(String(localized: "List name"), text: $name)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Color(.tertiarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
                        }
                }
            }
        }
    }

    private var colorCard: some View {
        featureCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Color")
                    .font(titleFont)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ListColorTheme.allCases) { t in
                        Button {
                            Haptics.selection()
                            theme = t
                        } label: {
                            Circle()
                                .fill(t.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if t == theme {
                                        FAImage("checkmark", relativeTo: .caption).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t.localizedName)
                        .accessibilityAddTraits(t == theme ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    private var iconCard: some View {
        featureCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Icon")
                    .font(titleFont)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(GROUP_ICON_CHOICES, id: \.self) { choice in
                        Button {
                            Haptics.selection()
                            icon = choice
                        } label: {
                            FAImage(choice, relativeTo: .title3)
                                .foregroundStyle(choice == icon ? .white : theme.color)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(choice == icon
                                    ? AnyShapeStyle(theme.color)
                                    : AnyShapeStyle(theme.color.opacity(0.15))))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice)
                        .accessibilityAddTraits(choice == icon ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    // MARK: - Load / save

    private func load() {
        guard let group = repo.currentHousehold else { return }
        name = group.name
        icon = group.icon
        theme = group.colorTheme
    }

    private func save() {
        guard canEdit else {
            Haptics.error()
            saveError = String(localized: "Only the list owner can edit list details.")
            return
        }
        repo.updateGroup(name: name.trimmingCharacters(in: .whitespaces),
                         store: repo.currentHousehold?.storeName,
                         icon: icon,
                         theme: theme)
        Haptics.success()
        dismiss()
    }

    // MARK: - Building blocks

    /// A standalone setting card: large rounded surface with generous padding.
    /// Matches the App Settings feature-screen card style.
    @ViewBuilder
    private func featureCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
            }
    }
}

#if DEBUG
#Preview("Customize List") {
    NavigationStack {
        CustomizeListView()
            .grocerPreviewEnvironment()
    }
}
#endif
