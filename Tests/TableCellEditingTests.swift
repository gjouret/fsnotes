//
//  TableCellEditingTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-e — Cell text editing inside a `TableElement`.
//
//  T2-d shipped cursor routing (Tab/Shift-Tab/arrows) but left Return
//  and character inserts as no-ops (a defensive swallow in
//  `handleEditViaBlockModel`). T2-e replaces both with real edits
//  routed through `EditingOps.replaceTableCellInline` — the same
//  primitive the widget path (`InlineTableView`) uses.
//
//  Scope of these tests (one per spec bullet):
//    1. Type a character at the END of a cell → the cell's inline tree
//       gains that character; serialization round-trips to the edited
//       markdown.
//    2. Type a character at the START of a cell → same contract.
//    3. Type a character in the MIDDLE of a cell → same contract.
//    4. Return inside a cell → the cell's inline tree gains a
//       `.rawHTML("<br>")` at that offset. (The cell-line-break
//       convention matches what `InlineRenderer
//       .inlineTreeFromAttributedString` emits for `\n` and what the
//       widget path writes out; no `.lineBreak(.hard)` is produced
//       because there is no such enum case — `Inline.lineBreak(raw:)`
//       exists but renders as `\n` which would corrupt the flat
//       separator-encoded storage.)
//    5. Backspace at cell start → no-op. The documented choice for
//       T2-e (matches the widget path: backspace at the start of a
//       cell does not merge with the previous cell).
//    6. Alignment propagation — a table block with `alignments:
//       [.center, .right, .left]` produces a `TableLayoutFragment`
//       whose backing `TableElement.block` carries those same
//       alignments. This verifies the `.tableAuthoritativeBlock`
//       attribute plumbing added in T2-e (previously the fragment's
//       alignments were always `.none` because the content-storage
//       delegate synthesized a placeholder block from the flat
//       separator text, which has no alignment data).
//
//  Rule 3 posture: tests 1–5 drive through `EditorHarness`
//  (which calls `handleEditViaBlockModel` the same way NSTextView's
//  delegate chain does) but assert on value-typed snapshots — the
//  `Document` model's blocks array — not on widget state. Test 6
//  asserts on the fragment's attribute-typed block payload.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableCellEditingTests: XCTestCase {

    // MARK: - Fixtures

    /// 2 columns × 2 body rows. Short distinct cell text so tests can
    /// reason about offsets without ambiguity.
    private static let markdown2x2 = """
    | H0 | H1 |
    | --- | --- |
    | c00 | c01 |
    | c10 | c11 |
    """

    /// Drive a harness seeded with the 2x2 markdown under flag ON.
    /// Returns nil if the TK2 content-storage invariants aren't met.
    private func makeHarness() -> (
        harness: EditorHarness,
        element: TableElement,
        elementStart: Int,
        offsetFor: (Int, Int) -> Int
    )? {
        FeatureFlag.nativeTableElements = true
        let harness = EditorHarness(markdown: Self.markdown2x2)
        guard let tlm = harness.editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage else {
            harness.teardown()
            return nil
        }
        tlm.ensureLayout(for: tlm.documentRange)
        var found: TableElement?
        var foundStart = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let el = fragment.textElement as? TableElement,
               let range = el.elementRange {
                found = el
                foundStart = cs.offset(
                    from: cs.documentRange.location, to: range.location
                )
                return false
            }
            return true
        }
        guard let element = found else {
            harness.teardown()
            return nil
        }
        let offsetFor: (Int, Int) -> Int = { row, col in
            let local = element.offset(
                forCellAt: (row: row, col: col)
            ) ?? 0
            return foundStart + local
        }
        return (harness, element, foundStart, offsetFor)
    }

    private func restoreFlag() {
        // Phase 2e-T2-f: default is now `true`. Restore to the new
        // default.
        FeatureFlag.nativeTableElements = true
    }

    /// Extract the `Block.table` at the given index from the harness's
    /// current Document.
    private func table(
        at index: Int,
        harness: EditorHarness
    ) -> (header: [TableCell], alignments: [TableAlignment], rows: [[TableCell]])? {
        guard let doc = harness.document,
              index < doc.blocks.count,
              case .table(let h, let a, let r, _) = doc.blocks[index] else {
            return nil
        }
        return (h, a, r)
    }

    // MARK: - 1. Type at END of cell

    func test_T2e_typeAtEndOfCell_updatesInlineTree() throws {
        guard let ctx = makeHarness() else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        // The table is the FIRST block in this document; the harness's
        // seed markdown is exactly the table with no preceding content.
        let tableBlockIndex = 0
        guard let before = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Initial table block missing")
            return
        }
        // Body (0,0) was parsed as `"c00"` → one `.text("c00")` inline.
        XCTAssertEqual(before.rows[0][0].rawText, "c00")

        // Park the cursor at the END of body (0,0) and type 'X'.
        let cell10Start = ctx.offsetFor(1, 0) // body row 0 (display row 1)
        let cell10End = cell10Start + before.rows[0][0].rawText.utf16.count
        harness.editor.setSelectedRange(NSRange(location: cell10End, length: 0))
        harness.type("X")

        guard let after = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Table block vanished after edit")
            return
        }
        XCTAssertEqual(
            after.rows[0][0].rawText, "c00X",
            "Typing 'X' at end of cell should append"
        )
        // Other cells untouched.
        XCTAssertEqual(after.rows[0][1].rawText, before.rows[0][1].rawText)
        XCTAssertEqual(after.rows[1][0].rawText, before.rows[1][0].rawText)
        XCTAssertEqual(after.rows[1][1].rawText, before.rows[1][1].rawText)
        // Header untouched.
        XCTAssertEqual(after.header[0].rawText, before.header[0].rawText)
        XCTAssertEqual(after.header[1].rawText, before.header[1].rawText)

        // Serialization round-trip reflects the edit.
        let serialized = MarkdownSerializer.serialize(harness.document!)
        XCTAssertTrue(
            serialized.contains("c00X"),
            "Serialized markdown should contain the edited cell content: \(serialized)"
        )
    }

    // MARK: - 2. Type at START of cell

    func test_T2e_typeAtStartOfCell_updatesInlineTree() throws {
        guard let ctx = makeHarness() else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        let tableBlockIndex = 0
        let cell10Start = ctx.offsetFor(1, 0)
        harness.editor.setSelectedRange(NSRange(location: cell10Start, length: 0))
        harness.type("X")

        guard let after = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Table block vanished after edit")
            return
        }
        XCTAssertEqual(
            after.rows[0][0].rawText, "Xc00",
            "Typing 'X' at start of cell should prepend"
        )
    }

    // MARK: - 3. Type in MIDDLE of cell

    func test_T2e_typeInMiddleOfCell_updatesInlineTree() throws {
        guard let ctx = makeHarness() else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        let tableBlockIndex = 0
        let cell10Start = ctx.offsetFor(1, 0)
        // "c00" — insert in the middle (offset 2 → after "c0").
        harness.editor.setSelectedRange(NSRange(location: cell10Start + 2, length: 0))
        harness.type("X")

        guard let after = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Table block vanished after edit")
            return
        }
        XCTAssertEqual(
            after.rows[0][0].rawText, "c0X0",
            "Typing 'X' in middle of 'c00' should produce 'c0X0'"
        )
    }

    // MARK: - 4. Return inside a cell → hard break

    func test_T2e_returnInsideCell_insertsHardBreak() throws {
        guard let ctx = makeHarness() else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        let tableBlockIndex = 0
        guard let before = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Initial table block missing")
            return
        }
        // Park cursor after "c0" in cell (1,0).
        let cell10Start = ctx.offsetFor(1, 0)
        harness.editor.setSelectedRange(NSRange(location: cell10Start + 2, length: 0))

        // Trigger Return via the same path NSResponder.insertNewline takes.
        _ = harness.editor.handleTableNavCommand(
            #selector(NSResponder.insertNewline(_:))
        )

        guard let after = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Table block vanished after Return")
            return
        }

        // The edited cell's inline tree must contain a `.rawHTML("<br>")`
        // node between the split text. Flatten the cell's inline tree
        // and assert a `<br>` appears in the sequence.
        let inline = after.rows[0][0].inline
        XCTAssertTrue(
            inline.contains(where: { node in
                if case .rawHTML(let s) = node, s == "<br>" { return true }
                return false
            }),
            "Expected `.rawHTML(\"<br>\")` in cell inline tree after Return; got \(inline)"
        )
        // Block count unchanged — the edit stays inside the same table.
        XCTAssertEqual(
            before.header.count, after.header.count,
            "Header column count must not change on cell-internal Return"
        )
        XCTAssertEqual(
            before.rows.count, after.rows.count,
            "Body row count must not change on cell-internal Return"
        )
    }

    // MARK: - 5. Backspace at cell start → no-op

    func test_T2e_backspaceAtCellStart_isNoOp() throws {
        guard let ctx = makeHarness() else {
            XCTFail("Harness setup failed")
            return
        }
        let harness = ctx.harness
        defer {
            harness.teardown()
            restoreFlag()
        }

        let tableBlockIndex = 0
        guard let before = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Initial table block missing")
            return
        }
        let beforeSerialized = MarkdownSerializer.serialize(harness.document!)

        // Park cursor at the START of body (1,0). The preceding
        // storage offset is either a U+001F or U+001E separator — a
        // backspace would target (cellStart - 1, length 1), which
        // straddles the cell boundary. The cell primitive can't
        // express this, so it falls through; the fall-through path is
        // `EditingOps.delete(...)` which has no separator-aware apply.
        //
        // Documented behaviour: the edit is a no-op. No data loss,
        // no structural change.
        let cell10Start = ctx.offsetFor(1, 0)
        harness.editor.setSelectedRange(NSRange(location: cell10Start, length: 0))
        harness.pressDelete() // backspace

        guard let after = table(at: tableBlockIndex, harness: harness) else {
            XCTFail("Table block vanished after backspace")
            return
        }
        // All cells byte-identical to before.
        XCTAssertEqual(after.header[0].rawText, before.header[0].rawText)
        XCTAssertEqual(after.header[1].rawText, before.header[1].rawText)
        XCTAssertEqual(after.rows[0][0].rawText, before.rows[0][0].rawText)
        XCTAssertEqual(after.rows[0][1].rawText, before.rows[0][1].rawText)
        XCTAssertEqual(after.rows[1][0].rawText, before.rows[1][0].rawText)
        XCTAssertEqual(after.rows[1][1].rawText, before.rows[1][1].rawText)
        // Document-level round-trip unchanged.
        let afterSerialized = MarkdownSerializer.serialize(harness.document!)
        XCTAssertEqual(
            beforeSerialized, afterSerialized,
            "Backspace at cell start must not change the Document"
        )
    }

    // MARK: - 6. Alignment propagation

    /// A table with explicit `:---:` / `---:` / `:---` alignment markers
    /// in the source markdown must produce a `TableLayoutFragment`
    /// whose backing `TableElement.block` carries the same alignments.
    /// Before T2-e, the delegate synthesized a placeholder block from
    /// the flat separator-encoded string and defaulted alignments to
    /// `.none` (aka `.left` after mapping) — the fragment's grid
    /// painted left-aligned regardless of the source markdown.
    ///
    /// T2-e threads the authoritative block via the
    /// `.tableAuthoritativeBlock` attribute, so this test pins the
    /// end-to-end plumbing: source markdown → TableTextRenderer →
    /// attribute → delegate → TableElement → fragment.
    func test_T2e_alignmentsPropagateToFragment() throws {
        FeatureFlag.nativeTableElements = true
        defer { restoreFlag() }

        // center / right / left via the CommonMark separator row.
        let markdown = """
        | A | B | C |
        | :---: | ---: | :--- |
        | a0 | b0 | c0 |
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager else {
            XCTFail("No textLayoutManager")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        var fragmentAlignments: [TableAlignment]?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let el = fragment.textElement as? TableElement,
               case .table(_, let aligns, _, _) = el.block {
                fragmentAlignments = aligns
                return false
            }
            return true
        }

        guard let aligns = fragmentAlignments else {
            XCTFail("No TableElement found")
            return
        }
        XCTAssertEqual(
            aligns, [.center, .right, .left],
            "TableElement.block.alignments must reflect the source " +
            "markdown's alignment row (T2-e threads the auth block " +
            "through the .tableAuthoritativeBlock attribute)."
        )
    }

    // MARK: - 7. Flag-off: no TableElement, no tableAuthoritativeBlock

    /// Invariant: with the flag OFF (legacy path, retained for A/B
    /// coverage until T2-h), storage must contain zero
    /// `.tableAuthoritativeBlock` attributes and no `TableElement`
    /// fragments. Confirms T2-e changes are entirely flag-gated — the
    /// widget path remains byte-identical under flag-off.
    func test_T2e_flagOff_noAuthoritativeBlockAttribute() throws {
        FeatureFlag.nativeTableElements = false
        // Phase 2e-T2-f: default is now `true`. Restore to default on
        // exit so subsequent tests see the new shipping behaviour.
        defer { FeatureFlag.nativeTableElements = true }

        let harness = EditorHarness(markdown: Self.markdown2x2)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("No textStorage")
            return
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        var sawAuth = false
        storage.enumerateAttribute(
            .tableAuthoritativeBlock, in: fullRange, options: []
        ) { value, _, _ in
            if value != nil { sawAuth = true }
        }
        XCTAssertFalse(
            sawAuth,
            "Flag-off storage must carry no .tableAuthoritativeBlock " +
            "attributes (T2-e is flag-gated)"
        )

        // And the flag-off path must produce no TableElement fragments.
        if let tlm = harness.editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            var sawElement = false
            tlm.enumerateTextLayoutFragments(
                from: tlm.documentRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                if fragment.textElement is TableElement {
                    sawElement = true
                    return false
                }
                return true
            }
            XCTAssertFalse(
                sawElement,
                "Flag-off storage must produce zero TableElement fragments"
            )
        }
    }
}
