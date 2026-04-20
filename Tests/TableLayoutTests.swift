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

        // Row height for single-line cell should equal the rendered
        // boundingRect.height + top + bottom padding. No additional
        // fudge (no `fontSize * 0.4`, no extra editorLineSpacing on
        // top of `usesFontLeading` which already accounts for leading).
        let font = UserDefaultsManagement.noteFont
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let attrs: [NSAttributedString.Key: Any] = [.font: bold]
        let rendered = NSAttributedString(string: "Header", attributes: attrs)
        let natural = ceil(rendered.boundingRect(
            with: NSSize(width: layout.colWidths[0] - 8,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let vPad = max(2, ceil(CGFloat(UserDefaultsManagement.editorLineSpacing) * 0.75))
        let expected = natural + vPad * 2
        XCTAssertEqual(layout.headerHeight, expected,
                       "Single-line row height must be tight: boundingRect + top + bottom padding, no fudge")
    }

    func test_rowHeight_scalesLinearlyWithLines() {
        // The incremental height of each added line should equal the
        // natural per-line height (no extra fudge baked into the single-
        // line baseline). If minCellHeight is inflated with fontSize*0.4
        // or if wrappedCellHeight double-counts editorLineSpacing, the
        // delta between 1-line and 2-line rows drifts from the true
        // per-line height and the single-line row looks oversized.
        let t1 = makeTable(headers: ["H"], rows: [["One"]])
        let t2 = makeTable(headers: ["H"], rows: [["One<br>Two"]])
        let h1 = t1.computeLayout().dataRowHeight(0)
        let h2 = t2.computeLayout().dataRowHeight(0)

        let font = UserDefaultsManagement.noteFont
        let line = NSAttributedString(string: "One", attributes: [.font: font])
            .boundingRect(with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let perLine = ceil(line)

        XCTAssertEqual(h2 - h1, perLine, accuracy: 1.0,
                       "Adding a line must add exactly one line-height; no fudge on the 1-line baseline")
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
