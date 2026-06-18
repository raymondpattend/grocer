import PostHog
import SwiftUI

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
                Picker("Priority", selection: $priority) {
                    ForEach(ItemPriority.allCases) { p in
                        Text(p.localizedName).tag(p)
                    }
                }
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

    /// Debounce handle for the AI parse; cancelled and rescheduled on each edit.
    @State private var parseTask: Task<Void, Never>?
    /// Last text we ran a parse for, so identical text doesn't re-parse.
    @State private var lastParsedText = ""
    /// Set when a text change originates from a row edit (mirror write-back) so
    /// it doesn't trigger another parse, preventing a feedback loop.
    @State private var suppressParse = false

    @FocusState private var inputFocused: Bool

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
                .overlay(alignment: .bottomTrailing) {
                    if !showHistory && !historySuggestions.isEmpty {
                        historyButton
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
        .onChange(of: inputText) { _, newValue in
            if suppressParse {
                suppressParse = false
                return
            }
            // Once the list spans more than one line (the user hit return), render
            // it as a bullet list so each item reads as its own point.
            let formatted = bulletified(newValue)
            if formatted != newValue {
                suppressParse = true
                inputText = formatted
            }
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
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityLabel("Add from history")
    }

    private var addFlowContent: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                // The glass container lives inside the ScrollView so the cards'
                // glass is rendered (and clipped) within the scroll bounds — otherwise
                // it draws over the pinned header when the list scrolls up.
                scrollContent
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    // Reserve space for the floating History pill (height 34 + 16
                    // bottom inset) so a long proposed list can scroll clear of it
                    // instead of having its last rows overlapped.
                    .padding(.bottom, historySuggestions.isEmpty ? 24 : 74)
            }
            .scrollDismissesKeyboard(.interactively)
        }
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
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Add Items")
                // ~10% larger than .headline (17pt).
                .font(.system(size: 18.7, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 36)
                .grocerLiquidGlass(in: Capsule())
                // Purely a label — taps pass through to nothing.
                .allowsHitTesting(false)

            Spacer()

            Button {
                Haptics.tap()
                // While typing, the button drops the keyboard; otherwise it closes.
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
    }

    // MARK: - Top pane: input + autocomplete

    private var composePanel: some View {
        TextField("Type your list freely — milk, eggs, bananas, etc.", text: $inputText, axis: .vertical)
            .focused($inputFocused)
            .font(.title3.weight(.medium))
            .textInputAutocapitalization(.sentences)
            .lineLimit(3...8)
            .submitLabel(.done)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var emptyProposed: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.append")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("Start typing — items you add will appear here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

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
        let cleaned = stripBullets(text)
        let parsed = await APIClient.shared.parseList(cleaned)
        guard !Task.isCancelled else { isParsing = false; return }

        let detected = parsed.isEmpty ? localSplit(cleaned) : parsed.compactMap(DetectedItem.init(parsedItem:))
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
                return match
            }

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
            return ParsedGroceryDraft(name: item.name, quantity: quantity, unit: proposedUnit, category: item.category)
        }
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
        let parts = drafts.map { $0.quantity.isEmpty ? $0.name : "\($0.quantity) \($0.name)" }
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
    private func bulletified(_ text: String) -> String {
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
    private func stripBulletPrefix(_ line: String) -> String {
        String(line.drop(while: { $0 == "•" || $0 == " " }))
    }

    /// Strips bullet markers and surrounding whitespace from each line, recovering
    /// the plain item text for parsing.
    private func stripBullets(_ text: String) -> String {
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
                notes: nil,
                replacementPreference: nil
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

    init(name: String, quantity: String, unit: String = "", category: GroceryCategory) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.category = category
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
            ProductImageView(itemName: draft.name, size: 44)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Item", text: nameBinding)
                        .font(.headline)
                        .textInputAutocapitalization(.words)

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
