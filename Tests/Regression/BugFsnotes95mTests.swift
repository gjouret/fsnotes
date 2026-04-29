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

    private static let markdownPopulatedLastCell = """
    | A | B |
    | --- | --- |
    | a0 | b0 |
    | a1 | bb |
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

    /// Companion variant: last cell starts non-empty and the caret is
    /// parked at end-of-cell. Mirrors the user-reported flow ("type
    /// after existing text in the bottom-right cell").
    func test_typeAfterExistingTextInLastCell_doesNotInsertBr() {
        let harness = EditorHarness(
            markdown: Self.markdownPopulatedLastCell,
            windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager,
              let projection = harness.editor.documentProjection else {
            XCTFail("editor not initialised")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Locate table block + element, find storage offset of the
        // last cell's END.
        var tIdx: Int = -1
        for (i, block) in projection.document.blocks.enumerated() {
            if case .table = block { tIdx = i; break }
        }
        guard tIdx >= 0 else { XCTFail("no table"); return }
        let elementStart = projection.blockSpans[tIdx].location

        var tableElement: TableElement?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location, options: [.ensuresLayout]
        ) { frag in
            if let el = frag.textElement as? TableElement {
                tableElement = el; return false
            }
            return true
        }
        guard let element = tableElement else {
            XCTFail("no table element"); return
        }
        guard case .table(_, _, let rows, _) =
                projection.document.blocks[tIdx]
        else { XCTFail("no rows"); return }
        let lastRow = rows.count - 1
        let lastCol = rows[lastRow].count - 1
        guard let elementCellStart = element.offset(
            forCellAt: (row: lastRow + 1, col: lastCol)
        ) else { XCTFail("no cell offset"); return }
        // Walk forward from cellStart inside the element string until
        // separator or end → that's the cell's END.
        let elString = element.attributedString.string as NSString
        let elLen = elString.length
        var endLocal = elementCellStart
        let cellSep = unichar(TableElement.cellSeparator
            .unicodeScalars.first!.value)
        let rowSep = unichar(TableElement.rowSeparator
            .unicodeScalars.first!.value)
        while endLocal < elLen {
            let ch = elString.character(at: endLocal)
            if ch == cellSep || ch == rowSep { break }
            endLocal += 1
        }
        // Move past the trailing paragraph terminator in the element
        // (if any) — the cursor must be inside the cell, NOT past the
        // newline.
        let cellEndStorage = elementStart + endLocal
        // Park caret AT the cell end (after "bb"), then type 'X'.
        harness.editor.setSelectedRange(
            NSRange(location: cellEndStorage, length: 0)
        )

        harness.type("X")

        guard let liveProjection = harness.editor.documentProjection,
              tIdx < liveProjection.document.blocks.count,
              case .table(_, _, let rowsAfter, _) =
                liveProjection.document.blocks[tIdx]
        else { XCTFail("no rows after"); return }
        let cell = rowsAfter[lastRow][lastCol]
        // Acceptable: [.text("bbX")] (canonical) — single text node.
        // Unacceptable: anything containing .rawHTML("<br>"),
        // .lineBreak, or text with embedded "\n" / U+2028 / "<br>".
        for node in cell.inline {
            if case .lineBreak = node {
                XCTFail("last cell .lineBreak after type; cell=\(cell.inline)")
            }
            if case .rawHTML(let s) = node, s == "<br>" {
                XCTFail("last cell <br> after type; cell=\(cell.inline)")
            }
            if case .text(let s) = node {
                XCTAssertFalse(
                    s.contains("<br>") || s.contains("\n") || s.contains("\u{2028}"),
                    "last cell text break artefact: '\(s)' (cell=\(cell.inline))"
                )
            }
        }
        XCTAssertEqual(cell.inline, [.text("bbX")],
                       "last cell should be [.text(\"bbX\")] — got \(cell.inline)")
    }

    /// Multi-keystroke variant. The bead's wording — "<br> for every
    /// character typed" — suggests the artefact accumulates on each
    /// subsequent keystroke after the cell has any content. This test
    /// types 3 characters in succession and asserts the cell never
    /// grows a `.rawHTML("<br>")` between them.
    func test_multipleConsecutiveKeystrokesInLastCell_dontAccumulateBr() {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager,
              let projection = harness.editor.documentProjection else {
            XCTFail("editor not initialised"); return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        var tIdx: Int = -1
        for (i, block) in projection.document.blocks.enumerated() {
            if case .table = block { tIdx = i; break }
        }
        guard tIdx >= 0 else { XCTFail("no table"); return }
        let elementStart = projection.blockSpans[tIdx].location
        var tableElement: TableElement?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location, options: [.ensuresLayout]
        ) { frag in
            if let el = frag.textElement as? TableElement {
                tableElement = el; return false
            }
            return true
        }
        guard let element = tableElement else {
            XCTFail("no table element"); return
        }
        guard case .table(_, _, let rows, _) =
                projection.document.blocks[tIdx]
        else { XCTFail("no rows"); return }
        let lastRow = rows.count - 1
        let lastCol = rows[lastRow].count - 1
        guard let cellStartLocal = element.offset(
            forCellAt: (row: lastRow + 1, col: lastCol)
        ) else { XCTFail("no offset"); return }
        let cellStartStorage = elementStart + cellStartLocal
        harness.editor.setSelectedRange(
            NSRange(location: cellStartStorage, length: 0)
        )

        // Type three chars; after each, read back and assert clean.
        let chars = ["X", "Y", "Z"]
        var expected = ""
        for ch in chars {
            harness.type(ch)
            expected += ch
            guard let live = harness.editor.documentProjection,
                  tIdx < live.document.blocks.count,
                  case .table(_, _, let rs, _) = live.document.blocks[tIdx]
            else {
                XCTFail("no rows after typing '\(ch)'"); return
            }
            let cell = rs[lastRow][lastCol]
            for node in cell.inline {
                if case .lineBreak = node {
                    XCTFail("after typing '\(ch)': cell .lineBreak; cell=\(cell.inline)")
                }
                if case .rawHTML(let s) = node, s == "<br>" {
                    XCTFail("after typing '\(ch)': cell <br>; cell=\(cell.inline)")
                }
            }
            XCTAssertEqual(cell.inline, [.text(expected)],
                "after typing '\(ch)' expected [.text(\"\(expected)\")] got \(cell.inline)")
        }
    }

    /// Live integration test that exercises the click+type path through
    /// `handleTableCellEdit`. This is the path the bead describes as
    /// regressed: typing a single 'X' into the bottom-right cell yields
    /// `[.text("X"), .rawHTML("<br>")]` — a stray `<br>` per keystroke.
    /// The pure primitive (test above) is clean; this test isolates the
    /// integration layer.
    ///
    /// Hypothesis: the table element's attributedString carries the
    /// paragraph terminator `\n`, and `TableElement.cellRange(forCellAt:)`
    /// scans for the next U+001F / U+001E and falls off the end at
    /// `length` for the last cell — capturing the trailing `\n` in the
    /// returned range. `handleTableCellEdit` reads that range,
    /// `inlineTreeFromAttributedString` then sees the `\n` and emits a
    /// `<br>` after every keystroke.
    func test_typeInLastCell_viaHandleTableCellEdit_doesNotInsertBr() {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage,
              let projection = harness.editor.documentProjection else {
            XCTFail("editor not initialised")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Locate the table block + its element so we can park the caret
        // exactly inside the last cell.
        var tableBlockIdx: Int?
        for (i, block) in projection.document.blocks.enumerated() {
            if case .table = block { tableBlockIdx = i; break }
        }
        guard let tIdx = tableBlockIdx else {
            XCTFail("no table block in seeded document")
            return
        }
        let span = projection.blockSpans[tIdx]
        let elementStart = span.location

        // Walk fragments to find the TableElement. We need the element
        // for `offset(forCellAt:)`.
        var tableElement: TableElement?
        let docRange = tlm.documentRange
        tlm.enumerateTextLayoutFragments(from: docRange.location,
                                          options: [.ensuresLayout]) { frag in
            if let el = frag.textElement as? TableElement {
                tableElement = el
                return false
            }
            return true
        }
        guard let element = tableElement else {
            XCTFail("table element not found in fragments")
            return
        }
        guard case .table(_, _, let rows, _) = projection.document.blocks[tIdx]
        else {
            XCTFail("table block missing rows")
            return
        }
        let lastRow = rows.count - 1
        let lastCol = rows[lastRow].count - 1
        guard let elementLocalCellOffset = element.offset(
            forCellAt: (row: lastRow + 1, col: lastCol)
        ) else {
            // `offset(forCellAt:)` indexes header as row 0 and body
            // rows starting at 1, so we add 1 above. If that fails,
            // the element shape is unexpected.
            XCTFail("offset(forCellAt:) returned nil for last body cell")
            return
        }
        // Element-local -> document-storage offset.
        let cellStorageStart = elementStart + elementLocalCellOffset
        // Last cell of `markdown` is empty; cell content range is empty,
        // so cell-start == cell-end. Park the caret at cellStorageStart.
        harness.editor.setSelectedRange(
            NSRange(location: cellStorageStart, length: 0)
        )
        _ = cs  // touch to silence unused-var warning on some configs

        harness.type("X")

        // Read back the table block from the live projection.
        guard let liveProjection = harness.editor.documentProjection,
              tIdx < liveProjection.document.blocks.count,
              case .table(_, _, let rowsAfter, _) =
                liveProjection.document.blocks[tIdx]
        else {
            XCTFail("table block missing after live edit")
            return
        }
        let cell = rowsAfter[lastRow][lastCol]
        XCTAssertEqual(
            cell.inline, [.text("X")],
            "last cell after typing 'X' should be [.text(\"X\")] — got \(cell.inline)"
        )
        // Defensive specifics for any future regression mode.
        for node in cell.inline {
            switch node {
            case .lineBreak:
                XCTFail("last cell contains .lineBreak after live type")
            case .rawHTML(let s):
                XCTAssertNotEqual(s, "<br>",
                    "last cell contains stray <br> after live type")
            case .text(let s):
                XCTAssertFalse(
                    s.contains("<br>") || s.contains("\n") || s.contains("\u{2028}"),
                    "last cell text carries break artefact after live type: \(s)"
                )
            default:
                break
            }
        }
    }
}
