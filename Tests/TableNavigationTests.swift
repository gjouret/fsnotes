//
//  TableNavigationTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-d — Cursor + keyboard navigation inside a TableElement.
//
//  The tests split into two layers:
//
//    1. Pure-function locator tests on `TableElement.cellLocation(forOffset:)`
//       and `TableElement.offset(forCellAt:)`. These are the load-bearing
//       primitives for the nav layer and must round-trip across every
//       (row, col) in the grid. No NSWindow, no layout manager — just a
//       `TableElement` constructed from a rendered attributed string.
//
//    2. Harness-driven tests for the keyboard commands (Tab, Shift-Tab,
//       Left/Right/Up/Down, Return). These use `EditorHarness` with the
//       feature flag ON so `TableTextRenderer.renderNative(...)` emits
//       the separator-encoded storage and the content-storage delegate
//       vends a `TableElement`. They call `doCommand(by:)` on the
//       editor — the same path a real key event takes through
//       `NSResponder.keyDown → super.keyDown → doCommand(by:)` — and
//       assert on the resulting selection.
//
//  Rule 3 posture: every keyboard-command test asserts on a value-typed
//  snapshot of the editor's selection after the command. No mouse events,
//  no field-editor probes.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableNavigationTests: XCTestCase {

    // MARK: - Fixtures

    /// Build a freestanding TableElement for the locator tests. The
    /// attributed string is produced by `TableTextRenderer.renderNative`
    /// so the encoding matches production byte-for-byte.
    private func makeElement(
        cols: Int,
        bodyRows: Int
    ) -> TableElement {
        let header = (0..<cols).map { TableCell.parsing("H\($0)") }
        let rows: [[TableCell]] = (0..<bodyRows).map { r in
            (0..<cols).map { c in TableCell.parsing("r\(r)c\(c)") }
        }
        let alignments: [TableAlignment] = Array(
            repeating: .none, count: cols
        )
        let font = NSFont.systemFont(ofSize: 14)
        let rendered = TableTextRenderer.render(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: "",
            bodyFont: font
        )
        let block: Block = .table(
            header: header,
            alignments: alignments,
            rows: rows,
            columnWidths: nil
        )
        let element = TableElement(
            block: block, attributedString: rendered
        )
        // Preconditions: init never returns nil for a .table block.
        XCTAssertNotNil(element, "TableElement.init must succeed for .table block")
        return element!
    }

    // MARK: - 1. cellLocation decodes offset correctly

    /// 3 cols × 2 body rows. Walk every cell's start offset and assert
    /// the locator reports the expected `(row, col)`. The header is
    /// row 0; body rows are 1 and 2.
    func test_T2d_cellLocation_decodesOffsetCorrectly() throws {
        let element = makeElement(cols: 3, bodyRows: 2)
        // Collect start offset for every cell.
        for row in 0..<3 {
            for col in 0..<3 {
                guard let offset = element.offset(
                    forCellAt: (row: row, col: col)
                ) else {
                    XCTFail("Expected offset for (\(row),\(col))")
                    continue
                }
                guard let loc = element.cellLocation(
                    forOffset: offset
                ) else {
                    XCTFail(
                        "cellLocation returned nil for offset \(offset) " +
                        "at (\(row),\(col))"
                    )
                    continue
                }
                XCTAssertEqual(
                    loc.row, row,
                    "Row mismatch at (\(row),\(col)): got \(loc.row)"
                )
                XCTAssertEqual(
                    loc.col, col,
                    "Col mismatch at (\(row),\(col)): got \(loc.col)"
                )
            }
        }
    }

    // MARK: - 2. cellLocation returns nil for separators

    /// Every U+001F / U+001E character in the element's string must
    /// resolve to nil — the cursor is on a separator, not inside a cell.
    /// Walk the string via NSString so the indexing matches the UTF-16
    /// offsets the locator operates on.
    func test_T2d_cellLocation_returnsNilForSeparators() throws {
        let element = makeElement(cols: 3, bodyRows: 2)
        let ns = element.attributedString.string as NSString
        let cellSep: unichar = unichar(
            TableElement.cellSeparator.unicodeScalars.first!.value
        )
        let rowSep: unichar = unichar(
            TableElement.rowSeparator.unicodeScalars.first!.value
        )
        var foundAtLeastOne = false
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == cellSep || ch == rowSep {
                foundAtLeastOne = true
                let loc = element.cellLocation(forOffset: i)
                XCTAssertNil(
                    loc,
                    "Offset \(i) is on a separator (\(ch == cellSep ? "U+001F" : "U+001E")) " +
                    "but locator returned \(String(describing: loc))"
                )
            }
        }
        XCTAssertTrue(
            foundAtLeastOne,
            "Rendered 3x2 table must contain separator characters"
        )
    }

    // MARK: - 3. offset(forCellAt:) round-trips

    /// For every `(row, col)` in a 3×2 table, round-trip via
    /// `cellLocation(forOffset: offset(forCellAt: …))` and assert the
    /// result equals the input. Also exercised for edge shapes 1×1,
    /// 4×1, 1×5 to cover single-row / single-column tables.
    func test_T2d_offsetForCellAt_roundTrips() throws {
        let shapes: [(cols: Int, bodyRows: Int)] = [
            (cols: 3, bodyRows: 2),
            (cols: 1, bodyRows: 1),
            (cols: 4, bodyRows: 1),
            (cols: 1, bodyRows: 5)
        ]
        for shape in shapes {
            let element = makeElement(
                cols: shape.cols, bodyRows: shape.bodyRows
            )
            let totalRows = 1 + shape.bodyRows
            for row in 0..<totalRows {
                for col in 0..<shape.cols {
                    guard let offset = element.offset(
                        forCellAt: (row: row, col: col)
                    ) else {
                        XCTFail(
                            "Shape \(shape) (\(row),\(col)): offset(forCellAt:) returned nil"
                        )
                        continue
                    }
                    guard let back = element.cellLocation(
                        forOffset: offset
                    ) else {
                        XCTFail(
                            "Shape \(shape) (\(row),\(col)): cellLocation(forOffset: \(offset)) returned nil"
                        )
                        continue
                    }
                    XCTAssertEqual(
                        back.row, row,
                        "Shape \(shape) (\(row),\(col)): round-trip row mismatch"
                    )
                    XCTAssertEqual(
                        back.col, col,
                        "Shape \(shape) (\(row),\(col)): round-trip col mismatch"
                    )
                }
            }
            // Out of range must return nil.
            XCTAssertNil(element.offset(forCellAt: (row: -1, col: 0)))
            XCTAssertNil(element.offset(forCellAt: (row: 0, col: -1)))
            XCTAssertNil(element.offset(forCellAt: (row: totalRows, col: 0)))
            XCTAssertNil(element.offset(forCellAt: (row: 0, col: shape.cols)))
        }
    }

    // MARK: - Scenario helpers for keyboard-command tests

    /// 2 cols × 2 body rows. `| A | B |` + body rows `| A0 | B0 |` /
    /// `| A1 | B1 |`. Cell text is short and distinct so the tests can
    /// reason about offsets without colliding on identical cell strings.
    private static let markdown2x2 = """
    | H0 | H1 |
    | --- | --- |
    | c00 | c01 |
    | c10 | c11 |
    """

    /// Build a scenario seeded with the 2×2 markdown together with the
    /// reachable `TableElement`. Returns nil when no element
    /// materialised (`useSubviewTables` leaked, fill failure, etc.) —
    /// every test guards on that and fails with "Harness setup failed".
    /// (Phase 11 Slice F.3 — replaces the legacy 4-tuple
    /// `makeHarnessWith2x2Table` factory.)
    private func makeScenarioWith2x2Table() -> (
        scenario: EditorScenario,
        element: TableElement
    )? {
        let scenario = Given.note(markdown: Self.markdown2x2)
        guard let hit = scenario.firstFragmentElement(of: TableElement.self)
        else { return nil }
        return (scenario, hit.element)
    }

    // MARK: - 4. Tab moves to next cell

    func test_T2d_tabKey_movesToNextCell() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // Park cursor at cell (0,0).
        let start00 = scenario.tableCellOffset(row: 0, col: 0)!
        scenario.editor.setSelectedRange(NSRange(location: start00, length: 0))

        // Simulate Tab via NSResponder selector.
        scenario.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        let expected = scenario.tableCellOffset(row: 0, col: 1)!
        XCTAssertEqual(
            scenario.editor.selectedRange().location, expected,
            "Tab from (0,0) should land at start of (0,1)"
        )
    }

    // MARK: - 5. Tab advances across the row boundary

    /// Tab from the last cell of one row should advance to the first
    /// cell of the next row in row-major order. (Bug #32: this is not
    /// a "wrap" — wrapping at grid edges was removed; this test
    /// crosses an internal row boundary, which is just the next cell
    /// in row-major sequence and still works post-clamp.)
    func test_T2d_tabKey_advancesAcrossRowBoundary() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // Park cursor at cell (0,1) — the last header cell.
        let start01 = scenario.tableCellOffset(row: 0, col: 1)!
        scenario.editor.setSelectedRange(NSRange(location: start01, length: 0))

        scenario.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        let expected = scenario.tableCellOffset(row: 1, col: 0)!
        XCTAssertEqual(
            scenario.editor.selectedRange().location, expected,
            "Tab from (0,1) should advance to start of (1,0) — first body cell"
        )
    }

    // MARK: - 5b. Tab at bottom-right cell clamps (no wrap; bug #32)

    /// Tab from the last cell of the last row must NOT wrap back to
    /// the top-left cell. The cursor stays in (lastRow, lastCol).
    func test_bug32_tabAtBottomRightCell_clampsAndStays() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // 2x2 body table → last cell is body row 1 (storage row 2),
        // column 1.
        let lastRow = 2
        let lastCol = 1
        let startLast = scenario.tableCellOffset(row: lastRow, col: lastCol)!
        scenario.editor.setSelectedRange(NSRange(location: startLast, length: 0))

        scenario.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        XCTAssertEqual(
            scenario.editor.selectedRange().location, startLast,
            "Tab at bottom-right must clamp (no wrap to (0,0))"
        )
    }

    // MARK: - 5c. Shift-Tab at top-left cell clamps (no wrap; bug #32)

    /// Shift-Tab from cell (0, 0) must NOT wrap to the bottom-right
    /// cell. The cursor stays at (0, 0). Direct user-prescribed
    /// behaviour for bug #32.
    func test_bug32_shiftTabAtTopLeftCell_clampsAndStays() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        let start00 = scenario.tableCellOffset(row: 0, col: 0)!
        scenario.editor.setSelectedRange(NSRange(location: start00, length: 0))

        scenario.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))

        XCTAssertEqual(
            scenario.editor.selectedRange().location, start00,
            "Shift-Tab at top-left must clamp (no wrap to bottom-right)"
        )
    }

    // MARK: - 6. Shift-Tab moves to previous cell

    func test_T2d_shiftTabKey_movesToPreviousCell() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // Park cursor at cell (0,1).
        let start01 = scenario.tableCellOffset(row: 0, col: 1)!
        scenario.editor.setSelectedRange(NSRange(location: start01, length: 0))

        scenario.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))

        let expected = scenario.tableCellOffset(row: 0, col: 0)!
        XCTAssertEqual(
            scenario.editor.selectedRange().location, expected,
            "Shift-Tab from (0,1) should land at start of (0,0)"
        )
    }

    // MARK: - 7. Right-arrow at cell end moves to next cell

    func test_T2d_arrowRight_atCellEnd_movesToNextCell() throws {
        guard let (scenario, tableElement) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // Find the END of cell (0,0): its start + its text length.
        guard case .table(let header, _, _, _) = tableElement.block else {
            XCTFail("Element block is not .table")
            return
        }
        let cell00Len = header[0].rawText.utf16.count
        let end00 = scenario.tableCellOffset(row: 0, col: 0)! + cell00Len
        scenario.editor.setSelectedRange(NSRange(location: end00, length: 0))

        scenario.editor.doCommand(by: #selector(NSResponder.moveRight(_:)))

        let expected = scenario.tableCellOffset(row: 0, col: 1)!
        XCTAssertEqual(
            scenario.editor.selectedRange().location, expected,
            "Right-arrow at end of (0,0) should land at start of (0,1)"
        )
    }

    // MARK: - 8. Down-arrow moves vertically

    func test_T2d_arrowDown_movesVertically() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // Cursor at cell (0,0) → down-arrow → cell (1,0).
        let start00 = scenario.tableCellOffset(row: 0, col: 0)!
        scenario.editor.setSelectedRange(NSRange(location: start00, length: 0))

        scenario.editor.doCommand(by: #selector(NSResponder.moveDown(_:)))

        let expected = scenario.tableCellOffset(row: 1, col: 0)!
        XCTAssertEqual(
            scenario.editor.selectedRange().location, expected,
            "Down-arrow from (0,0) should land at (1,0) — same column, row below"
        )
    }

    // MARK: - Tab/Shift-Tab from cursor at end-of-cell (Phase 11 Slice B)
    //
    // Bug #30 from the inventory: clicking inside a cell parks the
    // cursor at the END of the cell's content. For non-last cells,
    // that offset sits on a U+001F separator. The strict
    // `cellLocation(forOffset:)` returns nil for separator offsets,
    // which made `tableCursorContext()` return nil, which made
    // `handleTableNavCommand` return false, which let `super.doCommand
    // (insertTab:)` insert a literal `\t` into the cell.
    //
    // Fix: `TableElement.cellAtCursor(forOffset:)` resolves separator
    // offsets to the preceding cell so Tab routes through us. The
    // tests below pin the behavior — they fail on master and pass
    // after the fix.

    /// Tab from end of cell (0, 0) — where a click-to-cell parks the
    /// caret — must advance to start of (0, 1), NOT insert a tab
    /// character.
    func test_phase11sliceB_tabAtEndOfCell_movesToNextCell() throws {
        guard let (scenario, tableElement) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed"); return
        }

        // End of cell (0, 0) = its start + cell text length. For
        // header "H0" that's start00 + 2 — which is the offset of
        // the U+001F separator.
        guard case .table(let header, _, _, _) = tableElement.block else {
            XCTFail("not a table"); return
        }
        let cell00Len = header[0].rawText.utf16.count
        let endOfCell00 = scenario.tableCellOffset(row: 0, col: 0)! + cell00Len
        scenario.editor.setSelectedRange(NSRange(location: endOfCell00, length: 0))

        let storageBefore = scenario.editor.textStorage?.string ?? ""
        scenario.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        let expected = scenario.tableCellOffset(row: 0, col: 1)!
        XCTAssertEqual(
            scenario.editor.selectedRange().location, expected,
            "Tab from end of (0,0) (= on the U+001F separator) " +
            "must advance to start of (0,1), not insert a tab"
        )
        // Storage must not have been mutated — no literal \t.
        let storageAfter = scenario.editor.textStorage?.string ?? ""
        XCTAssertEqual(
            storageBefore, storageAfter,
            "Tab inside table must not modify storage (no literal \\t)"
        )
    }

    /// Shift-Tab from start of cell (0, 0) must not insert a literal
    /// `\t` into storage. After the bug #32 fix, the cursor also stays
    /// at (0, 0) — clamped at the grid's start. (`bug32_*` tests
    /// above own the clamp assertion specifically; this one keeps the
    /// no-tab-character contract for the same scenario.)
    func test_phase11sliceB_shiftTabAtStartOfFirstCell_doesNotInsertTab() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed"); return
        }

        let start00 = scenario.tableCellOffset(row: 0, col: 0)!
        scenario.editor.setSelectedRange(NSRange(location: start00, length: 0))
        let storageBefore = scenario.editor.textStorage?.string ?? ""

        scenario.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))

        let storageAfter = scenario.editor.textStorage?.string ?? ""
        XCTAssertEqual(
            storageBefore, storageAfter,
            "Shift-Tab inside table must not modify storage (no literal \\t)"
        )
        // Bug #32 contract: clamps at the grid's start — cursor stays
        // at (0, 0). This is stricter than "still in table"; the
        // dedicated bug32 test asserts identity, this one re-verifies
        // it as a side-channel check on the no-tab-character path.
        let cursor = scenario.editor.selectedRange().location
        XCTAssertEqual(
            cursor, start00,
            "Shift-Tab from (0,0) must clamp — cursor stays at (0,0)"
        )
    }

    /// End-to-end with a click-then-Tab simulation. Place cursor at
    /// end of cell (1, 0) — same offset `handleTableCellClick` parks
    /// at — then Tab. Expect cell (1, 1).
    func test_phase11sliceB_tabAfterClickToCell10_movesToCell11() throws {
        guard let (scenario, tableElement) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed"); return
        }

        guard case .table(_, _, let rows, _) = tableElement.block else {
            XCTFail("not a table"); return
        }
        let cell10Len = rows[0][0].rawText.utf16.count
        let endOfCell10 = scenario.tableCellOffset(row: 1, col: 0)! + cell10Len
        scenario.editor.setSelectedRange(NSRange(location: endOfCell10, length: 0))
        let storageBefore = scenario.editor.textStorage?.string ?? ""

        scenario.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        let expected = scenario.tableCellOffset(row: 1, col: 1)!
        XCTAssertEqual(
            scenario.editor.selectedRange().location, expected,
            "Tab from end of body (1,0) must move to start of (1,1)"
        )
        XCTAssertEqual(
            scenario.editor.textStorage?.string ?? "", storageBefore,
            "Storage must not be mutated"
        )
    }

    // MARK: - Bug #37: Backspace at start of table cell stays in cell

    /// Backspace from cell offset 0 must not cross the cell boundary.
    /// Pre-fix, the deletion swallowed either the U+001F separator
    /// (corrupting the table) or the inter-block boundary preceding
    /// the table (merging the table away). Post-fix, the operation is
    /// a no-op: storage unchanged, block count unchanged, cursor
    /// stays put.
    func test_T2_backspaceAtCellStart_staysInCell() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // Park the cursor at offset 0 of cell (0, 0) — the top-left
        // cell, where the bug originally manifested as "the entire
        // table block disappears."
        let start00 = scenario.tableCellOffset(row: 0, col: 0)!
        scenario.editor.setSelectedRange(NSRange(location: start00, length: 0))

        let storageBefore = scenario.editor.textStorage?.string ?? ""
        let blocksBefore = scenario.harness.document?.blocks.count ?? 0

        _ = scenario.editor.handleEditViaBlockModel(
            in: NSRange(location: start00 - 1, length: 1),
            replacementString: ""
        )

        let storageAfter = scenario.editor.textStorage?.string ?? ""
        let blocksAfter = scenario.harness.document?.blocks.count ?? 0
        XCTAssertEqual(
            storageBefore, storageAfter,
            "Backspace at cell (0,0) start must not modify storage"
        )
        XCTAssertEqual(
            blocksBefore, blocksAfter,
            "Backspace at cell (0,0) start must not change block count " +
            "(table must not merge with predecessor)"
        )

        // And the same at an internal-cell boundary (cell (1, 0)).
        // Pre-fix this would corrupt the U+001F encoding.
        let start10 = scenario.tableCellOffset(row: 1, col: 0)!
        scenario.editor.setSelectedRange(NSRange(location: start10, length: 0))

        let storage2Before = scenario.editor.textStorage?.string ?? ""
        _ = scenario.editor.handleEditViaBlockModel(
            in: NSRange(location: start10 - 1, length: 1),
            replacementString: ""
        )
        let storage2After = scenario.editor.textStorage?.string ?? ""
        XCTAssertEqual(
            storage2Before, storage2After,
            "Backspace at cell (1,0) start must not modify storage " +
            "(no separator deletion, no cell-merge)"
        )
    }

    // MARK: - 9. Return inside a cell inserts a `<br>`  (T2-e)
    //
    // This test originally asserted Return was a no-op (T2-d slice) and
    // carried the comment "T2-e will handle <br>". T2-e has landed; the
    // test now locks in the new behaviour: Return inside a cell inserts
    // a `.rawHTML("<br>")` into the cell's inline tree, the block
    // structure stays intact, and the serialized markdown changes to
    // include `<br>` inside the cell.

    func test_T2d_returnKey_inCell_insertsBr() throws {
        guard let (scenario, _) = makeScenarioWith2x2Table() else {
            XCTFail("Harness setup failed")
            return
        }

        // Snapshot the Document before the Return.
        guard let before = scenario.harness.document else {
            XCTFail("No Document on harness")
            return
        }

        let start00 = scenario.tableCellOffset(row: 0, col: 0)!
        scenario.editor.setSelectedRange(NSRange(location: start00, length: 0))

        scenario.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        guard let after = scenario.harness.document else {
            XCTFail("Document gone after Return")
            return
        }
        // Block count + count of table rows must not change — Return
        // inside a cell is a cell-internal edit.
        XCTAssertEqual(
            before.blocks.count, after.blocks.count,
            "Return inside a cell must not change the Document's block count"
        )
        // Locate the table block and assert the edited cell (header,
        // col 0) carries a `.rawHTML("<br>")` inline.
        var found = false
        for block in after.blocks {
            if case .table(let header, _, _, _) = block {
                let inline = header[0].inline
                if inline.contains(where: { node in
                    if case .rawHTML(let s) = node, s == "<br>" { return true }
                    return false
                }) {
                    found = true
                    break
                }
            }
        }
        XCTAssertTrue(
            found,
            "Return inside header cell (0,0) should insert `<br>` into its inline tree"
        )
    }
}
