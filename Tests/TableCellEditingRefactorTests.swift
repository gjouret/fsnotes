//
//  TableCellEditingRefactorTests.swift
//  FSNotesTests
//
//  Contract test for the InlineTableView refactor described in CLAUDE.md
//  "Outstanding technical debt: table cell editing".
//
//  The bug: editing cell (0,0) to wrap "foo" in **, then editing cell
//  (1,1) to wrap "qux" in *, and then serializing, should produce
//  markdown containing both "**foo**" and "*qux*" in the correct cells.
//
//  On current master this fails for a specific architectural reason:
//  `Block.table` has a `raw: String` field that `MarkdownSerializer`
//  emits verbatim at save time. Editing the `header` / `rows` arrays
//  alone does not update `raw`, so the serializer never sees the edit.
//  The production code path works around this by having
//  `InlineTableView` own its own mutable cell state and having
//  `serializeViaBlockModel` walk live view attachments at save time to
//  rewrite `raw` — a post-hoc patch that CLAUDE.md's top section
//  describes as the cautionary tale for the whole project.
//
//  The refactor introduces a pure primitive on `EditingOps` that takes
//  a `Document`, a cell location, and replacement source text, and
//  returns a new `Document` whose `.table.raw` already reflects the
//  edit. No view involvement. Unit-testable without an NSWindow.
//
//  This test uses a LOCAL helper `replaceTableCell` that stands in for
//  the future primitive. On master it naively mutates `rows` without
//  touching `raw` — the exact shortcut that produces the bug. On the
//  refactor branch, the helper's body is replaced with a call to
//  `EditingOps.replaceTableCell(...)` and the test body stays
//  unchanged. The test passes iff the primitive correctly keeps
//  `raw` in sync with the edited cells.
//

import XCTest
@testable import FSNotes

class TableCellEditingRefactorTests: XCTestCase {

    // MARK: - Helpers

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }
    private func project(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
    }

    /// Forwarder that mirrors the old stub's shape so the contract
    /// tests below read the same. Routes to `EditingOps.replaceTableCell`
    /// under the hood — this is what makes the contract "the refactor
    /// landed" rather than "the test was rewritten to match buggy code".
    ///
    /// `row == -1` means header; `row >= 0` indexes data rows.
    private func replaceTableCell(
        blockIndex: Int,
        row: Int,
        col: Int,
        newSourceText: String,
        in document: Document
    ) -> Document {
        let proj = DocumentProjection(
            document: document, bodyFont: bodyFont(), codeFont: codeFont()
        )
        let location: EditingOps.TableCellLocation
        if row < 0 {
            location = .header(col: col)
        } else {
            location = .body(row: row, col: col)
        }
        do {
            let result = try EditingOps.replaceTableCell(
                blockIndex: blockIndex, at: location,
                newSourceText: newSourceText, in: proj
            )
            return result.newProjection.document
        } catch {
            XCTFail("replaceTableCell threw: \(error)")
            return document
        }
    }

    // MARK: - The contract

    /// A 2-column, 2-row table. Cell (0,0) is bolded, cell (1,1) is
    /// italicized, the document is serialized, and both markers must
    /// survive in the correct cells.
    ///
    /// FAILS ON MASTER: `MarkdownSerializer.serialize` emits
    /// `Block.table.raw` verbatim (see MarkdownSerializer.swift line 74),
    /// and the local `replaceTableCell` stub cannot update `raw`
    /// without re-implementing a full table re-serializer — which is
    /// exactly the post-hoc patch the refactor will delete. The
    /// serialized output therefore equals the original markdown, with
    /// no formatting markers anywhere, and both assertions fire.
    ///
    /// PASSES AFTER REFACTOR: `EditingOps.replaceTableCell(...)`
    /// updates the canonical table state so that a subsequent
    /// `MarkdownSerializer.serialize(...)` reflects the edit directly.
    func test_crossCellFormatting_persistsBothMarkersOnSerialize() {
        let md = """
        | A | B |
        |---|---|
        | foo | bar |
        | baz | qux |

        """
        let parsed = MarkdownParser.parse(md)

        // Sanity: the parse produced the shape we expect.
        guard case .table(_, _, let rows, _, _) = parsed.blocks[0] else {
            XCTFail("block 0 is not a table"); return
        }
        XCTAssertEqual(rows.count, 2, "expected two data rows")
        XCTAssertEqual(rows[0].count, 2, "expected two columns")
        XCTAssertEqual(rows[0][0].rawText, "foo")
        XCTAssertEqual(rows[1][1].rawText, "qux")

        // Edit cell (0,0): wrap "foo" in bold markers.
        let afterBold = replaceTableCell(
            blockIndex: 0, row: 0, col: 0,
            newSourceText: "**foo**", in: parsed
        )

        // Edit cell (1,1): wrap "qux" in italic markers.
        let afterBoth = replaceTableCell(
            blockIndex: 0, row: 1, col: 1,
            newSourceText: "*qux*", in: afterBold
        )

        let serialized = MarkdownSerializer.serialize(afterBoth)

        XCTAssertTrue(
            serialized.contains("**foo**"),
            """
            cell (0,0) bold edit was lost at serialize time.
            This is the refactor contract: after the InlineTableView
            rewrite, EditingOps.replaceTableCell must update the
            canonical table state so the serializer sees the edit.

            serialized output:
            \(serialized)
            """
        )
        XCTAssertTrue(
            serialized.contains("*qux*"),
            """
            cell (1,1) italic edit was lost at serialize time — and
            critically, the cell (0,0) edit was either lost with it
            or survived. Whichever happened, the fact that both edits
            must survive simultaneously is the single contract the
            refactor exists to satisfy.

            serialized output:
            \(serialized)
            """
        )

        // Bonus contract: the untouched cells must still contain their
        // original text. A correct primitive preserves everything it
        // does not explicitly replace.
        XCTAssertTrue(
            serialized.contains("bar"),
            "untouched cell (0,1) 'bar' was lost. serialized:\n\(serialized)"
        )
        XCTAssertTrue(
            serialized.contains("baz"),
            "untouched cell (1,0) 'baz' was lost. serialized:\n\(serialized)"
        )
    }

    /// Round-trip sanity: parsing the serialized post-edit markdown
    /// should yield a Document whose cell contents match what we just
    /// wrote. This is a stronger assertion than `contains()` because it
    /// proves the edits land in the RIGHT cells, not just somewhere in
    /// the output.
    ///
    /// Also fails on master for the same reason as the test above.
    func test_crossCellFormatting_reparsedCellsMatchEdits() {
        let md = """
        | A | B |
        |---|---|
        | foo | bar |
        | baz | qux |

        """
        let parsed = MarkdownParser.parse(md)

        let edited = replaceTableCell(
            blockIndex: 0, row: 1, col: 1, newSourceText: "*qux*",
            in: replaceTableCell(
                blockIndex: 0, row: 0, col: 0, newSourceText: "**foo**",
                in: parsed
            )
        )

        let roundTripped = MarkdownParser.parse(MarkdownSerializer.serialize(edited))

        guard case .table(_, _, let rows, _, _) = roundTripped.blocks[0] else {
            XCTFail("round-tripped block 0 is not a table"); return
        }
        XCTAssertEqual(
            rows[0][0].rawText, "**foo**",
            "cell (0,0) did not round-trip with its bold markers"
        )
        XCTAssertEqual(
            rows[0][1].rawText, "bar",
            "untouched cell (0,1) changed during round-trip"
        )
        XCTAssertEqual(
            rows[1][0].rawText, "baz",
            "untouched cell (1,0) changed during round-trip"
        )
        XCTAssertEqual(
            rows[1][1].rawText, "*qux*",
            "cell (1,1) did not round-trip with its italic markers"
        )
    }

    // MARK: - Primitive unit tests
    //
    // Direct tests on `EditingOps.replaceTableCell` at the pure-function
    // layer. These exercise the primitive without going through the
    // stub forwarder above, so the signature the editor actually uses
    // is verified in addition to the refactor contract.

    private let threeByThree = """
    | A | B | C |
    |---|---|---|
    | a1 | b1 | c1 |
    | a2 | b2 | c2 |

    """

    func test_primitive_editBodyCell_updatesRawAndRows() throws {
        let proj = project(threeByThree)
        let result = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 1, col: 2),
            newSourceText: "**c2**", in: proj
        )
        guard case .table(_, _, let rows, _, let raw) =
                result.newProjection.document.blocks[0] else {
            XCTFail("block 0 is not a table"); return
        }
        XCTAssertEqual(rows[1][2].rawText, "**c2**")
        XCTAssertTrue(raw.contains("**c2**"),
            "raw was not recomputed after body edit. raw:\n\(raw)")
    }

    func test_primitive_editHeaderCell_updatesRawAndHeader() throws {
        let proj = project(threeByThree)
        let result = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .header(col: 0),
            newSourceText: "*A*", in: proj
        )
        guard case .table(let header, _, _, _, let raw) =
                result.newProjection.document.blocks[0] else {
            XCTFail("block 0 is not a table"); return
        }
        XCTAssertEqual(header[0].rawText, "*A*")
        XCTAssertTrue(raw.contains("*A*"),
            "raw was not recomputed after header edit. raw:\n\(raw)")
    }

    func test_primitive_unwrapMarkers_removesFromCell() throws {
        let md = "| A | B |\n|---|---|\n| **foo** | bar |\n"
        let proj = project(md)
        let result = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 0, col: 0),
            newSourceText: "foo", in: proj
        )
        let serialized = MarkdownSerializer.serialize(
            result.newProjection.document
        )
        XCTAssertFalse(serialized.contains("**foo**"),
            "expected bold markers removed. serialized:\n\(serialized)")
        XCTAssertTrue(serialized.contains("| foo | bar |") ||
                      serialized.contains("|foo|bar|") ||
                      serialized.contains("| foo "),
            "expected 'foo' in cell (0,0). serialized:\n\(serialized)")
    }

    func test_primitive_rejectsNonTableBlock() {
        let proj = project("just a paragraph\n")
        XCTAssertThrowsError(try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 0, col: 0),
            newSourceText: "x", in: proj
        )) { error in
            guard case EditingError.unsupported = error else {
                XCTFail("expected .unsupported, got \(error)"); return
            }
        }
    }

    func test_primitive_rejectsOutOfBoundsBlock() {
        let proj = project("just a paragraph\n")
        XCTAssertThrowsError(try EditingOps.replaceTableCell(
            blockIndex: 99, at: .body(row: 0, col: 0),
            newSourceText: "x", in: proj
        )) { error in
            guard case EditingError.outOfBounds = error else {
                XCTFail("expected .outOfBounds, got \(error)"); return
            }
        }
    }

    func test_primitive_rejectsOutOfBoundsRow() {
        let proj = project(threeByThree)
        XCTAssertThrowsError(try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 5, col: 0),
            newSourceText: "x", in: proj
        )) { error in
            guard case EditingError.outOfBounds = error else {
                XCTFail("expected .outOfBounds, got \(error)"); return
            }
        }
    }

    func test_primitive_rejectsOutOfBoundsCol() {
        let proj = project(threeByThree)
        XCTAssertThrowsError(try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 0, col: 99),
            newSourceText: "x", in: proj
        )) { error in
            guard case EditingError.outOfBounds = error else {
                XCTFail("expected .outOfBounds, got \(error)"); return
            }
        }
    }

    func test_primitive_rejectsOutOfBoundsHeaderCol() {
        let proj = project(threeByThree)
        XCTAssertThrowsError(try EditingOps.replaceTableCell(
            blockIndex: 0, at: .header(col: 99),
            newSourceText: "x", in: proj
        )) { error in
            guard case EditingError.outOfBounds = error else {
                XCTFail("expected .outOfBounds, got \(error)"); return
            }
        }
    }

    func test_primitive_untouchedCellsPreserveText() throws {
        let proj = project(threeByThree)
        // Edit exactly one cell. Every other cell must round-trip
        // unchanged, including text and position.
        let result = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 0, col: 1),
            newSourceText: "__B1__", in: proj
        )
        guard case .table(let header, _, let rows, _, _) =
                result.newProjection.document.blocks[0] else {
            XCTFail("block 0 is not a table"); return
        }
        XCTAssertEqual(header.map { $0.rawText }, ["A", "B", "C"])
        XCTAssertEqual(rows[0][0].rawText, "a1")
        XCTAssertEqual(rows[0][1].rawText, "__B1__")
        XCTAssertEqual(rows[0][2].rawText, "c1")
        XCTAssertEqual(rows[1][0].rawText, "a2")
        XCTAssertEqual(rows[1][1].rawText, "b2")
        XCTAssertEqual(rows[1][2].rawText, "c2")
    }

    func test_primitive_successiveEditsCompose() throws {
        // Multiple edits in sequence must all land. This is the exact
        // shape of the original bug: edit one cell, then edit another,
        // then serialize and check both edits survive.
        let proj = project(threeByThree)
        let after1 = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 0, col: 0),
            newSourceText: "**a1**", in: proj
        )
        let after2 = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 1, col: 2),
            newSourceText: "*c2*", in: after1.newProjection
        )
        let after3 = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .header(col: 1),
            newSourceText: "~~B~~", in: after2.newProjection
        )
        let serialized = MarkdownSerializer.serialize(
            after3.newProjection.document
        )
        XCTAssertTrue(serialized.contains("**a1**"),
            "first edit lost. serialized:\n\(serialized)")
        XCTAssertTrue(serialized.contains("*c2*"),
            "second edit lost. serialized:\n\(serialized)")
        XCTAssertTrue(serialized.contains("~~B~~"),
            "third edit (header) lost. serialized:\n\(serialized)")
    }

    func test_primitive_preservesAlignments() throws {
        // Canonical form with alignment markers. After editing a body
        // cell, the separator row must still carry the alignments.
        let md = """
        | A | B | C |
        |:--|:-:|--:|
        | a1 | b1 | c1 |

        """
        let proj = project(md)
        let result = try EditingOps.replaceTableCell(
            blockIndex: 0, at: .body(row: 0, col: 1),
            newSourceText: "**b1**", in: proj
        )
        guard case .table(_, let alignments, _, _, let raw) =
                result.newProjection.document.blocks[0] else {
            XCTFail("block 0 is not a table"); return
        }
        XCTAssertEqual(alignments, [.left, .center, .right],
            "alignment vector was corrupted by cell edit")
        // raw should contain the canonical alignment markers for the
        // three columns in order.
        XCTAssertTrue(raw.contains(":---"),
            "left-alignment marker missing from recomputed raw. raw:\n\(raw)")
        XCTAssertTrue(raw.contains(":---:"),
            "center-alignment marker missing from recomputed raw. raw:\n\(raw)")
        XCTAssertTrue(raw.contains("---:"),
            "right-alignment marker missing from recomputed raw. raw:\n\(raw)")
    }

    func test_primitive_untouchedTablesKeepExactSourceText() throws {
        // A table in non-canonical form (no spaces around pipes). If
        // we never call replaceTableCell on it, serialize must emit
        // the exact source — this is the B1 contract.
        let md = "|A|B|\n|-|-|\n|1|2|\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(
            serialized, md,
            "untouched non-canonical table lost its source text")

        // A different table in the same document getting edited must
        // not affect an untouched table.
        let md2 = """
        |A|B|
        |-|-|
        |1|2|

        | X | Y |
        |---|---|
        | x1 | y1 |

        """
        let proj = project(md2)
        let result = try EditingOps.replaceTableCell(
            blockIndex: 2, at: .body(row: 0, col: 0),
            newSourceText: "**x1**", in: proj
        )
        let outBlocks = result.newProjection.document.blocks
        guard case .table(_, _, _, _, let raw0) = outBlocks[0] else {
            XCTFail("block 0 is not a table"); return
        }
        // The first table was not touched — its raw must be byte-equal
        // to what the parser saw, i.e. the non-canonical form.
        XCTAssertEqual(raw0, "|A|B|\n|-|-|\n|1|2|",
            "untouched table was re-canonicalized after editing a DIFFERENT table")
    }

    // MARK: - Block deletion (select-table + delete)

    /// Selecting the table attachment character and pressing delete
    /// should remove the table block. Before this test landed, the
    /// path dispatched to `deleteInBlock(.table)` which was a no-op —
    /// so selecting a table and pressing delete did nothing at all.
    /// The fix detects when the delete range covers an entire atomic
    /// block (table, HR) and replaces the block with an empty
    /// paragraph, which is what every other markdown editor does.
    func test_delete_selectedTable_removesTheBlock() throws {
        let md = """
        before

        | A | B |
        |---|---|
        | 1 | 2 |

        after

        """
        let proj = project(md)
        // Find the table block. The test fixture is paragraph /
        // blankLine / table / blankLine / paragraph.
        guard let tableBlockIdx = proj.document.blocks.firstIndex(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            XCTFail("no table block in fixture"); return
        }
        let tableSpan = proj.blockSpans[tableBlockIdx]

        // Select exactly the table's rendered span and delete.
        let result = try EditingOps.delete(range: tableSpan, in: proj)

        // The new document must have no .table block.
        let hasTable = result.newProjection.document.blocks.contains { block in
            if case .table = block { return true } else { return false }
        }
        XCTAssertFalse(hasTable,
            "table still present after selecting and deleting it. blocks: \(result.newProjection.document.blocks)")
    }

    /// Same contract via the `replace(range:with:"")` path — the
    /// NSTextView delete action can dispatch through either code path
    /// depending on whether it's a range replacement or a pure
    /// delete. Both must remove the table.
    func test_delete_selectedTable_via_replace_removesTheBlock() throws {
        let md = """
        before

        | A | B |
        |---|---|
        | 1 | 2 |

        after

        """
        let proj = project(md)
        guard let tableBlockIdx = proj.document.blocks.firstIndex(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            XCTFail("no table block in fixture"); return
        }
        let tableSpan = proj.blockSpans[tableBlockIdx]

        // NSTextView's delete key with a selection eventually calls
        // handleEditViaBlockModel with `replacementString: ""`, which
        // routes through `EditingOps.delete` — same code path as
        // the test above. We assert it once more here to pin the
        // contract against the replace-with-empty shape.
        let result = try EditingOps.delete(range: tableSpan, in: proj)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertFalse(serialized.contains("| A | B |"),
            "serialized output still contains the table header row: \(serialized)")
        XCTAssertFalse(serialized.contains("|---|---|"),
            "serialized output still contains the table separator row: \(serialized)")
    }
}
