//
//  TableColumnWidthsRenderTests.swift
//  FSNotesTests
//
//  Regression test for DEEP1 #B1 — `Block.table.columnWidths` was
//  dropped on every WYSIWYG re-render because the table renderer
//  discarded `columnWidths` when building its attachment payload.
//  Result: drag-resized widths survived the
//  serialize/parse round-trip via the `<!-- fsnotes-col-widths: ... -->`
//  sentinel but were lost on any in-session refill (theme change, mode
//  switch, etc.).
//
//  This test seeds a `Block.table` with non-nil `columnWidths`, runs
//  it through `TableTextRenderer.render`, and asserts the
//  `TableAttachment` payload carries the same widths.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableColumnWidthsRenderTests: XCTestCase {

    private static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    private func makeCell(_ text: String) -> TableCell {
        return TableCell([.text(text)])
    }

    /// `TableTextRenderer.render` with non-nil `columnWidths` carries
    /// the same widths on the emitted TableAttachment payload.
    func test_render_preservesColumnWidthsOnAttachmentBlock() {
        let header = [makeCell("a"), makeCell("b"), makeCell("c")]
        let rows = [[makeCell("1"), makeCell("2"), makeCell("3")]]
        let alignments: [TableAlignment] = [.none, .none, .none]
        let widths: [CGFloat] = [120.5, 80.0, 200.25]

        let attributed = TableTextRenderer.render(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n",
            bodyFont: TableColumnWidthsRenderTests.bodyFont,
            columnWidths: widths
        )
        XCTAssertGreaterThan(attributed.length, 0)

        guard let attachment = attributed.attribute(
            .attachment, at: 0, effectiveRange: nil
        ) as? TableAttachment else {
            XCTFail("missing TableAttachment")
            return
        }
        guard case .table(_, _, _, let resultWidths) = attachment.block else {
            XCTFail("attachment block not a .table case")
            return
        }
        XCTAssertEqual(resultWidths, widths,
                       "columnWidths must round-trip through the render path")
    }

    /// Default-omitted `columnWidths` parameter still yields a
    /// `nil`-widths attachment block so existing call sites that don't
    /// pass widths keep their old behaviour.
    func test_render_defaultsToNilWidths() {
        let header = [makeCell("a"), makeCell("b")]
        let rows = [[makeCell("1"), makeCell("2")]]
        let alignments: [TableAlignment] = [.none, .none]

        let attributed = TableTextRenderer.render(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: "| a | b |\n|---|---|\n| 1 | 2 |\n",
            bodyFont: TableColumnWidthsRenderTests.bodyFont
        )
        guard let attachment = attributed.attribute(
            .attachment, at: 0, effectiveRange: nil
        ) as? TableAttachment else {
            XCTFail("missing TableAttachment")
            return
        }
        guard case .table(_, _, _, let resultWidths) = attachment.block else {
            XCTFail("attachment block not a .table case")
            return
        }
        XCTAssertNil(resultWidths)
    }
}
