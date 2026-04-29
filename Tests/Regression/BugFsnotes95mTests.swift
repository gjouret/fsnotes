//
//  BugFsnotes95mTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-95m (P1):
//  "Last table cell (bottom-right): typing inserts <br> per character —
//   REGRESSION"
//
//  Verifiable property: after typing 'X' into the bottom-right cell of
//  a 2x2 table, the Document's table block at rows[last][last].inline
//  must equal [.text("X")] — no .hardbreak, no .text("<br>"), no extra
//  inline nodes. Pure-fn layer: we read the live editor's projection
//  (Document) without going near rendered storage.
//
//  Bug history: a prior fix substituted '\n' with U+2028 in cell
//  rendering (bug #12, commit 68d262a) so the cell stays one fragment.
//  This bead reports the regression returning specifically in the
//  last cell. Test asserts the cell content matches typed input
//  byte-for-byte, with no '<br>' artefact.
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

    func test_typeInLastCell_doesNotInsertBrTag() {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager else {
            XCTFail("no text layout manager")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Find the last cell's character offset in storage. The cell
        // rendering writes one character per cell (the substituted
        // content), separated by attribute-tagged separators — we
        // navigate via the projection rather than storage geometry.
        guard let projection = harness.editor.documentProjection else {
            XCTFail("no document projection")
            return
        }

        // Locate the table block.
        var tableBlockIdx: Int?
        for (i, block) in projection.document.blocks.enumerated() {
            if case .table = block { tableBlockIdx = i; break }
        }
        guard let tIdx = tableBlockIdx,
              case .table(_, _, let rowsBefore, _) =
                projection.document.blocks[tIdx]
        else {
            XCTFail("no table block in seeded document")
            return
        }

        XCTAssertTrue(rowsBefore.count >= 2, "expected at least 2 data rows")

        // We don't drive a real click here — keyboard placement of the
        // caret in a specific cell goes through a separate path that
        // the fix will need to address. For the *scaffold* we directly
        // mutate the projection through the same EditingOps primitive
        // a working in-cell type call would use, and assert the output
        // is byte-clean. If that path is broken (the bead), the test
        // fails. If it's clean, we still need the §1 bisect-anchor to
        // confirm the live-editor path also doesn't fail (run the
        // harness's `type` after a `clickAt(point:)` once the caret-in-
        // cell click pipeline is reliable — see fsnotes-1ml).
        let lastRow = rowsBefore.count - 1
        let lastCol = rowsBefore[lastRow].count - 1

        let typed: [Inline] = [.text("X")]
        let result: EditResult
        do {
            result = try EditingOps.replaceTableCellInline(
                blockIndex: tIdx,
                at: .body(row: lastRow, col: lastCol),
                inline: typed,
                in: projection
            )
        } catch {
            XCTFail("replaceTableCellInline threw: \(error)")
            return
        }

        guard case .table(_, _, let rowsAfter, _) =
            result.newProjection.document.blocks[tIdx]
        else {
            XCTFail("table block missing after edit")
            return
        }

        let cell = rowsAfter[lastRow][lastCol]
        XCTAssertEqual(
            cell.inline.count, 1,
            "expected single inline node, got \(cell.inline)"
        )
        // Must not contain .hardbreak or a literal '<br>' text run.
        for node in cell.inline {
            switch node {
            case .lineBreak:
                XCTFail("cell contains .lineBreak — regression of bug #12 fix")
            case .text(let s):
                XCTAssertFalse(
                    s.contains("<br>"),
                    "cell text contains literal '<br>' — regression"
                )
                XCTAssertFalse(
                    s.contains("\n"),
                    "cell text contains literal newline — should be sanitized"
                )
            default:
                break
            }
        }
        XCTAssertEqual(cell.inline, typed,
                       "cell content should equal typed input byte-for-byte")
    }
}
