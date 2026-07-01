import PostHog
import SwiftUI
import UIKit

struct AddItemView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var quantity = ""
    @State private var category: GroceryCategory = .other
    @State private var notes = ""
    @State private var replacementPreference = ""
    @State private var priority: ItemPriority = .normal
    @State private var categoryEditedManually = false
    @State private var showPastItems = false

    var body: some View {
        Form {
            if !repo.pastItemNames.isEmpty {
                Section {
                    Button {
                        Haptics.selection()
                        showPastItems = true
                    } label: {
                        Label("Add from Previous Items", systemImage: "clock.arrow.circlepath")
                    }
                }
            }

            Section("Item") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .onSubmit { if canSave { save() } }
            }

            Section("Quantity") {
                QuantityStepperField(
                    quantity: $quantity,
                    proposedUnit: proposedUnit,
                    tint: .green,
                    prominent: true
                )
                .padding(.vertical, 8)
            }

            Section("Details (optional)") {
                Picker("Category", selection: $category) {
                    ForEach(GroceryCategory.ordered) { Text($0.localizedName).tag($0) }
                }
                .onChange(of: category) { _, _ in categoryEditedManually = true }
                Toggle("Critical", isOn: Binding(
                    get: { priority == .critical },
                    set: { priority = $0 ? .critical : .normal }
                ))
                TextField("Notes", text: $notes, axis: .vertical)
            }

            Section("If unavailable") {
                TextField("Replacement preference", text: $replacementPreference)
                    .textInputAutocapitalization(.sentences)
            }
        }
        .navigationTitle("Add Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    Haptics.tap()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: save).bold()
                    .disabled(!canSave)
            }
        }
        .onChange(of: name) { _, newValue in
            guard !categoryEditedManually else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2 {
                category = CategoryGuess.guess(for: trimmed)
            }
        }
        .sheet(isPresented: $showPastItems) {
            PastItemsSheet { selectedName in
                name = selectedName
                if !categoryEditedManually {
                    category = CategoryGuess.guess(for: selectedName)
                }
            }
        }
        .postHogScreenView("Add Item")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Natural unit proposed for the current name (e.g. eggs → "dozen"), offered
    /// by the quantity stepper. `nil` when nothing fits.
    private var proposedUnit: String? {
        let unit = UnitGuess.guess(for: trimmedName)
        return unit.isEmpty ? nil : unit
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
    }

    private func save() {
        Haptics.success()
        PostHogSDK.shared.capture("items_added", properties: [
            "item_count": 1,
            "category": category.rawValue,
            "has_quantity": !quantity.isEmpty,
            "source": "add_item_form",
        ])
        repo.addItem(
            name: trimmedName,
            quantity: quantity,
            category: category,
            notes: notes,
            priority: priority,
            replacementPreference: replacementPreference
        )
        dismiss()
    }
}

// MARK: - Full-screen add flow
//
// A list-style composer. The user types one grocery item per line; pressing
// return (or dismissing the keyboard) commits the line, lifting it out of the
// compose field into a flat row. Each committed line is interpreted independently
// as exactly one item — never split — showing a skeleton image and a shimmering
// "Thinking…" until the AI resolves its name, quantity, and unit. The amount then
// becomes a liquid-glass button that opens a stepper popover; editing a row's name
// re-interprets it. Camera (photo → identify) and History add already-resolved
// rows. "Add" saves every committed row and closes the modal.

struct AddItemSearchView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var tint: Color = .green

    /// The list to add to. `nil` uses the app's current selection; combined
    /// trips pass an explicit list so adding to one group doesn't switch the
    /// whole app's selected group as a side effect.
    var targetListId: String? = nil

    /// The active line being typed. The compose field only ever holds this one
    /// uncommitted line; committing it lifts it out into an `items` row.
    @State private var draftText = ""
    /// Committed lines, in commit order. Each one interprets independently — a
    /// line is always exactly one grocery item, never split.
    @State private var items: [LineItem] = []
    @State private var contentAppeared = false
    @State private var showHistory = false
    @State private var showDiscardConfirm = false
    /// Whether the software keyboard is currently up — drives the floating controls.
    @State private var keyboardVisible = false
    /// The row whose quantity stepper is currently expanded (at most one).
    @State private var expandedQuantityItem: UUID?

    // MARK: Photo capture → AI identify
    /// Presents the custom in-app camera (captures with no Retake/Use Photo step).
    @State private var showCamera = false
    /// Presents the photo library — the fallback where no camera exists (Simulator).
    @State private var showImagePicker = false
    /// The user-taken photo, shown small in the confirm card and attached to the item.
    @State private var captureImage: UIImage?
    /// Downscaled JPEG attached to the item once confirmed.
    @State private var capturePhotoData: Data?
    /// Holds the just-captured photo between the camera/library cover dismissing
    /// and the identify sheet presenting. Presenting the sheet while the cover is
    /// still animating away is silently dropped by UIKit, so we stash the photo
    /// and wait for the cover's `onDismiss` (fires once it's fully gone).
    @State private var pendingCaptureImage: UIImage?
    /// Drives the post-capture confirm card.
    @State private var showIdentifyCard = false
    /// True while the vision request is in flight.
    @State private var isIdentifying = false
    /// Whether the model returned a usable guess (for analytics).
    @State private var didIdentify = false
    @State private var identifiedName = ""
    @State private var identifiedCategory: GroceryCategory = .other
    @State private var identifiedQuantity = ""
    @State private var identifiedNotes = ""
    /// Set when the identify call is rejected with a 429 so the view can show
    /// an actionable error rather than a silent empty result.
    @State private var aiRateLimited = false
    /// True when the identify card was opened for manual entry (no photo) rather
    /// than from a capture — drives the "Cancel" vs "Retake" button and analytics.
    @State private var identifyIsManual = false
    /// True when the camera/library is being opened only to attach a photo to the
    /// already-open manual card, so its `onDismiss` attaches the image rather than
    /// re-running identification.
    @State private var attachPhotoOnly = false

    /// Typed amounts the count cap clamped (e.g. "15000 milk"), awaiting a "did you
    /// mean that many?" confirmation. Shown one at a time via `overCapPrompt`.
    @State private var overCapQueue: [OverCapPrompt] = []
    /// The over-cap confirmation currently presented, if any.
    @State private var overCapPrompt: OverCapPrompt?

    /// First-responder for the active compose line. A plain Bool bridged to the
    /// UIKit-backed compose field (so it can detect backspace-on-empty); each
    /// committed row owns its own focus for inline name edits.
    @State private var draftFocused = false
    /// Set to a row id to programmatically focus that row's name field — used when
    /// backspacing on the empty compose line to jump up to the previous item.
    @State private var focusRequestItem: UUID?

    /// Scroll anchor pinned to the active compose line so each commit keeps it in
    /// view as the list of rows grows above it.
    private let composeAnchor = "compose-anchor"

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether anything is staged or typed — gates the discard prompt and the
    /// History pane's confirm checkmark.
    private var hasProposedItems: Bool {
        !items.isEmpty || !trimmedDraft.isEmpty
    }

    /// Count "Add" will save: every named committed row, plus the line still in
    /// the field (which is committed first on save).
    private var addableCount: Int {
        items.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            + (trimmedDraft.isEmpty ? 0 : 1)
    }

    /// Distinct items anyone in the group has added before — gates the History
    /// button (the pane itself reads the live list straight from the repo).
    private var historySuggestions: [GroceryItemSuggestion] {
        repo.currentItemSuggestions
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
                // Tapping anywhere off a text field dismisses the keyboard.
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }

            addFlowContent
                .opacity(contentAppeared ? 1 : 0)
                .offset(y: contentAppeared ? 0 : 14)
                // The close button is sticky (added after the opacity/offset so it
                // stays put as the title scrolls beneath it).
                .overlay(alignment: .top) {
                    closeButton
                }
                .overlay(alignment: .bottom) {
                    floatingControls
                }
        }
        .sheet(isPresented: $showHistory) {
            HistoryItemsView(
                tint: tint,
                hasProposedItems: hasProposedItems,
                onSelect: { name, quantity, category in
                    // Stay in History after adding so several previously-bought
                    // items can be batch-added; the user closes via the sheet.
                    addFromHistory(name: name, quantity: quantity, category: category)
                },
                onUpdateQuantity: { name, quantity in
                    updateHistoryQuantity(name: name, quantity: quantity)
                },
                onRemove: { name in
                    removeFromHistory(name: name)
                },
                onDeleteFromHistory: { name in
                    deleteFromHistory(name: name)
                },
                onClose: { showHistory = false }
            )
        }
        .tint(tint)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)) {
                contentAppeared = true
            }
            refocusInput(after: 0.24)
        }
        .onChange(of: draftText) { _, _ in
            // A return (or a multi-line paste) introduces newline(s): commit every
            // completed line and keep only the trailing, still-being-typed text.
            // No interpretation runs while typing within a line.
            commitCompletedLines()
        }
        .onChange(of: draftFocused) { _, focused in
            // Losing focus (keyboard dismissed, tapped away, opened Camera/History)
            // commits whatever line is still in the field; focusing it back collapses
            // any open quantity stepper.
            if focused {
                collapseQuantitySteppers()
            } else {
                commitActiveLine()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Pinned to the bottom and kept visible while the keyboard is up (it
            // rides just above it) so the running item count is always in reach.
            bottomAction
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .alert("Discard proposed items?", isPresented: $showDiscardConfirm) {
            Button("Discard", role: .destructive) {
                Haptics.warning()
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have items ready to add. Close without adding them?")
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: presentIdentifyIfPending) {
            CameraCaptureView { image in
                pendingCaptureImage = image
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showImagePicker, onDismiss: presentIdentifyIfPending) {
            ImagePicker { image in
                pendingCaptureImage = image
                showImagePicker = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showIdentifyCard) {
            IdentifyItemCard(
                userPhoto: $captureImage,
                isIdentifying: $isIdentifying,
                name: $identifiedName,
                category: $identifiedCategory,
                quantity: $identifiedQuantity,
                notes: $identifiedNotes,
                tint: tint,
                allowsRetake: !identifyIsManual,
                onAdd: commitIdentifiedItem,
                onRetake: retakePhoto,
                onCancel: cancelIdentifyCard,
                onAddPhoto: startManualPhotoCapture,
                onRemovePhoto: removeManualPhoto
            )
        }
        .postHogScreenView("Add Item Search")
        .alert("Too Many Requests", isPresented: $aiRateLimited) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You've made too many photo requests. Please wait a moment and try again.")
        }
        .alert("Did you mean that many?", isPresented: Binding(
            get: { overCapPrompt != nil },
            set: { if !$0 { overCapPrompt = nil } }
        ), presenting: overCapPrompt) { prompt in
            Button("Use \(Quantity.displayString(prompt.originalQuantity))") {
                applyUncapped(prompt)
            }
            Button("Keep \(Quantity.displayString(prompt.cappedQuantity))", role: .cancel) {
                scheduleNextOverCapPrompt()
            }
        } message: { prompt in
            Text("You entered \(Quantity.displayString(prompt.originalQuantity)) \(prompt.name). Add that many, or keep it at \(Quantity.displayString(prompt.cappedQuantity))?")
        }
    }

    /// Bottom-floating row: the camera and History buttons are pinned to the
    /// leading edge side by side; while the keyboard is up a dismiss button joins
    /// the trailing edge.
    private var floatingControls: some View {
        HStack(spacing: 12) {
            cameraButton
            manualEntryButton
            if !historySuggestions.isEmpty {
                historyButton
            }
            Spacer(minLength: 0)
            if keyboardVisible {
                keyboardDownButton
            }
        }
        .padding(.horizontal, 16)
        // Sits a touch lower (closer to the bottom edge) than the close button up top.
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: keyboardVisible)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86),
                   value: historySuggestions.isEmpty)
    }

    /// Floating glass circle that opens the camera to photograph an item (or a
    /// written list), then has the server identify it. Icon-only, sized and styled
    /// to match the close button.
    private var cameraButton: some View {
        Button {
            startPhotoCapture()
        } label: {
            Image(systemName: "camera.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
                .grocerLiquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityLabel("Take a photo to identify an item")
    }

    /// Floating glass circle that opens the same item card as the camera flow, but
    /// empty — for entering an item by hand (name, category, quantity, notes) with
    /// the option to attach a photo, instead of typing it as plain text.
    private var manualEntryButton: some View {
        Button {
            startManualEntry()
        } label: {
            Image(systemName: "plus.circle.dashed")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
                .grocerLiquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityLabel("Add an item manually")
    }

    /// Floating glass circle that swaps the add flow for the group's item history.
    /// Icon-only, matching the close and camera buttons.
    private var historyButton: some View {
        Button {
            Haptics.tap()
            draftFocused = false
            showHistory = true
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
                .grocerLiquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityLabel("Add from history")
    }

    /// Floating glass circle that drops the keyboard. Lives on the trailing edge of
    /// the bottom controls row and only appears while the keyboard is up.
    private var keyboardDownButton: some View {
        Button {
            Haptics.tap()
            dismissKeyboard()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .grocerLiquidGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .transition(.opacity)
        .accessibilityLabel(String(localized: "Dismiss keyboard"))
    }

    private var addFlowContent: some View {
        // No pinned header bar: the title chip scrolls with the content while only
        // the close button stays put (a sticky overlay in `body`). A
        // `ScrollViewReader` lets each commit nudge the active line back into view.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    titleChip
                    itemsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                // Reserve space for the always-present floating controls row (pill
                // height 34 + 16 bottom inset) so a long list can scroll clear of it
                // instead of having its last rows overlapped.
                .padding(.bottom, 74)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: items.count) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    proxy.scrollTo(composeAnchor, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var itemsSection: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                listBody
            }
        } else {
            listBody
        }
    }

    /// The committed rows followed by the active compose line. Each row reads like
    /// a typed line that has gained a leading image and a trailing quantity — not a
    /// card. The compose line is always last, so new items stack above it as they
    /// commit.
    private var listBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                LineItemRow(
                    item: item,
                    tint: tint,
                    name: nameBinding(for: item.id),
                    quantity: quantityBinding(for: item.id),
                    quantityExpanded: Binding(
                        get: { expandedQuantityItem == item.id },
                        set: { expandedQuantityItem = $0 ? item.id : nil }
                    ),
                    focusRequest: $focusRequestItem,
                    onReturn: { draftFocused = true },
                    onBeginEditingName: { collapseQuantitySteppers() },
                    onCommitName: { recalcIfNeeded(item.id) },
                    onRemove: { removeItem(item.id) },
                    onRemovePriority: {
                        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
                            items[idx].priority = .normal
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }

            composeLine

            if items.isEmpty {
                emptyProposed
            }
        }
    }

    /// The page title as a Liquid Glass capsule chip. It scrolls with the content
    /// (not pinned), centered across the content width (the close button floats
    /// over the leading edge).
    private var titleChip: some View {
        Text("Add Items")
            // ~10% larger than .headline (17pt).
            .font(.system(size: 18.7, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 36)
//            .grocerLiquidGlass(in: Capsule())
            // Purely a label — taps pass through to nothing.
            .allowsHitTesting(false)
    }

    /// The sticky close control, floated over the content at the top-leading edge
    /// (there's no header bar behind it). It always closes the flow — keyboard
    /// dismissal lives on the bottom controls row instead.
    private var closeButton: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap()
                attemptClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
                    .grocerLiquidGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .accessibilityLabel(String(localized: "Close"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Compose line (the active, uncommitted item)

    /// The line currently being typed. Visually a list row whose leading image
    /// slot and trailing accessory stay empty until it commits. A vertical-axis
    /// field so Return inserts a newline we detect (`commitCompletedLines`) to lift
    /// the line out into a row.
    private var composeLine: some View {
        HStack(alignment: .center, spacing: 10) {
            // A small leading dot marks the active input line. Its slot is narrow
            // before any item exists (so the placeholder sits near the left) and
            // widens to align with the rows' images once items are added. The width
            // animates as part of the commit's own `withAnimation`, so it isn't
            // given a separate `.animation(value:)` (which desynced the layout,
            // leaving the line mis-indented until the next item).
            Circle()
                .fill(.tertiary)
                .frame(width: 7, height: 7)
                .frame(width: items.isEmpty ? 8 : LineItemRow.imageSize)
            ComposeTextField(text: $draftText, isFocused: $draftFocused,
                             onBackspaceWhenEmpty: editPreviousItem)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .id(composeAnchor)
        // Tapping the input (even while already focused) collapses any open stepper.
        .simultaneousGesture(TapGesture().onEnded { collapseQuantitySteppers() })
    }

    /// Backspace on the empty compose line: jump up to edit the previous item's
    /// name (cursor lands there) instead of doing nothing.
    private func editPreviousItem() {
        guard trimmedDraft.isEmpty, let last = items.last else { return }
        Haptics.tap()
        focusRequestItem = last.id
    }

    // Shown beneath the compose line before anything is typed: a short,
    // monochrome cheat-sheet of the things shoppers tend not to discover on their
    // own (inline amounts, the "!" urgency marker, return-per-item, the camera).
    private var emptyProposed: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Tips", systemImage: "lightbulb")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.composeTips) { tip in
                    composeTipRow(tip)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
        .padding(.bottom, 20)
        .padding(.horizontal, 4)
    }

    private func composeTipRow(_ tip: ComposeTip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: tip.icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(tip.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private struct ComposeTip: Identifiable {
        let id = UUID()
        let icon: String
        let text: LocalizedStringKey
    }

    // Bold spans (markdown) only change weight, never colour, so the whole panel
    // stays grayscale. The icons mirror what each tip refers to: the urgency mark
    // uses the same "exclamationmark" symbol as the CRITICAL chip.
    private static let composeTips: [ComposeTip] = [
        ComposeTip(icon: "number", text: "Just say the amount, like **10 Potatoes**"),
        ComposeTip(icon: "exclamationmark", text: "Mark an item as critical with **!**, like **Milk!**"),
        ComposeTip(icon: "return", text: "Press **return** to start a new line"),
        ComposeTip(icon: "camera", text: "Tap the **camera** to add items from a photo"),
    ]

    private var bottomAction: some View {
        Button {
            addItems()
        } label: {
            Text("Add ^[\(addableCount) item](inflect: true)")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        }
        .grocerGlassButton(prominent: true)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .disabled(addableCount == 0)
        // Removing the last row drops the count to 0; ease the active→disabled
        // style change so the button fades between states instead of flashing.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: addableCount == 0)
    }

    // MARK: - Commit (typed line → row)

    /// Commit every completed line in the draft (everything before a newline),
    /// keeping the trailing, still-being-typed text in the field. Handles both a
    /// single Return and a multi-line paste.
    private func commitCompletedLines() {
        guard draftText.contains("\n") else { return }
        let segments = draftText.components(separatedBy: "\n")
        for segment in segments.dropLast() {
            commitLine(segment)
        }
        let remainder = segments.last ?? ""
        if remainder != draftText { draftText = remainder }
        // Keep the caret on the fresh line so the user can keep listing items.
        draftFocused = true
    }

    /// Commit whatever is currently typed — used when the keyboard is dismissed, or
    /// the user taps "Add" with a line still in the field.
    private func commitActiveLine() {
        guard !trimmedDraft.isEmpty else { return }
        // This runs as the field loses focus — including when the keyboard-down
        // button dismisses the keyboard. Commit without the row-insertion spring so
        // that spring doesn't sweep the keyboard's safe-area shift into a bouncy
        // transaction, which made the floating controls and "Add" bar jump.
        commitLine(draftText, animated: false)
        draftText = ""
    }

    /// Stage one typed line as a thinking row and start interpreting it. A line is
    /// always exactly one grocery item — it is never split, however it reads.
    /// `animated` springs the row in (a Return commit); blur-driven commits pass
    /// false so the insertion doesn't bounce the keyboard dismissal.
    private func commitLine(_ raw: String, animated: Bool = true) {
        let priority: ItemPriority = Self.hasHighPriorityMarker(in: raw) ? .critical : .normal
        let name = Self.strippingPriorityMarkers(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .groceryTitleCased
        guard !name.isEmpty else { return }

        let item = LineItem(
            name: name,
            state: .thinking,
            unit: UnitGuess.guess(for: name),
            category: CategoryGuess.guess(for: name),
            priority: priority
        )
        // A firm thud as the line is committed (Enter) and the row drops into thinking.
        Haptics.commit()
        let insertion: Animation? = animated && !reduceMotion
            ? .spring(response: 0.32, dampingFraction: 0.86) : nil
        withAnimation(insertion) {
            items.append(item)
        }
        Task { await interpret(item.id, allowSplit: true) }
    }

    /// Apply a manual name edit. Clearing the name removes the row. Otherwise the
    /// name (and the product image, which is keyed on it) and the inline priority
    /// marker update — but the quantity and its label are left exactly as they were.
    /// A manual edit never re-runs the AI, never re-enters thinking, and never
    /// splits into multiple items.
    private func recalcIfNeeded(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let raw = items[idx].name
        let priority: ItemPriority = Self.hasHighPriorityMarker(in: raw) ? .critical : .normal
        let name = Self.strippingPriorityMarkers(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .groceryTitleCased
        guard !name.isEmpty else { removeItem(id); return }

        let nameChanged = name.lowercased() != items[idx].lastInterpretedName.lowercased()
        guard nameChanged || priority != items[idx].priority else { return }

        items[idx].name = name
        items[idx].priority = priority
        items[idx].lastInterpretedName = name
        // Keep the category sensible for the new name (on-device, no AI). Quantity
        // and unit are intentionally left untouched.
        if nameChanged {
            items[idx].category = CategoryGuess.guess(for: name)
        }
    }

    // MARK: - Interpret (one line → one item)

    /// Resolve a single committed line into a name, quantity, unit, and category
    /// via the AI parser, with an on-device fallback. Best-effort: a failure (or
    /// offline) keeps the user's own text with on-device guesses.
    /// `allowSplit` is true only for a freshly committed line; manual name edits
    /// pass false so an edited item never fragments into several rows.
    private func interpret(_ id: UUID, allowSplit: Bool) async {
        guard let line = items.first(where: { $0.id == id }) else { return }
        let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // Only commas delineate multiple items, and only on a freshly committed
        // line: split it into comma segments and interpret each as a single item
        // (the AI never splits within a segment, so "Banana Goo Pie with Potatos"
        // stays one item while "10 potatoes, milk, cheese" becomes three). A manual
        // edit (`allowSplit == false`) always stays a single item.
        let lineSegments: [String]
        if allowSplit {
            let segments = name.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Cap the number of parse calls at 10: fold anything past the 10th back
            // into the final item so a huge comma paste can't fan out into dozens
            // of network requests.
            let maxItems = 10
            if segments.count > maxItems {
                lineSegments = Array(segments.prefix(maxItems - 1))
                    + [segments.dropFirst(maxItems - 1).joined(separator: ", ")]
            } else {
                lineSegments = segments.isEmpty ? [name] : segments
            }
        } else {
            lineSegments = [name]
        }

        var resolved: [ResolvedItem] = []
        for segment in lineSegments {
            let parsed = await APIClient.shared.parseList(segment)
            resolved.append(singleResolvedItem(from: parsed, fallbackName: segment))
        }

        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        // The user may have edited the name again while this was in flight; only
        // apply if it still matches what we interpreted (their edit re-runs this).
        guard items[idx].name.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return }
        guard let first = resolved.first else { return }

        let priority = items[idx].priority
        var capPrompts: [OverCapPrompt] = []
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            items[idx].name = first.name
            items[idx].quantity = first.quantity
            items[idx].unit = first.unit
            items[idx].category = first.category
            items[idx].lastInterpretedName = first.name
            items[idx].state = .resolved
            if let original = first.uncappedQuantity {
                capPrompts.append(OverCapPrompt(itemID: items[idx].id, name: first.name,
                                                cappedQuantity: first.quantity, originalQuantity: original))
            }

            // Extra comma segments land as their own rows just after this one.
            if resolved.count > 1 {
                let extras = resolved.dropFirst()
                let rows = extras.map { r in
                    LineItem(name: r.name, state: .resolved, quantity: r.quantity,
                             unit: r.unit, category: r.category, priority: priority)
                }
                items.insert(contentsOf: rows, at: idx + 1)
                for (offset, r) in extras.enumerated() {
                    guard let original = r.uncappedQuantity else { continue }
                    let row = items[idx + 1 + offset]
                    capPrompts.append(OverCapPrompt(itemID: row.id, name: row.name,
                                                    cappedQuantity: row.quantity, originalQuantity: original))
                }
            }
        }
        // A soft tick as the row(s) finish thinking and resolve — gentler than the
        // firm commit thud, so an item settling in doesn't jolt.
        Haptics.selection()
        enqueueOverCapPrompts(capPrompts)
        Task { await APIClient.shared.prewarmImages(resolved.map(\.name)) }
    }

    private struct ResolvedItem {
        var name: String
        var quantity: String
        var unit: String
        var category: GroceryCategory
        /// When the shopper's typed amount was clamped to the cap, the original
        /// (uncapped) quantity they typed — so we can offer to restore it.
        var uncappedQuantity: String?
    }

    /// Coalesce one comma segment's parse result into a single item.
    ///
    /// We use the AI's name only when it's *faithful* to what the user typed — a
    /// clean extraction/normalization (e.g. "a dozen eggs" → "Eggs") rather than a
    /// substitution that introduces words the user never wrote (e.g. "15 pancakes"
    /// → "Pancake mix"). When the AI strays, or over-splits a comma-free segment, or
    /// returns nothing, we keep the user's own wording. The user's explicit leading
    /// amount always wins; the AI's unit is used as the label only for a faithful
    /// name (otherwise its parse is suspect).
    private func singleResolvedItem(from parsed: [ParsedItem], fallbackName segment: String) -> ResolvedItem {
        let (userAmount, userNoun) = Self.splitLeadingAmount(segment)
        let typedName = (userNoun.isEmpty ? segment : userNoun).groceryTitleCased

        guard parsed.count == 1, let d = parsed.first.flatMap(DetectedItem.init(parsedItem:)) else {
            let q = resolveQuantity(name: typedName, aiAmount: userAmount, aiUnit: "")
            let capped = applyTypedCap(name: typedName, unit: q.unit, quantity: q.quantity, userAmount: userAmount)
            return ResolvedItem(name: typedName, quantity: capped.quantity, unit: q.unit,
                                category: CategoryGuess.guess(for: typedName),
                                uncappedQuantity: capped.uncapped)
        }

        let faithful = Self.aiNameIsFaithful(d.name, to: segment)
        let name = faithful ? d.name : typedName
        // The user's explicit amount wins; otherwise the AI's amount.
        let aiParsed = Quantity(parsing: d.quantity)
        let amount = userAmount.isEmpty ? (aiParsed.amount.map(Quantity.formatAmount) ?? "") : userAmount
        // Trust the AI's unit label only when its name was faithful.
        let unit = faithful ? (d.unit.isEmpty ? aiParsed.unit : d.unit) : ""
        let q = resolveQuantity(name: name, aiAmount: amount, aiUnit: unit)
        let capped = applyTypedCap(name: name, unit: q.unit, quantity: q.quantity, userAmount: userAmount)
        return ResolvedItem(name: name, quantity: capped.quantity, unit: q.unit, category: d.category,
                            uncappedQuantity: capped.uncapped)
    }

    /// Apply the count cap to a freshly resolved item. When the shopper *typed* an
    /// over-cap amount (e.g. "15000 milk"), swap in a sensible fallback for the row
    /// — the household's last-used amount from History if known, else the cap — and
    /// report the original they typed so it can be confirmed. Otherwise the quantity
    /// is returned unchanged with no confirmation.
    private func applyTypedCap(name: String, unit: String, quantity: String,
                              userAmount: String) -> (quantity: String, uncapped: String?) {
        guard let typed = Quantity(parsing: userAmount).amount,
              !GroceryUnits.isWeightUnit(unit),
              typed > GroceryUnits.maxCountableAmount else { return (quantity, nil) }
        let original = Quantity(amount: typed, unit: unit).formatted
        return (cappedFallbackQuantity(name: name, unit: unit), original)
    }

    /// The amount to fall back to when a typed amount is clamped: the household's
    /// last-used amount for this item if known, else the cap (999) in the resolved
    /// unit.
    private func cappedFallbackQuantity(name: String, unit: String) -> String {
        if let known = repo.currentItemSuggestion(named: name)?.quantity?
            .trimmingCharacters(in: .whitespaces), !known.isEmpty {
            return known
        }
        return Quantity(amount: GroceryUnits.maxCountableAmount, unit: unit).formatted
    }

    /// Split a leading numeric amount off the front of a segment, e.g.
    /// "15 pancakes" → ("15", "pancakes"), "pancakes" → ("", "pancakes").
    private static func splitLeadingAmount(_ segment: String) -> (amount: String, rest: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        var index = trimmed.startIndex
        var digits = ""
        while index < trimmed.endIndex, trimmed[index].isNumber || trimmed[index] == "." {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        let rest = String(trimmed[index...]).trimmingCharacters(in: .whitespaces)
        return (digits, rest)
    }

    /// Whether the AI's name is a faithful read of the user's text — i.e. it adds no
    /// new word. Every significant AI word must match a user word by a shared prefix
    /// (so "pancake" ↔ "pancakes" passes, but "mix" in "Pancake mix" — absent from
    /// "15 pancakes" — fails).
    private static func aiNameIsFaithful(_ aiName: String, to segment: String) -> Bool {
        let stop: Set<String> = ["a", "an", "the", "of", "some", "my", "with", "and", "for", "to"]
        func tokens(_ string: String) -> [String] {
            string.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !stop.contains($0) && !$0.allSatisfy(\.isNumber) }
        }
        let userTokens = tokens(segment)
        let aiTokens = tokens(aiName)
        guard !aiTokens.isEmpty, !userTokens.isEmpty else { return false }
        return aiTokens.allSatisfy { ai in
            userTokens.contains { user in user.hasPrefix(ai) || ai.hasPrefix(user) }
        }
    }

    /// Resolve an item's amount + unit label, keeping the label accurate by trusting
    /// the AI. An explicit amount uses the AI's unit *exactly* — an empty unit means
    /// a bare count, so "10 potatoes" stays "10", never "10 lb". With no amount we
    /// reuse the household's last-used amount, else propose the AI's unit (or, only
    /// as an offline fallback, an on-device guess).
    private func resolveQuantity(name: String, aiAmount: String, aiUnit: String) -> (quantity: String, unit: String) {
        let amount = aiAmount.trimmingCharacters(in: .whitespaces)
        if !amount.isEmpty {
            var parsed = Quantity(parsing: amount)
            if parsed.unit.isEmpty, !aiUnit.isEmpty { parsed.unit = aiUnit }
            // Cap countable amounts (e.g. "1500 milk" → 1000); weight/volume
            // measures like "1500 lb cement" are left alone.
            if let value = parsed.amount {
                parsed.amount = GroceryUnits.cappedAmount(value, unit: parsed.unit)
            }
            return (parsed.formatted, parsed.unit)
        }
        let proposedUnit = aiUnit.isEmpty ? UnitGuess.guess(for: name) : aiUnit
        if let known = repo.currentItemSuggestion(named: name)?.quantity?
            .trimmingCharacters(in: .whitespaces), !known.isEmpty {
            let knownUnit = Quantity(parsing: known).unit
            return (known, knownUnit.isEmpty ? proposedUnit : knownUnit)
        }
        if !proposedUnit.isEmpty { return ("1 \(proposedUnit)", proposedUnit) }
        return ("1", "")
    }

    // MARK: - Over-cap confirmation

    /// Queue the clamped-amount confirmations produced while interpreting a line,
    /// then surface the first one.
    private func enqueueOverCapPrompts(_ prompts: [OverCapPrompt]) {
        guard !prompts.isEmpty else { return }
        overCapQueue.append(contentsOf: prompts)
        presentNextOverCapPrompt()
    }

    /// Show the next queued confirmation, if no other is already up.
    private func presentNextOverCapPrompt() {
        guard overCapPrompt == nil, !overCapQueue.isEmpty else { return }
        overCapPrompt = overCapQueue.removeFirst()
    }

    /// Restore the shopper's original (uncapped) amount on the row it applied to.
    private func applyUncapped(_ prompt: OverCapPrompt) {
        if let idx = items.firstIndex(where: { $0.id == prompt.itemID }) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                items[idx].quantity = prompt.originalQuantity
            }
        }
        scheduleNextOverCapPrompt()
    }

    /// Let the current alert finish dismissing before presenting the next queued
    /// one (presenting two alerts in the same run loop drops the second).
    private func scheduleNextOverCapPrompt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            presentNextOverCapPrompt()
        }
    }

    // MARK: - Priority markers
    //
    // A shopper can flag an item urgent inline while typing — a "!" anywhere on the
    // line, or one of the words "critical", "important", or "high". Flagged items
    // are staged at .critical priority (the CRITICAL chip); everything else stays
    // .normal (no chip). The markers are stripped from the committed line so they
    // never become part of an item's name.

    /// Alternation of the urgency keywords, matched as whole words (so "thigh" or
    /// "high chair" don't trip "high").
    private static let highPriorityWords = "critical|important|high"

    /// Whether a typed line flags its item as urgent.
    static func hasHighPriorityMarker(in text: String) -> Bool {
        if text.contains("!") { return true }
        return text.range(of: "\\b(\(highPriorityWords))\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Strips urgency markers ("!" and the keywords) from each line, recovering the
    /// plain item text. Line breaks are preserved so a multi-line paste still
    /// splits cleanly into one item per line.
    static func strippingPriorityMarkers(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { line in
                line
                    .replacingOccurrences(of: "\\b(\(highPriorityWords))\\b", with: "",
                                          options: [.regularExpression, .caseInsensitive])
                    .replacingOccurrences(of: "!", with: " ")
                    .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }

    // MARK: - Row bindings

    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { items.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
                items[idx].name = newValue
            }
        )
    }

    private func quantityBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { items.first(where: { $0.id == id })?.quantity ?? "" },
            set: { newValue in
                guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
                items[idx].quantity = newValue
            }
        )
    }

    // MARK: - Rows

    private func removeItem(_ id: UUID) {
        Haptics.tap()
        if expandedQuantityItem == id { expandedQuantityItem = nil }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) {
            items.removeAll { $0.id == id }
        }
    }

    /// Collapse any expanded quantity stepper — called when the user focuses the
    /// input or taps away, so a stepper doesn't stay open while attention moves on.
    /// `animated` is false on the keyboard-dismiss path so the collapse spring
    /// doesn't bounce the keyboard's safe-area shift.
    private func collapseQuantitySteppers(animated: Bool = true) {
        guard expandedQuantityItem != nil else { return }
        let collapse: Animation? = animated && !reduceMotion
            ? .spring(response: 0.3, dampingFraction: 0.82) : nil
        withAnimation(collapse) {
            expandedQuantityItem = nil
        }
    }

    // MARK: - History

    /// Stage a previously-bought item picked from History as a fully-resolved row
    /// (deduping by name), so the user can still review it before "Add".
    private func addFromHistory(name: String, quantity: String, category: GroceryCategory) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = Quantity(parsing: trimmedQuantity).unit
        appendResolved(name: trimmedName, quantity: trimmedQuantity, unit: unit, category: category)
        Task { await APIClient.shared.prewarmImages([trimmedName]) }
    }

    /// Take a previously-staged History item back off the list when its row is
    /// toggled to "Remove".
    private func removeFromHistory(name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            items.removeAll { $0.name.lowercased() == key }
        }
    }

    /// Live-sync a still-open History row's amount to its staged row, so editing the
    /// quantity of an item that's already been added updates the staged item too
    /// (no re-tap of "Add" needed).
    private func updateHistoryQuantity(name: String, quantity: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = items.firstIndex(where: { $0.name.lowercased() == key }),
              items[idx].quantity != trimmedQuantity else { return }
        items[idx].quantity = trimmedQuantity
    }

    /// Permanently drop a previously-bought item from the group's history so it no
    /// longer appears as a suggestion. Any row staged here is taken back off first
    /// so the two stay in sync.
    private func deleteFromHistory(name: String) {
        removeFromHistory(name: name)
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            repo.removeCurrentItemSuggestion(named: name)
        }
    }

    /// Append (or merge by name) a fully-resolved row — the landing spot for the
    /// History and photo paths, which arrive already identified (no thinking state).
    private func appendResolved(name: String, quantity: String, unit: String,
                                category: GroceryCategory, notes: String? = nil,
                                photoData: Data? = nil) {
        let titled = name.groceryTitleCased
        let resolvedQuantity = quantity.isEmpty
            ? resolveQuantity(name: titled, aiAmount: "", aiUnit: unit).quantity
            : quantity
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            if let idx = items.firstIndex(where: { $0.name.lowercased() == titled.lowercased() }) {
                if !quantity.isEmpty { items[idx].quantity = quantity }
                items[idx].category = category
                if let notes { items[idx].notes = notes }
                if let photoData { items[idx].photoData = photoData }
                items[idx].state = .resolved
                items[idx].lastInterpretedName = titled
            } else {
                items.append(LineItem(name: titled, state: .resolved, quantity: resolvedQuantity,
                                      unit: unit, category: category, notes: notes, photoData: photoData))
            }
        }
    }

    // MARK: - Photo capture → AI identify

    /// Drop the keyboard and open the in-app camera (or the photo library where no
    /// camera exists, e.g. the Simulator).
    private func startPhotoCapture() {
        Haptics.tap()
        dismissKeyboard()
        if CameraCaptureView.isAvailable {
            showCamera = true
        } else {
            showImagePicker = true
        }
    }

    /// Once the camera/library cover has fully dismissed, present the identify
    /// sheet for the photo it produced (if any). Driving this off the cover's
    /// `onDismiss` rather than a fixed delay guarantees the cover is gone before
    /// we present, so the sheet — and its opening "thinking" animation — actually
    /// shows instead of being silently dropped mid-dismiss.
    private func presentIdentifyIfPending() {
        guard let image = pendingCaptureImage else { return }
        pendingCaptureImage = nil
        if attachPhotoOnly {
            attachPhotoOnly = false
            attachManualPhoto(image)
        } else {
            handleCapturedImage(image)
        }
    }

    /// Downscale the captured photo, show the confirm card immediately, and kick
    /// off the vision request. The card opens in its "thinking" animation until
    /// the model returns; if the photo turns out to be a written list rather than
    /// a single product, the card is dropped and every detected item is staged
    /// instead (skipping per-item confirmation).
    private func handleCapturedImage(_ image: UIImage) {
        identifyIsManual = false
        let data = image.resizedItemPhotoData()
        capturePhotoData = data
        captureImage = data.flatMap(UIImage.init(data:)) ?? image
        resetIdentifyDraft()
        isIdentifying = true
        // The camera/library cover is already fully gone (we run from its
        // `onDismiss`), so the sheet can present right away — and opens in its
        // "thinking" animation because `isIdentifying` is true.
        showIdentifyCard = true

        Task {
            let startedAt = Date()
            var outcome = IdentifyOutcome(item: nil, items: [])
            var rateLimited = false
            if let data {
                switch await APIClient.shared.identifyItem(imageData: data) {
                case .success(let result): outcome = result
                case .failure(.rateLimited): rateLimited = true
                }
            }
            // Let the thinking animation read as intentional even when the model
            // answers almost instantly (e.g. a cache hit) — hold it briefly so it
            // doesn't flash past before the user registers it.
            let minimumThinking: TimeInterval = 1.1
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < minimumThinking {
                try? await Task.sleep(for: .seconds(minimumThinking - elapsed))
            }
            await MainActor.run {
                if rateLimited {
                    showIdentifyCard = false
                    isIdentifying = false
                    aiRateLimited = true
                } else {
                    applyIdentifyOutcome(outcome)
                }
            }
        }
    }

    /// Resolve the vision result. A multi-item list bypasses the confirm card and
    /// stages every item; a single product resolves the thinking animation into
    /// the editable item card in place.
    private func applyIdentifyOutcome(_ outcome: IdentifyOutcome) {
        if !outcome.items.isEmpty {
            // A photographed list: dismiss the card while it's still in its
            // thinking state (so the item form never flashes) and stage every item
            // for review, exactly like a typed list.
            showIdentifyCard = false
            isIdentifying = false
            addParsedList(outcome.items)
            PostHogSDK.shared.capture("item_photo_added", properties: [
                "source": "camera_list",
                "item_count": outcome.items.count,
            ])
            return
        }

        if let item = outcome.item {
            didIdentify = true
            identifiedName = item.name
            identifiedCategory = item.groceryCategory
            identifiedQuantity = defaultQuantity(for: item.name)
            Haptics.success()
        }
        // Resolve the thinking animation into the editable item card — either the
        // single identified product, or an empty form to fill when nothing was
        // recognized. `IdentifyItemCard` animates the cross-dissolve.
        isIdentifying = false
    }

    /// Confirm the identified item: stage it as a draft (with its photo and the
    /// quantity/notes entered on the card) so it flows through the normal "Add to
    /// List" path.
    private func commitIdentifiedItem() {
        let name = identifiedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showIdentifyCard = false
        addFromPhoto(name: name, category: identifiedCategory,
                     quantity: identifiedQuantity, notes: identifiedNotes,
                     photoData: capturePhotoData)
        PostHogSDK.shared.capture("item_photo_added", properties: [
            "source": identifyIsManual ? "manual_entry" : "camera_identify",
            "ai_identified": didIdentify,
            "has_photo": capturePhotoData != nil,
        ])
    }

    /// Dismiss the card and re-open the camera to try another shot.
    private func retakePhoto() {
        showIdentifyCard = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            startPhotoCapture()
        }
    }

    // MARK: - Manual entry (same card, no photo)

    /// Open the item card empty so the shopper can enter an item by hand —
    /// structured fields instead of plain text — with the option to attach a photo.
    private func startManualEntry() {
        Haptics.tap()
        dismissKeyboard()
        identifyIsManual = true
        captureImage = nil
        capturePhotoData = nil
        resetIdentifyDraft()
        isIdentifying = false
        showIdentifyCard = true
    }

    /// From the open manual card, open the camera/library to attach a photo —
    /// flagged so its `onDismiss` attaches the image rather than re-identifying.
    private func startManualPhotoCapture() {
        attachPhotoOnly = true
        startPhotoCapture()
    }

    /// Attach a just-captured photo to the open manual card without re-running the
    /// vision model — the shopper's own picture, kept as-is.
    private func attachManualPhoto(_ image: UIImage) {
        let data = image.resizedItemPhotoData()
        capturePhotoData = data
        captureImage = data.flatMap(UIImage.init(data:)) ?? image
        Haptics.success()
    }

    /// Detach the photo from the open card (the "Remove Photo" action).
    private func removeManualPhoto() {
        captureImage = nil
        capturePhotoData = nil
    }

    /// Dismiss the manual card without adding anything.
    private func cancelIdentifyCard() {
        showIdentifyCard = false
        captureImage = nil
        capturePhotoData = nil
    }

    private func resetIdentifyDraft() {
        identifiedName = ""
        identifiedCategory = .other
        identifiedQuantity = ""
        identifiedNotes = ""
        didIdentify = false
    }

    /// A sensible non-zero starting amount for an item: one of its natural unit
    /// (e.g. "1 dozen" for eggs), else a plain "1".
    private func defaultQuantity(for name: String) -> String {
        let unit = UnitGuess.guess(for: name)
        return unit.isEmpty ? "1" : "1 \(unit)"
    }

    /// Stage a photographed single item as a fully-resolved row (deduping by name)
    /// carrying the photo, quantity, and notes, so the user can still review it
    /// before "Add".
    private func addFromPhoto(name: String, category: GroceryCategory,
                              quantity: String, notes: String, photoData: Data?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let unit = UnitGuess.guess(for: trimmed)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        appendResolved(name: trimmed, quantity: quantity.trimmingCharacters(in: .whitespaces),
                       unit: unit, category: category,
                       notes: trimmedNotes.isEmpty ? nil : trimmedNotes, photoData: photoData)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Haptics.success() }
        Task { await APIClient.shared.prewarmImages([trimmed]) }
    }

    /// Stage every item read off a photographed list as resolved rows. Additive
    /// (preserves any already-typed rows), deduping by name — the same review path
    /// a typed list lands in.
    private func addParsedList(_ parsed: [ParsedItem]) {
        let detected = parsed.compactMap(DetectedItem.init(parsedItem:))
        guard !detected.isEmpty else { return }
        for item in detected {
            let q = resolveQuantity(name: item.name, aiAmount: item.quantity, aiUnit: item.unit)
            appendResolved(name: item.name, quantity: q.quantity, unit: q.unit, category: item.category)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Haptics.success() }
        Task { await APIClient.shared.prewarmImages(detected.map(\.name)) }
    }

    // MARK: - Finalize

    private func attemptClose() {
        guard hasProposedItems else {
            dismiss()
            return
        }
        showDiscardConfirm = true
    }

    private func addItems() {
        // Commit a line still in the field so it isn't lost on save.
        commitActiveLine()
        let itemsToAdd = items.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !itemsToAdd.isEmpty else { return }

        Haptics.success()
        PostHogSDK.shared.capture("items_added", properties: [
            "item_count": itemsToAdd.count,
            "source": "ai_parse_flow",
        ])
        repo.addItems(itemsToAdd.map { item in
            GroceryItemInput(
                name: item.name,
                quantity: item.quantity,
                category: item.category,
                notes: item.notes,
                priority: item.priority,
                replacementPreference: nil,
                photoData: item.photoData
            )
        }, toListId: targetListId)
        dismiss()
    }

    private func refocusInput(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            draftFocused = true
        }
    }

    /// Resign whatever field is editing — the compose line or a row's name field —
    /// so a tap off the inputs (or a control that needs the keyboard down) drops it.
    /// Resigning a row field commits its name edit; resigning the compose line
    /// commits the active line.
    private func dismissKeyboard() {
        draftFocused = false
        // Collapse without a spring: this fires as the keyboard slides away, and a
        // spring here gets swept into the dismissal and bounces the bottom controls.
        collapseQuantitySteppers(animated: false)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

/// A food detected from the input text, before it becomes an editable draft.
private extension String {
    /// Title-cases a grocery item name ("eggs" -> "Eggs", "chicken breast" ->
    /// "Chicken Breast"), mirroring the API's `titleCase`. Words already cased
    /// (e.g. "OJ") keep their later letters.
    var groceryTitleCased: String {
        trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

private struct DetectedItem {
    var name: String
    var quantity: String
    /// Proposed natural unit (e.g. "dozen") even when no amount was stated.
    var unit: String
    var category: GroceryCategory
    /// Urgency parsed from inline markers ("!", "important", …); .normal by default.
    var priority: ItemPriority = .normal

    init(name: String, quantity: String, unit: String = "", category: GroceryCategory) {
        self.name = name.groceryTitleCased
        self.quantity = quantity
        self.unit = unit
        self.category = category
    }

    init?(parsedItem: ParsedItem) {
        let trimmedName = parsedItem.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        name = trimmedName.groceryTitleCased
        quantity = parsedItem.quantity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        unit = parsedItem.unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        category = GroceryCategory(rawValue: parsedItem.category) ?? CategoryGuess.guess(for: trimmedName)
    }
}

/// A pending "did you mean that many?" confirmation: the shopper typed an amount
/// (e.g. "15000 milk") that the count cap clamped. We keep both the clamped value
/// shown on the row and the original they typed, so they can restore it.
private struct OverCapPrompt: Identifiable, Equatable {
    let id = UUID()
    /// The row the typed amount landed on.
    let itemID: UUID
    let name: String
    /// What the row currently shows (clamped to the cap, e.g. "999").
    let cappedQuantity: String
    /// The shopper's original typed quantity (e.g. "15000").
    let originalQuantity: String
}

/// One committed line. Typed lines start `.thinking` and resolve once the AI (or
/// the on-device fallback) fills in the name, quantity, unit, and category;
/// History/photo items arrive already `.resolved`.
private struct LineItem: Identifiable, Equatable {
    enum State: Equatable { case thinking, resolved }

    let id = UUID()
    var name: String
    var state: State
    var quantity: String
    /// Proposed unit offered by the quantity popover's stepper.
    var unit: String
    var category: GroceryCategory
    /// Urgency from an inline marker ("!", "important", …); surfaced as a CRITICAL
    /// chip and carried to the saved item. .normal shows no chip.
    var priority: ItemPriority
    /// Notes captured on the photo-confirm card, carried to the saved item.
    var notes: String?
    /// User-taken photo carried to the saved item (only its detail screen shows it).
    var photoData: Data?
    /// Last name interpretation ran for, so an unchanged name doesn't re-parse on
    /// every focus change.
    var lastInterpretedName: String

    init(name: String, state: State, quantity: String = "", unit: String = "",
         category: GroceryCategory = .other, priority: ItemPriority = .normal,
         notes: String? = nil, photoData: Data? = nil) {
        self.name = name
        self.state = state
        self.quantity = quantity
        self.unit = unit
        self.category = category
        self.priority = priority
        self.notes = notes
        self.photoData = photoData
        self.lastInterpretedName = state == .resolved ? name : ""
    }
}

/// A committed line rendered as a flat list row (no card): a small product image
/// (or a skeleton while thinking) on the left, the editable name in the middle,
/// and either a shimmering "Thinking…" or a liquid-glass quantity button on the
/// right. Editing the name re-interprets the line.
private struct LineItemRow: View {
    /// Leading image size — small so the row height stays close to a typed line.
    static let imageSize: CGFloat = 30
    /// Name font, shared with the compose line so committed rows line up with it.
    static let nameFont: Font = .title3.weight(.medium)

    let item: LineItem
    var tint: Color
    @Binding var name: String
    @Binding var quantity: String
    /// Whether this row's quantity stepper is expanded (owned by the parent so it
    /// can collapse on input focus / tap-away).
    @Binding var quantityExpanded: Bool
    /// When set to this row's id (by a backspace on the empty compose line), the
    /// row focuses its name field for editing, then clears the request.
    @Binding var focusRequest: UUID?
    /// Return pressed in the name field — hand focus back to the compose line.
    var onReturn: () -> Void
    /// The name field started editing — collapse any open quantity stepper.
    var onBeginEditingName: () -> Void
    /// Name field finished editing — re-interpret the line if it changed.
    var onCommitName: () -> Void
    var onRemove: () -> Void
    var onRemovePriority: () -> Void

    @FocusState private var editing: Bool
    @State private var showCriticalAlert = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leftSlot

            // A vertical field so a long name can wrap to two lines while being
            // edited; it collapses back to one line — and the quantity fades back
            // in — once editing ends. The range line limit (1...2) reserves only a
            // single line and grows to a second one only when the content needs it,
            // so a long name doesn't leave an empty reserved line padding the row.
            // While not editing a truncating Text sits on top so a long name ends in
            // "…" (a TextField just clips); taps fall through to the field beneath to
            // start editing.
            ZStack(alignment: .leading) {
                TextField("Item", text: $name, axis: .vertical)
                    .lineLimit(editing ? 1...2 : 1...1)
                    .focused($editing)
                    .opacity(editing ? 1 : 0)
                    .onChange(of: name) { _, newValue in
                        // A vertical field inserts a newline on Return; an item name
                        // is always one line, so treat Return as "done": flatten it
                        // and hand focus back to the compose line.
                        guard newValue.contains("\n") else { return }
                        name = newValue.replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespaces)
                        onReturn()
                    }
                    .onChange(of: editing) { _, isEditing in
                        // Collapse any open stepper when a name starts being edited;
                        // re-interpret only after the edit finishes — never mid-keystroke.
                        if isEditing { onBeginEditingName() } else { onCommitName() }
                    }

                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(editing ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .font(Self.nameFont)
            .textInputAutocapitalization(.words)
            // Tapping the name (the whole label area) starts editing. A simultaneous
            // gesture so it doesn't steal taps for cursor placement while editing.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { if !editing { editing = true } })

            Spacer(minLength: 8)

            if item.priority == .critical {
                Button {
                    Haptics.tap()
                    showCriticalAlert = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .grocerLiquidGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .alert("Critical Item", isPresented: $showCriticalAlert) {
                    Button("Remove Critical", role: .destructive) {
                        Haptics.tap()
                        onRemovePriority()
                    }
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("This item is marked as critical. It will be highlighted so shoppers know it's especially important and shouldn't be skipped or substituted.")
                }
            }

            // The quantity yields the row to the name field while it's being edited
            // (fades out), so long names get the full width.
            if !editing {
                trailingAccessory
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            removeButton
        }
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: editing)
        .onChange(of: focusRequest) { _, request in
            // Backspace on the empty compose line jumped focus up to this row.
            if request == item.id {
                editing = true
                focusRequest = nil
            }
        }
    }

    /// Small, low-emphasis remove control at the trailing edge — present in both
    /// the thinking and resolved states.
    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove \(item.name)"))
    }

    @ViewBuilder
    private var leftSlot: some View {
        switch item.state {
        case .thinking:
            // Skeleton placeholder while the item is being interpreted.
            ShimmerRect(cornerRadius: 8)
                .frame(width: Self.imageSize, height: Self.imageSize)
        case .resolved:
            // Always the AI product image — the user-taken photo is reserved for
            // the item's detail screen, never the list rows.
            ProductImageView(itemName: item.name, size: Self.imageSize)
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        switch item.state {
        case .thinking:
            // A clean opacity cross-fade into the chip when the item resolves.
            ThinkingPill()
                .transition(.opacity)
        case .resolved:
            InlineQuantityChip(quantity: $quantity, unit: item.unit, tint: tint,
                               expanded: $quantityExpanded)
                .transition(.opacity)
        }
    }
}

/// A shimmering "Thinking…" label shown on a row's trailing edge while the AI
/// works out the item's details. A light band sweeps across the glyphs (honoring
/// Reduce Motion, which leaves the text static).
private struct ThinkingPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1.0

    private let label = String(localized: "Thinking…")

    var body: some View {
        Text(label)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    // A light band sweeps across the glyphs. No blend mode — it
                    // composited badly while the pill cross-fades into the chip.
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.7), .clear],
                        startPoint: UnitPoint(x: phase, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.5, y: 0.5)
                    )
                    .mask(Text(label).font(.subheadline.weight(.medium)))
                }
            }
            .padding(.horizontal, 4)
            .accessibilityLabel(Text("Thinking"))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

/// A liquid-glass quantity chip showing the amount + label, e.g. "2 bags".
/// Tapping it extends the chip in place to reveal an inline −/+ stepper for the
/// amount; long-pressing opens the shared grocery-unit picker to change the label
/// (Cups, Oz, …). Stepping fires subtle haptics and clamps above zero (use the
/// row's ✕ to remove an item).
private struct InlineQuantityChip: View {
    @Binding var quantity: String
    /// Proposed unit, used as the label when the amount carries none.
    var unit: String
    var tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by the row's parent so focusing the input / tapping away can collapse it.
    @Binding var expanded: Bool

    /// Drives the long-press unit picker popover and its "Custom…" alert.
    @State private var showUnitPicker = false
    @State private var showingCustomUnit = false
    @State private var customUnit = ""

    private var parsed: Quantity { Quantity(parsing: quantity) }

    /// The unit stepped against and shown: the explicit unit, else the proposal.
    private var effectiveUnit: String {
        parsed.unit.isEmpty ? unit : parsed.unit
    }

    /// "2 bags" style label, with the unit inflected for the amount.
    private var label: String {
        let display = Quantity.displayString(quantity)
        return display.isEmpty ? String(localized: "Qty") : display
    }

    var body: some View {
        HStack(spacing: 0) {
            if expanded {
                stepButton(systemImage: "minus") { adjust(-1) }
            }

            Text(label)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .padding(.horizontal, expanded ? 4 : 10)
                .frame(minWidth: expanded ? 44 : 0)
                // Tap toggles the inline stepper; a long press opens the unit picker.
                // Driven by explicit gestures (rather than a Button + .contextMenu)
                // so the long press reliably lands on the interactive glass chip.
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tap()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
                        expanded.toggle()
                    }
                }
                .onLongPressGesture(minimumDuration: 0.35) {
                    Haptics.selection()
                    showUnitPicker = true
                }

            if expanded {
                stepButton(systemImage: "plus") { adjust(1) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, expanded ? 4 : 2)
        .grocerLiquidGlass(in: Capsule(), interactive: true)
        // Keep the chip at its intrinsic width so a long label ("1 bunch") never
        // gets squeezed/truncated by the flexible name field beside it.
        .fixedSize()
        // The long-press picker (see the label's gestures) opens this popover of
        // grocery units — the same options as the add-item stepper's unit menu.
        .popover(isPresented: $showUnitPicker, arrowEdge: .top) {
            unitPickerPopover
        }
        .alert("Custom unit", isPresented: $showingCustomUnit) {
            TextField("Unit", text: $customUnit)
                .textInputAutocapitalization(.never)
            Button("Set") { setUnit(customUnit.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a unit like \u{201C}case\u{201D} or \u{201C}sticks\u{201D}.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Quantity"))
        .accessibilityValue(Text(label))
        .accessibilityHint(Text("Tap to adjust, long press to change the unit"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.5)))
    }

    /// Step the amount by the unit's natural increment, clamped above zero (removal
    /// lives on the row's ✕).
    private func adjust(_ direction: Double) {
        let u = effectiveUnit
        let step = GroceryUnits.step(for: u)
        let next = (parsed.amount ?? 0) + direction * step
        guard next > 0 else { Haptics.selection(); return }
        Haptics.selection()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            quantity = Quantity(amount: next, unit: u).formatted
        }
    }

    /// Change the unit label from the long-press picker, reparsing and reformatting
    /// the stored quantity string. Picking a real unit with no amount yet implies
    /// one of it; "None" clears the label back to the proposed unit.
    private func setUnit(_ unit: String) {
        Haptics.selection()
        var next = parsed
        next.unit = unit
        if !unit.isEmpty && next.amount == nil { next.amount = 1 }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            quantity = next.formatted
        }
    }

    /// The long-press unit picker: a compact, scrollable list of the same grocery
    /// units offered by the add-item stepper's unit menu (None, every
    /// `GroceryUnits.all`, then Custom…), checkmarking the current label.
    private var unitPickerPopover: some View {
        ScrollView {
            VStack(spacing: 0) {
                unitOption(title: String(localized: "None"), unit: "")
                ForEach(GroceryUnits.all, id: \.self) { unit in
                    unitOption(title: unit, unit: unit)
                }
                Divider().padding(.vertical, 4)
                Button {
                    showUnitPicker = false
                    customUnit = effectiveUnit
                    showingCustomUnit = true
                } label: {
                    Text("Custom\u{2026}")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 220, height: 300)
        .presentationCompactAdaptation(.popover)
    }

    /// One row in the unit picker popover: the unit name with a trailing checkmark
    /// when it's the current label. Picking it sets the unit and closes the popover.
    private func unitOption(title: String, unit: String) -> some View {
        Button {
            setUnit(unit)
            showUnitPicker = false
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if unit == effectiveUnit {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 9)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    @ViewBuilder
    func grocerLiquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.24), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    func grocerGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Past Items Sheet

private struct PastItemsSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    let onSelect: (String) -> Void

    @State private var search = ""

    private var filtered: [String] {
        let items = repo.pastItemNames
        guard !search.isEmpty else { return items }
        let query = search.lowercased()
        return items.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(filtered, id: \.self) { itemName in
                        Button {
                            Haptics.selection()
                            onSelect(itemName)
                            dismiss()
                        } label: {
                            Label(itemName, systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Filter previous items")
            .navigationTitle("Previous Items")
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
    }
}

// MARK: - Compose field

/// The active "Type an item…" line. A `UITextField` (not a SwiftUI `TextField`) so
/// it can detect a backspace pressed while empty — the cue to jump up and edit the
/// previous item. Return and multi-line pastes are funneled through the text
/// binding as newlines, so the parent's existing commit logic (split on "\n")
/// handles them uniformly. Committed rows still use plain SwiftUI `TextField`s.
private struct ComposeTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onBackspaceWhenEmpty: () -> Void

    func makeUIView(context: Context) -> BackspacingTextField {
        let field = BackspacingTextField()
        field.delegate = context.coordinator
        field.placeholder = String(localized: "Milk, Cheese, Eggs…")
        field.autocapitalizationType = .words
        field.returnKeyType = .next
        field.backgroundColor = .clear
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let base = UIFont.preferredFont(forTextStyle: .title3)
        let medium = UIFont.systemFont(ofSize: base.pointSize, weight: .medium)
        field.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: medium)
        field.adjustsFontForContentSizeCategory = true
        field.addTarget(context.coordinator,
                        action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.onBackspaceWhenEmpty = { context.coordinator.parent.onBackspaceWhenEmpty() }
        field.text = text
        return field
    }

    func updateUIView(_ field: BackspacingTextField, context: Context) {
        context.coordinator.parent = self
        field.onBackspaceWhenEmpty = { context.coordinator.parent.onBackspaceWhenEmpty() }
        if field.text != text {
            field.text = text
            // Park the caret at the end after an external set (e.g. a pulled-in name).
            let end = field.endOfDocument
            field.selectedTextRange = field.textRange(from: end, to: end)
        }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ComposeTextField

        init(_ parent: ComposeTextField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            // Funnel Return through the binding as a newline so the parent's commit
            // (which splits on "\n") handles it uniformly with multi-line pastes.
            parent.text = (field.text ?? "") + "\n"
            return false
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard string.contains("\n") else { return true }
            parent.text = ((field.text ?? "") as NSString).replacingCharacters(in: range, with: string)
            return false
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

/// A `UITextField` that reports a backspace pressed while it's empty.
private final class BackspacingTextField: UITextField {
    var onBackspaceWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        if (text ?? "").isEmpty {
            onBackspaceWhenEmpty?()
            return
        }
        super.deleteBackward()
    }
}
