//
//  Bug29ClickSelectionTests.swift
//  FSNotesTests
//
//  Diagnostic regression tests for Bug #29 (re-opened 2026-04-25):
//  "Click in top-left cell paints caret ABOVE the cell — and cursor
//  doesn't move inside cells."
//
//  The earlier hit-test tests in `TableCellHitTestTests.swift` exercise
//  `TableLayoutFragment.cellHit(at:)` against a free-standing fragment
//  built outside an EditTextView — they verify the pure
//  point→(row, col) function but do NOT exercise the
//  click → handleTableCellClick → setSelectedRange → drawInsertionPoint
//  pipeline as a single unit. CLAUDE.md rule 3 ("a passing test suite
//  with shipping bugs means the tests cover the wrong layer") applies.
//
//  These tests use `EditorHarness(windowActivation: .keyWindow)` so the
//  editor is first-responder in a key window and `mouseDown(with:)`
//  dispatches the way it does in the live app, then drive synthesised
//  click events through `harness.clickAt(point:)`.
//
//  Implementation note: each `EditorHarness(.keyWindow)` invocation
//  triggers AppKit / Storage initialisation that is heavy in this app
//  (the production note store at `~/iCloud~co~fluder~fsnotes/Documents/`
//  loads ~894 notes synchronously). To keep the suite fast and avoid
//  observed flakiness when many keyWindow harnesses are spun up in
//  sequence, the tests share a single keyWindow harness via a class-
//  level holder created lazily on first use and released at suite
//  teardown.
//

import XCTest
import AppKit
@testable import FSNotes

final class Bug29ClickSelectionTests: XCTestCase {

    // MARK: - Fixtures

    private static let markdown3x3 = """
    | A | B | C |
    | --- | --- | --- |
    | a0 | b0 | c0 |
    | a1 | b1 | c1 |
    """

    private struct LiveTableContext {
        let harness: EditorHarness
        let fragment: TableLayoutFragment
        let element: TableElement
        let elementStart: Int
        let geometry: TableGeometry.Result
    }

    /// Build a key-window harness seeded with `markdown` and resolve
    /// the fragment + element + geometry needed for click-point math.
    private func makeLiveTable(
        markdown: String = markdown3x3
    ) -> LiveTableContext? {
        let harness = EditorHarness(
            markdown: markdown, windowActivation: .keyWindow
        )
        guard let tlm = harness.editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage
        else {
            harness.teardown()
            return nil
        }
        tlm.ensureLayout(for: tlm.documentRange)

        var fragment: TableLayoutFragment?
        var element: TableElement?
        var elementStart = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            if let tf = f as? TableLayoutFragment,
               let el = f.textElement as? TableElement,
               let range = el.elementRange {
                fragment = tf
                element = el
                elementStart = cs.offset(
                    from: cs.documentRange.location, to: range.location
                )
                return false
            }
            return true
        }
        guard let f = fragment, let el = element,
              let g = f.geometryForHandleOverlay()
        else {
            harness.teardown()
            return nil
        }
        return LiveTableContext(
            harness: harness, fragment: f, element: el,
            elementStart: elementStart, geometry: g
        )
    }

    /// Convert a (fragment-local) point to the editor-view-local point.
    private func viewPoint(
        from fragLocal: CGPoint,
        in ctx: LiveTableContext
    ) -> NSPoint {
        let frameOrigin = ctx.fragment.layoutFragmentFrame.origin
        let containerOrigin = ctx.harness.editor.textContainerOrigin
        return NSPoint(
            x: fragLocal.x + frameOrigin.x + containerOrigin.x,
            y: fragLocal.y + frameOrigin.y + containerOrigin.y
        )
    }

    /// Center of cell (row, col) in fragment-local coords.
    private func cellCenter(
        row: Int, col: Int, in ctx: LiveTableContext
    ) -> CGPoint {
        var x = TableGeometry.handleBarWidth
        for i in 0..<col { x += ctx.geometry.columnWidths[i] }
        let w = ctx.geometry.columnWidths[col]
        var y = TableGeometry.handleBarHeight
        for i in 0..<row { y += ctx.geometry.rowHeights[i] }
        let h = ctx.geometry.rowHeights[row]
        return CGPoint(x: x + w / 2, y: y + h / 2)
    }

    // MARK: - Combined click-pipeline test
    //
    // Exercising click → setSelectedRange → typing → cell routing in
    // one shared harness, for several click points (centre of every
    // cell in the 3x3 grid + a click at the visual top of cell (0,0),
    // which is the user's reported failure point — "click in top-left
    // cell"). Combined to amortise the per-harness Storage init.
    func test_bug29_clickPipeline_routesAllCellsAndTopOfTopLeft()
        throws
    {
        guard let ctx = makeLiveTable() else {
            XCTFail("harness setup failed"); return
        }
        let h = ctx.harness
        defer { h.teardown() }

        guard case .table(let header, _, let rows, _) = ctx.element.block
        else { XCTFail("element block isn't .table"); return }
        let cols = header.count
        let totalRows = 1 + rows.count
        XCTAssertEqual(cols, 3)
        XCTAssertEqual(totalRows, 3)

        // Part A: click at the centre of every cell. Expect the
        // selection to land somewhere inside that cell's element-local
        // range.
        for r in 0..<totalRows {
            for c in 0..<cols {
                h.editor.setSelectedRange(NSRange(location: 0, length: 0))
                let local = cellCenter(row: r, col: c, in: ctx)
                let pt = viewPoint(from: local, in: ctx)
                _ = h.clickAt(point: pt)

                guard let cellRange = ctx.element.cellRange(
                    forCellAt: (row: r, col: c)
                ) else {
                    XCTFail("no cellRange for (\(r),\(c))"); continue
                }
                let cellStart = ctx.elementStart + cellRange.location
                let cellEnd = cellStart + cellRange.length
                let sel = h.editor.selectedRange()
                XCTAssertTrue(
                    sel.location >= cellStart && sel.location <= cellEnd,
                    "Click at center of (\(r),\(c)) → sel.location=\(sel.location), expected within [\(cellStart), \(cellEnd)]"
                )
            }
        }

        // Part B: the user-reported failure point — "click in top-left
        // cell paints caret ABOVE the cell". Click 2pt below the top of
        // the header row content area, at the horizontal centre of cell
        // (0, 0). If the bug is live (handle strip overlap into cell
        // visual area), this lands `selectedRange` either OUTSIDE the
        // table element (TK2's natural-flow fallback) or at offset 0 of
        // the table (TK2 mid-line fallback for an in-fragment point).
        let topOfCell00 = CGPoint(
            x: TableGeometry.handleBarWidth + ctx.geometry.columnWidths[0] / 2,
            y: TableGeometry.handleBarHeight + 2
        )
        let topPt = viewPoint(from: topOfCell00, in: ctx)
        h.editor.setSelectedRange(NSRange(location: 0, length: 0))
        _ = h.clickAt(point: topPt)
        guard let cell00 = ctx.element.cellRange(
            forCellAt: (row: 0, col: 0)
        ) else { XCTFail("no cellRange (0,0)"); return }
        let cell00Start = ctx.elementStart + cell00.location
        let cell00End = cell00Start + cell00.length
        let sel00 = h.editor.selectedRange()
        XCTAssertTrue(
            sel00.location >= cell00Start && sel00.location <= cell00End,
            "Click 2pt below handleBarHeight at (0,0) → sel=\(sel00), expected [\(cell00Start),\(cell00End)]"
        )

        // Part C: caret-rect override is non-nil after the in-cell
        // click (verifies the storage offset agrees with
        // `cellAtCursor(forOffset:)`).
        XCTAssertNotNil(
            h.editor.caretRectIfInTableCell(),
            "caretRectIfInTableCell must return non-nil after click in (0,0)"
        )
    }

    // MARK: - Tab navigation populates each cell in turn
    //
    // Decoupled from the click pipeline — uses `setSelectedRange`
    // directly, then `doCommand(by:insertTab:)`. This is the
    // diagnostic for Hypothesis 2E (Tab nav broken inside cells).
    func test_bug29_tabFromTopLeft_typesIntoEachCellInOrder() throws {
        let emptyMd = """
        |  |  |  |
        | --- | --- | --- |
        |  |  |  |
        |  |  |  |
        """
        guard let ctx = makeLiveTable(markdown: emptyMd) else {
            XCTFail("harness setup failed"); return
        }
        let h = ctx.harness
        defer { h.teardown() }

        let start00 = ctx.elementStart + (
            ctx.element.offset(forCellAt: (row: 0, col: 0)) ?? 0
        )
        h.editor.setSelectedRange(NSRange(location: start00, length: 0))

        let chars = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
        for (idx, ch) in chars.enumerated() {
            h.type(ch)
            if idx < chars.count - 1 {
                h.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            }
        }

        let parsed = MarkdownParser.parse(h.savedMarkdown)
        guard let table = parsed.blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            XCTFail("no table in saved markdown:\n\(h.savedMarkdown)"); return
        }
        guard case .table(let header, _, let rows, _) = table
        else { XCTFail("not a table"); return }

        XCTAssertEqual(
            header.map { $0.rawText }, ["a", "b", "c"],
            "header row mismatch — Tab nav across header failed"
        )
        if rows.count > 0 {
            XCTAssertEqual(
                rows[0].map { $0.rawText }, ["d", "e", "f"],
                "body row 0 mismatch — Tab nav across row boundary failed"
            )
        }
        if rows.count > 1 {
            XCTAssertEqual(
                rows[1].map { $0.rawText }, ["g", "h", "i"],
                "body row 1 mismatch — Tab nav across rows failed"
            )
        }
    }

    // MARK: - Narrow regressions for Fix 2 (trailing-edge separator park)
    //
    // Fix 2 changed `tableCursorContextForOffset` to call the
    // cursor-aware `cellAtCursor(forOffset:)` instead of the strict
    // `cellLocation(forOffset:)`. The bug it closes is:
    //
    //  - empty 3×3 table; Tab from header → ... → last cell (2,2);
    //    the caret parks at offset == element_end - 1 (the trailing
    //    separator just before the element terminator);
    //  - the strict locator returns nil for that offset (it's on a
    //    separator), so `tableCursorContextForOffset` returns nil;
    //  - `handleEditViaBlockModel` therefore falls through the
    //    table-cell path and types the character into post-table
    //    storage, which TK2 routes to the natural-flow paragraph
    //    AFTER the table.
    //
    // The next two tests exercise the same boundary via the two
    // entry routes (Tab nav and click) using a minimal 3×3 fixture.

    /// Tab from (0,0) all the way to the last cell (2,2), then type
    /// one character. The character must be serialized into cell
    /// (body row 1, col 2) — NOT into a paragraph after the table.
    func test_bug29_typeIntoLastEmptyCellAfterTab_routesIntoTable()
        throws
    {
        let emptyMd = """
        |  |  |  |
        | --- | --- | --- |
        |  |  |  |
        |  |  |  |
        """
        guard let ctx = makeLiveTable(markdown: emptyMd) else {
            XCTFail("harness setup failed"); return
        }
        let h = ctx.harness
        defer { h.teardown() }

        let start00 = ctx.elementStart + (
            ctx.element.offset(forCellAt: (row: 0, col: 0)) ?? 0
        )
        h.editor.setSelectedRange(NSRange(location: start00, length: 0))

        // Tab 8 times to reach (2, 2) from (0, 0) without typing in
        // intermediate cells.
        for _ in 0..<8 {
            h.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        }
        h.type("X")

        let parsed = MarkdownParser.parse(h.savedMarkdown)
        guard let table = parsed.blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            XCTFail(
                "no table in saved markdown:\n\(h.savedMarkdown)"
            ); return
        }
        guard case .table(_, _, let rows, _) = table
        else { XCTFail("not a table"); return }

        XCTAssertGreaterThanOrEqual(rows.count, 2)
        if rows.count >= 2 {
            XCTAssertEqual(
                rows[1][2].rawText, "X",
                "typed 'X' did not land in last cell (2,2). Saved markdown:\n\(h.savedMarkdown)"
            )
        }
        // Defensive: only one block in the parsed output and it must
        // be the table. If the type leaked outside the table it would
        // appear as a sibling paragraph block.
        XCTAssertEqual(
            parsed.blocks.count, 1,
            "expected exactly 1 block (the table); got \(parsed.blocks.count). Saved markdown:\n\(h.savedMarkdown)"
        )
    }

    /// Click at the centre of the last cell of an empty 3×3 table,
    /// then type one character. The character must be serialized
    /// into (body row 1, col 2) — NOT into a paragraph after the
    /// table. This exercises the click-route variant of Fix 2: the
    /// click parks the caret at the cell's trailing-edge separator
    /// (since the cell is empty, end == start of the next separator)
    /// and the next type must resolve through `cellAtCursor`.
    func test_bug29_clickThenTypeIntoLastEmptyCell_routesIntoTable()
        throws
    {
        let emptyMd = """
        |  |  |  |
        | --- | --- | --- |
        |  |  |  |
        |  |  |  |
        """
        guard let ctx = makeLiveTable(markdown: emptyMd) else {
            XCTFail("harness setup failed"); return
        }
        let h = ctx.harness
        defer { h.teardown() }

        // Click the centre of the last cell (2, 2). With Fix 2 this
        // parks the caret at the cell's trailing edge.
        let local = cellCenter(row: 2, col: 2, in: ctx)
        let pt = viewPoint(from: local, in: ctx)
        _ = h.clickAt(point: pt)
        h.type("Z")

        let parsed = MarkdownParser.parse(h.savedMarkdown)
        guard let table = parsed.blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            XCTFail(
                "no table in saved markdown:\n\(h.savedMarkdown)"
            ); return
        }
        guard case .table(_, _, let rows, _) = table
        else { XCTFail("not a table"); return }

        XCTAssertGreaterThanOrEqual(rows.count, 2)
        if rows.count >= 2 {
            XCTAssertEqual(
                rows[1][2].rawText, "Z",
                "click+type at last cell (2,2) did not land in cell. Saved markdown:\n\(h.savedMarkdown)"
            )
        }
        XCTAssertEqual(
            parsed.blocks.count, 1,
            "expected exactly 1 block (the table); got \(parsed.blocks.count). Saved markdown:\n\(h.savedMarkdown)"
        )
    }

    /// Tab from the last cell of a 3×3 table must NOT insert a literal
    /// `\t` into the cell. The nav handler clamps `targetIdx` so the
    /// cursor stays in (last row, last col) by design (bug #32 — no
    /// modular wrap), but the keystroke still has to be consumed
    /// (`handleTableNavCommand` returns true) — otherwise the default
    /// `insertTab:` action falls through and inserts a tab character
    /// into the cell content.
    ///
    /// User report (post-deploy of `a07d931`): "tab inserts a tab
    /// spacing in cell 2,2".
    func test_bug29_tabAtLastCell_isConsumedNotInsertedAsTab() throws {
        let emptyMd = """
        |  |  |  |
        | --- | --- | --- |
        |  |  |  |
        |  |  |  |
        """
        guard let ctx = makeLiveTable(markdown: emptyMd) else {
            XCTFail("harness setup failed"); return
        }
        let h = ctx.harness
        defer { h.teardown() }

        // Park the caret at the start of cell (2, 2) (= end of element
        // for an empty 3×3) and type "X" so the cell is non-empty —
        // this matches the user's flow (they typed before pressing
        // Tab).
        guard let cell22Start = ctx.element.offset(
            forCellAt: (row: 2, col: 2)
        ) else { XCTFail("no cell22 offset"); return }
        h.editor.setSelectedRange(NSRange(
            location: ctx.elementStart + cell22Start, length: 0
        ))
        h.type("X")

        // Press Tab. Must be consumed.
        h.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        // Cell (2, 2) content must be exactly "X" — no `\t`, no extra
        // characters. If Tab fell through to `insertTab:`, the cell
        // would contain "X\t".
        let parsed = MarkdownParser.parse(h.savedMarkdown)
        guard let table = parsed.blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        }) else { XCTFail("no table block"); return }
        guard case .table(_, _, let rows, _) = table
        else { XCTFail("not a table"); return }
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertEqual(
            rows[1][2].rawText, "X",
            "Tab from last cell inserted a literal '\\t'. Cell content:\n\(rows[1][2].rawText.debugDescription). Saved markdown:\n\(h.savedMarkdown)"
        )
        XCTAssertEqual(
            parsed.blocks.count, 1,
            "expected exactly 1 block (the table); got \(parsed.blocks.count). Saved markdown:\n\(h.savedMarkdown)"
        )
    }


    /// Enter inside a cell with content must insert a hard line break
    /// (`<br>` per the Phase 2e-T2-e contract). It must NOT be silently
    /// consumed (cursor stays put, no break inserted) and it must NOT
    /// fall through to the default newline path (which would corrupt
    /// the separator-encoded TableElement by inserting a real `\n`).
    ///
    /// User report (post-deploy of `a07d931`): "Enter is just consumed
    /// — doing nothing".
    func test_bug29_enterInCell_insertsLineBreak() throws {
        let emptyMd = """
        |  |  |  |
        | --- | --- | --- |
        |  |  |  |
        |  |  |  |
        """
        guard let ctx = makeLiveTable(markdown: emptyMd) else {
            XCTFail("harness setup failed"); return
        }
        let h = ctx.harness
        defer { h.teardown() }

        // Park caret in cell (1, 1), type "ab", press Enter, type "cd".
        // The cell content must serialize as "ab<br>cd".
        guard let cell11Start = ctx.element.offset(
            forCellAt: (row: 1, col: 1)
        ) else { XCTFail("no cell11 offset"); return }
        h.editor.setSelectedRange(NSRange(
            location: ctx.elementStart + cell11Start, length: 0
        ))
        h.type("ab")
        h.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        h.type("cd")

        let parsed = MarkdownParser.parse(h.savedMarkdown)
        guard let table = parsed.blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        }) else { XCTFail("no table block"); return }
        guard case .table(_, _, let rows, _) = table
        else { XCTFail("not a table"); return }
        XCTAssertGreaterThanOrEqual(rows.count, 1)
        // Cell (1, 1) is body row 0, col 1.
        let actual = rows[0][1].rawText
        XCTAssertTrue(
            actual.contains("<br>") || actual.contains("\\\n"),
            "Enter in cell did not insert a hard line break. Cell content: \(actual.debugDescription). Saved markdown:\n\(h.savedMarkdown)"
        )
        XCTAssertTrue(
            actual.contains("ab"),
            "Pre-Enter text 'ab' missing from cell. Cell content: \(actual.debugDescription)"
        )
        XCTAssertTrue(
            actual.contains("cd"),
            "Post-Enter text 'cd' missing from cell — the keystroke after Enter went somewhere else. Cell content: \(actual.debugDescription)"
        )
        XCTAssertEqual(
            parsed.blocks.count, 1,
            "expected exactly 1 block (the table); got \(parsed.blocks.count). Saved markdown:\n\(h.savedMarkdown)"
        )
    }
}
