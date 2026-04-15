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
        // The widget now stores TableCell values (inline trees). Parse
        // each string-cell through `TableCell.parsing` so tests written
        // against the old string API keep their intent.
        table.headers = headers.map { TableCell.parsing($0) }
        table.rows = rows.map { row in row.map { TableCell.parsing($0) } }
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

    func test_wideTable_wrapsToFitContainer() {
        let table = makeTable(
            headers: ["Very long header text here", "Another long header"],
            rows: [["Some wide content that exceeds the container", "More wide content"]],
            containerWidth: 200
        )
        let layout = table.computeLayout()

        // With auto-wrap, columns shrink to fit container — no horizontal scroll needed
        XCTAssertLessThanOrEqual(layout.scrollWidth, 200)
        // Row heights should increase to accommodate wrapped text
        XCTAssertGreaterThan(layout.rHeights[1], layout.rHeights[0],
            "Data row with long text should be taller than header after wrapping")
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

        let fontSize = UserDefaultsManagement.noteFont.pointSize
        let spacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        let vPad = max(2, ceil(spacing * 0.75))
        let expectedMinCellHeight = ceil(fontSize + spacing + vPad * 2 + fontSize * 0.4)
        XCTAssertGreaterThanOrEqual(layout.headerHeight, expectedMinCellHeight) // minCellHeight (font + spacing relative)
    }

    func test_multiLineCell_increasesHeight() {
        let table = makeTable(headers: ["H"], rows: [["Line1<br>Line2<br>Line3"]])
        let layout = table.computeLayout()

        let rowH = layout.dataRowHeight(0)
        let fs = UserDefaultsManagement.noteFont.pointSize
        let sp = CGFloat(UserDefaultsManagement.editorLineSpacing)
        let vp = max(2, ceil(sp * 0.75))
        let minH = ceil(fs + sp + vp * 2 + fs * 0.4)
        XCTAssertGreaterThan(rowH, minH) // Should be taller than minCellHeight
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

    func test_totalHeight_alwaysIncludesHandleMargin() {
        let table = makeTable(headers: ["A"], rows: [["1"]])

        // Margins are always reserved to prevent layout shift on hover
        table.focusState = .unfocused
        let unfocused = table.computeLayout()
        XCTAssertGreaterThan(unfocused.totalHeight, unfocused.gridHeight)
        XCTAssertGreaterThan(unfocused.leftMargin, 0)
        XCTAssertGreaterThan(unfocused.topMargin, 0)

        table.focusState = .hovered
        let hovered = table.computeLayout()
        XCTAssertEqual(hovered.totalHeight, unfocused.totalHeight, "Size must not change on hover")
        XCTAssertEqual(hovered.leftMargin, unfocused.leftMargin)
        XCTAssertEqual(hovered.topMargin, unfocused.topMargin)
    }

    // MARK: - Visual Snapshots

    private func snapshotTable(_ table: InlineTableView, filename: String) {
        let layout = table.computeLayout()
        table.frame = NSRect(x: 0, y: 0, width: layout.scrollWidth, height: layout.totalHeight)

        // Put in offscreen window so subviews render
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(table)
        table.layoutSubtreeIfNeeded()
        table.display()

        let width = Int(table.bounds.width)
        let height = Int(table.bounds.height)
        guard width > 0, height > 0 else {
            print("Table has zero size: \(width)x\(height)")
            return
        }

        guard let bitmapRep = table.bitmapImageRepForCachingDisplay(in: table.bounds) else { return }
        table.cacheDisplay(in: table.bounds, to: bitmapRep)

        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let outputPath = "\(outputDir)/\(filename)"
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: outputPath))
            print("Saved: \(outputPath) (\(width)x\(height))")
        }

        table.removeFromSuperview()
    }

    // MARK: - Copy Button

    func test_copyButton_existsOnHover() {
        // The copy button was moved from InlineTableView to the gutter
        // (GutterController.drawIcons). rebuild() now explicitly removes
        // any copy button subview. Verify the button is NOT a subview.
        let table = makeTable(headers: ["A", "B"], rows: [["1", "2"]])
        table.focusState = .hovered
        table.rebuild()

        let buttons = table.subviews.compactMap { $0 as? GlassButton }
        XCTAssertTrue(buttons.isEmpty,
                      "Copy button should not be a subview — it lives in the gutter now")
    }

    func test_copyButton_absentWhenUnfocused() {
        let table = makeTable(headers: ["A", "B"], rows: [["1", "2"]])
        table.focusState = .unfocused
        table.rebuild()

        // Only the scrollView should be a subview, no GlassButtons
        let buttons = table.subviews.compactMap { $0 as? GlassButton }
        XCTAssertTrue(buttons.isEmpty, "No copy button when unfocused")
    }

    // MARK: - Visual Snapshots

    func test_tableWidget_unfocused() {
        let table = makeTable(
            headers: ["Feature", "Status"],
            rows: [["Visual editor", "Yes"], ["Markdown", "Yes"], ["Fold/unfold", "Yes"]],
            containerWidth: 400
        )
        table.focusState = .unfocused
        table.rebuild()
        snapshotTable(table, filename: "table_unfocused.png")
    }

    func test_tableWidget_editing() {
        let table = makeTable(
            headers: ["Feature", "Status"],
            rows: [["Visual editor", "Yes"], ["Markdown", "Yes"], ["Fold/unfold", "Yes"]],
            containerWidth: 400
        )
        table.focusState = .editing
        table.rebuild()
        snapshotTable(table, filename: "table_editing.png")
    }

    func test_tableWidget_hovered() {
        let table = makeTable(
            headers: ["Feature", "Status"],
            rows: [["Visual editor", "Yes"], ["Markdown", "Yes"], ["Fold/unfold", "Yes"]],
            containerWidth: 400
        )
        table.focusState = .hovered
        table.rebuild()
        snapshotTable(table, filename: "table_hovered.png")
    }
}
