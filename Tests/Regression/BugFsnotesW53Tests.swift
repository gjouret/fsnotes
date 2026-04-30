//
//  BugFsnotesW53Tests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-w53 (P3):
//  "Auto right-alignment for numeric/currency table columns"
//
//  When no explicit alignment is set (markdown separator line has
//  no colons), TableGeometry.autoDetectAlignments detects numeric/
//  currency columns → right-align, and short text columns → center.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotesW53Tests: XCTestCase {

    private func parseTable(_ md: String) -> (
        header: [TableCell],
        alignments: [TableAlignment],
        rows: [[TableCell]]
    ) {
        let doc = MarkdownParser.parse(md)
        guard doc.blocks.count == 1,
              case .table(let header, let alignments, let rows, _) = doc.blocks[0]
        else {
            XCTFail("not a table")
            return ([], [], [])
        }
        return (header, alignments, rows)
    }

    private func effectiveAlignments(_ md: String) -> [TableAlignment] {
        let table = parseTable(md)
        return TableGeometry.effectiveAlignments(
            alignments: table.alignments,
            header: table.header,
            rows: table.rows
        )
    }

    private func paragraphAlignment(in view: TableCellTextView) -> NSTextAlignment? {
        guard let storage = view.textStorage,
              storage.length > 0,
              let style = storage.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
              ) as? NSParagraphStyle
        else { return nil }
        return style.alignment
    }

    /// Numeric column with no explicit alignment → auto right-align
    func test_numericColumn_autoRightAlign() {
        let md = """
        | Item | Price |
        | --- | --- |
        | Apple | 1.50 |
        | Banana | 2.00 |
        | Cherry | 3.75 |
        """

        let alignments = effectiveAlignments(md)
        XCTAssertEqual(alignments[0], .none)
        XCTAssertEqual(alignments[1], .right)
    }

    /// Short text column → auto center-align
    func test_shortTextColumn_autoCenter() {
        let md = """
        | A | B |
        | --- | --- |
        | X | Y |
        | Z | W |
        """

        let alignments = effectiveAlignments(md)
        XCTAssertEqual(alignments, [.center, .center])
    }

    /// Mixed column stays left-aligned
    func test_mixedColumn_staysLeft() {
        let md = """
        | Name | Description |
        | --- | --- |
        | Alice | Engineer working on the backend |
        | Bob | Designer |
        """

        let alignments = effectiveAlignments(md)
        XCTAssertEqual(alignments[0], .none)
        XCTAssertEqual(alignments[1], .none)
    }

    /// Explicit alignment should not be overridden
    func test_explicitAlignment_preserved() {
        let md = """
        | Item | Price |
        | :--- | ---: |
        | Apple | 1.50 |
        """

        let doc = MarkdownParser.parse(md)
        guard case .table(_, let alignments, _, _) = doc.blocks[0]
        else { XCTFail("not a table"); return }

        // Column 0 has explicit left (":---"), Column 1 has explicit right ("---:")
        XCTAssertEqual(alignments[0], .left, "Explicit left should be preserved")
        XCTAssertEqual(alignments[1], .right, "Explicit right should be preserved")
    }

    /// Currency symbols detected as numeric
    func test_currencyColumn_detectedAsNumeric() {
        let md = """
        | Item | Cost |
        | --- | --- |
        | A | $10.00 |
        | B | €20.50 |
        | C | £5.99 |
        """

        let alignments = effectiveAlignments(md)
        XCTAssertEqual(alignments[1], .right)
    }

    /// The live editable cell views use the same effective alignments
    /// as TableGeometry, not just the raw markdown separator row.
    func test_containerCellViewsUseAutoDetectedAlignment() {
        let md = """
        | Item | Price |
        | --- | --- |
        | Apple | 1.50 |
        | Banana | 2.00 |
        """

        let doc = MarkdownParser.parse(md)
        guard case .table = doc.blocks[0] else {
            XCTFail("not a table")
            return
        }
        let container = TableContainerView(block: doc.blocks[0], containerWidth: 400)
        guard let price = container.cellViewAt(row: 1, col: 1),
              let item = container.cellViewAt(row: 1, col: 0)
        else {
            XCTFail("missing cell views")
            return
        }

        XCTAssertEqual(paragraphAlignment(in: item), .left)
        XCTAssertEqual(paragraphAlignment(in: price), .right)
    }
}
