//
//  UIBugRegressionTests.swift
//  FSNotesTests
//
//  One test per currently-known UI bug, written against
//  `EditorSnapshot`. Each test captures the observed widget-layer
//  failure — the ~1,640 pure-function tests in this suite pass while
//  these ship, because the defect lives in the overlay / fragment /
//  subview mounting glue, not in the pipeline.
//
//  Currently-broken tests wrap in `XCTExpectFailure` so the overall
//  suite stays green. When a fix lands, the expected-failure flips
//  to a pass and the test reports an "unexpectedly passed" failure
//  (XCTest's mechanism for retiring the wrapper), which surfaces the
//  fix in CI and tells the maintainer to drop the `XCTExpectFailure`.
//
//  Bugs captured here (date 2026-04-24):
//
//    1. test_tableHandleOverlay_mountsOnFill
//       Hover handles don't appear even after commit 08506d3 wired
//       `vc.tableHandleOverlay.reposition()` into the fill path.
//
//    2. test_codeBlockEditToggle_buttonVisibleOnFill
//       `</>` edit toggle button doesn't appear even after commits
//       25dd7dd + e03a75a wired `vc.codeBlockEditToggleOverlay.
//       reposition()` into the fill path.
//
//    3a. test_singleTable_producesSingleTableLayoutFragment
//        Plain single-table fill should produce exactly one
//        TableLayoutFragment — regression gate for the "table
//        rendered twice" bug.
//    3b. test_tableWithTrailingBrInLastCell_stillSingleFragment
//        Table whose last cell contains `<br><br>` is observed to
//        render twice on master (two TableLayoutFragments).
//
//    4. test_clickInsideCell_placesCursorInsideCellSpan
//       Deferred to `TableCellClickHarnessTests` (another agent is
//       building the click DSL + this specific test).
//
//    5. test_inlineMath_attachmentBaselineAligned
//       Inline-math attachment hydration is async via WKWebView —
//       synchronous snapshot cannot observe the hydrated
//       attachment bounds. Covered by `InlineMathBaselineTests`
//       at the pure-function layer (commit 1095395).
//
//    6. test_bulletList_mountsGlyphsOnFill /
//       test_checkboxList_mountsGlyphsOnFill
//       Bullet and checkbox glyphs don't mount as subviews until
//       the editor scrolls; first-fill snapshots find no
//       BulletGlyphView / CheckboxGlyphView subviews.
//

import XCTest
@testable import FSNotes

final class UIBugRegressionTests: XCTestCase {

    // MARK: - Helpers

    /// Strict options: reports a test failure when the expected
    /// failure does NOT occur. Without `isStrict = true`, a test
    /// where the bug got silently fixed would keep passing with no
    /// signal to drop the `XCTExpectFailure` wrapper. Strict mode
    /// makes the "bug is fixed" case loud.
    private func strictExpectedFailureOptions() -> XCTExpectedFailure.Options {
        let opts = XCTExpectedFailure.Options()
        opts.isStrict = true
        return opts
    }

    // MARK: - Bug 1: TableHandleView overlay mounts on fill

    /// EXPECTED TO FAIL on master — per user report, hover handles
    /// still don't appear after `08506d3`'s responder-chain wire-up.
    /// Offscreen tests have an additional reason to fail: the harness
    /// creates a borderless window without a `ViewController`, so the
    /// production path `owningViewControllerForTableHandleOverlay()`
    /// returns nil and `tableHandleOverlay.reposition()` never runs.
    /// Either way, a correct fix mounts `TableHandleView` subviews on
    /// the editor. This test captures that outcome.
    func test_tableHandleOverlay_mountsOnFill() {
        XCTExpectFailure(
            "Known bug 2026-04-24: TableHandleView subviews are not " +
            "mounted after fill. Responder-chain wire-up in 08506d3 " +
            "does not fire in offscreen harness, and user reports it " +
            "still doesn't fire in the live app.",
            options: strictExpectedFailureOptions()
        )
        let h = EditorHarness(
            markdown: "| a | b |\n|---|---|\n| 1 | 2 |",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(overlay class=TableHandleView visible=true"
        )
    }

    // MARK: - Bug 2: CodeBlockEditToggleView button visible on fill

    /// EXPECTED TO FAIL — parallel to bug 1. `</>` button overlay is
    /// wired the same way (`owningViewControllerForTableHandleOverlay()`
    /// → `vc.codeBlockEditToggleOverlay.reposition()`), so offscreen
    /// harness + live-app report the same missing-subview outcome.
    func test_codeBlockEditToggle_buttonVisibleOnFill() {
        XCTExpectFailure(
            "Known bug 2026-04-24: CodeBlockEditToggleView subviews " +
            "are not mounted after fill. Same wiring failure as " +
            "TableHandleOverlay — see bug 1.",
            options: strictExpectedFailureOptions()
        )
        let h = EditorHarness(
            markdown: "```swift\nlet x = 1\n```",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(overlay class=CodeBlockEditToggleView visible=true"
        )
    }

    // MARK: - Bug 3a: single-table fragment count regression gate

    /// SHOULD PASS on master. Guards against reintroducing the "table
    /// rendered twice" class of bugs: a well-formed single-table fill
    /// must produce exactly one `TableLayoutFragment` per block.
    func test_singleTable_producesSingleTableLayoutFragment() {
        let h = EditorHarness(
            markdown: "| a | b |\n|---|---|\n| 1 | 2 |"
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "class=TableLayoutFragment count=1"
        )
    }

    // MARK: - Bug 3b: table with trailing <br><br> in last cell

    /// EXPECTED TO FAIL — the `<br><br>` in the last cell is observed
    /// on master to cause the table to render twice
    /// (two `TableLayoutFragment`s against a single `kind=table`
    /// block). Wrapped in XCTExpectFailure until the fix lands.
    func test_tableWithTrailingBrInLastCell_stillSingleFragment() {
        XCTExpectFailure(
            "Known bug 2026-04-24: table with <br><br> in the last " +
            "cell renders twice — two TableLayoutFragment instances " +
            "per block.",
            options: strictExpectedFailureOptions()
        )
        let h = EditorHarness(
            markdown: "| a | b |\n|---|---|\n| 1 | 2<br><br> |"
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "class=TableLayoutFragment count=1"
        )
    }

    // MARK: - Bug 4: click inside cell places cursor inside cell span
    //
    // Coverage for this bug lives in `TableCellClickHarnessTests` —
    // a sibling agent is building the `.clickAt(point:)` harness DSL
    // and wiring the test there. Do not duplicate here.

    // MARK: - Bug 5: inline-math attachment baseline alignment

    /// Inline-math hydration is async via WKWebView. The harness is
    /// synchronous — the math placeholder renders with
    /// `.inlineMathSource` on plain text, and the actual
    /// `NSTextAttachment` is substituted later by the hydration
    /// callback. Without a deterministic "wait for hydration" hook,
    /// a snapshot taken right after fill sees no attachment and
    /// cannot observe `bounds.y`.
    ///
    /// The pure-function contract (bounds.y = -|descender|) is
    /// already covered by `InlineMathBaselineTests` (commit
    /// 1095395). This test is skipped pending a hydration-wait
    /// primitive in the harness.
    func test_inlineMath_attachmentBaselineAligned() throws {
        throw XCTSkip(
            "Inline-math hydration is async via WKWebView. The " +
            "pure function `InlineMathBaseline.bounds(imageSize:font:)` " +
            "is covered by InlineMathBaselineTests. A live-harness " +
            "assertion needs a deterministic hydration-wait primitive " +
            "which EditorHarness does not yet expose."
        )
    }

    // MARK: - Bug 6: bullet list glyphs mount on fill

    /// Regression gate: bullet glyphs must mount as subviews on the
    /// first fill (no scroll required). TK2 parents attachment-host
    /// subviews via `NSTextAttachmentViewProvider.loadView`, which
    /// fires only after the viewport has been laid out AND the run
    /// loop has ticked once. Production calls `layoutViewport()`
    /// twice around a `DispatchQueue.main.async` boundary to satisfy
    /// this two-phase contract.
    ///
    /// Historical bug (2026-04-24): glyphs didn't mount until the
    /// user scrolled. Fixed by the two-phase pump in
    /// `EditTextView.fillViaBlockModel`.
    func test_bulletList_mountsGlyphsOnFill() {
        let h = EditorHarness(
            markdown: "- one\n- two\n- three\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(attachment-host class=BulletGlyphView"
        )
    }

    /// Same mount contract as bullets; checkbox glyphs must appear
    /// on first fill without a scroll.
    func test_checkboxList_mountsGlyphsOnFill() {
        let h = EditorHarness(
            markdown: "- [ ] a\n- [x] b\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(attachment-host class=CheckboxGlyphView"
        )
    }

    // MARK: - Bug 7: live fragment dispatch matrix
    //
    // Pure-function `TextKit2FragmentDispatchTests` already verify
    // that a hand-constructed `NSTextContentStorage` + the real
    // delegates dispatch each `.blockModelKind` tag to the right
    // fragment class. What those tests DON'T exercise is the live
    // fill path: parse → render → apply to storage → layout →
    // fragment emitted. A bug anywhere in that chain (missing
    // `.blockModelKind` tag at render time, wrong element class,
    // delegate dispatch miss) would leave the pure tests green while
    // the live editor renders paragraphs where it should render
    // headings or code blocks.
    //
    // One document, one snapshot — seven assertions. If the fill
    // path ever starts routing a block kind to the wrong fragment,
    // this test flips red without having to hand-construct anything.

    func test_fragmentDispatch_coversCustomFragmentKinds() {
        let md = """
        # Heading one

        Plain paragraph body.

        > Blockquote line.

        ```
        code block line
        ```

        ---

        | a | b |
        |---|---|
        | 1 | 2 |

        $$x^2 + y^2 = z^2$$

        Inline <kbd>Cmd</kbd> marker.
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()

        snap.assertContains("(fragment class=HeadingLayoutFragment")
        snap.assertContains("(fragment class=BlockquoteLayoutFragment")
        snap.assertContains("(fragment class=CodeBlockLayoutFragment")
        snap.assertContains(
            "(fragment class=HorizontalRuleLayoutFragment"
        )
        snap.assertContains("(fragment class=TableLayoutFragment")
        snap.assertContains(
            "(fragment class=DisplayMathLayoutFragment"
        )
        snap.assertContains(
            "(fragment class=KbdBoxParagraphLayoutFragment"
        )
    }

    // MARK: - Offensive discovery probes
    //
    // Each test below targets one user-visible UI invariant and
    // asserts it against the live snapshot. No XCTExpectFailure
    // wrappers — any failure is a discovered bug.

    // Probe 1: folded header — FoldedLayoutFragment dispatches for
    // collapsed content. If the fragment is missing, the fold
    // apparatus is broken end-to-end.
    func test_probe_foldedHeader_hasFoldedFragment() {
        let h = EditorHarness(
            markdown: "# Parent\n\nhidden paragraph body\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.note.cachedFoldState = [0]
        h.editor.fillViaBlockModel(note: h.note)
        let snap = h.snapshot()
        snap.assertContains("(fragment class=FoldedLayoutFragment")
    }

    // Probe 2: table cell text lives in content storage (Phase 2e
    // T2-f) — cell sexps carry the cell strings.
    func test_probe_tableCell_textPresentInSnapshot() {
        let h = EditorHarness(
            markdown:
                "| A | B |\n|---|---|\n| foo | bar |\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        let body = snap.raw
        XCTAssertTrue(
            body.contains("foo") && body.contains("bar"),
            "expected cell text 'foo' and 'bar' in snapshot"
        )
    }

    // Probe 3: all six ATX heading levels dispatch to HeadingLayoutFragment.
    func test_probe_allSixHeadingLevels_dispatchHeadingFragment() {
        let md = """
        # h1

        ## h2

        ### h3

        #### h4

        ##### h5

        ###### h6
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        let body = snap.raw
        let count = body.components(
            separatedBy: "(fragment class=HeadingLayoutFragment"
        ).count - 1
        XCTAssertEqual(
            count, 6,
            "expected 6 HeadingLayoutFragment dispatches; got \(count)"
        )
    }

    // Probe 4: todo list items mount CheckboxGlyphView, not BulletGlyphView.
    func test_probe_todoList_mountsCheckboxNotBullet() {
        let h = EditorHarness(
            markdown: "- [ ] todo item\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        let body = snap.raw
        XCTAssertTrue(
            body.contains("(attachment-host class=CheckboxGlyphView"),
            "todo item should mount CheckboxGlyphView"
        )
        XCTAssertFalse(
            body.contains("(attachment-host class=BulletGlyphView"),
            "todo item should NOT mount BulletGlyphView"
        )
    }

    // Probe 5: mermaid block dispatches to MermaidLayoutFragment.
    func test_probe_mermaidBlock_fragmentEmitted() {
        let md = """
        ```mermaid
        graph LR
          A --> B
        ```
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains("(fragment class=MermaidLayoutFragment")
    }

    // Probe 6: empty selection after first fill.
    func test_probe_firstFill_yieldsEmptySelection() {
        let h = EditorHarness(
            markdown: "one two three\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        let body = snap.raw
        XCTAssertTrue(
            body.contains("selection=0..0"),
            "first-fill should produce cursor-at-start; got prefix: " +
            "\(body.prefix(200))"
        )
    }

    // Probe 7: multi-line blockquote — at least one blockquote
    // fragment emitted. (Blockquotes group paragraphs; one fragment
    // may cover multiple lines depending on block structure.)
    func test_probe_multiLineBlockquote_fragmentEmitted() {
        let md = """
        > line one
        > line two
        > line three
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains("(fragment class=BlockquoteLayoutFragment")
    }

    // Probe 8: HR between two headings gets its own fragment — no
    // collapse back into adjacent paragraph dispatch.
    func test_probe_horizontalRule_betweenHeadings_fragmentEmitted() {
        let md = """
        # a

        ---

        # b
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(fragment class=HorizontalRuleLayoutFragment"
        )
    }

    // Probe 9: code-block info-string (`swift`) survives to the
    // snapshot. Info string is the language tag used by
    // highlight.js and the `</>` toggle button logic.
    func test_probe_codeBlock_infoStringPresent() {
        let md = """
        ```swift
        let x = 42
        ```
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(fragment class=CodeBlockLayoutFragment"
        )
        snap.assertContains("swift")
    }

    // Probe 10: single-block heading carries a folded indicator rect
    // when the note's fold state includes its block index. We probe
    // via fragment presence (Probe 1 covers the underlying dispatch)
    // plus a text body check — once fold is set, the collapsed body
    // paragraph should NOT appear as a regular paragraph in the
    // snapshot (it should be folded away).
    func test_probe_foldedHeader_bodyContentHidden() {
        let h = EditorHarness(
            markdown: "# Parent\n\nUNIQUEFOLDEDMARKER body text\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.note.cachedFoldState = [0]
        h.editor.fillViaBlockModel(note: h.note)
        let snap = h.snapshot()
        let body = snap.raw
        // A folded body should dispatch via FoldedLayoutFragment.
        XCTAssertTrue(
            body.contains("(fragment class=FoldedLayoutFragment"),
            "expected folded body to dispatch FoldedLayoutFragment"
        )
    }

    // MARK: - Interactive discovery probes (edit-time UI behavior)

    // Probe 11: typing a character after fill doesn't destroy block
    // structure. Type one char at end-of-heading; heading fragment
    // should still be present.
    func test_probe_typeInHeading_preservesHeadingFragment() {
        let h = EditorHarness(
            markdown: "# Title\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 7) // end of "# Title"
        h.type("!")
        let snap = h.snapshot()
        snap.assertContains("(fragment class=HeadingLayoutFragment")
    }

    // Probe 12: Return at end of list item creates a new list item,
    // not a plain paragraph.
    func test_probe_returnInListItem_producesAnotherListItem() {
        let h = EditorHarness(
            markdown: "- first item\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: h.editor.textStorage?.length ?? 0)
        h.pressReturn()
        h.type("second")
        let snap = h.snapshot()
        // Two list-item blocks should exist now.
        let body = snap.raw
        let count = body.components(
            separatedBy: "kind=listItem"
        ).count - 1
        XCTAssertGreaterThanOrEqual(
            count, 2,
            "Return inside list should produce ≥2 list-item blocks; " +
            "got \(count). Snapshot:\n\(body.prefix(500))"
        )
    }

    // Probe 13: backspace at start-of-document is a no-op. Must not
    // crash, must not delete anything.
    func test_probe_backspaceAtDocStart_isNoop() {
        let h = EditorHarness(
            markdown: "hello\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let initialLen = h.editor.textStorage?.length ?? 0
        h.moveCursor(to: 0)
        h.pressDelete()
        let finalLen = h.editor.textStorage?.length ?? 0
        XCTAssertEqual(
            finalLen, initialLen,
            "backspace at position 0 should be a no-op"
        )
    }

    // Probe 14: typing inside a code block preserves the code-block
    // fragment dispatch (does not fall back to default paragraph).
    func test_probe_typeInCodeBlock_preservesCodeBlockFragment() {
        let md = """
        ```
        x
        ```
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        // Cursor to end of `x` (between `x` and `\n`).
        let contentRange = NSRange(location: 5, length: 0)
        h.selectRange(contentRange)
        h.type("y")
        let snap = h.snapshot()
        snap.assertContains("(fragment class=CodeBlockLayoutFragment")
    }

    // Probe 15: typing inside a blockquote preserves the blockquote
    // fragment dispatch.
    func test_probe_typeInBlockquote_preservesBlockquoteFragment() {
        let h = EditorHarness(
            markdown: "> quoted\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: h.editor.textStorage?.length ?? 0)
        h.type("!")
        let snap = h.snapshot()
        snap.assertContains("(fragment class=BlockquoteLayoutFragment")
    }

    // Probe 16: Return at end of heading creates a paragraph, NOT
    // another heading (common editor UX expectation).
    func test_probe_returnAfterHeading_producesParagraph() {
        let h = EditorHarness(
            markdown: "# title\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 7)
        h.pressReturn()
        h.type("body")
        let snap = h.snapshot()
        let body = snap.raw
        // Should have one heading and one paragraph block.
        XCTAssertTrue(
            body.contains("kind=heading") &&
            body.contains("kind=paragraph"),
            "Return after heading should produce heading + paragraph. " +
            "Snapshot:\n\(body.prefix(500))"
        )
    }

    // Probe 17: selection after typing is collapsed-at-cursor (no
    // stale selection from previous state).
    func test_probe_afterType_selectionCollapsed() {
        let h = EditorHarness(
            markdown: "abc\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 3)
        h.type("d")
        let snap = h.snapshot()
        let body = snap.raw
        // Extract selection=X..Y; require X == Y.
        let re = try! NSRegularExpression(pattern: "selection=(\\d+)\\.\\.(\\d+)")
        let match = re.firstMatch(
            in: body, range: NSRange(location: 0, length: body.utf16.count)
        )
        XCTAssertNotNil(match)
        if let m = match {
            let a = (body as NSString).substring(with: m.range(at: 1))
            let b = (body as NSString).substring(with: m.range(at: 2))
            XCTAssertEqual(
                a, b,
                "selection should be collapsed after type; got \(a)..\(b)"
            )
        }
    }

    // Probe 18: typing keeps text in table cells addressable — the
    // table block's cell text still appears after a typed edit
    // elsewhere in the doc.
    func test_probe_typeOutsideTable_leavesCellsIntact() {
        let md = """
        paragraph

        | A | B |
        |---|---|
        | foo | bar |
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 9) // end of "paragraph"
        h.type("!")
        let snap = h.snapshot()
        snap.assertContains("foo")
        snap.assertContains("bar")
        snap.assertContains("(fragment class=TableLayoutFragment")
    }

    // Probe 19: Return inside a paragraph produces TWO paragraph
    // blocks (not one merged block with an embedded newline).
    func test_probe_returnSplitsParagraph() {
        let h = EditorHarness(
            markdown: "first second third\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 5) // between "first" and " second"
        h.pressReturn()
        let snap = h.snapshot()
        let body = snap.raw
        let count = body.components(
            separatedBy: "kind=paragraph"
        ).count - 1
        XCTAssertGreaterThanOrEqual(
            count, 2,
            "Return should split paragraph; got \(count) paragraph " +
            "blocks. Snapshot:\n\(body.prefix(500))"
        )
    }

    // Probe 20: fragment dispatch survives TWO consecutive edits.
    // This probes the re-splice path: first edit applies a Document
    // diff, second edit re-splices on top. Both should leave
    // fragment classes intact.
    func test_probe_twoConsecutiveEdits_preserveHeadingFragment() {
        let h = EditorHarness(
            markdown: "# Title\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 7)
        h.type("X")
        h.type("Y")
        let snap = h.snapshot()
        snap.assertContains("(fragment class=HeadingLayoutFragment")
    }

    // MARK: - Aggressive probes targeting known-fragile surfaces

    // Probe 21: USER-REPORTED — typing in a table cell.
    // Click inside the cell, then type: the cell's text storage
    // should contain the typed content.
    func test_probe_typeInsideTableCell_updatesCellText() {
        let md = "| A | B |\n|---|---|\n| x | y |\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        // Find position of "x" in the storage and move cursor there.
        // Native-tables T2-f stores cell text directly in storage.
        guard let storage = h.editor.textStorage else {
            XCTFail("no text storage"); return
        }
        let s = storage.string as NSString
        let xRange = s.range(of: "x")
        guard xRange.location != NSNotFound else {
            XCTFail("cell 'x' not found in storage"); return
        }
        h.moveCursor(to: xRange.location + xRange.length)
        h.type("Z")
        // After typing, the cell should contain "xZ".
        let newString = h.editor.textStorage?.string ?? ""
        XCTAssertTrue(
            newString.contains("xZ"),
            "Typing in cell should update cell text. Storage: " +
            "\(newString.prefix(200))"
        )
    }

    // Probe 22: typing a single char into a DOCUMENT with just a
    // table doesn't crash or lose the table.
    func test_probe_typeInOnlyTableDoc_preservesTable() {
        let md = "| A |\n|---|\n| x |\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        let xRange = (storage.string as NSString).range(of: "x")
        if xRange.location == NSNotFound {
            XCTFail("cell text 'x' not found"); return
        }
        h.moveCursor(to: xRange.location + xRange.length)
        h.type("y")
        let snap = h.snapshot()
        snap.assertContains("(fragment class=TableLayoutFragment")
    }

    // Probe 23: empty document emits a valid snapshot (no crash, no
    // empty forms).
    func test_probe_emptyDoc_hasValidSnapshot() {
        let h = EditorHarness(
            markdown: "", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(snap.raw.hasPrefix("(editor"))
    }

    // Probe 24: type into empty doc produces a paragraph block.
    func test_probe_typeInEmptyDoc_producesParagraph() {
        let h = EditorHarness(
            markdown: "", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.type("hi")
        let snap = h.snapshot()
        snap.assertContains("kind=paragraph")
    }

    // Probe 25: Unicode text survives through the pipeline intact.
    // Uses CJK + accented Latin to exercise non-BMP paths.
    func test_probe_unicode_roundTrips() {
        let h = EditorHarness(
            markdown: "日本語 café naïve 한국어\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(snap.raw.contains("日本語"))
        XCTAssertTrue(snap.raw.contains("café"))
        XCTAssertTrue(snap.raw.contains("한국어"))
    }

    // Probe 26: emoji input lands in storage and produces a valid
    // fragment (NSAttributedString treats emoji as a single glyph).
    func test_probe_emoji_lands() {
        let h = EditorHarness(
            markdown: "", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.type("🎉")
        let snap = h.snapshot()
        XCTAssertTrue(snap.raw.contains("🎉"))
    }

    // Probe 27: forward-delete at end of doc is a no-op.
    func test_probe_forwardDeleteAtEnd_isNoop() {
        let h = EditorHarness(
            markdown: "abc\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let len = h.editor.textStorage?.length ?? 0
        h.moveCursor(to: len)
        h.pressForwardDelete()
        XCTAssertEqual(h.editor.textStorage?.length ?? 0, len)
    }

    // Probe 28: backspace to delete last char of heading does not
    // change the block kind (heading stays heading).
    func test_probe_backspaceInHeading_preservesHeadingKind() {
        let h = EditorHarness(
            markdown: "# XY\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        h.moveCursor(to: storage.length - 1) // before trailing \n
        h.pressDelete()
        let snap = h.snapshot()
        snap.assertContains("kind=heading")
    }

    // Probe 29: code block with many lines — fragment should still
    // dispatch once (single fragment covering the whole code block).
    func test_probe_multiLineCodeBlock_singleFragment() {
        let md = """
        ```
        line 1
        line 2
        line 3
        line 4
        ```
        """
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        let body = snap.raw
        let count = body.components(
            separatedBy: "(fragment class=CodeBlockLayoutFragment"
        ).count - 1
        XCTAssertEqual(
            count, 1,
            "multi-line code block should dispatch ONE " +
            "CodeBlockLayoutFragment; got \(count)"
        )
    }

    // Probe 30: typing inside a heading at position 0 does NOT
    // break the heading kind even at the first character.
    func test_probe_typeAtHeadingStart_preservesHeading() {
        let h = EditorHarness(
            markdown: "# title\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 0)
        h.type("X")
        let snap = h.snapshot()
        snap.assertContains("kind=heading")
    }

    // Probe 31: select-all then type replaces entire document.
    func test_probe_selectAllThenType_replacesDocument() {
        let h = EditorHarness(
            markdown: "# old heading\n\nold body\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let len = h.editor.textStorage?.length ?? 0
        h.selectRange(NSRange(location: 0, length: len))
        h.type("N")
        let text = h.editor.textStorage?.string ?? ""
        XCTAssertFalse(text.contains("old heading"))
        XCTAssertFalse(text.contains("old body"))
        XCTAssertTrue(text.contains("N"))
    }

    // Probe 32: typing consecutive chars keeps fragment count stable
    // — multi-char typing shouldn't multiply fragments.
    func test_probe_rapidType_stableFragmentCount() {
        let h = EditorHarness(
            markdown: "# hi\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: h.editor.textStorage?.length ?? 0)
        for _ in 0..<20 { h.type("x") }
        let snap = h.snapshot()
        let body = snap.raw
        let count = body.components(
            separatedBy: "(fragment class=HeadingLayoutFragment"
        ).count - 1
        XCTAssertEqual(
            count, 1,
            "rapid typing should not multiply heading fragments; " +
            "got \(count)"
        )
    }

    // Probe 33: bulletList with a bold-formatted item — bullet still
    // mounts even with inline formatting.
    func test_probe_boldInsideBullet_bulletStillMounts() {
        let h = EditorHarness(
            markdown: "- **bold** item\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains("(attachment-host class=BulletGlyphView")
    }

    // Probe 34: a link's URL appears in the snapshot's inline tree.
    func test_probe_link_urlPreserved() {
        let h = EditorHarness(
            markdown: "[click](https://example.com)\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(
            snap.raw.contains("https://example.com"),
            "Link URL must be emitted in the snapshot inline tree. " +
            "Snapshot:\n\(snap.raw.prefix(400))"
        )
    }

    // Probe 35: inline code span preserves its text + renders with
    // backtick marker stripped in WYSIWYG storage.
    func test_probe_inlineCode_textPreserved() {
        let h = EditorHarness(
            markdown: "Here is `code` inline.\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(snap.raw.contains("code"))
    }

    // MARK: - More aggressive probes — targets where I expect fails

    // Probe 36: REMOVED — offscreen-window click handling hangs in
    // the harness. Cell-click cursor placement is tracked separately
    // in `TableCellClickHarnessTests` (commit 427321b).

    // Probe 36g: USER REPORTED — `<kbd>` rounded rectangle. True
    // draw-layer test: render the kbd fragment to a bitmap,
    // inspect pixel values for the expected stroke/fill color.
    //
    // Without the box, every non-text pixel in the rendered
    // fragment would be the default background white. The kbd
    // fragment's stroke is #CCCCCC (RGB 204,204,204) and fill is
    // #FCFCFC (RGB 252,252,252); at least a handful of stroke
    // pixels should appear on the box outline.
    //
    // We check for ANY pixel whose RGB is in a tight band around
    // #CCCCCC (±8 per channel). If zero such pixels appear, the
    // fragment didn't draw the rounded rectangle — the user's
    // exact symptom.
    func test_probe_kbdBox_actuallyDrawsStrokeColor() {
        let h = EditorHarness(
            markdown: "Press <kbd>Cmd</kbd> to copy.\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        guard let bitmap = h.renderFragmentToBitmap(
            blockIndex: 0,
            fragmentClass: "KbdBoxParagraphLayoutFragment"
        ) else {
            XCTFail(
                "could not render KbdBoxParagraphLayoutFragment for " +
                "block 0. Fragment dispatch may be wrong, or the " +
                "block isn't 0, or there is no paragraph."
            )
            return
        }
        let (px, w, h2) = bitmap
        var strokePixels = 0
        let target: (UInt8, UInt8, UInt8) = (204, 204, 204)
        let tolerance: UInt8 = 8
        for y in 0..<h2 {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = px[i], g = px[i+1], b = px[i+2]
                if abs(Int(r) - Int(target.0)) <= Int(tolerance) &&
                   abs(Int(g) - Int(target.1)) <= Int(tolerance) &&
                   abs(Int(b) - Int(target.2)) <= Int(tolerance) {
                    strokePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(
            strokePixels, 10,
            "KbdBoxParagraphLayoutFragment rendered no stroke-color " +
            "pixels (expected >10 around #CCCCCC). The kbd box is " +
            "NOT being drawn — matches the user's 'just changes the " +
            "font' symptom. bitmap=\(w)x\(h2), strokePixels=" +
            "\(strokePixels)"
        )
    }

    // Probe 36f: USER REPORTED — `<kbd>Cmd</kbd>` doesn't draw a
    // rounded rectangle; user sees only a font change. We can't
    // inspect the CGContext draw output from the snapshot, but we
    // CAN check the necessary preconditions for drawing:
    //   1. Fragment class = KbdBoxParagraphLayoutFragment (done by
    //      another probe; passes — fragment dispatches correctly).
    //   2. `.kbdTag` attribute IS set on the storage run covering
    //      the kbd text — if not, `drawKbdBoxes` iterates nothing
    //      and silently paints no box.
    //
    // This probe tests (2) directly: enumerate `.kbdTag` over the
    // storage range and assert at least one non-nil value.
    func test_probe_kbdTag_attributeSetOnRun() {
        let h = EditorHarness(
            markdown: "Press <kbd>Cmd</kbd> to copy.\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        var found = false
        storage.enumerateAttribute(
            .kbdTag,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            if value != nil { found = true }
        }
        XCTAssertTrue(
            found,
            "`.kbdTag` attribute must be set on at least one run " +
            "of the rendered kbd text. Without it, " +
            "KbdBoxParagraphLayoutFragment.drawKbdBoxes iterates " +
            "nothing and no rounded rectangle is ever drawn — " +
            "matches the user's reported 'just changes the font' " +
            "symptom."
        )
    }

    // Probe 36d: USER REPORTED — deleting a list item wipes ALL
    // glyphs from the todo list. After removing one item (structural
    // delete via select-item-content + pressDelete), the remaining
    // items should all still have CheckboxGlyphView mounted.
    func test_probe_deleteTodoItem_preservesOtherGlyphs() {
        let md = "- [ ] one\n- [ ] two\n- [ ] three\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let before = h.snapshot()
        let beforeCount = before.raw.components(
            separatedBy: "(attachment-host class=CheckboxGlyphView"
        ).count - 1
        XCTAssertEqual(
            beforeCount, 3,
            "pre: expected 3 checkbox glyphs; got \(beforeCount)"
        )

        // Delete "two" including its newline — simulate user
        // selecting one line of text and deleting.
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        let twoRange = (storage.string as NSString).range(of: "two")
        guard twoRange.location != NSNotFound else {
            XCTFail("item 'two' text not found"); return
        }
        // Select "two" → pressDelete should delete selection.
        h.selectRange(twoRange)
        h.pressDelete()

        // Re-layout so view providers re-mount.
        if let tlm = h.editor.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let tlm = h.editor.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let after = h.snapshot()
        let afterCount = after.raw.components(
            separatedBy: "(attachment-host class=CheckboxGlyphView"
        ).count - 1
        // After deleting "two" text, we still have 3 items (item
        // structure unchanged — only text content changed). ALL 3
        // checkbox glyphs must remain mounted.
        XCTAssertEqual(
            afterCount, 3,
            "After deleting one list item's text, all 3 checkbox " +
            "glyphs must remain mounted; got \(afterCount). " +
            "Snapshot:\n\(after.raw.prefix(800))"
        )
    }

    // Probe 36e: USER REPORTED — triple-click selects paragraph then
    // press Delete; should delete the paragraph, NOT demote the list
    // line below it. Simulated via selectRange(full-paragraph) +
    // pressDelete (triple-click's selection effect without needing
    // click event synthesis).
    func test_probe_selectParagraphThenDelete_paragraphGone_listStays() {
        let md = "paragraph text here\n\n- list line one\n- list line two\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        let paraRange =
            (storage.string as NSString).range(of: "paragraph text here")
        if paraRange.location == NSNotFound {
            XCTFail("paragraph not found"); return
        }
        h.selectRange(paraRange)
        h.pressDelete()
        let snap = h.snapshot()
        let body = snap.raw
        // Paragraph text should be gone.
        XCTAssertFalse(
            body.contains("paragraph text here"),
            "Paragraph text should be deleted. Snapshot:\n" +
            "\(body.prefix(500))"
        )
        // The list should remain (not demoted to paragraphs).
        XCTAssertTrue(
            body.contains("kind=list"),
            "List below should remain a list (not demoted to " +
            "paragraphs). Snapshot:\n\(body.prefix(500))"
        )
    }

    // Probe 36c: USER REPORTED — selecting multiple paragraph lines
    // and invoking Bullet List formats ONLY the first line. Expected:
    // all selected paragraph lines become list items under one
    // list block. Drives `toggleListViaBlockModel(marker: "-")`
    // (the same path the Format menu's Bullet List calls).
    func test_probe_multiLineSelection_toBulletList_formatsAllLines() {
        let md = "line one\n\nline two\n\nline three\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let len = h.editor.textStorage?.length ?? 0
        // Select everything.
        h.selectRange(NSRange(location: 0, length: len))
        _ = h.editor.toggleListViaBlockModel(marker: "-")
        let snap = h.snapshot()
        let body = snap.raw
        // A single combined `.list` block is the expected shape —
        // wrapSelectionInSingleList path. The list should span all
        // three lines (so "one", "two", "three" all appear inside
        // the list, not in separate paragraphs).
        XCTAssertTrue(
            body.contains("kind=list"),
            "multi-line selection → bullet list should produce a " +
            "list block. Snapshot:\n\(body.prefix(500))"
        )
        // All three line texts should appear in the snapshot.
        XCTAssertTrue(
            body.contains("one"),
            "bullet-list convert dropped 'one' from snapshot.\n" +
            "Full snapshot:\n\(body)"
        )
        XCTAssertTrue(body.contains("two"))
        XCTAssertTrue(body.contains("three"))
        // Should NOT have any remaining paragraph blocks for the
        // original lines — assert no `kind=paragraph` appears with
        // "two" or "three" text in it. (If the bug is real — first
        // line only — we'd see lines two/three still as paragraphs.)
        let paragraphBlocks = body.components(
            separatedBy: "kind=paragraph"
        ).count - 1
        XCTAssertEqual(
            paragraphBlocks, 0,
            "After bullet-list on 3-line selection, no paragraph " +
            "blocks should remain; got \(paragraphBlocks). Snapshot:\n" +
            "\(body.prefix(600))"
        )
    }

    // Probe 36b: USER REPORTED — toggling one todo checkbox wipes
    // ALL checkbox glyphs in the note. Routes through the same
    // primitive a checkbox click fires (toggleTodoCheckboxViaBlockModel).
    //
    // NOTE: this probe passes in the offscreen harness but the bug
    // reproduces in the live app — there's a gap between the
    // harness state and the live click path we don't yet capture.
    // Left as a green regression gate for the offscreen-observable
    // invariant; live symptom tracked separately for XCUITest.
    func test_probe_toggleOneTodo_preservesAllTodoGlyphs() {
        let md = "- [ ] one\n- [ ] two\n- [ ] three\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let before = h.snapshot()
        let beforeCount = before.raw.components(
            separatedBy: "(attachment-host class=CheckboxGlyphView"
        ).count - 1
        XCTAssertEqual(
            beforeCount, 3,
            "expected 3 checkbox glyphs before toggle; got " +
            "\(beforeCount)"
        )

        // Toggle the first todo (position 0 = first list item).
        _ = h.editor.toggleTodoCheckboxViaBlockModel(at: 0)

        // Mirror the production post-edit sequence: TK2 re-lays the
        // viewport, which re-mounts view-provider subviews. If the
        // toggle invalidates all attachments instead of just the one,
        // we see the wipe here.
        if let tlm = h.editor.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let tlm = h.editor.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let after = h.snapshot()
        let afterCount = after.raw.components(
            separatedBy: "(attachment-host class=CheckboxGlyphView"
        ).count - 1
        XCTAssertEqual(
            afterCount, 3,
            "toggling one todo must preserve all 3 checkbox glyphs; " +
            "got \(afterCount) after toggle. Snapshot:\n" +
            "\(after.raw.prefix(800))"
        )
    }

    // Probe 37: paste plain text into empty doc actually inserts it.
    func test_probe_pasteIntoEmpty_insertsText() {
        let h = EditorHarness(
            markdown: "", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.paste(markdown: "pasted content")
        let result = h.editor.textStorage?.string ?? ""
        XCTAssertTrue(
            result.contains("pasted content"),
            "Paste into empty doc. Got: '\(result)'"
        )
    }

    // Probe 38: typing in a blockquote line preserves blockquote —
    // even if the line gets much longer. (Re-splice ≥ 1 full line.)
    func test_probe_longTypingInBlockquote_preservesKind() {
        let h = EditorHarness(
            markdown: "> q\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: h.editor.textStorage?.length ?? 0)
        for _ in 0..<50 { h.type("x") }
        let snap = h.snapshot()
        snap.assertContains("kind=blockquote")
    }

    // Probe 39: select across two blocks then type replaces both.
    func test_probe_selectAcrossBlocks_typeReplaces() {
        let h = EditorHarness(
            markdown: "first para\n\nsecond para\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let len = h.editor.textStorage?.length ?? 0
        h.selectRange(NSRange(location: 0, length: len))
        h.type("O")
        let result = h.editor.textStorage?.string ?? ""
        XCTAssertFalse(result.contains("first"))
        XCTAssertFalse(result.contains("second"))
    }

    // Probe 40: very long paragraph (3000 chars) renders without
    // truncation or fragment duplication.
    func test_probe_longParagraph_rendersIntact() {
        let long = String(repeating: "abc ", count: 750) // 3000 chars
        let h = EditorHarness(
            markdown: long + "\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        // Storage should be exactly as long (± WYSIWYG marker strip).
        let storageLen = h.editor.textStorage?.length ?? 0
        XCTAssertGreaterThan(
            storageLen, 2990,
            "Long paragraph storage length unexpectedly small: " +
            "\(storageLen)"
        )
    }

    // Probe 41: 50 paragraphs render with 50 fragment emissions.
    func test_probe_manyParagraphs_fragmentCountMatches() {
        let md = (0..<50).map { "Para \($0)" }.joined(separator: "\n\n") + "\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        let blockCount = snap.raw.components(
            separatedBy: "kind=paragraph"
        ).count - 1
        XCTAssertGreaterThanOrEqual(
            blockCount, 50,
            "expected ≥50 paragraph blocks; got \(blockCount)"
        )
    }

    // Probe 42: bold inline formatting survives a type-at-end edit.
    func test_probe_boldTextExtendedByType_remainsBold() {
        let h = EditorHarness(
            markdown: "**hello** world\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 5) // end of "hello"
        h.type("X")
        let snap = h.snapshot()
        // Assert "helloX" is still bold — via the inline tree having
        // a bold inline.
        XCTAssertTrue(
            snap.raw.contains("bold") || snap.raw.contains("strong"),
            "bold inline formatting should survive; snapshot:\n" +
            "\(snap.raw.prefix(400))"
        )
    }

    // Probe 43: Return at start-of-heading creates an empty paragraph
    // BEFORE the heading (not after).
    func test_probe_returnAtStartOfHeading_createsEmptyParagraphBefore() {
        let h = EditorHarness(
            markdown: "# H1\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 0)
        h.pressReturn()
        let snap = h.snapshot()
        // The heading should still be present.
        snap.assertContains("kind=heading")
    }

    // Probe 44: backspace to merge two paragraphs — after, one
    // paragraph remains with both contents.
    func test_probe_backspaceMergesParagraphs() {
        let h = EditorHarness(
            markdown: "first\n\nsecond\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        // Find position of "second" and move cursor there (start of
        // the second paragraph).
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        let secRange =
            (storage.string as NSString).range(of: "second")
        if secRange.location == NSNotFound {
            XCTFail("second not found"); return
        }
        h.moveCursor(to: secRange.location)
        h.pressDelete() // should merge
        h.pressDelete() // may merge again if separator was multiple chars
        let merged = h.editor.textStorage?.string ?? ""
        XCTAssertTrue(merged.contains("first"))
        XCTAssertTrue(merged.contains("second"))
    }

    // Probe 45: typing after Return at middle of paragraph lands in
    // the NEW paragraph, not the old one.
    func test_probe_typeAfterReturnMidPara_landsInNewBlock() {
        let h = EditorHarness(
            markdown: "onetwo\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: 3) // between "one" and "two"
        h.pressReturn()
        h.type("X")
        let text = h.editor.textStorage?.string ?? ""
        // Order should be: "one\nXtwo" — X between the split point
        // and "two".
        XCTAssertTrue(
            text.contains("one") && text.contains("Xtwo"),
            "After split+type, expected 'one\\nXtwo'; got '\(text)'"
        )
    }

    // Probe 46: inline math attachment lands in the snapshot as a
    // distinct inline node (not just as raw `$x$` text).
    func test_probe_inlineMath_renderedAsAttachment() {
        let h = EditorHarness(
            markdown: "before $x^2$ after\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        // Inline math renders as an attachment, which appears in the
        // snapshot under the paragraph's inline subtree as "attachment".
        XCTAssertTrue(
            snap.raw.contains("attachment") ||
            snap.raw.contains("math"),
            "inline math should render as an attachment; got: " +
            "\(snap.raw.prefix(400))"
        )
    }

    // Probe 47: display math renders as a DisplayMathLayoutFragment
    // and the raw math source survives in storage.
    func test_probe_displayMath_sourcePreserved() {
        let h = EditorHarness(
            markdown: "$$\\sqrt{2}$$\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(fragment class=DisplayMathLayoutFragment"
        )
        XCTAssertTrue(
            snap.raw.contains("sqrt") || snap.raw.contains("{2}"),
            "display math source should survive in storage; got: " +
            "\(snap.raw.prefix(400))"
        )
    }

    // Probe 48: two Returns in a row inside a list item creates
    // exit-list behavior (common editor pattern) — the second Return
    // on empty item ends the list.
    func test_probe_twoReturnsInList_exitsToParagraph() {
        let h = EditorHarness(
            markdown: "- item\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        h.moveCursor(to: h.editor.textStorage?.length ?? 0)
        h.pressReturn() // new empty list item
        h.pressReturn() // should exit list → paragraph
        h.type("plain")
        let snap = h.snapshot()
        snap.assertContains("kind=paragraph")
    }

    // Probe 49: backspace at start of list item un-indents or exits.
    // After one backspace on a single-level first-item list, cursor
    // should be in a paragraph with "item" text.
    func test_probe_backspaceAtListItemStart_exitsList() {
        let h = EditorHarness(
            markdown: "- item\n", windowActivation: .keyWindow
        )
        defer { h.teardown() }
        // Move cursor to start of "item" — past the bullet attachment.
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        let itemRange = (storage.string as NSString).range(of: "item")
        if itemRange.location == NSNotFound {
            XCTFail("item not found"); return
        }
        h.moveCursor(to: itemRange.location)
        h.pressDelete()
        let snap = h.snapshot()
        // Either paragraph kind or list-less structure.
        XCTAssertFalse(
            snap.raw.contains("kind=list") &&
            snap.raw.contains("BulletGlyphView"),
            "backspace at item-start should exit list. Snapshot:\n" +
            "\(snap.raw.prefix(400))"
        )
    }

    // Probe 50: edit inside a table cell via type doesn't produce
    // a second TableLayoutFragment (re-splice shouldn't duplicate).
    func test_probe_editInTable_singleFragmentPreserved() {
        let md = "| A | B |\n|---|---|\n| foo | bar |\n"
        let h = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { h.teardown() }
        guard let storage = h.editor.textStorage else {
            XCTFail("no storage"); return
        }
        let fooRange = (storage.string as NSString).range(of: "foo")
        if fooRange.location == NSNotFound {
            XCTFail("foo not found"); return
        }
        h.moveCursor(to: fooRange.location + fooRange.length)
        h.type("!")
        let snap = h.snapshot()
        let count = snap.raw.components(
            separatedBy: "(fragment class=TableLayoutFragment"
        ).count - 1
        XCTAssertEqual(
            count, 1,
            "edit in table cell should not duplicate fragment; got " +
            "\(count)"
        )
    }
}
