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
//  Rule 3 posture: tests 1–5 drive through the EditorScenario DSL
//  (which routes typing through `handleEditViaBlockModel` the same
//  way NSTextView's delegate chain does) but assert on value-typed
//  snapshots — the `Document` model's blocks array — not on widget
//  state. Test 6 asserts on the fragment's attribute-typed block
//  payload.
//
//  Phase 11 Slice F.2 — migrated off `makeHarness()` factory to
//  `Given.note(markdown:)` + `tableCellOffset` / `tableBlock(at:)`
//  fixture helpers.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableCellEditingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // This suite tests the NATIVE-cell editing path
        // (`TableElement` + `handleTableCellEdit`). If a previous test
        // leaks `useSubviewTables = true` into UserDefaults (it
        // persists across processes), the renderer emits subview
        // attachments here and `TableElement` is never produced —
        // every test in this suite then fails with "No TableElement
        // found" / "Harness setup failed". Force the flag off.
        UserDefaultsManagement.useSubviewTables = false
    }

    // MARK: - Fixtures

    /// 2 columns × 2 body rows. Short distinct cell text so tests can
    /// reason about offsets without ambiguity.
    private static let markdown2x2 = """
    | H0 | H1 |
    | --- | --- |
    | c00 | c01 |
    | c10 | c11 |
    """

    /// Build a scenario seeded with the 2x2 markdown and verify the
    /// TK2 invariants (a `TableElement` is reachable). Returns nil if
    /// no element materialised — every test guards on that and fails
    /// with "Harness setup failed".
    private func makeScenario() -> EditorScenario? {
        let scenario = Given.note(markdown: Self.markdown2x2)
        guard scenario.firstFragmentElement(of: TableElement.self) != nil
        else { return nil }
        return scenario
    }

    // MARK: - 1. Type at END of cell

    func test_T2e_typeAtEndOfCell_updatesInlineTree() throws {
        guard let scenario = makeScenario() else {
            XCTFail("Harness setup failed")
            return
        }

        // The table is the FIRST block in this document; the seed
        // markdown is exactly the table with no preceding content.
        let tableBlockIndex = 0
        guard let before = scenario.tableBlock(at: tableBlockIndex) else {
            XCTFail("Initial table block missing")
            return
        }
        // Body (0,0) was parsed as `"c00"` → one `.text("c00")` inline.
        XCTAssertEqual(before.rows[0][0].rawText, "c00")

        // Park the cursor at the END of body (0,0) and type 'X'.
        guard let cell10Start = scenario.tableCellOffset(row: 1, col: 0)
        else { XCTFail("Cell (1,0) offset unresolved"); return }
        let cell10End = cell10Start + before.rows[0][0].rawText.utf16.count
        scenario.editor.setSelectedRange(NSRange(location: cell10End, length: 0))
        scenario.type("X")

        guard let after = scenario.tableBlock(at: tableBlockIndex) else {
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
        let serialized = MarkdownSerializer.serialize(scenario.harness.document!)
        XCTAssertTrue(
            serialized.contains("c00X"),
            "Serialized markdown should contain the edited cell content: \(serialized)"
        )
    }

    // MARK: - 2. Type at START of cell

    func test_T2e_typeAtStartOfCell_updatesInlineTree() throws {
        guard let scenario = makeScenario() else {
            XCTFail("Harness setup failed")
            return
        }

        let tableBlockIndex = 0
        guard let cell10Start = scenario.tableCellOffset(row: 1, col: 0)
        else { XCTFail("Cell (1,0) offset unresolved"); return }
        scenario.editor.setSelectedRange(NSRange(location: cell10Start, length: 0))
        scenario.type("X")

        guard let after = scenario.tableBlock(at: tableBlockIndex) else {
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
        guard let scenario = makeScenario() else {
            XCTFail("Harness setup failed")
            return
        }

        let tableBlockIndex = 0
        guard let cell10Start = scenario.tableCellOffset(row: 1, col: 0)
        else { XCTFail("Cell (1,0) offset unresolved"); return }
        // "c00" — insert in the middle (offset 2 → after "c0").
        scenario.editor.setSelectedRange(NSRange(location: cell10Start + 2, length: 0))
        scenario.type("X")

        guard let after = scenario.tableBlock(at: tableBlockIndex) else {
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
        guard let scenario = makeScenario() else {
            XCTFail("Harness setup failed")
            return
        }

        let tableBlockIndex = 0
        guard let before = scenario.tableBlock(at: tableBlockIndex) else {
            XCTFail("Initial table block missing")
            return
        }
        // Park cursor after "c0" in cell (1,0).
        guard let cell10Start = scenario.tableCellOffset(row: 1, col: 0)
        else { XCTFail("Cell (1,0) offset unresolved"); return }
        scenario.editor.setSelectedRange(NSRange(location: cell10Start + 2, length: 0))

        // Trigger Return via the same path NSResponder.insertNewline takes
        // — `handleTableNavCommand` routes the cell-internal hard-break
        // primitive (NOT `handleEditViaBlockModel("\n")` which would
        // exit the cell).
        _ = scenario.editor.handleTableNavCommand(
            #selector(NSResponder.insertNewline(_:))
        )

        guard let after = scenario.tableBlock(at: tableBlockIndex) else {
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
        guard let scenario = makeScenario() else {
            XCTFail("Harness setup failed")
            return
        }

        let tableBlockIndex = 0
        guard let before = scenario.tableBlock(at: tableBlockIndex) else {
            XCTFail("Initial table block missing")
            return
        }
        let beforeSerialized = MarkdownSerializer.serialize(scenario.harness.document!)

        // Park cursor at the START of body (1,0). The preceding
        // storage offset is either a U+001F or U+001E separator — a
        // backspace would target (cellStart - 1, length 1), which
        // straddles the cell boundary. The cell primitive can't
        // express this, so it falls through; the fall-through path is
        // `EditingOps.delete(...)` which has no separator-aware apply.
        //
        // Documented behaviour: the edit is a no-op. No data loss,
        // no structural change.
        guard let cell10Start = scenario.tableCellOffset(row: 1, col: 0)
        else { XCTFail("Cell (1,0) offset unresolved"); return }
        scenario.editor.setSelectedRange(NSRange(location: cell10Start, length: 0))
        scenario.pressDelete() // backspace

        guard let after = scenario.tableBlock(at: tableBlockIndex) else {
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
        let afterSerialized = MarkdownSerializer.serialize(scenario.harness.document!)
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
        // center / right / left via the CommonMark separator row.
        let markdown = """
        | A | B | C |
        | :---: | ---: | :--- |
        | a0 | b0 | c0 |
        """
        let scenario = Given.note(markdown: markdown)

        guard let hit = scenario.firstFragmentElement(of: TableElement.self),
              case .table(_, let aligns, _, _) = hit.element.block
        else {
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

}
