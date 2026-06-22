import XCTest

/// Guardrails for the Add Items flow wiring that's awkward to drive at runtime:
/// the title's (removed) glass background, the keyboard-dismiss tap on the
/// proposed area, and the camera → AI-identify path.
final class AddItemSourceGuardrailTests: XCTestCase {
    private func addItemSource() throws -> String {
        try source("Grocer/Views/AddItemView.swift")
    }

    func testTitleIsAScrollingGlassChipAndCloseButtonIsSticky() throws {
        let src = try addItemSource()

        // The title is a Liquid Glass capsule chip again.
        let title = try excerpt(src, from: "private var titleChip", to: "private var closeButton")
        XCTAssertTrue(title.contains("Text(\"Add Items\")"))
        XCTAssertTrue(title.contains("grocerLiquidGlass(in: Capsule())"),
                      "The Add Items title should have its liquid-glass chip back")

        // The title scrolls with the content (no pinned header bar)…
        let content = try excerpt(src, from: "private var addFlowContent", to: "private var scrollContent")
        XCTAssertTrue(content.contains("ScrollView {"))
        XCTAssertTrue(content.contains("titleChip"),
                      "The title should live inside the ScrollView so it scrolls")
        let searchView = try excerpt(src, from: "struct AddItemSearchView", to: "private struct DetectedItem")
        XCTAssertFalse(searchView.contains("private var header"),
                       "The Add Items flow should no longer define a pinned header bar")

        // …while only the close button is sticky (a top overlay over the content).
        let body = try excerpt(src, from: "var body: some View", to: "private var floatingControls")
        XCTAssertTrue(body.contains(".overlay(alignment: .top) {"))
        XCTAssertTrue(body.contains("closeButton"))
    }

    func testInlineMarkersStageItemsAsHighPriority() throws {
        let src = try addItemSource()
        // "!" or the words critical/important/high flag an item as urgent.
        XCTAssertTrue(src.contains("critical|important|high"))
        XCTAssertTrue(src.contains("func hasHighPriorityMarker"))

        // Markers are stripped before parsing, then priority is reattached.
        let parse = try excerpt(src, from: "private func runParse", to: "private func localSplit")
        XCTAssertTrue(parse.contains("highPriorityItemNames"))
        XCTAssertTrue(parse.contains("strippingPriorityMarkers"))
        XCTAssertTrue(parse.contains("isHighPriority"))

        // Priority rides the draft through to the saved item.
        XCTAssertTrue(src.contains("priority: draft.priority"))
        // The HIGH chip is shown on the proposed/draft row (normal shows nothing).
        let row = try excerpt(src, from: "private struct ParsedGroceryDraftRow", to: "/// Shimmer placeholder")
        XCTAssertTrue(row.contains("PriorityLabel(priority: draft.priority)"))
    }

    func testInlineMarkerTogglesCriticalBothWaysAndInstantly() throws {
        let src = try addItemSource()

        // Priority follows the text both ways: merge mirrors the detected item's
        // priority (escalate *and* downgrade), not an escalate-only guard — so
        // removing a "!" clears the CRITICAL flag instead of leaving it stuck.
        let merge = try excerpt(src, from: "private func merge(", to: "private func makeDraft")
        XCTAssertTrue(merge.contains("match.priority = item.priority"))
        XCTAssertFalse(merge.contains("if item.priority == .critical { match.priority = .critical }"),
                       "merge should no longer be escalate-only — removing a marker must clear critical")

        // The write-back re-emits the "!" for critical rows so a quantity edit (or
        // add-from-history/photo) doesn't strip the flag and reset it on re-parse.
        let sync = try excerpt(src, from: "private func syncTextFromDrafts", to: "private static let bullet")
        XCTAssertTrue(sync.contains("draft.priority == .critical ?"))
        XCTAssertTrue(sync.contains("(base)!"))

        // Marker changes apply instantly (locally) on each keystroke, not only via
        // the debounced network parse — adding/removing "!" flips the chip at once.
        XCTAssertTrue(src.contains("applyPriorityFromText()"))
        let apply = try excerpt(src, from: "private func applyPriorityFromText", to: "/// Re-projects detected items")
        XCTAssertTrue(apply.contains("isHighPriority(draft.name, among: urgentNames) ? .critical : .normal"))
    }

    func testCameraViewShowsCaptureHint() throws {
        let src = try source("Grocer/Views/CameraCaptureView.swift")
        // A hint at the top explains what's worth photographing — an item, a list…
        XCTAssertTrue(src.contains("makeHintContainer"))
        XCTAssertTrue(src.contains("written list"))
        // …pinned to the top safe area.
        let controls = try excerpt(src, from: "private func addControls", to: "private func makeShutterButton")
        XCTAssertTrue(controls.contains("hintContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor"))
    }

    func testProposedAreaTapDismissesKeyboard() throws {
        let src = try addItemSource()
        let panels = try excerpt(src, from: "private var panels: some View", to: "private var titleChip")
        XCTAssertTrue(panels.contains("proposedPanel"))
        XCTAssertTrue(panels.contains(".onTapGesture { dismissKeyboard() }"))
    }

    func testComposeFieldPreservesCaretWhenBulleting() throws {
        let src = try addItemSource()
        // The compose field is backed by a UITextView (not a plain TextField) so
        // re-bulleting the list as the user types doesn't reset the caret to the
        // end. Pressing return mid-list used to teleport the caret to the bottom
        // and, racing UIKit's newline insert, leave a stray trailing bullet.
        let compose = try excerpt(src, from: "private var composePanel: some View", to: "MARK: - Bottom pane")
        XCTAssertTrue(compose.contains("BulletListTextEditor(text: $inputText"),
                      "The compose field should use the caret-preserving editor")
        XCTAssertFalse(compose.contains("TextField("),
                       "The compose field should no longer be a plain TextField")

        // The editor re-applies the bullet formatting, then restores the caret to
        // the line being edited instead of leaving it at the end.
        let editor = try excerpt(src, from: "struct BulletListTextEditor", to: "MARK: Caret mapping")
        XCTAssertTrue(editor.contains("AddItemSearchView.bulletified(raw)"))
        XCTAssertTrue(editor.contains("caretLocation(movingFrom:"))
        XCTAssertTrue(editor.contains("textView.selectedRange = NSRange(location: caret"))
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
        let capture = try excerpt(src, from: "private func startPhotoCapture", to: "private func handleCapturedImage")
        XCTAssertTrue(capture.contains("CameraCaptureView.isAvailable"))
        XCTAssertTrue(capture.contains("showCamera = true"))
    }

    func testPhotoCaptureIdentifiesAndStagesDraftWithPhoto() throws {
        let src = try addItemSource()

        // Capture → vision identify.
        let capture = try excerpt(src, from: "private func handleCapturedImage", to: "private func applyIdentifyOutcome")
        XCTAssertTrue(capture.contains("resizedItemPhotoData()"))
        XCTAssertTrue(capture.contains("APIClient.shared.identifyItem(imageData:"))

        // Confirmed single item is staged as a draft carrying its photo, quantity,
        // and notes.
        let addFromPhoto = try excerpt(src, from: "private func addFromPhoto", to: "private func addParsedList")
        XCTAssertTrue(addFromPhoto.contains("photoData: photoData"))
        XCTAssertTrue(addFromPhoto.contains("notes: resolvedNotes"))

        // The photo and notes flow into the saved item on finalize.
        XCTAssertTrue(src.contains("photoData: draft.photoData"))
        XCTAssertTrue(src.contains("notes: draft.notes"))
    }

    func testListPhotoBypassesCardAndStagesEveryItem() throws {
        let src = try addItemSource()
        // A photographed list drops the per-item card and stages every detected item.
        let apply = try excerpt(src, from: "private func applyIdentifyOutcome", to: "private func commitIdentifiedItem")
        XCTAssertTrue(apply.contains("outcome.items.isEmpty"))
        XCTAssertTrue(apply.contains("showIdentifyCard = false"))
        XCTAssertTrue(apply.contains("addParsedList(outcome.items)"))
    }

    func testDraftRowUsesAIProductImageNotUserPhoto() throws {
        let src = try addItemSource()
        // The proposed/draft row always renders the AI image — the user photo is
        // reserved for the item detail screen.
        let row = try excerpt(src, from: "private struct ParsedGroceryDraftRow", to: "/// Shimmer placeholder")
        XCTAssertTrue(row.contains("ProductImageView(itemName: draft.name, size: 44)"))
        XCTAssertFalse(row.contains("UIImage(data: photoData)"),
                       "The draft row should not display the user-taken photo")
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
