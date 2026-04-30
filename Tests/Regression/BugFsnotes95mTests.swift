//
//  BugFsnotes95mTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-95m:
//  bottom-right table-cell typing must not synthesize <br> nodes.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes95mTests: XCTestCase {

    private static let markdown = """
    | A | B |
    | --- | --- |
    | a0 | b0 |
    | a1 |  |
    """

    private static let markdownPopulatedLastCell = """
    | A | B |
    | --- | --- |
    | a0 | b0 |
    | a1 | bb |
    """

    private static let markdownWithFollowingParagraph = """
    | A | B |
    | --- | --- |
    | a0 |  |
    after
    """

    private struct TableContext {
        let harness: EditorHarness
        let blockIndex: Int
        let attachment: TableAttachment
        let lastRow: Int
        let lastCol: Int
    }

    private func makeTableContext(
        markdown: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> TableContext? {
        let harness = EditorHarness(
            markdown: markdown, windowActivation: .keyWindow
        )
        guard let projection = harness.editor.documentProjection,
              let storage = harness.editor.textStorage else {
            XCTFail("editor not initialised", file: file, line: line)
            harness.teardown()
            return nil
        }

        var tableBlockIndex: Int?
        for (idx, block) in projection.document.blocks.enumerated() {
            if case .table = block {
                tableBlockIndex = idx
                break
            }
        }
        guard let blockIndex = tableBlockIndex,
              case .table(_, _, let rows, _) =
                projection.document.blocks[blockIndex],
              !rows.isEmpty,
              blockIndex < projection.blockSpans.count else {
            XCTFail("no table block", file: file, line: line)
            harness.teardown()
            return nil
        }

        let span = projection.blockSpans[blockIndex]
        guard span.location < storage.length,
              let attachment = storage.attribute(
                  .attachment, at: span.location, effectiveRange: nil
              ) as? TableAttachment else {
            XCTFail("no TableAttachment", file: file, line: line)
            harness.teardown()
            return nil
        }

        let lastRow = rows.count - 1
        let lastCol = rows[lastRow].count - 1
        return TableContext(
            harness: harness,
            blockIndex: blockIndex,
            attachment: attachment,
            lastRow: lastRow,
            lastCol: lastCol
        )
    }

    private func replaceBottomRightCell(
        _ text: String,
        in ctx: TableContext
    ) {
        ctx.harness.editor.applyTableCellInPlaceEdit(
            attachment: ctx.attachment,
            cellRow: ctx.lastRow + 1,
            cellCol: ctx.lastCol,
            inline: text.isEmpty ? [] : [.text(text)]
        )
    }

    private func assertBottomRightCell(
        in ctx: TableContext,
        equals expected: [Inline],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let projection = ctx.harness.editor.documentProjection,
              ctx.blockIndex < projection.document.blocks.count,
              case .table(_, _, let rows, _) =
                projection.document.blocks[ctx.blockIndex] else {
            XCTFail("table block missing after edit", file: file, line: line)
            return
        }

        let cell = rows[ctx.lastRow][ctx.lastCol]
        XCTAssertEqual(cell.inline, expected, file: file, line: line)
        for node in cell.inline {
            switch node {
            case .lineBreak:
                XCTFail("cell contains .lineBreak: \(cell.inline)", file: file, line: line)
            case .rawHTML(let s):
                XCTAssertNotEqual(s, "<br>", file: file, line: line)
            case .text(let s):
                XCTAssertFalse(
                    s.contains("<br>") || s.contains("\n") || s.contains("\u{2028}"),
                    "cell text carries break artefact: \(s)",
                    file: file,
                    line: line
                )
            default:
                break
            }
        }
        XCTAssertFalse(
            MarkdownSerializer.serialize(projection.document).contains("<br>"),
            "saved markdown must not contain synthetic <br>",
            file: file,
            line: line
        )
    }

    func test_typeInLastCell_doesNotInsertBrTag() throws {
        let doc = MarkdownParser.parse(Self.markdown)
        let projection = DocumentProjection(
            document: doc,
            bodyFont: NSFont.systemFont(ofSize: 14),
            codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        )
        guard let tableIndex = projection.document.blocks.firstIndex(where: {
            if case .table = $0 { return true }
            return false
        }),
              case .table(_, _, let rowsBefore, _) =
                projection.document.blocks[tableIndex] else {
            XCTFail("no table")
            return
        }

        let lastRow = rowsBefore.count - 1
        let lastCol = rowsBefore[lastRow].count - 1
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: tableIndex,
            at: .body(row: lastRow, col: lastCol),
            inline: [.text("X")],
            in: projection
        )

        guard case .table(_, _, let rowsAfter, _) =
            result.newProjection.document.blocks[tableIndex] else {
            XCTFail("table block missing after edit")
            return
        }
        XCTAssertEqual(rowsAfter[lastRow][lastCol].inline, [.text("X")])
    }

    func test_typeAfterExistingTextInLastCell_doesNotInsertBr() {
        guard let ctx = makeTableContext(markdown: Self.markdownPopulatedLastCell)
        else { return }
        defer { ctx.harness.teardown() }

        replaceBottomRightCell("bbX", in: ctx)
        assertBottomRightCell(in: ctx, equals: [.text("bbX")])
    }

    func test_multipleConsecutiveKeystrokesInLastCell_dontAccumulateBr() {
        guard let ctx = makeTableContext(markdown: Self.markdown) else { return }
        defer { ctx.harness.teardown() }

        var expected = ""
        for ch in ["X", "Y", "Z"] {
            expected += ch
            replaceBottomRightCell(expected, in: ctx)
            assertBottomRightCell(in: ctx, equals: [.text(expected)])
        }
    }

    func test_typeInLastCellBeforeFollowingParagraph_doesNotReadParagraphNewlineAsBr() {
        guard let ctx = makeTableContext(markdown: Self.markdownWithFollowingParagraph)
        else { return }
        defer { ctx.harness.teardown() }

        replaceBottomRightCell("XY", in: ctx)
        assertBottomRightCell(in: ctx, equals: [.text("XY")])
    }

    func test_typeInLastCell_viaSubviewCellEdit_doesNotInsertBr() {
        guard let ctx = makeTableContext(markdown: Self.markdown) else { return }
        defer { ctx.harness.teardown() }

        replaceBottomRightCell("X", in: ctx)
        assertBottomRightCell(in: ctx, equals: [.text("X")])
    }
}
