//
//  TableGeometryTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-a — Unit tests for `TableGeometry`, the pure-function
//  column-width / row-height computer that replaces
//  `InlineTableView.contentBasedColumnWidths` +
//  `InlineTableView.rowHeights` (+ `wrappedCellHeight`) for the TK2
//  table rendering path shared by attachments and cell subviews.
//
//  Ported from the geometry subset of `TableLayoutTests`. Since the
//  implementation in `TableGeometry` is a verbatim port of the widget
//  methods, these tests should produce identical pixel-for-pixel
//  results to the widget-driven equivalents.
//
//  Intentionally omitted from this port: tests that exercise widget
//  state (`focusState`, `rebuild`, snapshots, copy button). Those belong
//  with the widget until slice 2e-T2-h deletes it.
//

import XCTest
@testable import FSNotes

class TableGeometryTests: XCTestCase {

    // MARK: - Helpers

    private func cell(_ source: String) -> TableCell {
        return TableCell.parsing(source)
    }

    private func cells(_ sources: [String]) -> [TableCell] {
        return sources.map { cell($0) }
    }

    private func rowsFrom(_ sources: [[String]]) -> [[TableCell]] {
        return sources.map { row in cells(row) }
    }

    private func defaultAlignments(count: Int) -> [TableAlignment] {
        return Array(repeating: TableAlignment.left, count: count)
    }

    private var font: NSFont { UserDefaultsManagement.noteFont }

    private func compute(
        headers: [String],
        rows: [[String]],
        containerWidth: CGFloat = 600
    ) -> TableGeometry.Result {
        let header = cells(headers)
        let body = rowsFrom(rows)
        return TableGeometry.compute(
            header: header,
            rows: body,
            alignments: defaultAlignments(count: header.count),
            containerWidth: containerWidth,
            font: font
        )
    }

    // MARK: - Basic Layout

    func test_2x2_layout() {
        let r = compute(headers: ["A", "B"], rows: [["1", "2"]])
        XCTAssertEqual(r.columnWidths.count, 2)
        XCTAssertEqual(r.rowHeights.count, 2) // header + 1 data row
        XCTAssertGreaterThan(r.columnWidths.reduce(0, +), 0)
        XCTAssertGreaterThan(r.totalHeight, 0)
    }

    func test_singleColumn_layout() {
        let r = compute(headers: ["Header"], rows: [["One"], ["Two"], ["Three"]])
        XCTAssertEqual(r.columnWidths.count, 1)
        XCTAssertEqual(r.rowHeights.count, 4) // header + 3 data rows
    }

    func test_emptyHeader_returnsEmptyGeometry() {
        let r = TableGeometry.compute(
            header: [],
            rows: [],
            alignments: [],
            containerWidth: 400,
            font: font
        )
        XCTAssertTrue(r.columnWidths.isEmpty)
        XCTAssertTrue(r.rowHeights.isEmpty)
        XCTAssertEqual(r.totalHeight, 0)
    }

    // MARK: - Column widths

    func test_columnWidths_respectMinimum() {
        let r = compute(headers: ["A", "B"], rows: [["1", "2"]])
        for w in r.columnWidths {
            XCTAssertGreaterThanOrEqual(w, TableGeometry.minColumnWidth)
        }
    }

    func test_columnWidths_growWithContent() {
        // A column with wider content must end up at least as wide as a
        // column with narrow content (both above the minimum floor).
        let r = compute(
            headers: ["Short", "Much much much much much longer header"],
            rows: [["a", "b"]],
            containerWidth: 2000
        )
        XCTAssertGreaterThanOrEqual(r.columnWidths[1], r.columnWidths[0])
    }

    // MARK: - Auto-wrap

    func test_wideTable_wrapsToFitContainer() {
        let r = compute(
            headers: ["Very long header text here", "Another long header"],
            rows: [["Some wide content that exceeds the container", "More wide content"]],
            containerWidth: 200
        )
        // Auto-wrap: columns shrink so row content rewraps rather than
        // overflowing horizontally. The data row becomes taller than
        // the header row because its cells wrap to more visual lines.
        XCTAssertGreaterThan(r.rowHeights[1], r.rowHeights[0],
            "Data row with long text should be taller than header after wrapping")
    }

    func test_narrowContent_doesNotWrap() {
        // With ample container width and short content, no column is
        // shrunk below its measured width.
        let r1 = compute(headers: ["A", "B"], rows: [["1", "2"]], containerWidth: 800)
        let r2 = compute(headers: ["A", "B"], rows: [["1", "2"]], containerWidth: 2000)
        // Same content → same column widths (no auto-wrap path taken).
        XCTAssertEqual(r1.columnWidths, r2.columnWidths)
    }

    // MARK: - Row Heights

    func test_headerHeight_singleLine_isTight() {
        let r = compute(headers: ["Header"], rows: [["Data"]])
        // Row height for single-line cell should equal the rendered
        // boundingRect.height + top + bottom padding. No additional
        // fudge.
        let font = UserDefaultsManagement.noteFont
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let attrs: [NSAttributedString.Key: Any] = [.font: bold]
        let rendered = NSAttributedString(string: "Header", attributes: attrs)
        let natural = ceil(rendered.boundingRect(
            with: NSSize(width: r.columnWidths[0] - 8,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let vPad = max(2, ceil(CGFloat(UserDefaultsManagement.editorLineSpacing) * 0.75))
        let expected = natural + vPad * 2
        XCTAssertEqual(r.rowHeights[0], expected,
                       "Single-line row height must be tight: boundingRect + top + bottom padding, no fudge")
    }

    func test_rowHeight_scalesLinearlyWithLines() {
        // Adding one line must add exactly one line-height; no fudge on
        // the 1-line baseline.
        let r1 = compute(headers: ["H"], rows: [["One"]])
        let r2 = compute(headers: ["H"], rows: [["One<br>Two"]])
        let h1 = r1.rowHeights[1]
        let h2 = r2.rowHeights[1]

        let font = UserDefaultsManagement.noteFont
        let line = NSAttributedString(string: "One", attributes: [.font: font])
            .boundingRect(with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let perLine = ceil(line)

        XCTAssertEqual(h2 - h1, perLine, accuracy: 1.0,
                       "Adding a line must add exactly one line-height")
    }

    func test_dataRow_atLeastMinHeight() {
        // Even with trivially short content, the data row is at least
        // the one-line minCellHeight (natural + top + bottom padding).
        let r = compute(headers: ["X"], rows: [["y"]])
        XCTAssertGreaterThan(r.rowHeights[1], 0)
        let font = UserDefaultsManagement.noteFont
        let natural = ceil(
            NSAttributedString(string: "X", attributes: [.font: font])
                .boundingRect(
                    with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
        )
        let vPad = max(2, ceil(CGFloat(UserDefaultsManagement.editorLineSpacing) * 0.75))
        let minH = natural + vPad * 2
        XCTAssertGreaterThanOrEqual(r.rowHeights[1], minH)
    }

    // MARK: - Consistency

    func test_totalHeight_equalsSumOfRowHeights() {
        let r = compute(
            headers: ["A", "B"],
            rows: [["1", "2"], ["3", "4"], ["5", "6"]]
        )
        let sumOfHeights = r.rowHeights.reduce(0, +)
        XCTAssertEqual(r.totalHeight, sumOfHeights)
    }

    func test_rowHeightsCount_equalsBodyPlusHeader() {
        let r = compute(
            headers: ["A", "B"],
            rows: [["1", "2"], ["3", "4"], ["5", "6"]]
        )
        XCTAssertEqual(r.rowHeights.count, 4) // 1 header + 3 data
    }

    func test_columnWidthsCount_equalsHeaderCount() {
        let r = compute(
            headers: ["A", "B", "C", "D"],
            rows: [["1", "2", "3", "4"]]
        )
        XCTAssertEqual(r.columnWidths.count, 4)
    }

    // MARK: - Determinism

    func test_compute_isDeterministic() {
        // Same inputs → identical outputs. The function must be pure
        // modulo the `UserDefaultsManagement` reads (which are stable
        // across a single test run).
        let r1 = compute(headers: ["A", "B"], rows: [["hello", "world"]])
        let r2 = compute(headers: ["A", "B"], rows: [["hello", "world"]])
        XCTAssertEqual(r1, r2)
    }

    // MARK: - Inline formatting preservation

    func test_boldFormatting_measuresAsVisibleWidth() {
        // Markdown markers for bold must NOT contribute to measured
        // column width — `InlineRenderer` strips them before measurement.
        // A bold cell and the same plain cell should yield the same
        // column width (bold may be *slightly* wider due to glyph metrics,
        // but within a few px — certainly not the 4 chars of `**` markers).
        let rPlain = compute(
            headers: ["H"], rows: [["word"]], containerWidth: 2000
        )
        let rBold = compute(
            headers: ["H"], rows: [["**word**"]], containerWidth: 2000
        )
        // The marker-containing markdown must not produce a column
        // width measured from the raw markdown string (which would be
        // 4 characters longer). Allow a modest delta for the bold
        // glyph weighting.
        XCTAssertLessThan(
            abs(rBold.columnWidths[0] - rPlain.columnWidths[0]),
            30.0,
            "Bold markdown markers must not inflate measured column width"
        )
    }
}
