//
//  TableStructuralEditingTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-g — Structural editing primitives for tables:
//  insert row / insert column / delete row / delete column / set
//  column alignment. These are the pure `EditingOps` entry points the
//  T2-g hover-handle context menu routes user picks through.
//
//  Rule-3 posture: every test operates on a value-typed
//  `DocumentProjection` built from a parsed table block. No
//  `NSWindow`, no field editor, no synthesized mouse events. The
//  primitive's contract is that it mutates `Block.table` structurally
//  and rebuilds `raw` canonically; these tests assert against the
//  returned `Document` and its serialization.
//

import XCTest
@testable import FSNotes

final class TableStructuralEditingTests: XCTestCase {

    // MARK: - Fixtures

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }

    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// Parse a markdown snippet into a projection. The snippet is
    /// expected to parse to a single `.table` block.
    private func projectTable(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
    }

    /// Pull the `.table` block from the projection at index 0. The
    /// returned `raw` string is the canonical rebuild used by the
    /// serializer (Phase 4.2 dropped the per-block source cache).
    private func table(
        in projection: DocumentProjection,
        at blockIndex: Int = 0
    ) -> (header: [TableCell], alignments: [TableAlignment], rows: [[TableCell]], raw: String)? {
        guard blockIndex < projection.document.blocks.count,
              case .table(let h, let a, let r, _) = projection.document.blocks[blockIndex]
        else { return nil }
        let raw = EditingOps.rebuildTableRaw(header: h, alignments: a, rows: r)
        return (h, a, r, raw)
    }

    private static let markdown3x2 = """
    | A | B | C |
    | --- | --- | --- |
    | a0 | b0 | c0 |
    | a1 | b1 | c1 |
    """

    // MARK: - insertTableRow

    func test_insertTableRow_atStart_prependsEmptyBodyRow() throws {
        let p = projectTable(Self.markdown3x2)
        guard let before = table(in: p) else {
            XCTFail("Fixture did not parse to a .table block")
            return
        }
        XCTAssertEqual(before.rows.count, 2)

        let result = try EditingOps.insertTableRow(
            blockIndex: 0, at: 0, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.rows.count, 3)
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["", "", ""])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["a0", "b0", "c0"])
        XCTAssertEqual(after.rows[2].map { $0.rawText }, ["a1", "b1", "c1"])
        // Header preserved.
        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "C"])
        // Alignments preserved.
        XCTAssertEqual(after.alignments.count, before.alignments.count)
    }

    func test_insertTableRow_inMiddle_inserts() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.insertTableRow(
            blockIndex: 0, at: 1, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.rows.count, 3)
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "b0", "c0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["", "", ""])
        XCTAssertEqual(after.rows[2].map { $0.rawText }, ["a1", "b1", "c1"])
    }

    func test_insertTableRow_atEnd_appends() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.insertTableRow(
            blockIndex: 0, at: 2, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.rows.count, 3)
        XCTAssertEqual(after.rows[2].map { $0.rawText }, ["", "", ""])
    }

    func test_insertTableRow_outOfBounds_throws() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.insertTableRow(blockIndex: 0, at: 99, in: p)
        )
        XCTAssertThrowsError(
            try EditingOps.insertTableRow(blockIndex: 0, at: -1, in: p)
        )
    }

    func test_insertTableRow_nonTableBlock_throws() {
        let doc = Document(blocks: [
            .paragraph(inline: [.text("not a table")])
        ], trailingNewline: true)
        let p = DocumentProjection(
            document: doc, bodyFont: bodyFont(), codeFont: codeFont()
        )
        XCTAssertThrowsError(
            try EditingOps.insertTableRow(blockIndex: 0, at: 0, in: p)
        )
    }

    func test_insertTableRow_preservesAlignments() throws {
        let md = """
        | A | B | C |
        | :--- | :---: | ---: |
        | a0 | b0 | c0 |
        | a1 | b1 | c1 |
        """
        let p = projectTable(md)
        guard let before = table(in: p) else {
            XCTFail("Fixture did not parse to a .table block")
            return
        }
        XCTAssertEqual(before.alignments, [.left, .center, .right])

        let result = try EditingOps.insertTableRow(
            blockIndex: 0, at: 1, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.alignments, [.left, .center, .right])
    }

    // MARK: - insertTableColumn

    func test_insertTableColumn_atStart_prependsColumn() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.insertTableColumn(
            blockIndex: 0, at: 0, alignment: .none, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.header.count, 4)
        XCTAssertEqual(after.header.map { $0.rawText }, ["", "A", "B", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["", "a0", "b0", "c0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["", "a1", "b1", "c1"])
        XCTAssertEqual(after.alignments.count, 4)
    }

    func test_insertTableColumn_inMiddle_inserts() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.insertTableColumn(
            blockIndex: 0, at: 2, alignment: .center, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "b0", "", "c0"])
        XCTAssertEqual(after.alignments[2], .center)
    }

    func test_insertTableColumn_atEnd_appends() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.insertTableColumn(
            blockIndex: 0, at: 3, alignment: .right, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "C", ""])
        XCTAssertEqual(after.alignments.last, .right)
    }

    func test_insertTableColumn_outOfBounds_throws() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.insertTableColumn(blockIndex: 0, at: 99, alignment: .none, in: p)
        )
        XCTAssertThrowsError(
            try EditingOps.insertTableColumn(blockIndex: 0, at: -1, alignment: .none, in: p)
        )
    }

    // MARK: - deleteTableRow

    func test_deleteTableRow_first_removes() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.deleteTableRow(
            blockIndex: 0, at: 0, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.rows.count, 1)
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a1", "b1", "c1"])
        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "C"])
    }

    func test_deleteTableRow_last_removes() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.deleteTableRow(
            blockIndex: 0, at: 1, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.rows.count, 1)
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "b0", "c0"])
    }

    func test_deleteTableRow_lastBodyRow_throws() {
        let md = """
        | A | B |
        | --- | --- |
        | a0 | b0 |
        """
        let p = projectTable(md)
        // Single-body-row table — deleting the only body row is refused.
        XCTAssertThrowsError(
            try EditingOps.deleteTableRow(blockIndex: 0, at: 0, in: p)
        )
    }

    func test_deleteTableRow_outOfBounds_throws() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.deleteTableRow(blockIndex: 0, at: 99, in: p)
        )
    }

    // MARK: - deleteTableColumn

    func test_deleteTableColumn_first_removes() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.deleteTableColumn(
            blockIndex: 0, at: 0, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.header.map { $0.rawText }, ["B", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["b0", "c0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["b1", "c1"])
        XCTAssertEqual(after.alignments.count, 2)
    }

    func test_deleteTableColumn_middle_removes() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.deleteTableColumn(
            blockIndex: 0, at: 1, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "c0"])
    }

    func test_deleteTableColumn_preservesAlignments() throws {
        let md = """
        | A | B | C |
        | :--- | :---: | ---: |
        | a0 | b0 | c0 |
        """
        let p = projectTable(md)
        let result = try EditingOps.deleteTableColumn(
            blockIndex: 0, at: 1, in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        // Deleting middle column removes its `.center` alignment.
        XCTAssertEqual(after.alignments, [.left, .right])
    }

    func test_deleteTableColumn_lastColumn_throws() {
        let md = """
        | A |
        | --- |
        | a0 |
        | a1 |
        """
        let p = projectTable(md)
        XCTAssertThrowsError(
            try EditingOps.deleteTableColumn(blockIndex: 0, at: 0, in: p)
        )
    }

    func test_deleteTableColumn_outOfBounds_throws() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.deleteTableColumn(blockIndex: 0, at: 99, in: p)
        )
    }

    // MARK: - setTableColumnAlignment

    func test_setTableColumnAlignment_roundTripsAllAlignments() throws {
        let p = projectTable(Self.markdown3x2)
        for (col, a) in [
            (0, TableAlignment.left),
            (1, TableAlignment.center),
            (2, TableAlignment.right)
        ] {
            let r = try EditingOps.setTableColumnAlignment(
                blockIndex: 0, col: col, alignment: a, in: p
            )
            guard let after = table(in: r.newProjection) else {
                XCTFail("Post-edit block was not a table")
                return
            }
            XCTAssertEqual(after.alignments[col], a)
            // Header / rows untouched.
            XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "C"])
            XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "b0", "c0"])
            // Serialization reflects alignment marker.
            switch a {
            case .left:
                XCTAssertTrue(after.raw.contains(":---"),
                              "left alignment should produce ':---' marker")
            case .center:
                XCTAssertTrue(after.raw.contains(":---:"),
                              "center alignment should produce ':---:' marker")
            case .right:
                XCTAssertTrue(after.raw.contains("---:"),
                              "right alignment should produce '---:' marker")
            case .none:
                break
            }
        }
    }

    func test_setTableColumnAlignment_outOfBounds_throws() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.setTableColumnAlignment(
                blockIndex: 0, col: 99, alignment: .left, in: p
            )
        )
    }

    // MARK: - Round-trip serialization

    func test_insertTableRow_serializesCanonical() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.insertTableRow(
            blockIndex: 0, at: 0, in: p
        )
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        // The empty row appears between header+separator and the first
        // body row.
        XCTAssertTrue(serialized.contains("|"))
        XCTAssertTrue(serialized.contains("a0"))
        XCTAssertTrue(serialized.contains("a1"))
    }

    func test_deleteTableRow_serializesCanonical() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.deleteTableRow(
            blockIndex: 0, at: 0, in: p
        )
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertFalse(serialized.contains("a0"),
                       "Deleted row content should be gone from the serialization")
        XCTAssertTrue(serialized.contains("a1"))
    }

    // MARK: - Contract

    // MARK: - T2-g.4 regression: insert-column + widths interaction

    func test_T2g4_insertTableColumn_preservesExistingWidths_orResetsToNil() throws {
        // Contract pinned in `EditingOps.insertTableColumn`: inserting
        // a column resets `columnWidths` to nil (the new column has no
        // authoritative width; arbitrarily picking one would distort
        // the layout).
        let p = projectTable(Self.markdown3x2)
        // Seed persisted widths.
        let set = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        guard case .table(_, _, _, let seeded) =
                set.newProjection.document.blocks[0] else {
            XCTFail("Block 0 must be a table after setTableColumnWidths")
            return
        }
        XCTAssertEqual(seeded, [100, 120, 140])

        // Insert a column — widths must reset to nil.
        let afterInsert = try EditingOps.insertTableColumn(
            blockIndex: 0, at: 1, alignment: .none,
            in: set.newProjection
        )
        guard case .table(_, _, _, let afterW) =
                afterInsert.newProjection.document.blocks[0] else {
            XCTFail("Block 0 must still be a table after insertTableColumn")
            return
        }
        XCTAssertNil(
            afterW,
            "insertTableColumn must reset persisted widths to nil"
        )
    }

    // MARK: - clearTableRow / clearTableColumn

    func test_clearTableRow_clearsBodyRowContentsOnly() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.clearTableRow(
            blockIndex: 0,
            row: 2,
            in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }

        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "b0", "c0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["", "", ""])
        XCTAssertEqual(after.alignments, [.none, .none, .none])
    }

    func test_clearTableRow_canClearHeaderRow() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.clearTableRow(
            blockIndex: 0,
            row: 0,
            in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }

        XCTAssertEqual(after.header.map { $0.rawText }, ["", "", ""])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "b0", "c0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["a1", "b1", "c1"])
    }

    func test_clearTableColumn_clearsHeaderAndBodyCells() throws {
        let p = projectTable(Self.markdown3x2)
        let result = try EditingOps.clearTableColumn(
            blockIndex: 0,
            col: 1,
            in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }

        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "", "c0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["a1", "", "c1"])
        XCTAssertEqual(after.alignments, [.none, .none, .none])
    }

    func test_clearTableRowAndColumn_outOfBounds_throw() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.clearTableRow(blockIndex: 0, row: -1, in: p)
        )
        XCTAssertThrowsError(
            try EditingOps.clearTableRow(blockIndex: 0, row: 3, in: p)
        )
        XCTAssertThrowsError(
            try EditingOps.clearTableColumn(blockIndex: 0, col: -1, in: p)
        )
        XCTAssertThrowsError(
            try EditingOps.clearTableColumn(blockIndex: 0, col: 3, in: p)
        )
    }

    // MARK: - sortTableRows

    func test_sortTableRows_numericColumnAscendingAndDescending() throws {
        let md = """
        | Item | Price |
        | --- | --- |
        | Banana | 2.00 |
        | Cherry | 10.00 |
        | Apple | 1.50 |
        """
        let p = projectTable(md)

        let ascending = try EditingOps.sortTableRows(
            blockIndex: 0,
            byColumn: 1,
            ascending: true,
            in: p
        )
        guard let asc = table(in: ascending.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(
            asc.rows.map { $0[0].rawText },
            ["Apple", "Banana", "Cherry"]
        )

        let descending = try EditingOps.sortTableRows(
            blockIndex: 0,
            byColumn: 1,
            ascending: false,
            in: p
        )
        guard let desc = table(in: descending.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(
            desc.rows.map { $0[0].rawText },
            ["Cherry", "Banana", "Apple"]
        )
    }

    func test_sortTableRows_stringColumnIsStable() throws {
        let md = """
        | Name | Group |
        | --- | --- |
        | b | x |
        | a1 | tie |
        | a2 | tie |
        | c | y |
        """
        let p = projectTable(md)

        let result = try EditingOps.sortTableRows(
            blockIndex: 0,
            byColumn: 1,
            ascending: true,
            in: p
        )
        guard let after = table(in: result.newProjection) else {
            XCTFail("Post-edit block was not a table")
            return
        }
        XCTAssertEqual(
            after.rows.map { $0[0].rawText },
            ["a1", "a2", "b", "c"],
            "equal sort keys should preserve their original order"
        )
    }

    func test_allPrimitives_declareReplaceBlockAction() throws {
        let p = projectTable(Self.markdown3x2)
        let ops: [(String, () throws -> EditResult)] = [
            ("insertRow", { try EditingOps.insertTableRow(blockIndex: 0, at: 0, in: p) }),
            ("insertCol", { try EditingOps.insertTableColumn(blockIndex: 0, at: 0, alignment: .none, in: p) }),
            ("deleteRow", { try EditingOps.deleteTableRow(blockIndex: 0, at: 0, in: p) }),
            ("deleteCol", { try EditingOps.deleteTableColumn(blockIndex: 0, at: 0, in: p) }),
            ("clearRow", { try EditingOps.clearTableRow(blockIndex: 0, row: 1, in: p) }),
            ("clearCol", { try EditingOps.clearTableColumn(blockIndex: 0, col: 0, in: p) }),
            ("sortRows", { try EditingOps.sortTableRows(blockIndex: 0, byColumn: 0, ascending: true, in: p) }),
            ("setAlign",  { try EditingOps.setTableColumnAlignment(blockIndex: 0, col: 0, alignment: .center, in: p) })
        ]
        for (name, op) in ops {
            let r = try op()
            XCTAssertNotNil(r.contract, "\(name): contract must be populated")
            XCTAssertEqual(
                r.contract?.declaredActions,
                [.replaceBlock(at: 0)],
                "\(name): declared action must be .replaceBlock(at: 0)"
            )
        }
    }
}
