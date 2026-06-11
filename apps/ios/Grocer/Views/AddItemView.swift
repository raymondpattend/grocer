import SwiftUI
import UIKit

/// Lightweight taptic feedback for discrete UI actions in the add/history flow.
enum Haptics {
    /// A light tap for ordinary button presses (close, history, remove).
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    /// A selection tick for toggling/expanding rows.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    /// A success notification when an item lands on the list.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

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
                    ForEach(GroceryCategory.ordered) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: category) { _, _ in categoryEditedManually = true }
                Picker("Priority", selection: $priority) {
                    ForEach(ItemPriority.allCases) { p in
                        Label(p.rawValue, systemImage: p.systemImage).tag(p)
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
                Button("Cancel") { dismiss() }
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

    var tint: Color = .green

    @State private var inputText = ""
    @State private var drafts: [ParsedGroceryDraft] = []
    @State private var isParsing = false
    @State private var contentAppeared = false
    @State private var showHistory = false

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
                    onSelect: { name, quantity, category in
                        addFromHistory(name: name, quantity: quantity, category: category)
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showHistory = false
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.28)) {
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
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                contentAppeared = true
            }
            refocusInput(after: 0.24)
        }
        .onChange(of: inputText) { _, _ in
            if suppressParse {
                suppressParse = false
                return
            }
            scheduleParse(after: .milliseconds(500))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showHistory {
                bottomAction
            }
        }
    }

    /// Floating glass pill that swaps the add flow for the group's item history.
    private var historyButton: some View {
        Button {
            Haptics.tap()
            inputFocused = false
            withAnimation(.easeInOut(duration: 0.28)) {
                showHistory = true
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
        }
        .tint(.primary)
        .grocerGlassButton()
        .clipShape(Circle())
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityLabel("Add from history")
    }

    @ViewBuilder
    private var addFlowContent: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                flowStack
            }
        } else {
            flowStack
        }
    }

    private var flowStack: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    composePanel
                    proposedPanel
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Add Items")
                .font(.largeTitle.weight(.bold))

            Spacer()

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
            }
            .tint(.primary)
            .grocerGlassButton()
            .clipShape(Circle())
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Top pane: input + autocomplete

    private var composePanel: some View {
        TextField("Milk, eggs, bananas, e.t.c.", text: $inputText, axis: .vertical)
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
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { drafts = [] }
            lastParsedText = ""
            return
        }

        isParsing = true
        let parsed = await APIClient.shared.parseList(text)
        guard !Task.isCancelled else { isParsing = false; return }

        let detected = parsed.isEmpty ? localSplit(text) : parsed.compactMap(DetectedItem.init(parsedItem:))
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
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
            } else if let known = repo.currentItemSuggestions.first(where: { $0.name.lowercased() == item.name.lowercased() }),
                      let knownQuantity = known.quantity {
                // Reuse the amount this household last bought.
                quantity = knownQuantity
            } else if !proposedUnit.isEmpty {
                // Propose one of the natural unit, e.g. "1 dozen" for eggs.
                quantity = "1 \(proposedUnit)"
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
        drafts[idx].category = category
        // Category isn't reflected in the mirrored text, so no write-back needed.
    }

    private func removeDraft(_ id: UUID) {
        Haptics.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
            drafts.removeAll { $0.id == id }
        }
        syncTextFromDrafts()
    }

    /// Rewrites the input text from the current drafts. Guarded so the resulting
    /// `inputText` change doesn't kick off another parse.
    private func syncTextFromDrafts() {
        let text = drafts
            .map { $0.quantity.isEmpty ? $0.name : "\($0.quantity) \($0.name)" }
            .joined(separator: ", ")
        suppressParse = true
        inputText = text
        lastParsedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
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

    // MARK: - Finalize

    private func addItems() {
        let itemsToAdd = drafts.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !itemsToAdd.isEmpty else { return }

        Haptics.success()
        for draft in itemsToAdd {
            repo.addItem(
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: draft.quantity.trimmingCharacters(in: .whitespacesAndNewlines),
                category: draft.category,
                notes: nil,
                replacementPreference: nil
            )
        }
        dismiss()
    }

    private func refocusInput(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            inputFocused = true
        }
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
                    Label(category.rawValue, systemImage: category.systemImage)
                        .tag(category)
                }
            }
        } label: {
            Label(draft.category.rawValue, systemImage: draft.category.systemImage)
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
                    .accessibilityLabel("Remove \(draft.name)")
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
    var onSelect: (String, String, GroceryCategory) -> Void
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
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.title2.weight(.bold))
                Text("Previously added by the group")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
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
                        HistoryItemRow(suggestion: suggestion, tint: tint) { quantity in
                            onSelect(suggestion.name, quantity, suggestion.category)
                        }
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
                 ? "No previous items yet"
                 : "No items match \u{201C}\(search)\u{201D}")
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

    @State private var expanded = false
    @State private var quantity = ""

    private var proposedUnit: String? {
        let unit = UnitGuess.guess(for: suggestion.name)
        return unit.isEmpty ? nil : unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                toggle()
            } label: {
                rowHeader
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(spacing: 12) {
                    QuantityStepperField(
                        quantity: $quantity,
                        proposedUnit: proposedUnit,
                        tint: tint
                    )

                    Spacer(minLength: 0)

                    Button {
                        Haptics.success()
                        onAdd(quantity)
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                    }
                    .tint(.primary)
                    .grocerGlassButton()
                    .clipShape(Capsule())
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .grocerLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
    }

    private var rowHeader: some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: suggestion.name, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if suggestion.isPending {
                        Text("On list")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if let last = suggestion.quantity?.trimmingCharacters(in: .whitespaces), !last.isEmpty {
                    Text("Last: \(last)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label(suggestion.category.rawValue, systemImage: suggestion.category.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: expanded ? "chevron.up" : "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .contentShape(Rectangle())
    }

    private func toggle() {
        Haptics.selection()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if !expanded {
                // Seed the stepper with the group's last-used amount.
                quantity = suggestion.quantity?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            expanded.toggle()
        }
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
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
