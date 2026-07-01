import XCTest

/// Guardrails for the Add Items flow wiring that's awkward to drive at runtime:
/// the commit-per-line model (interpret only on commit, one line = one item), the
/// thinking → resolved row states, the liquid-glass quantity button + popover, the
/// title/close chrome, and the camera → AI-identify path.
final class AddItemSourceGuardrailTests: XCTestCase {
    private func addItemSource() throws -> String {
        try source("Grocer/Views/AddItemView.swift")
    }

    func testTitleIsAScrollingGlassChipAndCloseButtonIsSticky() throws {
        let src = try addItemSource()

        // The title is a Liquid Glass capsule chip.
        let title = try excerpt(src, from: "private var titleChip", to: "private var closeButton")
        XCTAssertTrue(title.contains("Text(\"Add Items\")"))
        XCTAssertTrue(title.contains("grocerLiquidGlass(in: Capsule())"),
                      "The Add Items title should have its liquid-glass chip")

        // The title scrolls with the content (no pinned header bar)…
        let content = try excerpt(src, from: "private var addFlowContent", to: "private var itemsSection")
        XCTAssertTrue(content.contains("ScrollView {"))
        XCTAssertTrue(content.contains("titleChip"),
                      "The title should live inside the ScrollView so it scrolls")
        let searchView = try excerpt(src, from: "struct AddItemSearchView", to: "private struct DetectedItem")
        XCTAssertFalse(searchView.contains("private var header"),
                       "The Add Items flow should not define a pinned header bar")

        // …while only the close button is sticky (a top overlay over the content).
        let body = try excerpt(src, from: "var body: some View", to: "private var floatingControls")
        XCTAssertTrue(body.contains(".overlay(alignment: .top) {"))
        XCTAssertTrue(body.contains("closeButton"))
    }

    func testAddFlowWritesToExplicitTargetListWithoutGlobalSelectionSideEffect() throws {
        let src = try addItemSource()

        // The add flow can target an explicit list and routes its write through it
        // (rather than always writing to the ambient `currentList`).
        XCTAssertTrue(src.contains("var targetListId: String?"),
                      "AddItemSearchView should accept an explicit target list")
        XCTAssertTrue(src.contains("toListId: targetListId"),
                      "the committed add should route to the explicit target list")

        // The combined trip presents the add flow with an explicit target and must
        // NOT mutate the global selected group as a side effect of adding.
        let combined = try source("Grocer/Views/CombinedShoppingSessionView.swift")
        let selectAdd = try excerpt(combined, from: "private func selectAddTarget", to: "private func addTargetTint")
        XCTAssertFalse(selectAdd.contains("selectHousehold"),
                       "adding during a combined trip must not switch the app's selected group")
        XCTAssertTrue(combined.contains("targetListId: target.id"),
                      "the combined add flow should pass the chosen list explicitly")
    }

    func testInterpretRunsOnlyOnCommitNotWhileTyping() throws {
        let src = try addItemSource()

        // The debounced, parse-while-typing pipeline (and its bullet text editor)
        // is gone — interpretation only runs when a line is committed.
        XCTAssertFalse(src.contains("scheduleParse"),
                       "the debounced while-typing parse should be gone")
        XCTAssertFalse(src.contains("BulletListTextEditor"),
                       "the bullet-formatting text editor should be gone")

        // A return / multi-line paste commits completed lines; losing focus commits
        // the trailing line. Neither runs while typing within a line.
        let draftChange = try excerpt(src, from: ".onChange(of: draftText)", to: ".onChange(of: draftFocused)")
        XCTAssertTrue(draftChange.contains("commitCompletedLines()"))
        let focusChange = try excerpt(src, from: ".onChange(of: draftFocused)", to: ".safeAreaInset")
        XCTAssertTrue(focusChange.contains("commitActiveLine()"))

        // The compose field is a UIKit-backed field (so it can detect backspace on
        // empty), bound to the one active line and bridging focus via draftFocused.
        let compose = try excerpt(src, from: "private var composeLine", to: "// Shown beneath the compose line")
        XCTAssertTrue(compose.contains("ComposeTextField(text: $draftText"))
        XCTAssertTrue(compose.contains("isFocused: $draftFocused"))
    }

    func testBackspaceOnEmptyComposeFocusesPreviousItem() throws {
        let src = try addItemSource()
        // The compose field reports a backspace pressed while empty…
        XCTAssertTrue(src.contains("override func deleteBackward()"))
        XCTAssertTrue(src.contains("onBackspaceWhenEmpty: editPreviousItem"))
        // …which requests focus on the previous row.
        XCTAssertTrue(src.contains("focusRequestItem = last.id"))
        // The row consumes the request by focusing its own name field.
        let row = try excerpt(src, from: "private struct LineItemRow", to: "private struct ThinkingPill")
        XCTAssertTrue(row.contains(".onChange(of: focusRequest)"))
        XCTAssertTrue(row.contains("editing = true"))
    }

    func testCommittedLinesLiftOutIntoRowsAboveTheComposeLine() throws {
        let src = try addItemSource()
        // The list is committed rows followed by the active compose line.
        let list = try excerpt(src, from: "private var listBody", to: "private var titleChip")
        XCTAssertTrue(list.contains("ForEach(items)"))
        XCTAssertTrue(list.contains("LineItemRow("))
        XCTAssertTrue(list.contains("composeLine"))
    }

    func testCommitStagesExactlyOneThinkingItemWithHaptic() throws {
        let src = try addItemSource()
        let commit = try excerpt(src, from: "private func commitLine", to: "private func recalcIfNeeded")
        // A committed line becomes one thinking row, with a firm thud as it
        // enters that state, and is then interpreted.
        XCTAssertTrue(commit.contains("state: .thinking"))
        XCTAssertTrue(commit.contains("Haptics.commit()"), "Enter/commit fires a firm thud")
        XCTAssertTrue(commit.contains("items.append(item)"),
                      "a committed line must append exactly one item")
        XCTAssertTrue(commit.contains("interpret(item.id, allowSplit: true)"))

        // A softer haptic (a selection tick, not the commit thud) fires when the AI
        // finishes and the row(s) resolve, so an item settling in doesn't jolt.
        let interpret = try excerpt(src, from: "private func interpret", to: "private struct ResolvedItem")
        XCTAssertTrue(interpret.contains("Haptics.selection()"))
    }

    func testOnlyCommasDelineateMultipleItems() throws {
        let src = try addItemSource()

        // The line is split on commas; each segment is interpreted as one item and
        // extras are inserted as additional rows after the first.
        let interpret = try excerpt(src, from: "private func interpret", to: "private struct ResolvedItem")
        XCTAssertTrue(interpret.contains("name.split(separator: \",\")"))
        XCTAssertTrue(interpret.contains("APIClient.shared.parseList(segment)"))
        XCTAssertTrue(interpret.contains("singleResolvedItem(from: parsed"))
        XCTAssertTrue(interpret.contains("items.insert(contentsOf:"))
        // The split is capped at 10 to bound the number of parse calls.
        XCTAssertTrue(interpret.contains("maxItems = 10"))
        XCTAssertTrue(interpret.contains("segments.prefix(maxItems - 1)"))

        // Each comma segment coalesces to exactly one item (the AI never splits
        // within a segment), with a single-item offline fallback that keeps the
        // user's typed wording.
        let single = try excerpt(src, from: "private func singleResolvedItem", to: "private func resolveQuantity")
        XCTAssertTrue(single.contains("parsed.count == 1"))
        XCTAssertTrue(single.contains("typedName"))
    }

    func testQuantityLabelComesFromAINotAnOnDeviceGuess() throws {
        let src = try addItemSource()
        let resolve = try excerpt(src, from: "private func resolveQuantity", to: "// MARK: - Priority markers")
        // An explicit amount trusts the AI's unit exactly (an empty unit = a bare
        // count), rather than forcing an on-device unit onto it.
        XCTAssertTrue(resolve.contains("aiUnit"))
        XCTAssertTrue(resolve.contains("Quantity(parsing: amount)"))
        // The on-device guess is only an offline fallback when there's no AI unit.
        XCTAssertTrue(resolve.contains("aiUnit.isEmpty ? UnitGuess.guess"))
    }

    func testThinkingRowShowsSkeletonAndShimmeringThinkingPill() throws {
        let src = try addItemSource()
        let row = try excerpt(src, from: "private struct LineItemRow", to: "private struct ThinkingPill")
        // Left: skeleton while thinking, AI product image once resolved.
        XCTAssertTrue(row.contains("ShimmerRect(cornerRadius: 8)"))
        XCTAssertTrue(row.contains("ProductImageView(itemName: item.name, size: Self.imageSize)"))
        // Right: the thinking pill while thinking.
        XCTAssertTrue(row.contains("ThinkingPill()"))

        // The pill is a shimmering "Thinking…" label (animated sweep).
        let pill = try excerpt(src, from: "private struct ThinkingPill", to: "private struct InlineQuantityChip")
        XCTAssertTrue(pill.contains("Thinking"))
        XCTAssertTrue(pill.contains("LinearGradient"))
        XCTAssertTrue(pill.contains("repeatForever"))
    }

    func testResolvedRowShowsInlineExpandingGlassQuantityStepper() throws {
        let src = try addItemSource()
        // The resolved accessory is the inline quantity chip.
        let row = try excerpt(src, from: "private struct LineItemRow", to: "private struct ThinkingPill")
        XCTAssertTrue(row.contains("InlineQuantityChip(quantity: $quantity, unit: item.unit"))

        // The chip shows the amount + label and extends in place to an inline −/+
        // stepper (a glass capsule). A tap toggles the stepper; a long press opens a
        // popover unit picker (driven by explicit gestures, not a Button +
        // .contextMenu, so the long press reliably lands on the glass chip).
        let chip = try excerpt(src, from: "private struct InlineQuantityChip", to: "extension View {")
        XCTAssertTrue(chip.contains("Quantity.displayString(quantity)"))
        XCTAssertTrue(chip.contains("expanded.toggle()"))
        XCTAssertTrue(chip.contains("systemImage: \"minus\""))
        XCTAssertTrue(chip.contains("systemImage: \"plus\""))
        XCTAssertTrue(chip.contains("grocerLiquidGlass(in: Capsule()"))
        XCTAssertTrue(chip.contains(".onLongPressGesture"),
                      "long-pressing the chip opens the unit picker")
        XCTAssertTrue(chip.contains(".popover(isPresented: $showUnitPicker"),
                      "the unit picker is a popover")
        XCTAssertTrue(chip.contains("GroceryUnits.all"),
                      "the picker offers the same grocery-unit options as the stepper")
        XCTAssertFalse(chip.contains("QuantityStepperField"),
                       "the stepper is inline, not the shared unit-editing field")
    }

    func testTappingNameEditsItLocallyWithoutTouchingQuantity() throws {
        let src = try addItemSource()
        let row = try excerpt(src, from: "private struct LineItemRow", to: "private struct ThinkingPill")
        // The name is an editable TextField; tapping it starts editing.
        XCTAssertTrue(row.contains("TextField(\"Item\", text: $name"))
        XCTAssertTrue(row.contains("if !editing { editing = true }"))
        // It grows to two lines while editing, one (truncating) line when done.
        XCTAssertTrue(row.contains(".lineLimit(editing ? 1...2 : 1...1)"))
        XCTAssertTrue(row.contains(".truncationMode(.tail)"))
        XCTAssertTrue(row.contains("onCommitName()"))
        XCTAssertTrue(src.contains("onCommitName: { recalcIfNeeded(item.id) }"))

        // A name edit updates the name (and the image, keyed on it) but NEVER
        // re-runs the AI, re-enters thinking, or touches the quantity/label.
        let recalc = try excerpt(src, from: "private func recalcIfNeeded", to: "// MARK: - Interpret")
        XCTAssertFalse(recalc.contains("interpret("), "a name edit must not re-run the AI")
        XCTAssertFalse(recalc.contains(".thinking"), "a name edit must not re-enter thinking")
        XCTAssertFalse(recalc.contains(".quantity"), "a name edit must not touch the quantity")
        XCTAssertTrue(recalc.contains("items[idx].name = name"))
        XCTAssertTrue(recalc.contains("removeItem(id)"),
                      "clearing a row's name should drop the row")
    }

    func testAINameIsKeptOnlyWhenFaithfulToTheTypedText() throws {
        let src = try addItemSource()
        let single = try excerpt(src, from: "private func singleResolvedItem", to: "private func resolveQuantity")
        // The AI name is adopted only when faithful; otherwise the user's wording wins.
        XCTAssertTrue(single.contains("aiNameIsFaithful"))
        XCTAssertTrue(single.contains("faithful ? d.name : typedName"))
        // The user's explicit leading amount wins over the AI's.
        XCTAssertTrue(single.contains("userAmount.isEmpty ?"))
        // Faithfulness = the AI adds no new word (prefix match handles plurals).
        XCTAssertTrue(single.contains("aiTokens.allSatisfy"))
        XCTAssertTrue(single.contains("user.hasPrefix(ai) || ai.hasPrefix(user)"))
    }

    func testInlineMarkersStageItemsAsHighPriority() throws {
        let src = try addItemSource()
        // "!" or the words critical/important/high flag an item as urgent.
        XCTAssertTrue(src.contains("critical|important|high"))
        XCTAssertTrue(src.contains("func hasHighPriorityMarker"))

        // Priority is derived per committed line, with the marker stripped from the name.
        let commit = try excerpt(src, from: "private func commitLine", to: "private func recalcIfNeeded")
        XCTAssertTrue(commit.contains("hasHighPriorityMarker(in: raw)"))
        XCTAssertTrue(commit.contains("strippingPriorityMarkers(raw)"))

        // Priority rides through to the saved item…
        XCTAssertTrue(src.contains("priority: item.priority"))
        // …and shows a tappable critical marker on the row (normal shows nothing).
        let row = try excerpt(src, from: "private struct LineItemRow", to: "private struct ThinkingPill")
        XCTAssertTrue(row.contains("item.priority == .critical"))
        XCTAssertTrue(row.contains("exclamationmark.triangle.fill"))
    }

    func testInlineMarkerTogglesCriticalBothWays() throws {
        let src = try addItemSource()
        let recalc = try excerpt(src, from: "private func recalcIfNeeded", to: "// MARK: - Interpret")
        // Editing the name re-derives priority both ways (escalate and clear)…
        XCTAssertTrue(recalc.contains("items[idx].priority = priority"))
        XCTAssertTrue(recalc.contains("priority != items[idx].priority"))
        // …and a bare "!" toggle (no name change) still updates without a re-parse.
        XCTAssertTrue(recalc.contains("if nameChanged {"))
    }

    func testCameraViewShowsCaptureHint() throws {
        let src = try source("Grocer/Views/CameraCaptureView.swift")
        // A Liquid Glass hint explains what's worth photographing — an item, a
        // written list, or a receipt.
        let hint = try excerpt(src, from: "private struct CameraHintView", to: "struct CameraZoomOption")
        XCTAssertTrue(hint.contains("written list"))
        XCTAssertTrue(hint.contains("grocerLiquidGlass(in: Capsule())"))
    }

    func testCameraButtonSitsLeadingOnTheHistoryRow() throws {
        let src = try addItemSource()
        let controls = try excerpt(src, from: "private var floatingControls: some View", to: "private var cameraButton")
        // Camera leading, History trailing on the same row.
        XCTAssertLessThan(
            try sourceIndex(of: "cameraButton", in: controls),
            try sourceIndex(of: "historyButton", in: controls)
        )
        XCTAssertTrue(controls.contains("Spacer(minLength: 0)"))
    }

    func testCameraButtonHasNoSnapItemLabel() throws {
        let src = try addItemSource()
        let button = try excerpt(src, from: "private var cameraButton: some View", to: "private var historyButton")
        // Icon-only — the "Snap Item" label was removed.
        XCTAssertFalse(button.contains("\"Snap Item\""),
                       "The camera button should no longer carry a \"Snap Item\" label")
        XCTAssertTrue(button.contains("Image(systemName: \"camera.fill\")"))
    }

    func testCameraCaptureSkipsRetakeConfirmation() throws {
        let src = try addItemSource()
        // The custom AVFoundation camera (no Retake/Use Photo step) is used when a
        // camera is available; the library picker is only the fallback.
        let capture = try excerpt(src, from: "private func startPhotoCapture", to: "private func presentIdentifyIfPending")
        XCTAssertTrue(capture.contains("CameraCaptureView.isAvailable"))
        XCTAssertTrue(capture.contains("showCamera = true"))
    }

    func testPhotoCaptureIdentifiesAndStagesResolvedRowWithPhoto() throws {
        let src = try addItemSource()

        // Capture → vision identify.
        let capture = try excerpt(src, from: "private func handleCapturedImage", to: "private func applyIdentifyOutcome")
        XCTAssertTrue(capture.contains("resizedItemPhotoData()"))
        XCTAssertTrue(capture.contains("APIClient.shared.identifyItem(imageData:"))

        // A confirmed single item lands as a resolved row carrying its photo + notes.
        let addFromPhoto = try excerpt(src, from: "private func addFromPhoto", to: "private func addParsedList")
        XCTAssertTrue(addFromPhoto.contains("appendResolved("))
        XCTAssertTrue(addFromPhoto.contains("photoData: photoData"))
        let append = try excerpt(src, from: "private func appendResolved", to: "// MARK: - Photo capture")
        XCTAssertTrue(append.contains("photoData: photoData"))
        XCTAssertTrue(append.contains("notes: notes"))

        // The photo and notes flow into the saved item on finalize.
        XCTAssertTrue(src.contains("photoData: item.photoData"))
        XCTAssertTrue(src.contains("notes: item.notes"))
    }

    func testListPhotoBypassesCardAndStagesEveryItem() throws {
        let src = try addItemSource()
        // A photographed list drops the per-item card and stages every detected item.
        let apply = try excerpt(src, from: "private func applyIdentifyOutcome", to: "private func commitIdentifiedItem")
        XCTAssertTrue(apply.contains("outcome.items.isEmpty"))
        XCTAssertTrue(apply.contains("showIdentifyCard = false"))
        XCTAssertTrue(apply.contains("addParsedList(outcome.items)"))
    }

    func testRowUsesAIProductImageNotUserPhoto() throws {
        let src = try addItemSource()
        // The list row always renders the AI image — the user photo is reserved for
        // the item detail screen.
        let row = try excerpt(src, from: "private struct LineItemRow", to: "private struct ThinkingPill")
        XCTAssertTrue(row.contains("ProductImageView(itemName: item.name, size: Self.imageSize)"))
        XCTAssertFalse(row.contains("UIImage(data:"),
                       "the row should not display the user-taken photo")
    }

    func testItemDetailShowsAIImageWithUserPhotoOverlay() throws {
        let src = try source("Grocer/Views/ItemDetailView.swift")
        let image = try excerpt(src, from: "private var itemImage: some View", to: "// MARK: - Quantity stepper")
        // AI image is the hero; the user photo only appears as a small overlay.
        XCTAssertTrue(image.contains("ProductImageView(itemName: item.name, size: 160)"))
        XCTAssertTrue(image.contains("item.photoData"))
        XCTAssertTrue(image.contains("ZStack(alignment: .bottomTrailing)"))
    }
}
