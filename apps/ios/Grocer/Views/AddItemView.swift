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
                TextField("Quantity", text: $quantity)
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

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            addFlowContent
                .opacity(contentAppeared ? 1 : 0)
                .offset(y: contentAppeared ? 0 : 14)
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
            bottomAction
        }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Items")
                    .font(.title2.weight(.bold))
                Text(repo.currentHousehold?.name ?? "Grocer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Top pane: input + autocomplete

    private var composePanel: some View {
        TextField("Milk, eggs, bananas for the week", text: $inputText, axis: .vertical)
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
                        ProgressView().controlSize(.small)
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
            .map { DetectedItem(name: $0, quantity: "", category: CategoryGuess.guess(for: $0)) }
    }

    /// Re-projects detected items onto the current drafts, reusing existing rows
    /// (and their `id`, so the streamed image doesn't reload) when names match.
    private func merge(_ detected: [DetectedItem], into existing: [ParsedGroceryDraft]) -> [ParsedGroceryDraft] {
        detected.map { item in
            if var match = existing.first(where: { $0.name.lowercased() == item.name.lowercased() }) {
                if !item.quantity.isEmpty { match.quantity = item.quantity }
                match.category = item.category
                return match
            }
            var quantity = item.quantity
            if quantity.isEmpty,
               let known = repo.currentItemSuggestions.first(where: { $0.name.lowercased() == item.name.lowercased() }),
               let knownQuantity = known.quantity {
                quantity = knownQuantity
            }
            return ParsedGroceryDraft(name: item.name, quantity: quantity, category: item.category)
        }
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

    // MARK: - Finalize

    private func addItems() {
        let itemsToAdd = drafts.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !itemsToAdd.isEmpty else { return }

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
private struct DetectedItem {
    var name: String
    var quantity: String
    var category: GroceryCategory

    init(name: String, quantity: String, category: GroceryCategory) {
        self.name = name
        self.quantity = quantity
        self.category = category
    }

    init?(parsedItem: ParsedItem) {
        let trimmedName = parsedItem.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        name = trimmedName
        quantity = parsedItem.quantity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        category = GroceryCategory(rawValue: parsedItem.category) ?? CategoryGuess.guess(for: trimmedName)
    }
}

private struct ParsedGroceryDraft: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var quantity: String
    var category: GroceryCategory

    init(name: String, quantity: String, category: GroceryCategory) {
        self.name = name
        self.quantity = quantity
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductImageView(itemName: draft.name, size: 44)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Item", text: nameBinding)
                    .font(.headline)
                    .textInputAutocapitalization(.words)

                HStack(spacing: 10) {
                    TextField("Quantity", text: quantityBinding)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)

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
                }
                .foregroundStyle(.secondary)
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
            .accessibilityLabel("Remove \(draft.name)")
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
