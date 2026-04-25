//
//  TableCellHitTestTests.swift
//  FSNotesTests
//
//  Pure tests for `TableLayoutFragment.cellHit(at:)` — the
//  click-point-to-(row, col) mapping used by
//  `EditTextView.handleTableCellClick` to place the cursor inside
//  the right cell on a mouseDown.
//
//  These bypass the offscreen-harness click event timing (which
//  hangs in `clickAt(point:)`) by setting up a real
//  NSTextLayoutManager + NSTextContentStorage with a TableElement
//  and hit-testing the fragment directly via the pure helper.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableCellHitTestTests: XCTestCase {

    /// Build a layout-manager + content-storage with one TableElement
    /// for the given markdown table; return the fragment and the
    /// element so the test can compute click points and call
    /// `cellHit(at:)` directly.
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
        // Hold onto the delegates + storage so they outlive the
        // function (otherwise TK2 deallocates the fragment).
        objc_setAssociatedObject(
            found ?? NSObject(),
            &TableCellHitTestTests.holdersKey,
            (csDelegate, lmDelegate, contentStorage, tlm) as AnyObject,
            .OBJC_ASSOCIATION_RETAIN
        )
        guard let fragment = found, let element = foundElement else {
            return nil
        }
        return (fragment, element)
    }

    private static var holdersKey: UInt8 = 0

    // MARK: - Tests

    /// Click in the visual middle of cell (row 1, col 0) — the
    /// body cell containing "x" — should resolve to (1, 0).
    func test_clickInBodyCell_resolvesToCorrectRowCol() {
        let md = """
        | A | B |
        |---|---|
        | x | y |
        | z | w |
        """
        guard let (fragment, _) = makeTableFragment(markdown: md) else {
            XCTFail("could not build TableLayoutFragment for markdown")
            return
        }
        // Geometry: handleBarWidth + 0.5 * column0_width on x;
        // handleBarHeight + (header_h + 0.5 * row0_h) on y.
        guard let g = fragment.geometryForHandleOverlay() else {
            XCTFail("geometry unavailable")
            return
        }
        let xMid = TableGeometry.handleBarWidth +
            g.columnWidths[0] / 2
        let yMid = TableGeometry.handleBarHeight +
            g.rowHeights[0] +  // header
            g.rowHeights[1] / 2  // first body row
        let hit = fragment.cellHit(at: CGPoint(x: xMid, y: yMid))
        XCTAssertNotNil(hit)
        if let hit = hit {
            // rowHeights index 0 = header, 1 = first body row, etc.
            // cellHit returns row index in the rowHeights array.
            XCTAssertEqual(hit.row, 1, "expected body row 0 (rowHeights[1])")
            XCTAssertEqual(hit.col, 0)
        }
    }

    /// Click in the header row (row 0) center of column 1.
    func test_clickInHeaderCell_resolvesToHeaderRow() {
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
        let xMid = TableGeometry.handleBarWidth +
            g.columnWidths[0] +
            g.columnWidths[1] / 2
        let yHeader = TableGeometry.handleBarHeight +
            g.rowHeights[0] / 2
        let hit = fragment.cellHit(at: CGPoint(x: xMid, y: yHeader))
        XCTAssertNotNil(hit)
        if let hit = hit {
            XCTAssertEqual(hit.row, 0)
            XCTAssertEqual(hit.col, 1)
        }
    }

    /// Click in the top handle strip — should NOT resolve to a
    /// cell (handle UI owns those clicks).
    func test_clickInTopStrip_returnsNil() {
        let md = """
        | A | B |
        |---|---|
        | x | y |
        """
        guard let (fragment, _) = makeTableFragment(markdown: md) else {
            XCTFail("could not build TableLayoutFragment")
            return
        }
        let hit = fragment.cellHit(at: CGPoint(x: 50, y: 5))
        XCTAssertNil(hit)
    }

    /// Click in the left handle strip — also NOT a cell hit.
    func test_clickInLeftStrip_returnsNil() {
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
        let yMid = TableGeometry.handleBarHeight +
            g.rowHeights[0] +
            g.rowHeights[1] / 2
        let hit = fragment.cellHit(
            at: CGPoint(x: 5, y: yMid)
        )
        XCTAssertNil(hit)
    }

    /// End-to-end: cellHit → cellRange → cell content. Click in
    /// (1, 0) should map to a storage range that contains "x".
    func test_clickInBodyCell_storageRangeContainsCellText() {
        let md = """
        | A | B |
        |---|---|
        | x | y |
        | z | w |
        """
        guard let (fragment, element) = makeTableFragment(
            markdown: md
        ) else {
            XCTFail("could not build TableLayoutFragment")
            return
        }
        guard let g = fragment.geometryForHandleOverlay() else {
            XCTFail("geometry unavailable")
            return
        }
        let xMid = TableGeometry.handleBarWidth +
            g.columnWidths[0] / 2
        let yMid = TableGeometry.handleBarHeight +
            g.rowHeights[0] +
            g.rowHeights[1] / 2
        guard let (row, col) = fragment.cellHit(
            at: CGPoint(x: xMid, y: yMid)
        ) else {
            XCTFail("cellHit returned nil for body cell click")
            return
        }
        guard let range = element.cellRange(
            forCellAt: (row: row, col: col)
        ) else {
            XCTFail("no cellRange for (\(row), \(col))")
            return
        }
        let elementString = element.attributedString.string as NSString
        let cellText = elementString.substring(with: range)
        XCTAssertEqual(
            cellText, "x",
            "click in (\(row), \(col)) cell should map to text 'x', got '\(cellText)'"
        )
    }

    /// User-flow regression: create a note, insert a table via the
    /// `Insert Table` IBAction, type a character. The character
    /// MUST land inside the new table's top-left cell, not at
    /// some position outside it.
    func test_insertTableThenType_landsInTopLeftCell() {
        let h = EditorHarness(markdown: "", windowActivation: .keyWindow)
        defer { h.teardown() }
        // Type a placeholder char so the document has at least one
        // block; otherwise `insertTableMenu` returns early when
        // `blockContaining(storageIndex: 0)` is nil.
        h.type("p")
        h.editor.insertTableMenu(NSObject())
        h.type("X")
        guard let projection = h.editor.documentProjection else {
            XCTFail("no projection"); return
        }
        let tableBlocks = projection.document.blocks.compactMap {
            block -> Block? in
            if case .table = block { return block } else { return nil }
        }
        XCTAssertEqual(
            tableBlocks.count, 1,
            "expected exactly one table block; got \(tableBlocks.count)"
        )
        guard case .table(let header, _, _, _) = tableBlocks[0]
        else { XCTFail("first table block isn't .table"); return }
        let headerTexts = header.map { $0.rawText }.joined(separator: ",")
        XCTAssertEqual(
            header.first?.rawText, "X",
            "expected 'X' in (0,0); got header=[\(headerTexts)]"
        )
    }
}
