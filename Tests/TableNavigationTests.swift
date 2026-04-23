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
        FeatureFlag.nativeTableElements = true
        defer { FeatureFlag.nativeTableElements = false }

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
            raw: ""
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

    // MARK: - Harness helpers for keyboard-command tests

    /// 2 cols × 2 body rows. `| A | B |` + body rows `| A0 | B0 |` /
    /// `| A1 | B1 |`. Cell text is short and distinct so the tests can
    /// reason about offsets without colliding on identical cell strings.
    private static let markdown2x2 = """
    | H0 | H1 |
    | --- | --- |
    | c00 | c01 |
    | c10 | c11 |
    """

    /// Seed an editor with the 2×2 table, feature flag on, and return
    /// the (harness, tableElement, elementStart, rowColOffsetFn).
    /// The flag is restored after the test via a deferred teardown.
    private func makeHarnessWith2x2Table(
        flagResetter: XCTestCase
    ) -> (
        harness: EditorHarness,
        element: TableElement,
        elementStart: Int,
        offset: (Int, Int) -> Int
    )? {
        FeatureFlag.nativeTableElements = true
        let harness = EditorHarness(markdown: Self.markdown2x2)
        guard let tlm = harness.editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage else {
            harness.teardown()
            return nil
        }
        tlm.ensureLayout(for: tlm.documentRange)
        // Find the TableElement + its element-start in storage.
        var foundElement: TableElement?
        var foundStart = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let el = fragment.textElement as? TableElement,
               let range = el.elementRange {
                foundElement = el
                foundStart = cs.offset(
                    from: cs.documentRange.location, to: range.location
                )
                return false
            }
            return true
        }
        guard let element = foundElement else {
            harness.teardown()
            return nil
        }
        let offsetFn: (Int, Int) -> Int = { row, col in
            let local = element.offset(
                forCellAt: (row: row, col: col)
            ) ?? 0
            return foundStart + local
        }
        return (harness, element, foundStart, offsetFn)
    }

    private func restoreFlag() {
        FeatureFlag.nativeTableElements = false
    }

    // MARK: - 4. Tab moves to next cell

    func test_T2d_tabKey_movesToNextCell() throws {
        guard let ctx = makeHarnessWith2x2Table(flagResetter: self) else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        // Park cursor at cell (0,0).
        let start00 = ctx.offset(0, 0)
        harness.editor.setSelectedRange(NSRange(location: start00, length: 0))

        // Simulate Tab via NSResponder selector.
        harness.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        let expected = ctx.offset(0, 1)
        XCTAssertEqual(
            harness.editor.selectedRange().location, expected,
            "Tab from (0,0) should land at start of (0,1)"
        )
    }

    // MARK: - 5. Tab wraps to next row

    func test_T2d_tabKey_wrapsToNextRow() throws {
        guard let ctx = makeHarnessWith2x2Table(flagResetter: self) else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        // Park cursor at cell (0,1) — the last header cell.
        let start01 = ctx.offset(0, 1)
        harness.editor.setSelectedRange(NSRange(location: start01, length: 0))

        harness.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

        let expected = ctx.offset(1, 0)
        XCTAssertEqual(
            harness.editor.selectedRange().location, expected,
            "Tab from (0,1) should wrap to start of (1,0) — first body cell"
        )
    }

    // MARK: - 6. Shift-Tab moves to previous cell

    func test_T2d_shiftTabKey_movesToPreviousCell() throws {
        guard let ctx = makeHarnessWith2x2Table(flagResetter: self) else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        // Park cursor at cell (0,1).
        let start01 = ctx.offset(0, 1)
        harness.editor.setSelectedRange(NSRange(location: start01, length: 0))

        harness.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))

        let expected = ctx.offset(0, 0)
        XCTAssertEqual(
            harness.editor.selectedRange().location, expected,
            "Shift-Tab from (0,1) should land at start of (0,0)"
        )
    }

    // MARK: - 7. Right-arrow at cell end moves to next cell

    func test_T2d_arrowRight_atCellEnd_movesToNextCell() throws {
        guard let ctx = makeHarnessWith2x2Table(flagResetter: self) else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        // Find the END of cell (0,0): its start + its text length.
        guard case .table(let header, _, _, _) = ctx.element.block else {
            XCTFail("Element block is not .table")
            return
        }
        let cell00Len = header[0].rawText.utf16.count
        let end00 = ctx.offset(0, 0) + cell00Len
        harness.editor.setSelectedRange(NSRange(location: end00, length: 0))

        harness.editor.doCommand(by: #selector(NSResponder.moveRight(_:)))

        let expected = ctx.offset(0, 1)
        XCTAssertEqual(
            harness.editor.selectedRange().location, expected,
            "Right-arrow at end of (0,0) should land at start of (0,1)"
        )
    }

    // MARK: - 8. Down-arrow moves vertically

    func test_T2d_arrowDown_movesVertically() throws {
        guard let ctx = makeHarnessWith2x2Table(flagResetter: self) else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        // Cursor at cell (0,0) → down-arrow → cell (1,0).
        let start00 = ctx.offset(0, 0)
        harness.editor.setSelectedRange(NSRange(location: start00, length: 0))

        harness.editor.doCommand(by: #selector(NSResponder.moveDown(_:)))

        let expected = ctx.offset(1, 0)
        XCTAssertEqual(
            harness.editor.selectedRange().location, expected,
            "Down-arrow from (0,0) should land at (1,0) — same column, row below"
        )
    }

    // MARK: - 9. Return inside a cell is a no-op (T2-e ships <br>)

    func test_T2d_returnKey_inCell_noOps() throws {
        guard let ctx = makeHarnessWith2x2Table(flagResetter: self) else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        // Snapshot the Document before the Return.
        guard let before = harness.document else {
            XCTFail("No Document on harness")
            return
        }

        let start00 = ctx.offset(0, 0)
        harness.editor.setSelectedRange(NSRange(location: start00, length: 0))

        harness.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        guard let after = harness.document else {
            XCTFail("Document gone after Return")
            return
        }
        // Contract: Document blocks count + serialized markdown unchanged.
        XCTAssertEqual(
            before.blocks.count, after.blocks.count,
            "Return inside a cell must not change the Document's block count"
        )
        XCTAssertEqual(
            MarkdownSerializer.serialize(before),
            MarkdownSerializer.serialize(after),
            "Return inside a cell must not change the Document (T2-e will handle <br>)"
        )
    }
}
