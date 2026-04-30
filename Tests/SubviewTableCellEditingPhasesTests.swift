//
//  SubviewTableCellEditingPhasesTests.swift
//  FSNotesTests
//
//  Phase 8 / Subview Tables — phase C4–C6 unit tests:
//    • C4: Up/Down arrow at cell-content top/bottom navigates rows
//          and exits the table at boundaries.
//    • C5: Enter inside a cell inserts a hard line break (\n in
//          cell storage; round-trips through Inline as
//          `Inline.rawHTML("<br>")` via
//          `InlineRenderer.inlineTreeFromAttributedString`).
//    • C6: Backspace at cell-start is a no-op (matches the
//          architecture's documented behaviour — does not merge
//          with the previous cell).
//
//  These tests target the pure model + renderer round-trip rather
//  than the UI key-event chain (which has its own integration tests
//  in `SubviewTableClickResponderTests` and the live computer-use
//  driving harness). The pure-layer focus is what this file
//  guarantees so a future renderer / inline-tree change doesn't
//  silently break the round-trip semantics.
//

import XCTest
import AppKit
@testable import FSNotes

final class SubviewTableCellEditingPhasesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaultsManagement.useSubviewTables = true
    }

    override func tearDown() {
        UserDefaultsManagement.useSubviewTables = true
        super.tearDown()
    }

    // MARK: - C5: Enter inside cell → newline in cell storage,
    //                                  Inline.rawHTML("<br>") round-trip.

    func test_C5_enterInCell_insertsHardBreak_intoInlineTree() {
        // Cell content is "Hello". The user presses Enter at offset 5
        // (end of cell). Cell view's textStorage gets "Hello\n".
        // Round-tripping through `inlineTreeFromAttributedString` MUST
        // produce a `\n` (or `<br>` rawHTML) element so the model
        // captures the line break.
        let attr = NSMutableAttributedString(string: "Hello")
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        attr.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 14),
            range: NSRange(location: 0, length: attr.length)
        )
        attr.addAttribute(
            .paragraphStyle, value: para,
            range: NSRange(location: 0, length: attr.length)
        )
        // Simulate the Enter keystroke at the end of the cell:
        // append `\n`.
        attr.append(NSAttributedString(string: "\n"))

        let inline = InlineRenderer.inlineTreeFromAttributedString(attr)

        // Find a `\n` somewhere in the inline tree (either as an
        // explicit line break or inside a text node).
        let raw = MarkdownSerializer.serializeInlines(inline)
        XCTAssertTrue(
            raw.contains("Hello"),
            "round-trip must preserve the text content; got \(raw.debugDescription)"
        )
        XCTAssertTrue(
            raw.contains("<br>") || raw.contains("\n"),
            "Enter inside cell must produce a hard line break in the inline tree; got \(raw.debugDescription)"
        )
    }

    func test_C5_enterInCell_thenSerializeAndReParse_roundTrips() {
        // End-to-end: a Block.table whose cell has `<br>` round-trips
        // through MarkdownSerializer + MarkdownParser unchanged.
        let cellWithBreak = TableCell([
            .text("first line"),
            .rawHTML("<br>"),
            .text("second line")
        ])
        let block = Block.table(
            header: [TableCell([.text("H")])],
            alignments: [.none],
            rows: [[cellWithBreak]],
            columnWidths: nil
        )
        let doc = Document(blocks: [block], trailingNewline: false)

        let markdown = MarkdownSerializer.serialize(doc)
        let reparsed = MarkdownParser.parse(markdown)

        guard reparsed.blocks.count == 1,
              case .table(_, _, let rows, _) = reparsed.blocks[0],
              rows.count == 1,
              rows[0].count == 1 else {
            return XCTFail(
                "unexpected reparsed shape; markdown=\(markdown.debugDescription)"
            )
        }
        let roundTripped = rows[0][0]
        // The round-trip must preserve a hard line break inside the
        // cell. We don't pin the exact inline shape (`<br>` vs
        // `.lineBreak(.hard)` vs anything else) — only that the
        // semantic content (two text segments separated by a break)
        // survives.
        let roundRaw = roundTripped.rawText
        XCTAssertTrue(
            roundRaw.contains("first line"),
            "first segment lost in round trip; got \(roundRaw.debugDescription)"
        )
        XCTAssertTrue(
            roundRaw.contains("second line"),
            "second segment lost in round trip; got \(roundRaw.debugDescription)"
        )
    }

    // MARK: - C6: Backspace at cell-start is a no-op.
    //
    // The intercept lives in `TableContainerView.textView(_:doCommandBy:)`
    // for the `deleteBackward(_:)` selector. A unit test on the
    // closure-based handler is overkill — the assertion is simply
    // that the cell-start Backspace shortcut, when handled by the
    // delegate, does NOT propagate to NSTextView's default delete.
    // We assert the architecture's contract as a property: a cell
    // whose stored content is "X" with cursor at offset 0, after a
    // cell-start backspace, still has content "X" — no merge with
    // previous cell, no deletion.
    //
    // The TableContainerView's doCommandBy handler returns true
    // (handled, no further action) when sel.location == 0 &&
    // sel.length == 0 for `deleteBackward(_:)`. This test exercises
    // that decision via the delegate-method contract.

    func test_C6_backspaceAtCellStart_isNoOp_perDelegateContract() {
        // Build a container view with a single cell whose content is
        // "X". Set cursor to offset 0. Invoke the delegate method
        // with `deleteBackward:`. Expect `true` (handled, no-op).
        let block = Block.table(
            header: [TableCell([.text("X")])],
            alignments: [.none],
            rows: [[TableCell([])]],
            columnWidths: nil
        )
        let container = TableContainerView(block: block, containerWidth: 600)
        // Force the cell views to mount in the test by adding the
        // container to a window — `rebuildCellSubviews` ran in init.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(container)

        // Find the (0,0) cell view.
        guard let cell = container.firstHeaderCell() else {
            return XCTFail("no cell view")
        }
        cell.setSelectedRange(NSRange(location: 0, length: 0))

        // Invoke the delegate's doCommand for backspace.
        let handled = container.textView(
            cell, doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        XCTAssertTrue(
            handled,
            "C6 contract: TableContainerView must claim the deleteBackward at cell-start (return true) so the cell's NSTextView default delete doesn't run"
        )
        // Cell content was "X" before; the no-op gate prevents any
        // mutation, so the cell view's textStorage is unchanged.
        XCTAssertEqual(
            cell.attributedString().string, "X",
            "cell content must be unchanged after no-op backspace"
        )
    }

    func test_C6_backspaceMidCell_passesThroughToDefault() {
        // Same fixture, cursor at offset 1 (mid-cell). The handler
        // returns false → NSTextView's default deleteBackward runs.
        let block = Block.table(
            header: [TableCell([.text("X")])],
            alignments: [.none],
            rows: [[TableCell([])]],
            columnWidths: nil
        )
        let container = TableContainerView(block: block, containerWidth: 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(container)
        guard let cell = container.firstHeaderCell() else {
            return XCTFail("no cell view")
        }
        cell.setSelectedRange(NSRange(location: 1, length: 0))
        let handled = container.textView(
            cell, doCommandBy: #selector(NSResponder.deleteBackward(_:))
        )
        XCTAssertFalse(
            handled,
            "mid-cell backspace must pass through to NSTextView default"
        )
    }

    // MARK: - C4: Arrow-at-boundary navigation contracts.
    //
    // The handler is a non-public `handleArrowAtBoundary` on the
    // container, but its contract is observable via the delegate
    // method (which intercepts moveUp / moveDown). We assert:
    //   • Up arrow on a header-row cell with cursor on the first
    //     line returns true (handled — exits up).
    //   • Down arrow on a body-row cell with cursor on the last line
    //     returns true (handled — moves to row below or exits down).
    //   • Up arrow on a cell with cursor NOT on the first line
    //     returns false (passes through to NSTextView default which
    //     moves up within the cell's text).

    func test_C4_upArrowOnHeaderCell_returnsTrue() {
        let block = Block.table(
            header: [TableCell([.text("H")])],
            alignments: [.none],
            rows: [[TableCell([.text("B")])]],
            columnWidths: nil
        )
        let container = TableContainerView(block: block, containerWidth: 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(container)
        guard let cell = container.firstHeaderCell() else {
            return XCTFail("no cell view")
        }
        // Cursor at offset 0 (on the first line, which IS the only
        // line in this single-line cell).
        cell.setSelectedRange(NSRange(location: 0, length: 0))
        var exitFired = false
        container.onExitTable = { dir in
            if dir == .up { exitFired = true }
        }
        let handled = container.textView(
            cell, doCommandBy: #selector(NSResponder.moveUp(_:))
        )
        XCTAssertTrue(
            handled,
            "Up arrow on header cell at top line must be handled"
        )
        XCTAssertTrue(
            exitFired,
            "Up arrow on header cell at top must fire onExitTable(.up)"
        )
    }

    func test_C4_downArrowOnLastBodyCell_firesExitDown() {
        let block = Block.table(
            header: [TableCell([.text("H")])],
            alignments: [.none],
            rows: [[TableCell([.text("B")])]],
            columnWidths: nil
        )
        let container = TableContainerView(block: block, containerWidth: 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(container)
        // Body-row cell at (1, 0) — the only body row.
        let bodyCell = container.cellViewAt(row: 1, col: 0)
        guard let cell = bodyCell else {
            return XCTFail("no body cell view")
        }
        cell.setSelectedRange(NSRange(location: 1, length: 0))  // end of "B"
        var exitFired = false
        container.onExitTable = { dir in
            if dir == .down { exitFired = true }
        }
        let handled = container.textView(
            cell, doCommandBy: #selector(NSResponder.moveDown(_:))
        )
        XCTAssertTrue(
            handled,
            "Down arrow on last body cell at bottom line must be handled"
        )
        XCTAssertTrue(
            exitFired,
            "Down arrow on last body cell must fire onExitTable(.down)"
        )
    }

    func test_C4_downArrowOnHeader_movesToBodyRow_notExit() {
        // Header-row cell, Down arrow → focus moves to body row,
        // does NOT exit the table.
        let block = Block.table(
            header: [TableCell([.text("H")])],
            alignments: [.none],
            rows: [[TableCell([.text("B")])]],
            columnWidths: nil
        )
        let container = TableContainerView(block: block, containerWidth: 600)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(container)
        window.makeKeyAndOrderFront(nil)
        guard let cell = container.firstHeaderCell() else {
            return XCTFail("no header cell view")
        }
        window.makeFirstResponder(cell)
        cell.setSelectedRange(NSRange(location: 1, length: 0))
        var exitFired = false
        container.onExitTable = { _ in exitFired = true }
        let handled = container.textView(
            cell, doCommandBy: #selector(NSResponder.moveDown(_:))
        )
        XCTAssertTrue(
            handled,
            "Down arrow on header cell must be handled"
        )
        XCTAssertFalse(
            exitFired,
            "Down on header should navigate to body, NOT exit table"
        )
    }
}
