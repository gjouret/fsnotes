//
//  TableCaretRectTests.swift
//  FSNotesTests
//
//  Phase 11 Slice B fix #29 — caret painted at wrong visual position
//  when the cursor is inside a TableElement cell. TK2's default
//  caret-painter reads coordinates from the fragment's natural-flow
//  `textLineFragments`, which `TableLayoutFragment.draw` does not
//  honor (it paints cells at custom grid positions). The caret ends
//  up drawn at the top-left of the fragment — in the column-handle
//  strip area — instead of inside the cell the cursor's storage
//  offset addresses.
//
//  Fix: `TableLayoutFragment.caretRectInCell(row:col:cellLocalOffset:)`
//  + `EditTextView.caretRectIfInTableCell()` compute the visually
//  correct caret rect; `EditTextView.drawInsertionPoint` consumes
//  it and hands the right rect to super.
//
//  These tests exercise the pure helper directly. The pure layer
//  has no `NSWindow` requirement; building a `TableLayoutFragment`
//  via the same harness pattern as `TableCellHitTestTests` is
//  enough.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableCaretRectTests: XCTestCase {

    private static var holdersKey: UInt8 = 0

    /// Build a layout-manager + content-storage with one TableElement
    /// for the given markdown table; return the fragment so the test
    /// can call `caretRectInCell(...)` directly.
    private func makeTableFragment(
        markdown: String, containerWidth: CGFloat = 800
    ) -> (fragment: TableLayoutFragment, element: TableElement)? {
        let document = MarkdownParser.parse(markdown)
        guard !document.blocks.isEmpty,
              case .table = document.blocks[0]
        else { return nil }

        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let codeFont = NSFont.userFixedPitchFont(
            ofSize: NSFont.systemFontSize
        ) ?? bodyFont
        let projection = DocumentProjection(
            document: document,
            bodyFont: bodyFont, codeFont: codeFont
        )
        let textStorage = NSTextStorage(
            attributedString: projection.attributed
        )
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = textStorage
        let tlm = NSTextLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: containerWidth, height: 1e6)
        )
        tlm.textContainer = container
        contentStorage.addTextLayoutManager(tlm)
        let csDelegate = BlockModelContentStorageDelegate()
        contentStorage.delegate = csDelegate
        let lmDelegate = BlockModelLayoutManagerDelegate()
        tlm.delegate = lmDelegate
        tlm.ensureLayout(for: tlm.documentRange)

        var found: TableLayoutFragment?
        var foundElement: TableElement?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let tf = fragment as? TableLayoutFragment,
               let el = fragment.textElement as? TableElement {
                found = tf
                foundElement = el
                return false
            }
            return true
        }
        objc_setAssociatedObject(
            found ?? NSObject(),
            &TableCaretRectTests.holdersKey,
            (csDelegate, lmDelegate, contentStorage, tlm) as AnyObject,
            .OBJC_ASSOCIATION_RETAIN
        )
        guard let fragment = found, let element = foundElement else {
            return nil
        }
        return (fragment, element)
    }

    // MARK: - 1. Caret rect for empty header cell sits inside the cell

    /// Cell (0, 0) in a freshly inserted empty 3x3 table — the caret
    /// rect must be *inside* the visual cell bounds, NOT at the top-
    /// left corner of the fragment (which would land in the column-
    /// handle strip).
    func test_caretRect_emptyTopLeftCell_landsInsideCell() {
        let md = """
        |  |  |  |
        |---|---|---|
        |  |  |  |
        |  |  |  |
        """
        guard let (fragment, _) = makeTableFragment(markdown: md) else {
            XCTFail("could not build TableLayoutFragment")
            return
        }
        guard let g = fragment.geometryForHandleOverlay() else {
            XCTFail("geometry unavailable")
            return
        }
        guard let caret = fragment.caretRectInCell(
            row: 0, col: 0, cellLocalOffset: 0, caretWidth: 2
        ) else {
            XCTFail("caretRectInCell returned nil for (0, 0)")
            return
        }

        // Cell (0, 0) lives at:
        //   x ∈ [handleBarWidth, handleBarWidth + columnWidths[0])
        //   y ∈ [handleBarHeight, handleBarHeight + rowHeights[0])
        let cellMinX = TableGeometry.handleBarWidth
        let cellMaxX = cellMinX + g.columnWidths[0]
        let cellMinY = TableGeometry.handleBarHeight
        let cellMaxY = cellMinY + g.rowHeights[0]

        // Caret center must fall inside the cell.
        let cx = caret.midX
        let cy = caret.midY
        XCTAssertGreaterThanOrEqual(
            cx, cellMinX,
            "caret center.x \(cx) is left of cell minX \(cellMinX)"
        )
        XCTAssertLessThanOrEqual(
            cx, cellMaxX,
            "caret center.x \(cx) is right of cell maxX \(cellMaxX)"
        )
        XCTAssertGreaterThanOrEqual(
            cy, cellMinY,
            "caret center.y \(cy) is above cell minY \(cellMinY) " +
            "(this is the bug — caret would paint in the handle strip)"
        )
        XCTAssertLessThanOrEqual(
            cy, cellMaxY,
            "caret center.y \(cy) is below cell maxY \(cellMaxY)"
        )
    }

    // MARK: - 2. Caret rect for a body cell with text — at end of text

    /// Body cell (1, 0) holds "x". The caret at end-of-cell (offset =
    /// length of "x") must sit inside the cell horizontally past the
    /// rendered "x" glyph and vertically inside the cell's row band.
    func test_caretRect_endOfBodyCell_landsAfterText() {
        let md = """
        | A | B |
        |---|---|
        | x | y |
        """
        guard let (fragment, _) = makeTableFragment(markdown: md) else {
            XCTFail("could not build TableLayoutFragment")
            return
        }
        guard let g = fragment.geometryForHandleOverlay() else {
            XCTFail("geometry unavailable")
            return
        }
        guard let caret = fragment.caretRectInCell(
            row: 1, col: 0, cellLocalOffset: 1 /* end of "x" */,
            caretWidth: 2
        ) else {
            XCTFail("caretRectInCell returned nil for (1, 0)")
            return
        }

        let cellMinX = TableGeometry.handleBarWidth
        let cellMaxX = cellMinX + g.columnWidths[0]
        let rowMinY = TableGeometry.handleBarHeight + g.rowHeights[0]
        let rowMaxY = rowMinY + g.rowHeights[1]

        XCTAssertGreaterThan(
            caret.midX, cellMinX + TableGeometry.cellPaddingH(),
            "caret should sit AFTER the 'x' glyph, not at the cell's left edge"
        )
        XCTAssertLessThanOrEqual(
            caret.midX, cellMaxX,
            "caret center.x must remain inside cell"
        )
        XCTAssertGreaterThanOrEqual(
            caret.midY, rowMinY,
            "caret center.y above row min"
        )
        XCTAssertLessThanOrEqual(
            caret.midY, rowMaxY,
            "caret center.y below row max"
        )
    }

    // MARK: - 3. Caret rect bounds reject out-of-range cells

    func test_caretRect_outOfRange_returnsNil() {
        let md = """
        | A | B |
        |---|---|
        | x | y |
        """
        guard let (fragment, _) = makeTableFragment(markdown: md) else {
            XCTFail("could not build TableLayoutFragment")
            return
        }
        XCTAssertNil(fragment.caretRectInCell(row: -1, col: 0))
        XCTAssertNil(fragment.caretRectInCell(row: 0, col: -1))
        XCTAssertNil(fragment.caretRectInCell(row: 99, col: 0))
        XCTAssertNil(fragment.caretRectInCell(row: 0, col: 99))
    }

    // MARK: - 4. Editor-level: cursor at (0,0) yields a rect inside cell

    /// End-to-end: place the cursor at the start of a TableElement in
    /// a real (offscreen) editor and confirm
    /// `EditTextView.caretRectIfInTableCell()` returns a rect whose
    /// CENTER falls inside the visual top-left cell bounds when
    /// converted to text-container coordinates.
    func test_caretRectIfInTableCell_atTopLeftCell_landsInCell() {
        let md = """
        | H0 | H1 |
        |---|---|
        | c00 | c01 |
        """
        let h = EditorHarness(markdown: md)
        defer { h.teardown() }
        guard let tlm = h.editor.textLayoutManager else {
            XCTFail("no tlm"); return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Find the TableElement and park the cursor at cell (0, 0).
        var fragment: TableLayoutFragment?
        var element: TableElement?
        var elementStart = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            if let tf = f as? TableLayoutFragment,
               let el = f.textElement as? TableElement,
               let range = el.elementRange,
               let cs = tlm.textContentManager as? NSTextContentStorage {
                fragment = tf
                element = el
                elementStart = cs.offset(
                    from: cs.documentRange.location, to: range.location
                )
                return false
            }
            return true
        }
        guard let frag = fragment, let el = element else {
            XCTFail("no TableLayoutFragment"); return
        }
        guard let local = el.offset(forCellAt: (row: 0, col: 0)) else {
            XCTFail("no offset for (0, 0)"); return
        }
        h.editor.setSelectedRange(NSRange(location: elementStart + local, length: 0))

        guard let caret = h.editor.caretRectIfInTableCell() else {
            XCTFail(
                "caretRectIfInTableCell returned nil for cursor in (0, 0) — " +
                "this is the bug: without the override, drawInsertionPoint " +
                "uses TK2's natural-flow rect which lands above the cell"
            )
            return
        }

        // Compute expected cell bounds in text-container coords by
        // adding the fragment's origin to the local cell rect.
        guard let g = frag.geometryForHandleOverlay() else {
            XCTFail("geometry unavailable"); return
        }
        let frameOrigin = frag.layoutFragmentFrame.origin
        let cellMinX = frameOrigin.x + TableGeometry.handleBarWidth
        let cellMaxX = cellMinX + g.columnWidths[0]
        let cellMinY = frameOrigin.y + TableGeometry.handleBarHeight
        let cellMaxY = cellMinY + g.rowHeights[0]

        let cx = caret.midX
        let cy = caret.midY
        XCTAssertGreaterThanOrEqual(cx, cellMinX, "caret midX < cellMinX")
        XCTAssertLessThanOrEqual(cx, cellMaxX, "caret midX > cellMaxX")
        XCTAssertGreaterThanOrEqual(
            cy, cellMinY,
            "caret midY \(cy) above cell minY \(cellMinY) — would paint in handle strip"
        )
        XCTAssertLessThanOrEqual(
            cy, cellMaxY,
            "caret midY \(cy) below cell maxY \(cellMaxY)"
        )
    }
}
