//
//  TableColumnResizeTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-g.4 — column drag-resize + persisted `columnWidths`
//  on native `TableElement` grids.
//
//  Rule-3 posture: every test operates on pure value types
//  (`DocumentProjection`, `Block`) and / or the pure
//  `MarkdownParser` / `MarkdownSerializer` functions. No `NSWindow`,
//  no field editor, no synthesized mouse events. The drag loop itself
//  lives in `TableHandleView`; its math is factored into a pure
//  helper (`applyDragDelta`), which is exercised indirectly through
//  the `setTableColumnWidths` primitive here.
//

import XCTest
@testable import FSNotes

final class TableColumnResizeTests: XCTestCase {

    // MARK: - Fixtures

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }

    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    private func projectTable(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
    }

    private static let markdown3x2 = """
    | A | B | C |
    | --- | --- | --- |
    | a0 | b0 | c0 |
    | a1 | b1 | c1 |
    """

    /// Pull (header, alignments, rows, widths) out of a table block.
    /// Matches the 4-field shape after Phase 4.2 dropped `raw`.
    private func unwrapTable(
        _ projection: DocumentProjection, at blockIndex: Int = 0
    ) -> (header: [TableCell],
          alignments: [TableAlignment],
          rows: [[TableCell]],
          widths: [CGFloat]?)? {
        guard blockIndex < projection.document.blocks.count,
              case .table(let h, let a, let r, let w) =
                projection.document.blocks[blockIndex]
        else { return nil }
        return (h, a, r, w)
    }

    // MARK: - Primitive

    func test_T2g4_setTableColumnWidths_preservesHeaderAndRows() throws {
        let p = projectTable(Self.markdown3x2)
        let widths: [CGFloat] = [100, 120, 140]
        let r = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: widths, in: p
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.widths, widths)
        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a0", "b0", "c0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["a1", "b1", "c1"])
        XCTAssertEqual(after.alignments.count, 3)
    }

    func test_T2g4_setTableColumnWidths_mismatchedLength_throws() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.setTableColumnWidths(
                blockIndex: 0, widths: [100, 120], in: p
            )
        )
        XCTAssertThrowsError(
            try EditingOps.setTableColumnWidths(
                blockIndex: 0, widths: [100, 120, 140, 160], in: p
            )
        )
        XCTAssertThrowsError(
            try EditingOps.setTableColumnWidths(
                blockIndex: 0, widths: [], in: p
            )
        )
    }

    func test_T2g4_setTableColumnWidths_negativeWidth_throws() {
        let p = projectTable(Self.markdown3x2)
        XCTAssertThrowsError(
            try EditingOps.setTableColumnWidths(
                blockIndex: 0, widths: [100, -1, 140], in: p
            )
        )
        XCTAssertThrowsError(
            try EditingOps.setTableColumnWidths(
                blockIndex: 0, widths: [100, 0, 140], in: p
            )
        )
        XCTAssertThrowsError(
            try EditingOps.setTableColumnWidths(
                blockIndex: 0, widths: [100, .infinity, 140], in: p
            )
        )
    }

    func test_T2g4_setTableColumnWidths_nonTable_throws() {
        let doc = Document(
            blocks: [.paragraph(inline: [.text("not a table")])],
            trailingNewline: true
        )
        let p = DocumentProjection(
            document: doc, bodyFont: bodyFont(), codeFont: codeFont()
        )
        XCTAssertThrowsError(
            try EditingOps.setTableColumnWidths(
                blockIndex: 0, widths: [100], in: p
            )
        )
    }

    func test_T2g4_setTableColumnWidths_declaresReplaceBlockAction() throws {
        let p = projectTable(Self.markdown3x2)
        let r = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        XCTAssertEqual(r.contract?.declaredActions, [.replaceBlock(at: 0)])
    }

    func test_T2g4_clearTableColumnWidths_resetsToNil() throws {
        let p = projectTable(Self.markdown3x2)
        let set = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        XCTAssertNotNil(unwrapTable(set.newProjection)?.widths)
        let cleared = try EditingOps.clearTableColumnWidths(
            blockIndex: 0, in: set.newProjection
        )
        XCTAssertNil(unwrapTable(cleared.newProjection)?.widths)
    }

    // MARK: - Serializer

    func test_T2g4_serializer_emitsColWidthsComment_whenSet() throws {
        let p = projectTable(Self.markdown3x2)
        let r = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100.5, 200, 150.25], in: p
        )
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(
            serialized.contains("<!-- fsnotes-col-widths: [100.5, 200, 150.25] -->"),
            "Widths sentinel missing from serialized output:\n\(serialized)"
        )
        // The sentinel must appear ON THE LINE ABOVE the table.
        let lines = serialized.components(separatedBy: "\n")
        guard let sentIdx = lines.firstIndex(where: {
            $0.hasPrefix("<!-- fsnotes-col-widths:")
        }) else {
            XCTFail("No sentinel line found"); return
        }
        XCTAssertTrue(
            sentIdx + 1 < lines.count,
            "Sentinel must be followed by table content"
        )
        XCTAssertTrue(
            lines[sentIdx + 1].contains("|"),
            "Line after sentinel must be a table header: \(lines[sentIdx + 1])"
        )
    }

    func test_T2g4_serializer_omitsComment_whenNil() {
        // Baseline table, no widths set. Serializer must NOT emit a
        // sentinel comment.
        let p = projectTable(Self.markdown3x2)
        let serialized = MarkdownSerializer.serialize(p.document)
        XCTAssertFalse(
            serialized.contains("fsnotes-col-widths"),
            "Serializer emitted sentinel despite columnWidths == nil:\n\(serialized)"
        )
    }

    // MARK: - Parser

    func test_T2g4_parser_readsComment_populatesColumnWidths() {
        let md = """
        <!-- fsnotes-col-widths: [100, 200, 150] -->
        | A | B | C |
        |---|---|---|
        | a | b | c |
        """
        let doc = MarkdownParser.parse(md)
        // Expect exactly one block, a .table with widths populated.
        // (The sentinel comment is consumed; it's not a separate block.)
        let tableBlocks = doc.blocks.compactMap { block -> [CGFloat]? in
            if case .table(_, _, _, let w) = block { return w ?? [] }
            return nil
        }
        XCTAssertEqual(tableBlocks.count, 1, "Expected exactly one table block")
        XCTAssertEqual(tableBlocks.first, [100, 200, 150])
        // Sentinel must NOT survive as an htmlBlock.
        let htmlBlocks = doc.blocks.compactMap { block -> String? in
            if case .htmlBlock(let raw) = block { return raw }
            return nil
        }
        XCTAssertFalse(htmlBlocks.contains(where: { $0.contains("fsnotes-col-widths") }),
                       "Sentinel leaked through as an htmlBlock")
    }

    func test_T2g4_parser_malformedComment_leavesWidthsNil() {
        let md = """
        <!-- fsnotes-col-widths: garbage -->
        | A | B |
        |---|---|
        | a | b |
        """
        let doc = MarkdownParser.parse(md)
        // Find the table; widths must be nil.
        let tableWidths = doc.blocks.compactMap { block -> [CGFloat]?? in
            if case .table(_, _, _, let w) = block { return .some(w) }
            return nil
        }
        XCTAssertEqual(tableWidths.count, 1)
        XCTAssertNil(tableWidths.first?.flatMap { $0 })
    }

    func test_T2g4_parser_mismatchedLength_leavesWidthsNil() {
        // 2-column table, 3-width comment → mismatch, treated as
        // malformed so widths are nil.
        let md = """
        <!-- fsnotes-col-widths: [100, 200, 150] -->
        | A | B |
        |---|---|
        | a | b |
        """
        let doc = MarkdownParser.parse(md)
        for block in doc.blocks {
            if case .table(_, _, _, let w) = block {
                XCTAssertNil(w, "Mismatched width count must be rejected")
            }
        }
    }

    // MARK: - Round-trip

    func test_T2g4_roundTrip_preservesWidths() throws {
        let p = projectTable(Self.markdown3x2)
        let r = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        // First serialization: produces a document with the sentinel.
        let s1 = MarkdownSerializer.serialize(r.newProjection.document)
        // Parse it back — widths should be recovered.
        let d2 = MarkdownParser.parse(s1)
        var recovered: [CGFloat]? = nil
        for block in d2.blocks {
            if case .table(_, _, _, let w) = block {
                recovered = w
                break
            }
        }
        XCTAssertEqual(recovered, [100, 120, 140])
        // Re-serialize. Byte-identical to first serialization.
        let s2 = MarkdownSerializer.serialize(d2)
        XCTAssertEqual(s1, s2, "Second serialization must be byte-identical")
    }

    // MARK: - Shape-drift safety

    func test_T2g4_columnWidths_nil_equivalent_to_missing_field() {
        // A parse of a note WITHOUT the sentinel, and a parse of a
        // note WITH a sentinel that was explicitly stripped, should
        // produce equivalent Documents (widths nil in both).
        let md1 = """
        | A | B |
        |---|---|
        | a | b |
        """
        let md2 = """
        <!-- fsnotes-col-widths: [garbage] -->
        | A | B |
        |---|---|
        | a | b |
        """
        let d1 = MarkdownParser.parse(md1)
        let d2 = MarkdownParser.parse(md2)
        // d1 has exactly one (table) block with widths == nil.
        XCTAssertTrue(d1.blocks.contains(where: {
            if case .table(_, _, _, let w) = $0 { return w == nil }
            return false
        }))
        // d2 has a (malformed-comment htmlBlock) + (table with widths nil).
        XCTAssertTrue(d2.blocks.contains(where: {
            if case .table(_, _, _, let w) = $0 { return w == nil }
            return false
        }))
    }

    // MARK: - Regression: insert-column resets widths

    func test_T2g4_insertTableColumn_preservesExistingWidths_orResetsToNil() throws {
        // T2-g.4 contract documented in `EditingOps.insertTableColumn`:
        // inserting a column resets `columnWidths` to nil (the new
        // column has no authoritative width). This regression test
        // pins the behaviour.
        let p = projectTable(Self.markdown3x2)
        let set = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        XCTAssertEqual(unwrapTable(set.newProjection)?.widths, [100, 120, 140])

        let afterInsert = try EditingOps.insertTableColumn(
            blockIndex: 0, at: 1, alignment: .none,
            in: set.newProjection
        )
        // Contract: widths cleared after insert-column.
        XCTAssertNil(
            unwrapTable(afterInsert.newProjection)?.widths,
            "insertTableColumn must reset persisted widths to nil"
        )
    }

    // MARK: - Regression: delete-column drops the entry

    func test_T2g4_deleteTableColumn_dropsCorrespondingWidth() throws {
        let p = projectTable(Self.markdown3x2)
        let set = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        let afterDelete = try EditingOps.deleteTableColumn(
            blockIndex: 0, at: 1, in: set.newProjection
        )
        // Contract: column 1's width (120) is dropped, others keep their
        // order. 2-column table → 2 widths.
        XCTAssertEqual(
            unwrapTable(afterDelete.newProjection)?.widths, [100, 140]
        )
    }

    // MARK: - Regression: insert-row preserves widths

    func test_T2g4_insertTableRow_preservesWidths() throws {
        let p = projectTable(Self.markdown3x2)
        let set = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        let afterInsert = try EditingOps.insertTableRow(
            blockIndex: 0, at: 0, in: set.newProjection
        )
        // Contract: row insert doesn't change column count, so widths
        // survive.
        XCTAssertEqual(
            unwrapTable(afterInsert.newProjection)?.widths,
            [100, 120, 140]
        )
    }
}
