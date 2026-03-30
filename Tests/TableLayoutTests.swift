//
//  TableLayoutTests.swift
//  FSNotesTests
//
//  Unit tests for InlineTableView.TableLayout computed geometry.
//  Verifies single source of truth for all table dimensions.
//

import XCTest
@testable import FSNotes

class TableLayoutTests: XCTestCase {

    // MARK: - Helpers

    private func makeTable(headers: [String], rows: [[String]], containerWidth: CGFloat = 600) -> InlineTableView {
        let table = InlineTableView()
        table.headers = headers
        table.rows = rows
        table.containerWidth = containerWidth
        return table
    }

    // MARK: - Basic Layout

    func test_2x2_layout() {
        let table = makeTable(headers: ["A", "B"], rows: [["1", "2"]])
        let layout = table.computeLayout()

        XCTAssertEqual(layout.colCount, 2)
        XCTAssertEqual(layout.rowCount, 1) // 1 data row (excludes header)
        XCTAssertEqual(layout.totalRows, 2) // header + 1 data row
        XCTAssertGreaterThan(layout.gridWidth, 0)
        XCTAssertGreaterThan(layout.gridHeight, 0)
    }

    func test_columnWidths_respectMinimum() {
        let table = makeTable(headers: ["A", "B"], rows: [["1", "2"]])
        let layout = table.computeLayout()

        for w in layout.colWidths {
            XCTAssertGreaterThanOrEqual(w, 80) // minColumnWidth
        }
    }

    func test_wideTable_clampedToContainer() {
        let table = makeTable(
            headers: ["Very long header text here", "Another long header"],
            rows: [["Some wide content that exceeds the container", "More wide content"]],
            containerWidth: 200
        )
        let layout = table.computeLayout()

        XCTAssertLessThanOrEqual(layout.scrollWidth, 200)
        XCTAssertGreaterThan(layout.docWidth, layout.scrollWidth) // Document wider than visible
    }

    func test_narrowTable_noScroll() {
        let table = makeTable(headers: ["A", "B"], rows: [["1", "2"]], containerWidth: 800)
        let layout = table.computeLayout()

        // Narrow table should fit without scrolling
        XCTAssertEqual(layout.scrollWidth, layout.docWidth)
    }

    // MARK: - Cell Frame

    func test_cellFrame_symmetricPadding() {
        let table = makeTable(headers: ["A"], rows: [["1"]])
        let rect = NSRect(x: 0, y: 0, width: 100, height: 40)
        let cell = table.cellFrame(from: rect)

        // Horizontal: 4pt each side
        XCTAssertEqual(cell.minX, 4)
        XCTAssertEqual(cell.width, 92) // 100 - 8

        // Vertical: 3pt top, 3pt bottom
        XCTAssertEqual(cell.minY, 3)
        XCTAssertEqual(cell.height, 34) // 40 - 6
    }

    // MARK: - Row Heights

    func test_headerHeight() {
        let table = makeTable(headers: ["Header"], rows: [["Data"]])
        let layout = table.computeLayout()

        XCTAssertGreaterThanOrEqual(layout.headerHeight, 32) // minCellHeight
    }

    func test_multiLineCell_increasesHeight() {
        let table = makeTable(headers: ["H"], rows: [["Line1<br>Line2<br>Line3"]])
        let layout = table.computeLayout()

        let rowH = layout.dataRowHeight(0)
        XCTAssertGreaterThan(rowH, 32) // Should be taller than minCellHeight
    }

    // MARK: - Consistency

    func test_gridHeight_sumOfRowHeights() {
        let table = makeTable(headers: ["A", "B"], rows: [["1", "2"], ["3", "4"], ["5", "6"]])
        let layout = table.computeLayout()

        let sumOfHeights = layout.rHeights.reduce(0, +)
        XCTAssertEqual(layout.gridHeight, sumOfHeights)
    }

    func test_gridWidth_sumOfColWidths() {
        let table = makeTable(headers: ["A", "B", "C"], rows: [["1", "2", "3"]])
        let layout = table.computeLayout()

        let sumOfWidths = layout.colWidths.reduce(0, +)
        XCTAssertEqual(layout.gridWidth, sumOfWidths)
    }

    func test_totalHeight_includesHandleMargin() {
        let table = makeTable(headers: ["A"], rows: [["1"]])
        // Unfocused: no handle margin
        table.focusState = .unfocused
        let unfocused = table.computeLayout()
        XCTAssertEqual(unfocused.totalHeight, unfocused.gridHeight)

        // Hovered: includes handle margin
        table.focusState = .hovered
        let hovered = table.computeLayout()
        XCTAssertGreaterThan(hovered.totalHeight, hovered.gridHeight)
    }
}
