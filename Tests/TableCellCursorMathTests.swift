//
//  TableCellCursorMathTests.swift
//  FSNotesTests
//
//  Pins the invariants for Return-in-cell line-break placement.
//
//  Table cell editing inserts `Inline.rawHTML("<br>")` on Return. The
//  original design assumed `<br>` rawHTML renders to a
//  single `\n` UTF-16 unit, but the initial implementation of
//  `InlineRenderer.render` emitted rawHTML verbatim, so `<br>` landed
//  in the cell as four literal characters ("<br>"). The cursor-advance
//  math (`oldOffset + 1`) then placed the caret mid-`<br>` literal.
//
//  Fix (T2-f, Batch N+2): `InlineRenderer.render` now special-cases a
//  rawHTML `<br>` tag (case-insensitive, optional self-close) to render
//  as a single `\n`. Serialization and parsing paths are unchanged —
//  corpus notes with `<br>` in cells still round-trip byte-identically
//  through `MarkdownSerializer`. Other rawHTML (spans, divs, comments)
//  continues to render verbatim.
//
//  These tests PIN the post-fix reality: `<br>` = one `\n`.
//
//  Pure-primitive: no NSWindow. Exercises renderer + `EditingOps`
//  directly.
//

import XCTest
@testable import FSNotes

final class TableCellCursorMathTests: XCTestCase {

    private func bodyFont() -> PlatformFont { .systemFont(ofSize: 14) }
    private func codeFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// `Inline.rawHTML("<br>")` renders as a single `\n` (one UTF-16
    /// unit). Case-insensitive and self-close variants are also
    /// accepted. Other rawHTML (non-`<br>`) renders verbatim.
    func test_phase2eT2f_brRender_isSingleNewline() {
        // Canonical lowercase `<br>`.
        let lower = InlineRenderer.render([.rawHTML("<br>")], baseAttributes: [:])
        XCTAssertEqual(lower.string.utf16.count, 1, "<br> must render as a single UTF-16 unit")
        XCTAssertEqual(lower.string, "\n", "<br> must render as a newline")

        // Uppercase and self-close variants also render as `\n`.
        let upper = InlineRenderer.render([.rawHTML("<BR>")], baseAttributes: [:]).string
        XCTAssertEqual(upper, "\n", "<BR> (uppercase) must render as a newline")
        let selfClose = InlineRenderer.render([.rawHTML("<br/>")], baseAttributes: [:]).string
        XCTAssertEqual(selfClose, "\n", "<br/> (self-close) must render as a newline")
        let selfCloseSpaced = InlineRenderer.render([.rawHTML("<br />")], baseAttributes: [:]).string
        XCTAssertEqual(selfCloseSpaced, "\n", "<br /> (self-close with space) must render as a newline")

        // Sanity: non-`<br>` rawHTML still renders verbatim.
        let other = InlineRenderer.render([.rawHTML("<span>")], baseAttributes: [:]).string
        XCTAssertEqual(other, "<span>", "non-<br> rawHTML must still render verbatim")
    }

    /// Inserting a `<br>` rawHTML into a cell increases the cell's
    /// rendered UTF-16 length by exactly **1** (one `\n`). This is the
    /// contract the subview cell editor relies on when committing a
    /// Return keystroke: the cell text view stores `\n`, the converter
    /// turns that `\n` into `.rawHTML("<br>")`, and
    /// `InlineRenderer.render` brings it back to `\n` (1 unit).
    func test_phase2eT2f_brInsert_addsOneUtf16Unit() throws {
        let md = """
        | A |
        |---|
        | hello |
        """
        let doc = MarkdownParser.parse(md)
        let proj = DocumentProjection(
            document: doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )

        let blockIdx = proj.document.blocks.firstIndex { block in
            if case .table = block { return true }
            return false
        }
        guard let blockIdx = blockIdx,
              case let .table(_, _, rows, _) = proj.document.blocks[blockIdx] else {
            XCTFail("Expected a .table block at some index")
            return
        }
        let cellInline = rows[0][0].inline
        let rendered = InlineRenderer.render(cellInline, baseAttributes: [:])
        XCTAssertEqual(rendered.string, "hello")
        let renderedOld = rendered.string.utf16.count

        // Post-edit inline tree: "he" + rawHTML(<br>) + "llo".
        let newInline: [Inline] = [
            .text("he"),
            .rawHTML("<br>"),
            .text("llo")
        ]

        let result = try EditingOps.replaceTableCellInline(
            blockIndex: blockIdx,
            at: .body(row: 0, col: 0),
            inline: newInline,
            in: proj
        )

        guard case let .table(_, _, newRows, _) = result.newProjection.document.blocks[blockIdx] else {
            XCTFail("Post-edit block must still be .table")
            return
        }
        let renderedString = InlineRenderer.render(
            newRows[0][0].inline,
            baseAttributes: [:]
        ).string
        let renderedNew = renderedString.utf16.count

        XCTAssertEqual(
            renderedNew, renderedOld + 1,
            "<br> rawHTML renders as a single `\\n` in the cell, so the rendered length delta must match."
        )
        XCTAssertEqual(
            renderedString, "he\nllo",
            "The cell's rendered string must contain a literal newline between `he` and `llo`."
        )
    }

    /// Serialization round-trip contract: a cell containing a `<br>`
    /// rawHTML inline must serialize back to `<br>` markdown source
    /// (NOT to a `\n`, which would split the table row). This protects
    /// corpus notes that already use `<br>` as a cell line-break from
    /// silent data loss if the renderer change above is ever naively
    /// applied to the serializer too.
    func test_phase2eT2f_brRoundTrip_serializesAsLiteralBrTag() {
        let md = """
        | A |
        |---|
        | hello |
        """
        let doc = MarkdownParser.parse(md)

        // Build a new Document where the body cell has a <br> mid-text.
        guard case let .table(header, alignments, _, _) = doc.blocks[0] else {
            XCTFail("Expected a table block")
            return
        }
        let newRows: [[TableCell]] = [
            [TableCell([
                .text("he"),
                .rawHTML("<br>"),
                .text("llo")
            ])]
        ]
        let newDoc = Document(
            blocks: [.table(header: header, alignments: alignments, rows: newRows, columnWidths: nil)],
            trailingNewline: doc.trailingNewline,
            refDefs: doc.refDefs
        )

        let serialized = MarkdownSerializer.serialize(newDoc)
        XCTAssertTrue(
            serialized.contains("he<br>llo"),
            "Serialized markdown must contain the literal `<br>` tag, not a newline. Got: \(serialized)"
        )
        XCTAssertFalse(
            serialized.contains("he\nllo"),
            "Serialized markdown must NOT embed a `\\n` inside a table row — that would split the row."
        )
    }
}
