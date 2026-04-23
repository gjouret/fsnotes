//
//  TableCellCursorMathTests.swift
//  FSNotesTests
//
//  Pins the invariants called out at `EditTextView+BlockModel.swift:1900`
//  and documents a latent bug in T2-e's Return-in-cell handler that this
//  test suite surfaced:
//
//    T2-e's `handleTableCellEdit` inserts `Inline.rawHTML("<br>")` on
//    Return. Its design comment (EditTextView+BlockModel.swift:1902-1906)
//    assumes `<br>` rawHTML renders to a single `\n` UTF-16 unit, so the
//    cursor advance from `newCellLocalOffset = oldOffset + 1` matches the
//    stored length delta. In reality `InlineRenderer.render` emits
//    rawHTML verbatim, so `<br>` lands in the cell as four literal
//    characters ("<br>"). Cell length increases by 4, cursor placed at
//    `oldOffset + 1`, and the clamp at :1917 silently lands the cursor
//    mid-`<br>` literal.
//
//  These tests PIN the current rendering reality (rawHTML is verbatim)
//  so any future fix — either switching the handler to `.lineBreak` /
//  `.softBreak`, or teaching `InlineRenderer` to decode `<br>` specially
//  — is accompanied by a test-suite update that makes the intent
//  explicit.
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

    /// Reality check: `Inline.rawHTML("<br>")` renders as the literal
    /// four-character string `"<br>"`, NOT `"\n"`. The T2-e design
    /// comment at `EditTextView+BlockModel.swift:1902-1906` should be
    /// reconciled with this — either the handler switches to
    /// `Inline.lineBreak` / `Inline.softBreak` or the renderer grows a
    /// `<br>` → `\n` special-case. Tracked for Phase 2e T2-f follow-up.
    func test_phase2eT2e_brRender_isLiteralFourChars() {
        let tree: [Inline] = [.rawHTML("<br>")]
        let rendered = InlineRenderer.render(tree, baseAttributes: [:])
        XCTAssertEqual(
            rendered.string.utf16.count, 4,
            "rawHTML renders verbatim. If this ever becomes 1, update handleTableCellEdit's `replacement == \"\\n\" ? +1 : +N` math and delete this test."
        )
        XCTAssertEqual(
            rendered.string, "<br>",
            "rawHTML stays as raw text in the rendered string; the converter inverse shape is InlineRenderer.inlineTreeFromAttributedString turning `\\n` back into `.rawHTML(<br>)`, but forward rendering is literal."
        )
    }

    /// Inserting a `<br>` rawHTML into a cell increases the cell's
    /// rendered UTF-16 length by exactly **4** today — NOT by 1.
    /// `EditTextView+BlockModel.swift:1917` compensates via `min()`
    /// clamp, which lands the cursor at `cellStart + oldOffset + 1`
    /// — i.e. between the first two chars of the `<br>` literal.
    /// This is a known T2-e regression. The clamp at :1917 is
    /// load-bearing and a proper fix is tracked for T2-f.
    func test_phase2eT2e_brInsert_addsFourUtf16Units_notOne() throws {
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
        let renderedNew = InlineRenderer.render(
            newRows[0][0].inline,
            baseAttributes: [:]
        ).string.utf16.count

        XCTAssertEqual(
            renderedNew, renderedOld + 4,
            "Today `<br>` rawHTML is a 4-char literal in the rendered string. `handleTableCellEdit` computes `newCellLocalOffset = oldOffset + 1` (assuming a single `\\n` unit) and relies on the `min()` clamp at EditTextView+BlockModel.swift:1917 to prevent out-of-bounds cursor — but the placed cursor is then between the `<` and `b` of the literal `<br>`. Tracked for Phase 2e T2-f follow-up."
        )
    }
}
