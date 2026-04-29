//
//  BugFsnotes1mlTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-1ml (P1):
//  "Table cell: typed text appears LEFT of cursor (1-2 char offset)"
//
//  Verifiable property: after typing N characters at the start of an
//  empty cell, the caret rect for cellLocalOffset == N must sit at
//  (or within < 1pt of) the right edge of the rendered run. The bug
//  reports a 1–2 char-width gap, so a 1pt tolerance is conservative.
//
//  Layer: coord-space (per DEBUG.md §1 layer table). Queries
//  TableLayoutFragment.caretRectInCell directly and compares against
//  NSAttributedString.size of the rendered character — no pixel
//  sampling, no screenshot.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes1mlTests: XCTestCase {

    /// 2x2 table with cell (1, 0) seeded with "Xab" so that
    /// `caretRectInCell(cellLocalOffset:)` is exercised at three
    /// distinct rendered positions (after each char). An empty cell
    /// would cause every offset to fall back to the same caret rect.
    private static let markdown = """
    | A | B |
    | --- | --- |
    | Xab | y |
    | z |  |
    """

    private struct LiveTableContext {
        let harness: EditorHarness
        let fragment: TableLayoutFragment
        let element: TableElement
    }

    private func makeLiveTable() -> LiveTableContext? {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        guard let tlm = harness.editor.textLayoutManager else {
            harness.teardown()
            return nil
        }
        tlm.ensureLayout(for: tlm.documentRange)

        var fragment: TableLayoutFragment?
        var element: TableElement?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            if let tf = f as? TableLayoutFragment,
               let el = f.textElement as? TableElement {
                fragment = tf
                element = el
                return false
            }
            return true
        }
        guard let f = fragment, let el = element else {
            harness.teardown()
            return nil
        }
        return LiveTableContext(harness: harness, fragment: f, element: el)
    }

    func test_caretRect_followsTypedCharacters_inDataCell() {
        guard let ctx = makeLiveTable() else {
            XCTFail("table fragment not laid out")
            return
        }
        defer { ctx.harness.teardown() }

        // Verifiable property: cell (1, 0) is seeded with "Xab" — three
        // distinct cellLocalOffsets (0, 1, 2, 3) must produce caret
        // rects whose pairwise differences match the rendered widths
        // of "X", "a", "b" respectively. If the bug is live, advances
        // will be too large (caret over-shoots glyphs by 1-2 char
        // widths) or zero (caret never advances).
        let offsets = (0...3).map { off -> CGRect in
            ctx.fragment.caretRectInCell(
                row: 1, col: 0, cellLocalOffset: off
            ) ?? .zero
        }
        let advances = zip(offsets.dropFirst(), offsets.dropLast())
            .map { $0.minX - $1.minX }

        // Build the same-attributes string the fragment would render
        // (data row, default (left) alignment, body font).
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let chars = ["X", "a", "b"]
        let expectedAdvances = chars.map { ch -> CGFloat in
            NSAttributedString(string: ch, attributes: [.font: baseFont])
                .size().width
        }

        let tolerance: CGFloat = 1.0
        for (i, ch) in chars.enumerated() {
            XCTAssertEqual(
                advances[i], expectedAdvances[i], accuracy: tolerance,
                "caret advance after '\(ch)' should equal its rendered " +
                "width (expected \(expectedAdvances[i]) ± \(tolerance), " +
                "got \(advances[i]))"
            )
        }
    }

    // MARK: - Click+type integration test
    //
    // The pure-fn test above verifies `caretRectInCell` math is correct
    // on a pre-seeded cell. This test exercises the full click → type →
    // `caretRectIfInTableCell` pipeline — the same path the live app
    // uses when the user clicks in a cell and types. The bead reports
    // "characters appear to the LEFT of cursor (1-2 char offset)" —
    // meaning the caret's drawn x coordinate is too far right by ~1-2
    // character widths relative to where the typed character renders.
    //
    // This test clicks into an empty cell, types one character, and
    // compares the caret's view-coordinate x (from the editor's
    // `caretRectIfInTableCell`) against the independently-computed
    // expected position (fragment-local caret rect at offset 1,
    // converted to view coords via the same formula the function uses).

    func test_clickThenType_caretRectAlignsWithTypedCharacter() {
        // Empty 2x2 table — matches the user's minimal repro note shape.
        let emptyMd = """
        | A | B |
        | --- | --- |
        |  |  |
        """

        let h = EditorHarness(
            markdown: emptyMd, windowActivation: .keyWindow
        )
        defer { h.teardown() }

        guard let tlm = h.editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage
        else { XCTFail("no tlm/cs"); return }
        tlm.ensureLayout(for: tlm.documentRange)

        // Find the table fragment + element.
        var tableFrag: TableLayoutFragment?
        var element: TableElement?
        var elementStart = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            if let tf = f as? TableLayoutFragment,
               let el = f.textElement as? TableElement,
               let range = el.elementRange {
                tableFrag = tf
                element = el
                elementStart = cs.offset(
                    from: cs.documentRange.location, to: range.location
                )
                return false
            }
            return true
        }
        guard let frag = tableFrag, let el = element
        else { XCTFail("no table fragment"); return }

        // Click at the center of the first data cell (row 1, col 0).
        guard let geom = frag.geometryForHandleOverlay(),
              geom.columnWidths.count >= 2,
              geom.rowHeights.count >= 2
        else { XCTFail("geometry missing"); return }

        let cellLocalX = TableGeometry.handleBarWidth + geom.columnWidths[0] / 2
        let cellLocalY = TableGeometry.handleBarHeight + geom.rowHeights[0] + geom.rowHeights[1] / 2
        let localPoint = CGPoint(x: cellLocalX, y: cellLocalY)

        let frameOrigin = frag.layoutFragmentFrame.origin
        let containerOrigin = h.editor.textContainerOrigin
        let viewPoint = NSPoint(
            x: localPoint.x + frameOrigin.x + containerOrigin.x,
            y: localPoint.y + frameOrigin.y + containerOrigin.y
        )
        _ = h.clickAt(point: viewPoint)

        // Verify the click landed inside the cell.
        guard let selCell = el.cellAtCursor(
            forOffset: h.editor.selectedRange().location - elementStart
        ) else { XCTFail("click did not land in a cell"); return }
        XCTAssertEqual(selCell.row, 1, "click should land in row 1 (first data row)")
        XCTAssertEqual(selCell.col, 0, "click should land in col 0")

        // Record the pre-type cell content and storage offset.
        let preTypeStorage = h.editor.textStorage?.string ?? ""
        let preTypeCursor = h.editor.selectedRange().location
        bmLog("1ml-test: pre-type cursor=\(preTypeCursor) storage='\(preTypeStorage)'")

        // Type one character.
        h.type("X")

        // Force layout so `caretRectIfInTableCell` sees settled geometry.
        tlm.ensureLayout(for: tlm.documentRange)

        let postTypeStorage = h.editor.textStorage?.string ?? ""
        let postTypeCursor = h.editor.selectedRange().location
        bmLog("1ml-test: post-type cursor=\(postTypeCursor) storage='\(postTypeStorage)'")

        // Re-read the fragment — TK2 may have rebuilt it after the edit.
        var postFrag: TableLayoutFragment?
        var postElement: TableElement?
        var postElementStart = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            if let tf = f as? TableLayoutFragment,
               let el = f.textElement as? TableElement,
               let range = el.elementRange {
                postFrag = tf
                postElement = el
                postElementStart = cs.offset(
                    from: cs.documentRange.location, to: range.location
                )
                return false
            }
            return true
        }
        guard let pfrag = postFrag, let pel = postElement
        else { XCTFail("no table fragment after edit"); return }
        let postFrameOrigin = pfrag.layoutFragmentFrame.origin

        // Dump the post-edit Block for diagnosis.
        if case .table(let header, _, let rows, _) = pel.block {
            let headerTexts = header.map { $0.rawText }
            let rowTexts = rows.map { $0.map { $0.rawText } }
            bmLog("1ml-test: post-edit block header=\(headerTexts) rows=\(rowTexts)")
        }

        // Query the caret rect via the editor's integration function.
        guard let caretRect = h.editor.caretRectIfInTableCell() else {
            XCTFail("caretRectIfInTableCell returned nil after typing in cell. cursor=\(postTypeCursor)")
            return
        }
        bmLog("1ml-test: caretRect=\(caretRect)")

        // Build the same-attributes string `caretRectInCell` measures.
        // Data rows use body font.
        let bodyFont = UserDefaultsManagement.noteFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attrStr = NSAttributedString(string: "X", attributes: [.font: bodyFont])
        let charWidth = attrStr.size().width

        // Independently compute the expected caret x in view coords:
        // fragment-local caret at offset 1 (after "X") in cell (1, 0),
        // converted to view coords. Use POST-EDIT fragment.
        guard let expectedLocalRect = pfrag.caretRectInCell(
            row: 1, col: 0, cellLocalOffset: 1
        ) else {
            XCTFail("caretRectInCell returned nil for (1,0) offset=1. " +
                    "post-elementStart=\(postElementStart)")
            return
        }
        let expectedViewX = expectedLocalRect.origin.x + postFrameOrigin.x + containerOrigin.x

        let tolerance: CGFloat = 2.0  // generous for integration path
        XCTAssertEqual(
            caretRect.origin.x, expectedViewX, accuracy: tolerance,
            "caretRectIfInTableCell x (\(caretRect.origin.x)) should match " +
            "independently-computed expected x (\(expectedViewX)) " +
            "after typing one char in an empty cell. " +
            "Char width: \(charWidth). Tolerance: ±\(tolerance)pt."
        )
    }
}
