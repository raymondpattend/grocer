import Contacts
import MessageUI
import PostHog
import SwiftUI
import UIKit

/// Branded contacts list for inviting people to a group. The user ticks the
/// people they want, and we drop them into a native Messages compose sheet with
/// a single invite link. CloudKit only auto-adds participants whose contact info
/// is a discoverable Apple ID, so a shared link is the path that works for
/// everyone — recipients tap it to join via `ShareAcceptance`.
struct InviteContactsView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    @State private var store = ContactsStore()
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var preparing = false
    @State private var errorMessage: String?
    @State private var messagePayload: MessagePayload?

    private var filtered: [InviteContact] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.contacts }
        return store.contacts.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Invite People")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            Haptics.tap()
                            dismiss()
                        }
                    }
                }
        }
        .task { await store.load() }
        .sheet(item: $messagePayload) { payload in
            MessageComposer(recipients: payload.recipients, body: payload.body) { sent in
                messagePayload = nil
                if sent { dismiss() }
            }
            .ignoresSafeArea()
        }
        .alert("Couldn\u{2019}t Invite", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            permissionDenied
        case .ready:
            contactsList
        }
    }

    private var contactsList: some View {
        List {
            ForEach(filtered) { contact in
                Button {
                    toggle(contact)
                } label: {
                    HStack(spacing: 12) {
                        avatar(for: contact)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.name).foregroundStyle(.primary)
                            Text(contact.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selected.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected.contains(contact.id) ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Search contacts")
        .overlay {
            if store.contacts.isEmpty {
                ContentUnavailableView("No Contacts", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .safeAreaInset(edge: .bottom) { inviteButton }
    }

    private var inviteButton: some View {
        Button(action: invite) {
            Text(selected.isEmpty
                 ? String(localized: "Select Contacts to Invite")
                 : String(localized: "Invite \(selected.count)"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .overlay(alignment: .trailing) {
                    if preparing { ProgressView().padding(.trailing, 16) }
                }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(selected.isEmpty || preparing)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var permissionDenied: some View {
        ContentUnavailableView {
            Label("Contacts Access Off", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("Turn on Contacts for Grocer in Settings to pick people to invite, or use \u{201C}Get a link instead.\u{201D}")
        } actions: {
            Button("Open Settings") {
                Haptics.selection()
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private func avatar(for contact: InviteContact) -> some View {
        if let data = contact.imageData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 40, height: 40).clipShape(Circle())
        } else {
            Text(contact.initials)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor.gradient))
        }
    }

    private func toggle(_ contact: InviteContact) {
        Haptics.selection()
        if selected.contains(contact.id) { selected.remove(contact.id) }
        else { selected.insert(contact.id) }
    }

    private func invite() {
        Haptics.selection()
        let recipients = store.contacts
            .filter { selected.contains($0.id) }
            .map(\.sendable)
        guard !recipients.isEmpty else { return }
        PostHogSDK.shared.capture("group_member_invited", properties: [
            "invite_count": recipients.count,
            "group_name": repo.currentHousehold?.name ?? "unknown",
        ])

        guard MFMessageComposeViewController.canSendText() else {
            // No Messages on this device (e.g. simulator) — fall back to the
            // system share sheet so the link can still be sent somewhere.
            prepareLink { url in
                ShareSheetPresenter.presentInvite(url: url)
                dismiss()
            }
            return
        }

        prepareLink { url in
            let groupName = repo.currentHousehold?.name ?? String(localized: "my grocery list")
            messagePayload = MessagePayload(
                recipients: recipients,
                body: String(localized: "Join \u{201C}\(groupName)\u{201D} on Grocer so we can share the list: \(url.absoluteString)")
            )
        }
    }

    private func prepareLink(_ completion: @escaping (URL) -> Void) {
        if let reason = repo.sharingUnavailableReason {
            Haptics.error()
            errorMessage = reason
            return
        }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                // Branded share.grocer.sh link; multi-use so every chosen
                // recipient can accept the same message.
                let url = try await repo.prepareBrandedInviteURL(singleUse: false)
                Haptics.success()
                completion(url)
            } catch {
                Haptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A selected contact's invite message: shared invite link sent to one or more
/// recipients at once.
private struct MessagePayload: Identifiable {
    let id = UUID()
    let recipients: [String]
    let body: String
}

// MARK: - Contact loading

struct InviteContact: Identifiable {
    let id: String
    let name: String
    /// Human-readable phone/email shown under the name.
    let detail: String
    /// Phone number or email address used as the Messages recipient.
    let sendable: String
    let imageData: Data?

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

@MainActor
@Observable
final class ContactsStore {
    enum Phase { case loading, denied, ready }

    private(set) var phase: Phase = .loading
    private(set) var contacts: [InviteContact] = []

    func load() async {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        switch status {
        case .notDetermined:
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            guard granted else { phase = .denied; return }
        case .denied, .restricted:
            phase = .denied
            return
        default:
            break
        }

        let fetched = await Self.fetchContacts(using: store)
        contacts = fetched
        phase = .ready
    }

    /// Reads contacts off the main actor — the CNContactStore enumeration is
    /// synchronous and can be slow for large address books.
    nonisolated private static func fetchContacts(using store: CNContactStore) async -> [InviteContact] {
        await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .givenName

            var result: [InviteContact] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                guard let sendable = contact.phoneNumbers.first?.value.stringValue
                    ?? (contact.emailAddresses.first?.value as String?) else { return }
                let name = CNContactFormatter.string(from: contact, style: .fullName)
                    ?? sendable
                let detail = contact.phoneNumbers.first?.value.stringValue
                    ?? (contact.emailAddresses.first?.value as String? ?? "")
                result.append(InviteContact(
                    id: contact.identifier,
                    name: name,
                    detail: detail,
                    sendable: sendable,
                    imageData: contact.thumbnailImageData
                ))
            }
            return result
        }.value
    }
}

// MARK: - Messages composer

/// Thin SwiftUI wrapper over `MFMessageComposeViewController` so we can present
/// a pre-filled iMessage/SMS with the chosen recipients and the invite link.
private struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onFinish: (_ sent: Bool) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (_ sent: Bool) -> Void
        init(onFinish: @escaping (_ sent: Bool) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(result == .sent)
        }
    }
}
