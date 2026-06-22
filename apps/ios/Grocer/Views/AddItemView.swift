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

            Section("Details (optional)") {
                LabeledContent("Quantity") {
                    QuantityStepperField(
                        quantity: $quantity,
                        proposedUnit: proposedUnit,
                        tint: .green
                    )
                }
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

// MARK: - Full-screen add/search flow
//
// A two-pane editor. The top pane is a freeform text field with inline
// autocomplete of previously-added items. The bottom pane is a live projection
// of the foods detected in that text — each row shows a streamed product image,
// an editable quantity, and a category. The panes mirror each other: typing
// re-derives the rows (debounced AI parse), and editing/removing a row rewrites
// the text. "Add to List" finalizes everything and closes the modal.

struct AddItemSearchView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var tint: Color = .green

    @State private var inputText = ""
    @State private var drafts: [ParsedGroceryDraft] = []
    @State private var isParsing = false
    @State private var contentAppeared = false
    @State private var showHistory = false
    @State private var showDiscardConfirm = false
    /// Whether the software keyboard is currently up — hides the bottom action.
    @State private var keyboardVisible = false

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

    /// Debounce handle for the AI parse; cancelled and rescheduled on each edit.
    @State private var parseTask: Task<Void, Never>?
    /// Last text we ran a parse for, so identical text doesn't re-parse.
    @State private var lastParsedText = ""
    /// Set when a text change originates from a row edit (mirror write-back) so
    /// it doesn't trigger another parse, preventing a feedback loop.
    @State private var suppressParse = false

    // Drives the compose field's first-responder state. A plain `Bool` (not
    // `@FocusState`) so it can bridge to the UIKit-backed `BulletListTextEditor`,
    // which owns the caret to keep bullet formatting from teleporting it.
    @State private var inputFocused = false

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasProposedItems: Bool {
        drafts.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Distinct items anyone in the group has added before — the pool offered in
    /// the History pane, latest first. Items already on the list are kept (and
    /// flagged) so the button still appears for a brand-new group's first reuse.
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
                .opacity(contentAppeared ? (showHistory ? 0 : 1) : 0)
                .offset(y: contentAppeared ? 0 : 14)
                // The close button is sticky (added after the opacity/offset so it
                // stays put as the title scrolls beneath it).
                .overlay(alignment: .top) {
                    if !showHistory {
                        closeButton
                    }
                }
                .overlay(alignment: .bottom) {
                    if !showHistory {
                        floatingControls
                    }
                }

            if showHistory {
                HistoryItemsView(
                    suggestions: historySuggestions,
                    tint: tint,
                    hasProposedItems: hasProposedItems,
                    onSelect: { name, quantity, category in
                        // Stay in History after adding so several previously-bought
                        // items can be batch-added; the user closes via Back.
                        addFromHistory(name: name, quantity: quantity, category: category)
                    },
                    onRemove: { name in
                        removeFromHistory(name: name)
                    },
                    onClose: {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                            showHistory = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(2)
            }
        }
        .tint(tint)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88)) {
                contentAppeared = true
            }
            refocusInput(after: 0.24)
        }
        .onChange(of: inputText) { _, _ in
            if suppressParse {
                suppressParse = false
                return
            }
            // Bullet formatting now happens inside `BulletListTextEditor` as the
            // user types (so the caret can be kept on the edited line). Priority
            // markers don't change *which* items are detected (they're stripped
            // before parsing), so re-apply them to the existing rows immediately —
            // a typed/removed "!" flips the CRITICAL chip without waiting on the
            // debounced network parse. The parse still runs to pick up item edits.
            applyPriorityFromText()
            scheduleParse(after: .milliseconds(500))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hide the bottom action while the keyboard is up so it doesn't ride
            // above the keyboard; it returns once typing dismisses.
            if !showHistory && !keyboardVisible {
                bottomAction
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { keyboardVisible = false }
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
                onAdd: commitIdentifiedItem,
                onRetake: retakePhoto
            )
        }
    }

    /// Bottom-floating row: the camera button is pinned to the leading edge and
    /// the History pill (when there's history) to the trailing edge.
    private var floatingControls: some View {
        HStack(spacing: 12) {
            cameraButton
            Spacer(minLength: 0)
            if !historySuggestions.isEmpty {
                historyButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86),
                   value: historySuggestions.isEmpty)
    }

    /// Floating glass pill that opens the camera to photograph an item (or a
    /// written list), then has the server identify it. Icon-only — no label.
    private var cameraButton: some View {
        Button {
            startPhotoCapture()
        } label: {
            Image(systemName: "camera.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 34)
        }
        .tint(.primary)
        .grocerGlassButton()
        .clipShape(Capsule())
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityLabel("Take a photo to identify an item")
    }

    /// Floating glass pill that swaps the add flow for the group's item history.
    private var historyButton: some View {
        Button {
            Haptics.tap()
            inputFocused = false
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                showHistory = true
            }
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 34)
        }
        .tint(.primary)
        .grocerGlassButton()
        .clipShape(Capsule())
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityLabel("Add from history")
    }

    private var addFlowContent: some View {
        // No pinned header bar: the title chip scrolls with the content while only
        // the close button stays put (a sticky overlay in `body`). The glass
        // container lives inside the ScrollView so the cards' glass is rendered (and
        // clipped) within the scroll bounds.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                titleChip
                scrollContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // Reserve space for the always-present floating controls row (pill
            // height 34 + 16 bottom inset) so a long proposed list can scroll clear
            // of it instead of having its last rows overlapped.
            .padding(.bottom, 74)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var scrollContent: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                panels
            }
        } else {
            panels
        }
    }

    private var panels: some View {
        VStack(alignment: .leading, spacing: 16) {
            composePanel
            proposedPanel
                // Tapping the proposed-items area (rows or the empty placeholder)
                // dismisses the keyboard. Child controls (row text fields/buttons)
                // take priority, and `dismissKeyboard()` no-ops when the keyboard
                // is already down, so this only fires for genuine empty-area taps.
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
        }
    }

    /// The page title as a Liquid Glass capsule chip. It scrolls with the content
    /// (not pinned), sitting at the leading content edge.
    private var titleChip: some View {
        Text("Add Items")
            // ~10% larger than .headline (17pt).
            .font(.system(size: 18.7, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .grocerLiquidGlass(in: Capsule())
            // Purely a label — taps pass through to nothing.
            .allowsHitTesting(false)
    }

    /// The sticky close control, floated over the content at the top-trailing edge
    /// (there's no header bar behind it). While typing it drops the keyboard;
    /// otherwise it closes the flow.
    private var closeButton: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                Haptics.tap()
                if keyboardVisible {
                    dismissKeyboard()
                } else {
                    attemptClose()
                }
            } label: {
                Image(systemName: keyboardVisible ? "keyboard.chevron.compact.down" : "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .grocerLiquidGlass(in: Circle(), interactive: true)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .accessibilityLabel(keyboardVisible ? String(localized: "Dismiss keyboard") : String(localized: "Close"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Top pane: input + autocomplete

    private var composePanel: some View {
        BulletListTextEditor(text: $inputText, isFocused: $inputFocused)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if inputText.isEmpty {
                    // UITextView has no native placeholder; mirror the editor's
                    // font and top inset so this sits exactly where the caret will.
                    Text("Type your list freely — milk, eggs, bananas, etc.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color(.placeholderText))
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Bottom pane: proposed items

    @ViewBuilder
    private var proposedPanel: some View {
        if drafts.isEmpty {
            if isParsing {
                VStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in
                        ParsedGroceryDraftSkeletonRow()
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Detecting items")
            } else {
                emptyProposed
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Proposed")
                        .font(.headline)
                    if isParsing {
                        ProgressView().controlSize(.small).tint(.secondary)
                    }
                    Spacer()
                    Text("^[\(drafts.count) item](inflect: true)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)

                VStack(spacing: 10) {
                    ForEach(drafts) { draft in
                        ParsedGroceryDraftRow(
                            draft: draft,
                            tint: tint,
                            onNameChange: updateDraft(draft.id) { $0.name = $1 },
                            onQuantityChange: updateDraft(draft.id) { $0.quantity = $1 },
                            onCategoryChange: { updateDraftCategory(draft.id, $0) },
                            onRemove: { removeDraft(draft.id) }
                        )
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.92).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
            }
        }
    }

    // Shown in place of the proposed list before anything is typed: a short,
    // monochrome cheat-sheet of the things shoppers tend not to discover on their
    // own (inline amounts, the "!" urgency marker, return-per-item, the camera).
    private var emptyProposed: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Tips", systemImage: "lightbulb")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                SquigglyLine()
                    .stroke(style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.tertiary)
                    .frame(height: 9)
                    .frame(maxWidth: 130, alignment: .leading)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.composeTips) { tip in
                    composeTipRow(tip)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
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

    /// A continuous, rounded sine wave used as a hand-drawn squiggly divider under
    /// the Tips title. The amplitude is sized to fill the view's height (minus the
    /// stroke inset) so the wave reads clearly rather than as a near-flat line.
    private struct SquigglyLine: Shape {
        /// Horizontal span of one full up-and-down crest.
        var wavelength: CGFloat = 9

        func path(in rect: CGRect) -> Path {
            var path = Path()
            // Leave ~1pt of headroom so the rounded stroke isn't clipped at the
            // crest of each wave.
            let amplitude = max(rect.height / 2 - 1, 0)
            let midY = rect.midY
            path.move(to: CGPoint(x: rect.minX, y: midY))
            var x = rect.minX
            while x <= rect.maxX {
                let y = midY + sin(x / wavelength * 2 * .pi) * amplitude
                path.addLine(to: CGPoint(x: x, y: y))
                x += 1
            }
            return path
        }
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
            Text("Add to List")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .grocerGlassButton(prominent: true)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .disabled(drafts.isEmpty)
    }

    // MARK: - Parse (text → rows)

    private func scheduleParse(after delay: Duration) {
        parseTask?.cancel()
        let text = trimmedInput
        parseTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await runParse(text)
        }
    }

    private func runParse(_ text: String) async {
        guard text != lastParsedText else { return }
        guard !text.isEmpty else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { drafts = [] }
            lastParsedText = ""
            return
        }

        isParsing = true
        // The freeform field may carry bullet markers ("• "); feed clean lines to
        // both the AI parse and the offline fallback.
        let cleaned = Self.stripBullets(text)
        // Names the shopper flagged urgent inline ("milk!", "eggs important"). The
        // markers themselves are stripped before parsing so they never leak into an
        // item's name; priority is reattached to the detected items afterward.
        let urgentNames = highPriorityItemNames(in: cleaned)
        let forParsing = Self.strippingPriorityMarkers(cleaned)
        let parsed = await APIClient.shared.parseList(forParsing)
        guard !Task.isCancelled else { isParsing = false; return }

        let detected = (parsed.isEmpty ? localSplit(forParsing) : parsed.compactMap(DetectedItem.init(parsedItem:)))
            .map { item -> DetectedItem in
                var item = item
                if isHighPriority(item.name, among: urgentNames) { item.priority = .critical }
                return item
            }
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            drafts = merge(detected, into: drafts)
        }
        lastParsedText = text
        isParsing = false

        let names = drafts.map(\.name)
        Task { await APIClient.shared.prewarmImages(names) }
    }

    /// Offline / API-down fallback: split on separators and guess categories.
    private func localSplit(_ text: String) -> [DetectedItem] {
        text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { DetectedItem(name: $0, quantity: "", unit: UnitGuess.guess(for: $0), category: CategoryGuess.guess(for: $0)) }
    }

    // MARK: - Priority markers
    //
    // A shopper can flag an item urgent inline while typing — a "!" anywhere on the
    // line, or one of the words "critical", "important", or "high". Flagged items
    // are staged at .critical priority (the CRITICAL chip); everything else stays .normal
    // (no chip). The markers are stripped before the text is parsed so they never
    // become part of an item's name.

    /// Alternation of the urgency keywords, matched as whole words (so "thigh" or
    /// "high chair" don't trip "high").
    private static let highPriorityWords = "critical|important|high"

    /// Whether a typed segment flags its item as urgent.
    static func hasHighPriorityMarker(in text: String) -> Bool {
        if text.contains("!") { return true }
        return text.range(of: "\\b(\(highPriorityWords))\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Strips urgency markers ("!" and the keywords) from each line, recovering the
    /// plain item text. Line breaks and commas are preserved so the structure the
    /// parser and the offline split rely on survives.
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

    /// Normalized item names (markers stripped, lowercased) the shopper flagged
    /// urgent, keyed off the raw text's comma/newline-separated segments.
    private func highPriorityItemNames(in text: String) -> Set<String> {
        Set(
            text
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .filter { Self.hasHighPriorityMarker(in: $0) }
                .map { Self.strippingPriorityMarkers($0).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// Whether a detected item's name was among the urgent-flagged segments. The
    /// parser may rename slightly (drop quantities, normalize case), so a loose
    /// containment match in either direction is used.
    private func isHighPriority(_ name: String, among urgentNames: Set<String>) -> Bool {
        guard !urgentNames.isEmpty else { return false }
        let lower = name.lowercased()
        return urgentNames.contains { $0 == lower || $0.contains(lower) || lower.contains($0) }
    }

    /// Re-derives each existing draft's priority from the current text's inline
    /// markers and applies it immediately — no debounce, no network round-trip.
    /// Markers don't affect item detection (they're stripped before parsing), so
    /// adding or removing a "!" can flip the CRITICAL chip instantly while the
    /// debounced parse catches up with any item changes. The text is the source of
    /// truth: a marker escalates to .critical, its removal drops back to .normal.
    private func applyPriorityFromText() {
        guard !drafts.isEmpty else { return }
        let urgentNames = highPriorityItemNames(in: Self.stripBullets(inputText))
        let updated = drafts.map { draft -> ParsedGroceryDraft in
            var draft = draft
            draft.priority = isHighPriority(draft.name, among: urgentNames) ? .critical : .normal
            return draft
        }
        guard updated != drafts else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            drafts = updated
        }
    }

    /// Re-projects detected items onto the current drafts, reusing existing rows
    /// (and their `id`, so the streamed image doesn't reload) when names match.
    private func merge(_ detected: [DetectedItem], into existing: [ParsedGroceryDraft]) -> [ParsedGroceryDraft] {
        detected.map { item in
            // Best unit to propose when the user didn't state one themselves:
            // the AI's natural unit first, else the on-device guess.
            let proposedUnit = item.unit.isEmpty ? UnitGuess.guess(for: item.name) : item.unit
            // The user stated an explicit amount in the text (e.g. "12 individual
            // bananas"). Their words win over any previously-proposed unit.
            let hasExplicitAmount = !item.quantity.trimmingCharacters(in: .whitespaces).isEmpty

            if var match = existing.first(where: { $0.name.lowercased() == item.name.lowercased() }) {
                if hasExplicitAmount {
                    // Rebuild from the user's explicit amount + unit, replacing the
                    // earlier proposal (e.g. "1 bunch" -> "12 each").
                    match.quantity = explicitQuantity(for: item)
                    match.unit = proposedUnit
                } else if match.unit.isEmpty, !proposedUnit.isEmpty {
                    // No new amount; only fill a missing unit, never clobber one
                    // the user already chose on the row.
                    match.unit = proposedUnit
                }
                match.category = item.category
                // The text is the single source of truth for priority: an inline
                // marker ("!", "important", …) escalates to .critical and its
                // removal drops it back to .normal. `syncTextFromDrafts` re-emits the
                // marker for critical rows, so a write-back never loses the flag.
                match.priority = item.priority
                return match
            }

            return makeDraft(from: item)
        }
    }

    /// Build a fresh draft for a newly-detected item, choosing a sensible non-zero
    /// quantity: the user's explicit amount, else the household's last-used amount,
    /// else one of the natural unit, else a plain "1".
    private func makeDraft(from item: DetectedItem) -> ParsedGroceryDraft {
        let proposedUnit = item.unit.isEmpty ? UnitGuess.guess(for: item.name) : item.unit
        let hasExplicitAmount = !item.quantity.trimmingCharacters(in: .whitespaces).isEmpty

        var quantity = ""
        if hasExplicitAmount {
            quantity = explicitQuantity(for: item)
        } else if let known = repo.currentItemSuggestion(named: item.name),
                  let knownQuantity = known.quantity {
            // Reuse the amount this household last bought.
            quantity = knownQuantity
        } else if !proposedUnit.isEmpty {
            // Propose one of the natural unit, e.g. "1 dozen" for eggs.
            quantity = "1 \(proposedUnit)"
        } else {
            // No amount, no known quantity, and no natural unit: default to a
            // single item rather than leaving the stepper showing "0".
            quantity = "1"
        }
        return ParsedGroceryDraft(name: item.name, quantity: quantity, unit: proposedUnit,
                                  category: item.category, priority: item.priority)
    }

    /// Combine an AI-detected amount and unit into a single quantity string,
    /// e.g. amount "12" + unit "each" -> "12 each". If the amount text already
    /// carries its own unit (e.g. "2 lbs") that is kept as-is.
    private func explicitQuantity(for item: DetectedItem) -> String {
        var parsed = Quantity(parsing: item.quantity)
        if parsed.unit.isEmpty, !item.unit.isEmpty {
            parsed.unit = item.unit
        }
        return parsed.formatted
    }

    // MARK: - Mirror (rows → text)

    private func updateDraft(_ id: UUID, _ mutate: @escaping (inout ParsedGroceryDraft, String) -> Void) -> (String) -> Void {
        { value in
            guard let idx = drafts.firstIndex(where: { $0.id == id }) else { return }
            mutate(&drafts[idx], value)
            syncTextFromDrafts()
        }
    }

    private func updateDraftCategory(_ id: UUID, _ category: GroceryCategory) {
        guard let idx = drafts.firstIndex(where: { $0.id == id }) else { return }
        Haptics.selection()
        drafts[idx].category = category
        // Category isn't reflected in the mirrored text, so no write-back needed.
    }

    private func removeDraft(_ id: UUID) {
        Haptics.tap()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) {
            drafts.removeAll { $0.id == id }
        }
        syncTextFromDrafts()
    }

    /// Rewrites the input text from the current drafts. Guarded so the resulting
    /// `inputText` change doesn't kick off another parse.
    private func syncTextFromDrafts() {
        let parts = drafts.map { draft -> String in
            let base = draft.quantity.isEmpty ? draft.name : "\(draft.quantity) \(draft.name)"
            // Re-emit the urgency marker so the text stays the source of truth for
            // priority: a critical row keeps a trailing "!" across the write-back, so
            // editing a quantity (or adding from history/photo) never silently drops
            // the CRITICAL flag on a later re-parse.
            return draft.priority == .critical ? "\(base)!" : base
        }
        // Mirror the bullet-list presentation: a single item stays plain, several
        // become a bulleted, one-per-line list to match the typed input.
        let text = parts.count > 1
            ? parts.map { "\(Self.bullet)\($0)" }.joined(separator: "\n")
            : parts.joined()
        suppressParse = true
        inputText = text
        lastParsedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bullet prefix used when the freeform input is rendered as a list.
    private static let bullet = "• "

    /// Renders the input as a bullet list once it spans multiple lines. Each
    /// non-empty line is normalized to a single "• " prefix; a trailing blank line
    /// (just after the user hit return) gets a bare bullet so the next item starts
    /// against one. Single-line input is left untouched.
    ///
    /// Backspace handling: an empty bullet sits as "• " (marker + space).
    /// Backspacing it removes the space, leaving a bare "•" — the signal that the
    /// user wants the bullet gone. That line is dropped so it collapses onto the
    /// previous item instead of being re-padded back to "• ".
    fileprivate static func bulletified(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        if let idx = lines.firstIndex(where: { $0 == Self.bulletMarker }), lines.count > 1 {
            lines.remove(at: idx)
            // A single surviving item reads plainly; several keep their bullets.
            guard lines.count > 1 else { return stripBulletPrefix(lines[0]) }
            return lines.map { Self.bullet + stripBulletPrefix($0) }.joined(separator: "\n")
        }

        guard text.contains("\n") else { return text }
        return lines
            .map { Self.bullet + stripBulletPrefix($0) }
            .joined(separator: "\n")
    }

    /// The bullet glyph without its trailing space.
    private static let bulletMarker = "•"

    /// Drops a line's leading bullet marker and surrounding spaces, recovering the
    /// plain item text.
    private static func stripBulletPrefix(_ line: String) -> String {
        String(line.drop(while: { $0 == "•" || $0 == " " }))
    }

    /// Strips bullet markers and surrounding whitespace from each line, recovering
    /// the plain item text for parsing.
    private static func stripBullets(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map(stripBulletPrefix)
            .joined(separator: "\n")
    }

    // MARK: - History

    /// Stage a previously-bought item picked from History. Mirrors the parse path:
    /// it lands as a draft (deduping by name) and is reflected back into the
    /// freeform text, so the user can still review before "Add to List".
    private func addFromHistory(name: String, quantity: String, category: GroceryCategory) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposedUnit = Quantity(parsing: trimmedQuantity).unit

        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            if let idx = drafts.firstIndex(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
                if !trimmedQuantity.isEmpty { drafts[idx].quantity = trimmedQuantity }
                drafts[idx].category = category
            } else {
                drafts.append(ParsedGroceryDraft(name: trimmedName, quantity: trimmedQuantity,
                                                 unit: proposedUnit, category: category))
            }
        }
        syncTextFromDrafts()
        Task { await APIClient.shared.prewarmImages([trimmedName]) }
    }

    /// Take a previously-staged History item back off the draft list when its row
    /// is toggled to "Remove".
    private func removeFromHistory(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            drafts.removeAll { $0.name.lowercased() == trimmedName.lowercased() }
        }
        syncTextFromDrafts()
    }

    // MARK: - Photo capture → AI identify

    /// Drop the keyboard and open the in-app camera (or the photo library where no
    /// camera exists, e.g. the Simulator).
    private func startPhotoCapture() {
        Haptics.tap()
        inputFocused = false
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
        handleCapturedImage(image)
    }

    /// Downscale the captured photo, show the confirm card immediately, and kick
    /// off the vision request. The card opens in its "thinking" animation until
    /// the model returns; if the photo turns out to be a written list rather than
    /// a single product, the card is dropped and every detected item is staged
    /// instead (skipping per-item confirmation).
    private func handleCapturedImage(_ image: UIImage) {
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
            if let data { outcome = await APIClient.shared.identifyItem(imageData: data) }
            // Let the thinking animation read as intentional even when the model
            // answers almost instantly (e.g. a cache hit) — hold it briefly so it
            // doesn't flash past before the user registers it.
            let minimumThinking: TimeInterval = 1.1
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < minimumThinking {
                try? await Task.sleep(for: .seconds(minimumThinking - elapsed))
            }
            await MainActor.run { applyIdentifyOutcome(outcome) }
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
            "source": "camera_identify",
            "ai_identified": didIdentify,
        ])
    }

    /// Dismiss the card and re-open the camera to try another shot.
    private func retakePhoto() {
        showIdentifyCard = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            startPhotoCapture()
        }
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

    /// Stage a photographed single item. Mirrors `addFromHistory`: it lands as a
    /// draft (deduping by name) carrying the photo, quantity, and notes, and is
    /// reflected back into the freeform text so the user can still review before
    /// "Add to List".
    private func addFromPhoto(name: String, category: GroceryCategory,
                              quantity: String, notes: String, photoData: Data?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let proposedUnit = UnitGuess.guess(for: trimmed)
        let trimmedQuantity = quantity.trimmingCharacters(in: .whitespaces)
        let resolvedQuantity = trimmedQuantity.isEmpty
            ? (proposedUnit.isEmpty ? "1" : "1 \(proposedUnit)")
            : trimmedQuantity
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedNotes = trimmedNotes.isEmpty ? nil : trimmedNotes

        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            if let idx = drafts.firstIndex(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                drafts[idx].category = category
                drafts[idx].quantity = resolvedQuantity
                if let resolvedNotes { drafts[idx].notes = resolvedNotes }
                if let photoData { drafts[idx].photoData = photoData }
            } else {
                drafts.append(ParsedGroceryDraft(name: trimmed.groceryTitleCased, quantity: resolvedQuantity,
                                                 unit: proposedUnit, category: category,
                                                 notes: resolvedNotes, photoData: photoData))
            }
        }
        syncTextFromDrafts()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Haptics.success() }
        Task { await APIClient.shared.prewarmImages([trimmed]) }
    }

    /// Stage every item read off a photographed list. Additive (preserves any
    /// already-typed drafts), deduping by name, and mirrored back into the text —
    /// the same review path a typed list lands in.
    private func addParsedList(_ items: [ParsedItem]) {
        let detected = items.compactMap(DetectedItem.init(parsedItem:))
        guard !detected.isEmpty else { return }

        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            for item in detected {
                if let idx = drafts.firstIndex(where: { $0.name.lowercased() == item.name.lowercased() }) {
                    drafts[idx].category = item.category
                } else {
                    drafts.append(makeDraft(from: item))
                }
            }
        }
        syncTextFromDrafts()
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
        let itemsToAdd = drafts.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !itemsToAdd.isEmpty else { return }

        Haptics.success()
        PostHogSDK.shared.capture("items_added", properties: [
            "item_count": itemsToAdd.count,
            "source": "ai_parse_flow",
        ])
        repo.addItems(itemsToAdd.map { draft in
            GroceryItemInput(
                name: draft.name,
                quantity: draft.quantity,
                category: draft.category,
                notes: draft.notes,
                priority: draft.priority,
                replacementPreference: nil,
                photoData: draft.photoData
            )
        })
        dismiss()
    }

    private func refocusInput(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            inputFocused = true
        }
    }

    /// Resign whatever field is editing — the compose field or a draft row's text
    /// field — so a tap off the inputs drops the keyboard.
    private func dismissKeyboard() {
        guard keyboardVisible else { return }
        inputFocused = false
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

private struct ParsedGroceryDraft: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var quantity: String
    /// Proposed unit offered by the stepper when `quantity` carries no unit.
    var unit: String
    var category: GroceryCategory
    /// Urgency derived from inline text markers; surfaced as a CRITICAL chip on the row
    /// and carried to the saved item. .normal shows no chip.
    var priority: ItemPriority
    /// Optional notes entered on the photo-confirm card, carried to the saved item.
    var notes: String?
    /// Optional user-taken photo carried through to the saved item. Preserved
    /// across re-parses because `merge` reuses the matching existing draft. Only
    /// surfaced on the item's detail screen — rows everywhere use the AI image.
    var photoData: Data?

    init(name: String, quantity: String, unit: String = "", category: GroceryCategory,
         priority: ItemPriority = .normal, notes: String? = nil, photoData: Data? = nil) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.category = category
        self.priority = priority
        self.notes = notes
        self.photoData = photoData
    }
}

private struct ParsedGroceryDraftRow: View {
    let draft: ParsedGroceryDraft
    var tint: Color
    var onNameChange: (String) -> Void
    var onQuantityChange: (String) -> Void
    var onCategoryChange: (GroceryCategory) -> Void
    var onRemove: () -> Void

    private var nameBinding: Binding<String> {
        Binding(get: { draft.name }, set: onNameChange)
    }
    private var quantityBinding: Binding<String> {
        Binding(get: { draft.quantity }, set: onQuantityChange)
    }

    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: Binding(get: { draft.category }, set: onCategoryChange)) {
                ForEach(GroceryCategory.ordered) { category in
                    Label(category.localizedName, systemImage: category.systemImage)
                        .tag(category)
                }
            }
        } label: {
            Label(draft.category.localizedName, systemImage: draft.category.systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .tint(.secondary)
        .foregroundStyle(.secondary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Always the AI product image — the user-taken photo is reserved for
            // the item's detail screen, never the list/draft rows.
            ProductImageView(itemName: draft.name, size: 44)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Item", text: nameBinding)
                        .font(.headline)
                        .textInputAutocapitalization(.words)

                    // Flagged-urgent drafts wear the CRITICAL chip (normal shows none).
                    if draft.priority == .critical {
                        PriorityLabel(priority: draft.priority)
                    }

                    Spacer(minLength: 0)

                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove \(draft.name)"))
                }

                HStack(spacing: 10) {
                    QuantityStepperField(
                        quantity: quantityBinding,
                        proposedUnit: draft.unit.isEmpty ? nil : draft.unit,
                        tint: tint
                    )

                    Spacer(minLength: 0)

                    categoryMenu
                }
            }
        }
        .padding(14)
        .grocerLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
    }
}

/// Shimmer placeholder mirroring `ParsedGroceryDraftRow`, shown while the list is parsing.
private struct ParsedGroceryDraftSkeletonRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ShimmerRect(cornerRadius: 10)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 8) {
                ShimmerRect(cornerRadius: 4)
                    .frame(width: 150, height: 15)
                ShimmerRect(cornerRadius: 3)
                    .frame(width: 90, height: 12)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .grocerLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Identify confirm card

/// Post-capture sheet for a single photographed product. It opens in a playful
/// "thinking" state — a circle of dots twinkling under a spinning gradient ring —
/// while the vision request is in flight, then cross-dissolves into the editable item card
/// once the model answers. The card leads with the AI-generated product image
/// (the user's own photo tucked in small), and the shopper can adjust the name,
/// category, a big quantity stepper, and notes before adding.
private struct IdentifyItemCard: View {
    /// The shopper's own photo, shown small — the saved item attaches this, but
    /// only its detail screen ever surfaces it. A binding (not a plain value) so
    /// the sheet content tracks it as a SwiftUI dependency and re-renders live.
    @Binding var userPhoto: UIImage?
    /// True while the vision request is in flight. Must be a binding: a plain
    /// value isn't tracked as a sheet dependency, so the content wouldn't
    /// re-render when it flips — the "thinking" animation would never appear and
    /// the sheet would open straight to the empty result form.
    @Binding var isIdentifying: Bool
    @Binding var name: String
    @Binding var category: GroceryCategory
    @Binding var quantity: String
    @Binding var notes: String
    var tint: Color
    var onAdd: () -> Void
    var onRetake: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Natural unit proposed for the current name, offered by the stepper.
    private var proposedUnit: String? {
        let unit = UnitGuess.guess(for: trimmedName)
        return unit.isEmpty ? nil : unit
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        ZStack {
            if isIdentifying {
                IdentifyThinkingView(onRetake: onRetake)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .scale(scale: 1.05))
                    ))
            } else {
                resultForm
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97)),
                        removal: .opacity
                    ))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86),
                   value: isIdentifying)
    }

    /// The editable item card the thinking animation resolves into.
    private var resultForm: some View {
        NavigationStack {
            Form {
                Section {
                    heroImages
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section("Item") {
                    TextField("Item name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Picker("Category", selection: $category) {
                        ForEach(GroceryCategory.ordered) { Text($0.localizedName).tag($0) }
                    }
                }

                Section("Quantity") {
                    QuantityStepperField(
                        quantity: $quantity,
                        proposedUnit: proposedUnit,
                        tint: tint,
                        large: true,
                        fill: true
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                Section("Notes (optional)") {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle("Add Photo Item")
            .navigationBarTitleDisplayMode(.inline)
            .tint(tint)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retake") {
                        Haptics.tap()
                        onRetake()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Haptics.success()
                        onAdd()
                    }
                    .bold()
                    .disabled(!canAdd)
                }
            }
        }
    }

    /// AI product image up top with the user's own photo overlaid small in the
    /// corner.
    private var heroImages: some View {
        ZStack(alignment: .bottomTrailing) {
            aiImage
            if let userPhoto {
                Image(uiImage: userPhoto)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color(.systemBackground), lineWidth: 3)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .padding(10)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The AI-generated product image, or a placeholder until a name is known
    /// (the image is keyed off the identified name).
    @ViewBuilder
    private var aiImage: some View {
        if trimmedName.isEmpty {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemGray6))
                .frame(width: 200, height: 200)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
        } else {
            ProductImageView(itemName: trimmedName, size: 200)
        }
    }
}

// MARK: - Identify thinking animation

/// The "thinking" state shown while the vision model works out what was
/// photographed. A dense field of monochrome dots (black in light mode, white in
/// dark) is clipped to a circle and twinkles on and off, fading out toward the
/// rim so the disc reads as a soft orb breathing in and out, with status copy
/// blur-replacing beneath it. It fills the sheet until `isIdentifying` clears, at
/// which point `IdentifyItemCard` cross-dissolves it into the editable item form.
/// Honors Reduce Motion: the twinkle gives way to a static dot field and the
/// status copy holds on its first line.
private struct IdentifyThinkingView: View {
    var onRetake: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Flipped true on appear to start the halo's breathing.
    @State private var animate = false
    /// Index into `messages` for the cycling status line.
    @State private var messageIndex = 0

    /// Diameter of the twinkling dot circle; the spinner ring sweeps just outside it.
    private let circleSize: CGFloat = 200

    private let messages = [
        String(localized: "Thinking…"),
        String(localized: "Looking at your photo…"),
        String(localized: "Spotting the product…"),
        String(localized: "Reading the label…"),
        String(localized: "Checking the details…"),
        String(localized: "Matching it to groceries…"),
        String(localized: "Sorting the shelves…"),
        String(localized: "Picking a category…"),
        String(localized: "Tidying things up…"),
        String(localized: "Almost done…"),
    ]

    private var currentMessageIndex: Int { reduceMotion ? 0 : messageIndex }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            artwork
            status
                .padding(.top, 40)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear { animate = true }
        .task {
            // Cycle the status line while the model thinks. Cancelled automatically
            // when the view is removed for the transition to the item form.
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                messageIndex = (messageIndex + 1) % messages.count
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(String(localized: "Retake")) {
                Haptics.tap()
                onRetake()
            }
            .font(.body.weight(.medium))
            .tint(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// The twinkling dot circle behind a soft halo.
    private var artwork: some View {
        ZStack {
            halo
            TwinklingDotCircle(diameter: circleSize, reduceMotion: reduceMotion)
        }
        .frame(width: circleSize + 80, height: circleSize + 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Identifying item from your photo"))
    }

    /// A soft monochrome glow that breathes behind the dot circle.
    private var halo: some View {
        Circle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: circleSize, height: circleSize)
            .blur(radius: 34)
            .scaleEffect(reduceMotion ? 1 : (animate ? 1.06 : 0.9))
            .opacity(reduceMotion ? 0.5 : (animate ? 0.85 : 0.4))
            .animation(reduceMotion ? nil :
                .easeInOut(duration: 2).repeatForever(autoreverses: true), value: animate)
    }

    private var status: some View {
        // Each new line blur-replaces the previous one (the system text transition)
        // rather than cross-fading in place. The `id` makes every message a fresh
        // view so the transition fires; Reduce Motion swaps with no effect.
        VStack {
            Text(messages[currentMessageIndex])
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .id(currentMessageIndex)
                .transition(reduceMotion ? .identity : AnyTransition(.blurReplace))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: currentMessageIndex)
        .accessibilityHidden(true)
    }
}

/// A dense field of dots clipped to a circle, each fading in and out on its own
/// rhythm so the whole disc reads as quietly "thinking". The field is drawn in a
/// single `Canvas` (cheap even at a few hundred dots) and laid out from a seeded
/// generator so it stays put across redraws. Under Reduce Motion it renders once,
/// static.
private struct TwinklingDotCircle: View {
    var diameter: CGFloat
    var reduceMotion: Bool

    /// One dot in the field: where it sits, its size, the phase/speed of its
    /// twinkle, and how much the rim falloff dims it.
    private struct Dot {
        let position: CGPoint
        let radius: CGFloat
        let phase: Double
        let speed: Double
        let baseOpacity: Double
        /// 1 at the center, easing to 0 at the rim so the disc has no hard edge.
        let edgeFade: Double
    }

    private let dots: [Dot]

    init(diameter: CGFloat, reduceMotion: Bool) {
        self.diameter = diameter
        self.reduceMotion = reduceMotion

        var generator = SeededGenerator(seed: 0x6D5A4C3B2A19)
        var built: [Dot] = []
        let spacing: CGFloat = 8
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        // Keep every dot (plus its radius) inside the circle's edge.
        let limit = diameter / 2 - 3

        var y = spacing / 2
        while y <= diameter - spacing / 2 {
            var x = spacing / 2
            while x <= diameter - spacing / 2 {
                // Jitter each dot off the lattice so the field reads organic rather
                // than as a visible grid. RNG is consumed for every cell (even ones
                // outside the circle) so the layout stays deterministic.
                let jx = CGFloat(generator.nextUnit() - 0.5) * spacing * 0.7
                let jy = CGFloat(generator.nextUnit() - 0.5) * spacing * 0.7
                let radius = 1.1 + CGFloat(generator.nextUnit()) * 0.9
                let phase = generator.nextUnit() * 2 * .pi
                let speed = 0.8 + generator.nextUnit() * 2.2
                let base = 0.05 + generator.nextUnit() * 0.12
                let p = CGPoint(x: x + jx, y: y + jy)
                let dx = p.x - center.x
                let dy = p.y - center.y
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist <= limit {
                    // Fade dots out across the outer half of the radius so the disc
                    // dissolves into the background instead of ending on a hard
                    // circular edge — the whole orb then reads as softly breathing.
                    let normalized = Double(dist / limit)
                    let t = max(0, (normalized - 0.5) / 0.5)
                    let edgeFade = 1 - (t * t * (3 - 2 * t))   // smoothstep falloff
                    built.append(Dot(position: p, radius: radius, phase: phase,
                                     speed: speed, baseOpacity: base, edgeFade: edgeFade))
                }
                x += spacing
            }
            y += spacing
        }
        dots = built
    }

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { context, _ in draw(in: context, time: nil) }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        draw(in: context, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// Paint every dot. With `time == nil` (Reduce Motion) each dot is drawn once
    /// at a steady mid brightness; otherwise its opacity rides a sharpened sine so
    /// it spends most of its time dim and pops bright briefly — "on and off".
    private func draw(in context: GraphicsContext, time: Double?) {
        for dot in dots {
            let twinkle: Double
            if let time {
                let wave = (sin(time * dot.speed + dot.phase) + 1) / 2
                twinkle = min(dot.baseOpacity + pow(wave, 3) * 0.9, 1)
            } else {
                twinkle = dot.baseOpacity + 0.3
            }
            let opacity = twinkle * dot.edgeFade
            let rect = CGRect(x: dot.position.x - dot.radius,
                              y: dot.position.y - dot.radius,
                              width: dot.radius * 2, height: dot.radius * 2)
            // Black in light mode, white in dark — resolved from the environment.
            context.fill(Path(ellipseIn: rect), with: .color(Color.primary.opacity(opacity)))
        }
    }
}

/// A tiny deterministic generator (xorshift64*) so the dot field lands in the
/// same place on every redraw — the view is re-initialized whenever the status
/// line cycles, and a fresh random layout each time would make the field jump.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// Next value in [0, 1).
    mutating func nextUnit() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = (state &* 0x2545F4914F6CDD1D) >> 11
        return Double(value) / Double(UInt64(1) << 53)
    }
}

// MARK: - History

/// Full-pane history browser shown when "History" is tapped in the add flow. It
/// lists items anyone in the group has bought before (with product image and the
/// last-used quantity). Tapping a row reveals the shared quantity stepper to
/// confirm the amount; "Add" stages it back in the add flow.
private struct HistoryItemsView: View {
    let suggestions: [GroceryItemSuggestion]
    var tint: Color
    /// Whether the add flow currently has at least one staged item — gates the
    /// header's confirm checkmark.
    var hasProposedItems: Bool
    var onSelect: (String, String, GroceryCategory) -> Void
    var onRemove: (String) -> Void
    var onClose: () -> Void

    @State private var search = ""

    private var filtered: [GroceryItemSuggestion] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return suggestions }
        return suggestions.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                content
            }
        }
        .tint(.primary)
    }

    private var header: some View {
        ZStack {
            Text("History")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .grocerLiquidGlass(in: Capsule())
                // Purely a label — taps pass through to nothing.
                .allowsHitTesting(false)

            HStack(spacing: 12) {
                circleButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                    onClose()
                }

                Spacer()

                // Once at least one item is staged, offer a checkmark to confirm
                // and return to the add flow. Filled + tinted so it reads as the
                // primary action, clearly distinct from the glass back button.
                if hasProposedItems {
                    Button {
                        Haptics.tap()
                        onClose()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.bold))
                            // Checkmark inverts against the fill: dark on the light
                            // (dark-theme) circle, light on the dark (light-theme) one.
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 44, height: 44)
                            // Solid primary fill — white in dark mode, black in light.
                            .background(Color.primary, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Done")
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: hasProposedItems)
    }

    private func circleButton(systemImage: String, accessibilityLabel: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .grocerLiquidGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel(accessibilityLabel)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search previous items", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    Haptics.tap()
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .grocerLiquidGlass(in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { suggestion in
                        HistoryItemRow(
                            suggestion: suggestion,
                            tint: tint,
                            onAdd: { quantity in
                                onSelect(suggestion.name, quantity, suggestion.category)
                            },
                            onRemove: { onRemove(suggestion.name) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(search.isEmpty
                 ? String(localized: "No previous items yet")
                 : String(localized: "No items match \u{201C}\(search)\u{201D}"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 28)
    }
}

/// A single history row. Collapsed it shows the image, name, and last quantity;
/// tapping expands it to confirm the amount via `QuantityStepperField` before
/// adding.
private struct HistoryItemRow: View {
    let suggestion: GroceryItemSuggestion
    var tint: Color
    var onAdd: (String) -> Void
    var onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var quantity = ""
    /// Drives the "already on your list" confirmation before re-adding.
    @State private var showAddAgainConfirm = false
    /// Amount captured when the confirmation is raised, applied on confirm.
    @State private var pendingQuantity = ""
    /// Set once this item has been staged from history. Gives the row a border and
    /// flips the action to "Remove" so the staged item can be taken back off.
    @State private var addedToList = false

    /// Whether the row should read as "on the list" — either it was already
    /// pending, or it's been staged here.
    private var isOnList: Bool { suggestion.isPending || addedToList }

    private var proposedUnit: String? {
        let unit = UnitGuess.guess(for: suggestion.name)
        return unit.isEmpty ? nil : unit
    }

    /// A sensible non-zero amount for a one-tap add: the group's last-used amount,
    /// else one of the natural unit, else no quantity at all (never "0").
    private var defaultQuantity: String {
        let last = suggestion.quantity?.trimmingCharacters(in: .whitespaces) ?? ""
        if !last.isEmpty { return last }
        if let unit = proposedUnit { return "1 \(unit)" }
        // No last-used amount and no natural unit: default to one rather than 0.
        return "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            rowInfo

            HStack(spacing: 12) {
                QuantityStepperField(
                    quantity: $quantity,
                    proposedUnit: proposedUnit,
                    tint: tint
                )

                Spacer(minLength: 0)

                Button {
                    toggleAdd()
                } label: {
                    Label(addedToList ? String(localized: "Remove") : String(localized: "Add"),
                          systemImage: addedToList ? "minus" : "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .contentTransition(.symbolEffect(.replace))
                }
                .tint(.primary)
                .grocerGlassButton()
                .clipShape(Capsule())
                .accessibilityLabel(addedToList
                    ? String(localized: "Remove \(suggestion.name) from list")
                    : String(localized: "Add \(suggestion.name) to list"))
            }
        }
        .padding(14)
        .grocerLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
        .overlay {
            if addedToList {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(.systemGray3), lineWidth: 2)
            }
        }
        .alert("Already on your list", isPresented: $showAddAgainConfirm) {
            Button("Add Again") { performAdd(pendingQuantity) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(suggestion.name) is already on your list. Add it again?")
        }
        .onAppear {
            // Always-expanded rows seed a non-zero amount to adjust from.
            if quantity.isEmpty { quantity = defaultQuantity }
        }
    }

    private var rowInfo: some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: suggestion.name, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if isOnList {
                        Text("On list")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Label(suggestion.category.localizedName, systemImage: suggestion.category.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Toggle the row's staged state: stage it (via the duplicate check) when it
    /// isn't on the list yet, or take it back off when it is.
    private func toggleAdd() {
        Haptics.tap()
        if addedToList {
            performRemove()
        } else {
            attemptAdd(quantity)
        }
    }

    /// Route an add through the duplicate check: items already on the list prompt
    /// for confirmation; everything else is added straight away.
    private func attemptAdd(_ rawQuantity: String) {
        let quantity = sanitizedQuantity(rawQuantity)
        if suggestion.isPending {
            pendingQuantity = quantity
            showAddAgainConfirm = true
        } else {
            performAdd(quantity)
        }
    }

    private func performAdd(_ quantity: String) {
        onAdd(quantity)
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            addedToList = true
        }
        // Sound the success notification just after the press tap. Haptics
        // debounces feedback fired within 40ms of each other, so a small delay
        // lets both land — the add reads as a tap followed by the success buzz.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Haptics.success()
        }
    }

    private func performRemove() {
        onRemove()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            addedToList = false
        }
    }

    /// Never hand a zero (or blank) amount to the list — treat it as "no quantity".
    private func sanitizedQuantity(_ quantity: String) -> String {
        let trimmed = quantity.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if let amount = Quantity(parsing: trimmed).amount, amount <= 0 { return "" }
        return trimmed
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

/// A growing, bullet-aware text editor for the freeform compose field.
///
/// SwiftUI's `TextField` resets the caret to the *end* whenever its bound text is
/// rewritten. The add flow re-applies bullet formatting on every keystroke, so
/// with a `TextField` pressing return in the middle of the list teleported the
/// caret to the bottom — and, racing UIKit's own newline insert, left a stray
/// empty bullet there. Owning a `UITextView` lets us re-apply the formatting and
/// then restore the caret to the line the user is actually editing.
private struct BulletListTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// Two-way bridge to the parent's first-responder state.
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        // Grow with content; the surrounding ScrollView handles any overflow.
        textView.isScrollEnabled = false
        textView.autocapitalizationType = .sentences
        applyFont(textView)
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        // External (mirror) writes — e.g. editing a proposed row rewrites the
        // text — land here. They happen while the field isn't being typed in, so
        // parking the caret at the end is fine.
        if textView.text != text {
            textView.text = text
            let end = (text as NSString).length
            textView.selectedRange = NSRange(location: end, length: 0)
        }
        if isFocused, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func applyFont(_ textView: UITextView) {
        // Match the SwiftUI `.title3.weight(.medium)` the field used to carry, and
        // keep it scaling with Dynamic Type.
        let base = UIFont.preferredFont(forTextStyle: .title3)
        let medium = UIFont.systemFont(ofSize: base.pointSize, weight: .medium)
        textView.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: medium)
        textView.adjustsFontForContentSizeCategory = true
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BulletListTextEditor

        init(_ parent: BulletListTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            let raw = textView.text ?? ""
            let formatted = AddItemSearchView.bulletified(raw)
            if formatted != raw {
                let caret = caretLocation(movingFrom: raw, to: formatted,
                                          caret: textView.selectedRange.location)
                textView.text = formatted
                textView.selectedRange = NSRange(location: caret, length: 0)
            }
            if parent.text != textView.text {
                parent.text = textView.text
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        // MARK: Caret mapping

        /// Maps the caret from the user's raw text onto the bullet-formatted text
        /// so it stays on the line being edited instead of jumping to the end.
        /// Works in UTF-16 units to match `UITextView.selectedRange`.
        private func caretLocation(movingFrom raw: String, to formatted: String, caret: Int) -> Int {
            let rawLines = raw.components(separatedBy: "\n")
            let fmtLines = formatted.components(separatedBy: "\n")
            let clamp: (Int) -> Int = { max(0, min($0, formatted.utf16.count)) }

            // Find the caret's line and its column within that line.
            var lineStart = 0
            var lineIndex = max(0, rawLines.count - 1)
            var column = rawLines.last?.utf16.count ?? 0
            for (i, line) in rawLines.enumerated() {
                let len = line.utf16.count
                if caret <= lineStart + len {
                    lineIndex = i
                    column = caret - lineStart
                    break
                }
                lineStart += len + 1   // + the "\n"
            }

            // A line was dropped (e.g. backspacing an empty bullet merges it
            // upward): land at the end of the line it merged into.
            guard fmtLines.count == rawLines.count, lineIndex < fmtLines.count else {
                let target = max(0, min(lineIndex - 1, fmtLines.count - 1))
                var start = 0
                for j in 0..<target { start += fmtLines[j].utf16.count + 1 }
                return clamp(start + fmtLines[target].utf16.count)
            }

            let rawPrefix = leadingBulletPrefixLength(rawLines[lineIndex])
            let fmtLine = fmtLines[lineIndex]
            let fmtPrefix = leadingBulletPrefixLength(fmtLine)
            let contentColumn = max(0, column - rawPrefix)
            let newColumn = min(fmtPrefix + contentColumn, fmtLine.utf16.count)

            var start = 0
            for j in 0..<lineIndex { start += fmtLines[j].utf16.count + 1 }
            return clamp(start + newColumn)
        }

        /// UTF-16 length of a line's leading run of bullet markers and spaces.
        private func leadingBulletPrefixLength(_ line: String) -> Int {
            var count = 0
            for ch in line {
                if ch == "•" || ch == " " { count += ch.utf16.count } else { break }
            }
            return count
        }
    }
}
