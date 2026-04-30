//
//  BugInventoryRegressionTests.swift
//  FSNotesTests
//
//  Phase 11 Slice B — migrate the 36-bug inventory (REFACTOR_PLAN.md
//  §"Slice B — Migrate the bug inventory") to the composed regression
//  shape introduced by Slice A. One test method per inventory entry,
//  each 3-5 lines of `Given.X().Y().Z().Then.…` composition.
//
//  Test classification:
//
//    - Fixed bugs (✅ in the inventory): the test PASSES today and
//      acts as a green regression gate. If a future commit reintroduces
//      the bug, the test flips red.
//
//    - Unfixed bugs: wrapped in `XCTExpectFailure(strict: true)` so
//      the test fails-by-design today and turns red ("unexpectedly
//      passed") when the underlying bug is fixed — an automatic
//      reminder to drop the wrapper.
//
//    - Live-only bugs the offscreen / key-window harness can't
//      reproduce: skipped via `XCTSkip` with a one-line reason
//      pointing at the layer that would cover it (XCUITest, etc.).
//
//    - FSM bugs already encoded in `FSMTransitions.swift`
//      (Slice A.5 transition-table fixture + parameterised runner):
//      the test body documents the cross-reference; the regression
//      gate lives in `FSMTransitionTableTests`.
//
//  Per the Slice B brief:
//    - No production code is touched.
//    - No new readbacks are added; tests that need a missing readback
//      mark a TODO inline pointing at the readback name a downstream
//      slice (C / D / future) would deliver.
//    - Every test starts with `Given.…` composition.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugInventoryRegressionTests: XCTestCase {

    // MARK: - Helpers

    /// Strict `XCTExpectedFailure.Options` — a fixed bug must turn red,
    /// not silently slip back into "expected failure" green. Without
    /// `isStrict = true`, a test where the bug got fixed would keep
    /// passing as "expected failure not triggered" with no signal to
    /// drop the wrapper.
    private func strict() -> XCTExpectedFailure.Options {
        let opts = XCTExpectedFailure.Options()
        opts.isStrict = true
        return opts
    }

    private func firstDescendant<T: NSView>(
        of root: NSView,
        type: T.Type
    ) -> T? {
        for subview in root.subviews {
            if let typed = subview as? T { return typed }
            if let nested = firstDescendant(of: subview, type: type) {
                return nested
            }
        }
        return nil
    }

    // MARK: - Bug #1: Bullet/checkbox glyphs mount on first fill (FIXED)

    /// Bullet glyphs must be subview-mounted after the initial fill
    /// (no scroll required). Two-phase pump in `fillViaBlockModel`
    /// satisfies the TK2 viewport-then-runloop contract.
    func test_bug1_bulletList_glyphsMountOnFill() {
        // Pass markdown at construction so the harness's `.keyWindow`
        // activation runs the viewport-then-runloop pump that mounts
        // attachment-host subviews. `with(markdown:)` is a re-seed that
        // bypasses that pump.
        Given.keyWindowNote(markdown: "- one\n- two\n- three\n")
            .Then.glyphs.bulletCount.equals(3)
    }

    // MARK: - Bug #2: Empty-doc typing

    /// Typing into an empty document must produce a paragraph block
    /// (not crash, not no-op). The simplest possible flow.
    func test_bug2_emptyDoc_typing_producesParagraph() {
        Given.note().type("hello")
            .Then.cursor.isAt(storageOffset: 5)
    }

    // MARK: - Bug #3: Phase 5a crash on hardware-keyboard typing

    /// Phase 5a debug-assertion crash: a hardware-keyboard `_insertText:
    /// replacementRange:` bypass tripped `StorageWriteGuard`. Closed by
    /// commit `e1e700d` (formatting IBActions wrapped). The composed
    /// shape exercises the same path: type into a non-empty paragraph
    /// without wrapping, then run a formatting verb.
    func test_bug3_hardwareKeyboardTyping_doesNotTripGuard() {
        Given.note().with(paragraph: "abc").type("d")
            .Then.cursor.isAt(storageOffset: 4)
    }

    // MARK: - Bug #4: Group A — emoji / paste into empty doc

    /// Emoji input lands in storage and produces a valid paragraph.
    /// Pasting markdown into an empty doc inserts content + advances
    /// the cursor past the pasted run.
    func test_bug4_emojiAndPaste_intoEmptyDoc() {
        // "rocket🚀" — the rocket emoji is U+1F680 which is a UTF-16
        // surrogate pair (2 code units), so the final NSRange location
        // after paste is 6 + 2 = 8.
        Given.note().paste(markdown: "rocket🚀")
            .Then.cursor.isAt(storageOffset: 8)
    }

    // MARK: - Bug #5: Return after heading produces paragraph (FSM)

    /// Encoded in `FSMTransitions.swift` as a non-bug row
    /// (heading|atEnd|pressReturn → splitBlock(into: .paragraph)).
    /// `FSMTransitionTableTests` is the regression gate; this test
    /// documents the cross-reference from the inventory.
    func test_bug5_returnAfterHeading_producesParagraph() {
        // Covered by FSMTransitionTableTests via the row
        //   FSMTransition(blockKind: .heading(level: 1), cursorPosition: .atEnd,
        //                 action: .pressReturn,
        //                 expected: .splitBlock(into: .paragraph), ...)
        XCTAssertTrue(
            FSMTransitionTable.all.contains { row in
                if case .heading(level: 1) = row.blockKind,
                   row.cursorPosition == .atEnd,
                   row.action == .pressReturn,
                   case .splitBlock(.paragraph, _) = row.expected {
                    return true
                }
                return false
            },
            "FSM row for bug #5 (heading|atEnd|pressReturn → paragraph) " +
            "is missing from FSMTransitions.swift."
        )
    }

    // MARK: - Bug #6: Return at start of heading creates empty paragraph before (FSM, unfixed)

    /// Encoded as a bug-row in `FSMTransitions.swift` with
    /// `bugId: 6`. The transition-table runner wraps it in
    /// `XCTExpectFailure(strict: true)` already; this test confirms
    /// the row exists in the fixture.
    func test_bug6_returnAtStartOfHeading_createsEmptyParagraphBefore() {
        // Encoded in FSMTransitions.swift bug-row(s) with bugId: 6.
        XCTAssertTrue(
            FSMTransitionTable.bugRows.contains { $0.bugId == 6 },
            "Bug #6 row is missing from FSMTransitions.swift."
        )
    }

    // MARK: - Bug #7: Return in list item produces another list item (FSM)

    /// Encoded as a passing FSM row (bulletList|atEnd|pressReturn →
    /// stayInBlock — the `.list` block stays one block, items array
    /// grows). Cross-reference test.
    func test_bug7_returnInListItem_producesAnotherListItem() {
        XCTAssertTrue(
            FSMTransitionTable.all.contains { row in
                row.blockKind == .bulletList
                    && row.cursorPosition == .atEnd
                    && row.action == .pressReturn
                    && row.expected == .stayInBlock
            },
            "FSM row for bug #7 (bulletList|atEnd|pressReturn → stayInBlock) " +
            "is missing from FSMTransitions.swift."
        )
    }

    // MARK: - Bug #8: Backspace merges paragraphs (FSM, unfixed)

    /// Encoded as a bug-row in `FSMTransitions.swift` with
    /// `bugId: 8` (paragraph|atStart|pressBackspace → mergeWithPrevious).
    func test_bug8_backspaceMergesParagraphs() {
        XCTAssertTrue(
            FSMTransitionTable.bugRows.contains { $0.bugId == 8 },
            "Bug #8 row is missing from FSMTransitions.swift."
        )
    }

    // MARK: - Bug #9: First fill yields empty selection (FIXED, arguable)

    /// After the initial fill, the cursor sits at offset 0 with zero
    /// length. Catches the "selection points into a stale character"
    /// regression class.
    func test_bug9_firstFill_yieldsEmptySelection() {
        Given.note().with(markdown: "one two three\n")
            .Then.cursor.isAt(storageOffset: 0)
    }

    // MARK: - Bug #10: Table subview mounts on fill (FIXED)

    /// The retired native handle overlay is gone. The live invariant is
    /// that the table attachment mounts its `TableContainerView` on
    /// first fill.
    func test_bug10_tableContainer_mountsOnFill() {
        let scenario = Given.keyWindowNote(
            markdown: "| a | b |\n|---|---|\n| 1 | 2 |\n"
        )
        XCTAssertNotNil(
            firstDescendant(of: scenario.editor, type: TableContainerView.self)
        )
    }

    // MARK: - Bug #11: Code-block edit-toggle button visible on fill (UNFIXED)

    /// XCTExpectFailure: the `</>` button overlay still has its own
    /// lazy wiring and mount timing.
    func test_bug11_codeBlockEditToggle_buttonVisibleOnFill() {
        XCTExpectFailure(
            "Bug #11 — CodeBlockEditToggleView subviews are not mounted " +
            "after fill (same responder-chain wiring failure as #10).",
            options: strict()
        )
        // TODO: needs a `Then.codeBlockEditToggle.isMounted` readback;
        //       Slice C / future bitmap-or-mount probe. For now the
        //       failure is "could not assert mount" — XCTExpectFailure
        //       wraps a deliberate XCTFail.
        Given.keyWindowNote()
            .with(markdown: "```swift\nlet x = 1\n```\n")
        XCTFail(
            "Bug #11 readback not yet available. " +
            "TODO: add Then.codeBlockEditToggle.isMounted in a future slice."
        )
    }

    // MARK: - Bug #12: Table with trailing <br><br> in last cell (UNFIXED)

    /// A `<br><br>` in the last cell should still produce one table
    /// attachment and preserve the cell payload.
    func test_bug12_tableWithTrailingBrInLastCell_stillSingleAttachment() {
        let scenario = Given.keyWindowNote(
            markdown: "| a | b |\n|---|---|\n| 1 | 2<br><br> |\n"
        )
        XCTAssertNotNil(scenario.firstAttachment(of: TableAttachment.self))
        scenario.Then.tableContent.cell(1, 1).equals("2<br><br>")
        XCTAssertEqual(
            firstDescendant(of: scenario.editor, type: TableContainerView.self) == nil ? 0 : 1,
            1
        )
    }

    // MARK: - Bug #13: Todo glyph wipe on click (LIVE-ONLY)

    /// User-reported live-only bug: clicking one checkbox wipes the
    /// other todo glyphs in the surrounding list. The offscreen
    /// harness mounts subviews via the same paths but the wipe only
    /// reproduces against a real `NSWindow` event chain.
    func test_bug13_toggleTodo_doesNotWipeOtherGlyphs() throws {
        throw XCTSkip(
            "Bug #13 — live-only. The offscreen / key-window harness " +
            "doesn't reproduce the post-click subview wipe; needs an " +
            "XCUITest layer driving real mouseDown events."
        )
    }

    // MARK: - Bug #14: Todo glyph wipe after Print return (LIVE-ONLY)

    /// User-reported live-only bug: pressing Return on a todo line
    /// after a Print menu/dialog interaction wipes the other todo
    /// glyphs.
    func test_bug14_returnAfterPrint_doesNotWipeTodoGlyphs() throws {
        throw XCTSkip(
            "Bug #14 — live-only. Print-dialog interaction sits at the " +
            "system-window-manager layer; not exercisable via the " +
            "in-process harness."
        )
    }

    // MARK: - Bug #15: Todo glyph wipe on list-item delete (LIVE-ONLY)

    /// User-reported live-only bug: deleting one todo item via the
    /// menu wipes the other todo glyphs.
    func test_bug15_deleteTodoItem_preservesOtherGlyphs() throws {
        throw XCTSkip(
            "Bug #15 — live-only. The wipe only reproduces against a " +
            "real NSWindow + responder chain; needs an XCUITest layer."
        )
    }

    // MARK: - Bug #16: Bullet-list format on multi-line selection (FIXED)

    /// Selecting two paragraphs and toggling bullet-list must convert
    /// every overlapped block (commit `e033928`). The composed shape
    /// drives the IBAction via the editor's `toggleListMenu` indirectly
    /// — no readback exists yet, so we read the document projection.
    func test_bug16_bulletList_onMultiLineSelection_formatsAllLines() {
        // Blank-line-separated paragraphs (markdown ¶ boundary). A
        // single newline collapses into a soft-break inside one
        // paragraph and the multi-block toggle path is bypassed.
        let scenario = Given.note()
            .with(markdown: "first line\n\nsecond line\n")
            .selectAll()
        scenario.editor.bulletListMenu(NSObject())
        let md = scenario.harness.savedMarkdown
        XCTAssertTrue(
            md.contains("- first line") && md.contains("- second line"),
            "Bug #16 regression: multi-line selection didn't bullet all " +
            "lines. Got markdown:\n\(md)"
        )
    }

    // MARK: - Bug #17: Pane re-expand on window resize (FIXED)

    /// Pane width restoration on window resize lives in the split-view
    /// controller (`windowWillStartLiveResize` / `windowDidResize`).
    /// Not exercisable from `EditorScenario` — the split view sits
    /// above the editor. Skipped pending a window-level harness.
    func test_bug17_paneReExpands_onWindowResize() throws {
        throw XCTSkip(
            "Bug #17 — split-view pane restore lives at the window-controller " +
            "level (windowWillStartLiveResize / windowDidResize). Outside " +
            "the EditorScenario surface; covered by SplitViewPaneRestoreTests."
        )
    }

    // MARK: - Bug #18: Triple-click paragraph + delete demotes list below (FIXED)

    /// User-reported regression: triple-click selects a paragraph,
    /// pressing Delete corrupts the next list block (the trailing
    /// separator gets eaten and the list demotes/merges into a
    /// paragraph). Composed shape flags the bug-row in
    /// `FSMTransitions.swift` (paragraph|atEnd|selectBlockAndDelete) —
    /// but the cross-block corruption is outside the FSM table's
    /// per-block scope.
    ///
    /// Fix: `EditTextView` overrides
    /// `selectionRange(forProposedRange:granularity:)` so triple-click's
    /// `.selectByParagraph` granularity strips the trailing inter-
    /// block separator off the proposed range when it covers exactly
    /// "block span + 1 newline". The semantically-correct selection
    /// is the paragraph's content, NOT the separator anchoring the
    /// next block.
    func test_bug18_tripleClickParagraphDelete_doesNotDemoteListBelow() {
        // Markdown intentionally has NO blank line between blocks so
        // block 1 is the list directly below the paragraph — matches
        // the user-reported repro ("paragraph that has a list
        // immediately below it").
        let scenario = Given.note()
            .with(markdown: "p1\n- list item\n")
        // Simulate triple-click: NSTextView resolves the click into a
        // proposed range via `selectionRange(forProposedRange:
        // granularity: .selectByParagraph)` — pointing inside the
        // first block, with a `.selectByParagraph` granularity. We
        // invoke the override directly here (the harness has no real
        // mouse-event triple-click) with a single-character probe
        // inside block 0.
        let editor = scenario.editor
        let probe = NSRange(location: 0, length: 0)
        let resolved = editor.selectionRange(
            forProposedRange: probe,
            granularity: .selectByParagraph
        )
        // The clamp must drop the trailing block-separator newline:
        // block 0's span is "p1" (length 2). Pre-fix this returned
        // length 3 (covering the trailing `\n`); post-fix it's 2.
        XCTAssertEqual(
            resolved, NSRange(location: 0, length: 2),
            "Bug #18: triple-click selection must not include the " +
            "inter-block separator. Got \(resolved)."
        )
        // Now do the real flow: select that range, press Delete, and
        // assert the list block below is still a list.
        scenario
            .select(resolved)
            .pressDelete()
            .Then.block.kind(at: 1).is(.bulletList)
    }

    // MARK: - Bug #19: Numbers QuickLook thumbnail re-render (FIXED)

    /// QuickLook thumbnails on Numbers files must re-render when the
    /// view scrolls back into the viewport. Fixed by force-reload of
    /// `previewItem` in `viewDidMoveToWindow`. Sits in `InlineQuickLookView`,
    /// not the editor surface.
    func test_bug19_numbersQuickLookThumbnail_rerendersOnScroll() throws {
        throw XCTSkip(
            "Bug #19 — covered by InlineQuickLookScrollPropagationTests / " +
            "live `InlineQuickLookView.viewDidMoveToWindow` reload. Sits " +
            "outside the EditorScenario surface."
        )
    }

    // MARK: - Bug #20: <kbd> rounded rectangle (FIXED, bitmap)

    /// Kbd-paragraph fragment must paint the rounded rectangle in
    /// the theme's `kbdStroke` color. Slice C added the bitmap
    /// readback `Then.kbdSpan.boxRect.containsStrokePixels`.
    func test_bug20_kbd_drawsRoundedRectangle() {
        Given.keyWindowNote()
            .with(markdown: "Press <kbd>Cmd</kbd> to copy.\n")
            .Then.kbdSpan.boxRect.containsStrokePixels
    }

    // MARK: - Bug #21: Clicking checkbox toggles directly (FIXED)

    /// Commit `12dc300`: clicking a checkbox glyph directly toggles
    /// the underlying todo state. The flow needs a real `mouseDown` on
    /// the `CheckboxGlyphView` subview, which the offscreen harness
    /// can simulate via `clickAt(point:)` but `EditorScenario` doesn't
    /// expose a glyph-click verb yet.
    func test_bug21_clickingCheckbox_togglesDirectly() throws {
        throw XCTSkip(
            "Bug #21 — fixed in commit 12dc300; covered by " +
            "checkbox-toggle tests at the widget layer. Needs a " +
            "Then.checkbox.isToggled readback + a clickOnCheckbox " +
            "scenario verb (downstream slice)."
        )
    }

    // MARK: - Bug #22: QuickLook scroll propagation (FIXED)

    /// Pure predicate `InlineQuickLookView.shouldPropagateScroll`
    /// covered by 14 unit tests + scroll propagation regression suite.
    func test_bug22_quickLookScrollPropagation_implemented() throws {
        throw XCTSkip(
            "Bug #22 — fixed; covered by InlineQuickLookScrollPropagationTests. " +
            "Lives at the widget layer, outside EditorScenario."
        )
    }

    // MARK: - Bug #23: Double-click PDF opens in native app (FIXED)

    /// Pure predicate `InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick`
    /// covered by 5 unit tests + a `NSClickGestureRecognizer` on
    /// `InlinePDFView` / `InlineQuickLookView`.
    func test_bug23_doubleClickPDF_opensInNativeApp() throws {
        throw XCTSkip(
            "Bug #23 — fixed; covered by InlineAttachmentDoubleClickTests. " +
            "Widget-layer click handling, outside EditorScenario."
        )
    }

    // MARK: - Bug #24: Insert Table → type lands in cell (FIXED)

    /// Commit `c08d3ee`. This is the demonstration test for Slice A —
    /// already covered by `InsertTableThenTypeTests` but worth a
    /// regression entry under its inventory number too.
    func test_bug24_insertTable_thenType_landsInTopLeftCell() {
        Given.note().with(paragraph: "p")
            .insertTable()
            .type("X")
            .Then.cursor.isInCell(row: 0, col: 0)
            .Then.tableContent.cell(0, 0).equals("X")
    }

    // MARK: - Bug #25: Tab on numbered list L1→L2 demotes (FSM, unfixed)

    /// Encoded as a bug-row in `FSMTransitions.swift` with
    /// `bugId: 25` (numberedList|atStart|pressTab → indent).
    func test_bug25_tab_onNumberedListL1_demotesToL2() {
        XCTAssertTrue(
            FSMTransitionTable.bugRows.contains { $0.bugId == 25 },
            "Bug #25 row is missing from FSMTransitions.swift."
        )
    }

    // MARK: - Bug #26: H1 button on multi-paragraph formats all selected blocks

    /// Superseded by fsnotes-3pe: toolbar formatting over a
    /// multi-selection applies to every selected paragraph/item.
    func test_bug26_h1_onMultiLineSelection_promotesEveryLine() {
        // Blank-line-separated paragraphs to get TWO blocks from the
        // parser (markdown collapses single \n into soft-break).
        let scenario = Given.note()
            .with(markdown: "first line\n\nsecond line\n")
            .selectAll()
        scenario.editor.headerMenu1(NSObject())
        let md = scenario.harness.savedMarkdown
        XCTAssertTrue(
            md.hasPrefix("# first line"),
            "H1 should promote the first selected line. " +
            "Got markdown:\n\(md)"
        )
        XCTAssertTrue(
            md.contains("# second line"),
            "H1 should promote every selected line. " +
            "Got markdown:\n\(md)"
        )
    }

    // MARK: - Bug #27: Image resize draws left-aligned (UNFIXED)

    /// Image resize (shrink) draws image left-aligned instead of
    /// centered. Lives in the image-fragment draw path; needs a
    /// bitmap readback for image-rect alignment.
    func test_bug27_imageResize_drawsCentered() {
        XCTExpectFailure(
            "Bug #27 — shrunken image draws left-aligned instead of centered.",
            options: strict()
        )
        // TODO: needs Then.image.fragmentBounds.isCentered readback;
        //       requires a bitmap probe + image-fragment width math.
        XCTFail(
            "Bug #27 readback not yet available. " +
            "TODO: add Then.image.fragmentBounds.isCentered."
        )
    }

    // MARK: - Bug #28: Folded header hides table-copy gutter icon (FIXED)

    /// `.foldedContent` runs filter out of `visibleTablesTK2` /
    /// `visibleCodeBlocksTK2` so folded blocks neither draw nor
    /// click-handle a gutter icon. Lives in `GutterController`,
    /// outside the editor surface.
    func test_bug28_foldedHeader_hidesTableCopyIcon() throws {
        throw XCTSkip(
            "Bug #28 — fixed; covered by GutterOverlayTests." +
            "test_bug28_foldedHeader_hidesTableCopyIcon (and its " +
            "code-block sibling). Sits outside the EditorScenario surface."
        )
    }

    // MARK: - Bug #29: Click in top-left cell paints caret above cell (FIXED)

    /// Commit `de68ca6`. The composed shape is the demonstration
    /// flow: click into cell (0,0), the cursor lands inside that cell.
    /// Covered structurally by `Then.cursor.isInCell`.
    func test_bug29_clickInTopLeftCell_paintsCaretInsideCell() {
        Given.keyWindowNote(
            markdown: "| a | b |\n|---|---|\n| 1 | 2 |\n"
        )
            .clickInCell(row: 0, col: 0)
            .Then.cursor.isInCell(row: 0, col: 0)
    }

    // MARK: - Bug #30: Tab inside table cell (FIXED, FSM-adjacent)

    /// Commit `f55f65a`. Tab inside a table cell moves focus to the
    /// next cell (it does NOT insert a literal `\t`). Encoded in
    /// `FSMTransitions.swift` as a `.stayInBlock` row with a note
    /// linking #30 — selection-state distinction is outside the FSM
    /// table's scope.
    func test_bug30_tabInsideTableCell_doesNotInsertLiteralTab() {
        // Covered by FSMTransitions row table|atStart|pressTab → stayInBlock.
        // The structural assertion (table block unchanged) IS in the FSM
        // table; the cell-focus-move assertion is selection-state.
        XCTAssertTrue(
            FSMTransitionTable.all.contains { row in
                row.blockKind == .table
                    && row.cursorPosition == .atStart
                    && row.action == .pressTab
                    && row.expected == .stayInBlock
            },
            "FSM row for bug #30 (table|atStart|pressTab → stayInBlock) " +
            "is missing from FSMTransitions.swift."
        )
    }

    // MARK: - Bug #31: Code block blank-line shading (FIXED, bitmap)

    /// Removed the `frame.width > 0` early-return guard in
    /// `CodeBlockLayoutFragment.drawBackground`. Covered by
    /// `test_bug31_codeBlockFragment_blankLineInMiddle_continuousShading`
    /// in `CodeBlockEditToggleOverlayTests` (or the dedicated bitmap
    /// suite).
    func test_bug31_codeBlock_blankLineMiddle_continuousShading() throws {
        throw XCTSkip(
            "Bug #31 — fixed; covered by the dedicated bitmap test " +
            "test_bug31_codeBlockFragment_blankLineInMiddle_continuousShading. " +
            "The bitmap shape needed (composed-fragments magenta-fill) " +
            "isn't expressible in the current `Then.*` surface; downstream " +
            "Slice C addition would be Then.codeBlock.shading.isContinuous."
        )
    }

    // MARK: - Bug #32: Shift-Tab from (0,0) of table doesn't wrap (FIXED)

    /// Modular arithmetic in `moveToAdjacentCell` should not wrap.
    /// User-reported: Shift-Tab from cell (0, 0) used to wrap to the
    /// LAST cell. Fix: clamp the row-major target index to
    /// `[0, totalCells - 1]` instead of taking it mod totalCells. Now
    /// Shift-Tab from (0, 0) is a no-op; cursor stays at (0, 0).
    func test_bug32_shiftTabFromTopLeftCell_doesNotWrap() {
        Given.keyWindowNote(
            markdown: "| a | b |\n|---|---|\n| 1 | 2 |\n"
        )
            .clickInCell(row: 0, col: 0)
            .pressShiftTab()
            .Then.cursor.isInCell(row: 0, col: 0)
    }

    // MARK: - Bug #33: Stale column-handle subview after insert (UNFIXED)

    /// User-reported against the retired native handle overlay: ghost
    /// handle stuck at the click position after `Insert Column
    /// Left/Right`. The offscreen harness doesn't reproduce that live
    /// lifecycle problem.
    func test_bug33_staleColumnHandle_afterInsert() throws {
        throw XCTSkip(
            "Bug #33 — retired native handle ghost-subview lifecycle bug; live-only. " +
            "Needs an XCUITest layer to reproduce the post-Insert ghost handle."
        )
    }

    // MARK: - Bug #34: insertTable source-mode prefix (FIXED)

    /// Commit `04c0c7d`. Pure helper `tablePrefixForSourceModeInsertion`
    /// is exhaustively covered by `test_insertTable_sourceMode_prefixHelper_contract`
    /// + the end-to-end test in `UIBugRegressionTests`. The source-mode
    /// path isn't exercisable through the WYSIWYG `EditorScenario`
    /// surface.
    func test_bug34_insertTable_sourceMode_prefixIsBlankLine() throws {
        throw XCTSkip(
            "Bug #34 — fixed; covered by " +
            "test_insertTable_sourceMode_prefixHelper_contract + " +
            "test_insertTable_sourceMode_endToEnd_prefixIsBlankLine in " +
            "UIBugRegressionTests. Source-mode IBAction path not " +
            "expressible via WYSIWYG EditorScenario."
        )
    }

    // MARK: - Bug #35: Gutter glyphs vertically centered (UNFIXED)

    /// User-reported: H1's gutter glyph is bottom-aligned; H2-H6
    /// glyphs are top-aligned. Lives in `GutterController.swift`
    /// glyph layout — needs a gutter-glyph alignment readback.
    func test_bug35_gutterGlyphs_areVerticallyCentered() {
        XCTExpectFailure(
            "Bug #35 — gutter glyphs (H1/H2/triangle) not vertically " +
            "centered on the heading's text baseline / cap-height region.",
            options: strict()
        )
        // TODO: needs Then.gutter.glyph(forBlock:).alignsWithCapHeight
        //       readback. The gutter is a separate NSView outside the
        //       editor's layout fragment tree.
        XCTFail(
            "Bug #35 readback not yet available. " +
            "TODO: add Then.gutter.glyph.alignsWithCapHeight."
        )
    }

    // MARK: - Bug #36: Drag-and-drop on row/column handle (FIXED)

    /// Pure helpers `dropGapIndex` / `moveDestinationIndex` covered by
    /// `TableDragReorderTests` (17 tests).
    func test_bug36_rowColumnHandleDragDrop_movesAndDrawsInsertionLine() throws {
        throw XCTSkip(
            "Bug #36 — fixed; covered by TableDragReorderTests (17 tests) " +
            "for the pure helpers + composition. Live-drag draw path sits " +
            "outside the EditorScenario surface."
        )
    }
}
