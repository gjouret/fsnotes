//
//  TableDragReorderTests.swift
//  FSNotesTests
//
//  Bug #36 regression coverage — drag-and-drop reorder for table
//  rows and columns. Tests the pure helpers + primitives the
//  TableHandleOverlay's drag loop consults.
//

import XCTest
@testable import FSNotes

final class TableDragReorderTests: XCTestCase {

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

    private static let markdown3x3 = """
    | A | B | C |
    | --- | --- | --- |
    | a0 | b0 | c0 |
    | a1 | b1 | c1 |
    | a2 | b2 | c2 |
    """

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

    // MARK: - dropGapIndex

    func test_dropGapIndex_atLeadingEdge_returnsZero() {
        let segments: [CGFloat] = [50, 50, 50]
        XCTAssertEqual(EditingOps.dropGapIndex(segments: segments, cursor: 0), 0)
        XCTAssertEqual(EditingOps.dropGapIndex(segments: segments, cursor: -10), 0)
    }

    func test_dropGapIndex_pastTrailingEdge_returnsCount() {
        let segments: [CGFloat] = [50, 50, 50]
        XCTAssertEqual(EditingOps.dropGapIndex(segments: segments, cursor: 200), 3)
    }

    func test_dropGapIndex_inMiddleOfSegment_returnsNearestGap() {
        let segments: [CGFloat] = [50, 50, 50]
        XCTAssertEqual(EditingOps.dropGapIndex(segments: segments, cursor: 10), 0)
        XCTAssertEqual(EditingOps.dropGapIndex(segments: segments, cursor: 40), 1)
        XCTAssertEqual(EditingOps.dropGapIndex(segments: segments, cursor: 75), 1)
    }

    func test_dropGapIndex_emptySegments_returnsZero() {
        XCTAssertEqual(EditingOps.dropGapIndex(segments: [], cursor: 100), 0)
    }

    // MARK: - moveDestinationIndex

    func test_moveDestinationIndex_gapEqualsSrc_returnsSrc() {
        XCTAssertEqual(EditingOps.moveDestinationIndex(from: 1, gap: 1), 1)
    }

    func test_moveDestinationIndex_gapBeforeSrc_returnsGap() {
        XCTAssertEqual(EditingOps.moveDestinationIndex(from: 2, gap: 0), 0)
        XCTAssertEqual(EditingOps.moveDestinationIndex(from: 2, gap: 1), 1)
    }

    func test_moveDestinationIndex_gapAfterSrc_decrementsByOne() {
        XCTAssertEqual(EditingOps.moveDestinationIndex(from: 0, gap: 2), 1)
        XCTAssertEqual(EditingOps.moveDestinationIndex(from: 1, gap: 3), 2)
    }

    // MARK: - moveTableRow

    func test_moveTableRow_bodyToBody_swapsRows() throws {
        let p = projectTable(Self.markdown3x3)
        let r = try EditingOps.moveTableRow(
            blockIndex: 0, from: 1, to: 3, in: p
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.header.map { $0.rawText }, ["A", "B", "C"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a1", "b1", "c1"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["a2", "b2", "c2"])
        XCTAssertEqual(after.rows[2].map { $0.rawText }, ["a0", "b0", "c0"])
    }

    func test_moveTableRow_headerToBody_promotesNewHeader() throws {
        let p = projectTable(Self.markdown3x3)
        let r = try EditingOps.moveTableRow(
            blockIndex: 0, from: 0, to: 1, in: p
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.header.map { $0.rawText }, ["a0", "b0", "c0"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["A", "B", "C"])
    }

    func test_moveTableRow_noOp_returnsUnchangedProjection() throws {
        let p = projectTable(Self.markdown3x3)
        let r = try EditingOps.moveTableRow(
            blockIndex: 0, from: 2, to: 2, in: p
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["a1", "b1", "c1"])
    }

    func test_moveTableRow_outOfBounds_throws() {
        let p = projectTable(Self.markdown3x3)
        XCTAssertThrowsError(
            try EditingOps.moveTableRow(blockIndex: 0, from: -1, to: 0, in: p)
        )
        XCTAssertThrowsError(
            try EditingOps.moveTableRow(blockIndex: 0, from: 0, to: 99, in: p)
        )
    }

    func test_moveTableRow_preservesAlignmentsAndWidths() throws {
        let md = """
        | A | B | C |
        | :--- | :---: | ---: |
        | a0 | b0 | c0 |
        | a1 | b1 | c1 |
        """
        let p = projectTable(md)
        let withWidths = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        let r = try EditingOps.moveTableRow(
            blockIndex: 0, from: 1, to: 2, in: withWidths.newProjection
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.alignments, [.left, .center, .right])
        XCTAssertEqual(after.widths, [100, 120, 140])
    }

    // MARK: - moveTableColumn

    func test_moveTableColumn_swapsHeaderAndAllRows() throws {
        let p = projectTable(Self.markdown3x3)
        let r = try EditingOps.moveTableColumn(
            blockIndex: 0, from: 0, to: 2, in: p
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.header.map { $0.rawText }, ["B", "C", "A"])
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["b0", "c0", "a0"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["b1", "c1", "a1"])
        XCTAssertEqual(after.rows[2].map { $0.rawText }, ["b2", "c2", "a2"])
    }

    func test_moveTableColumn_carriesAlignmentAndWidth() throws {
        let md = """
        | A | B | C |
        | :--- | :---: | ---: |
        | a0 | b0 | c0 |
        | a1 | b1 | c1 |
        """
        let p = projectTable(md)
        let withWidths = try EditingOps.setTableColumnWidths(
            blockIndex: 0, widths: [100, 120, 140], in: p
        )
        let r = try EditingOps.moveTableColumn(
            blockIndex: 0, from: 0, to: 2,
            in: withWidths.newProjection
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.alignments, [.center, .right, .left])
        XCTAssertEqual(after.widths, [120, 140, 100])
    }

    func test_moveTableColumn_outOfBounds_throws() {
        let p = projectTable(Self.markdown3x3)
        XCTAssertThrowsError(
            try EditingOps.moveTableColumn(blockIndex: 0, from: -1, to: 0, in: p)
        )
        XCTAssertThrowsError(
            try EditingOps.moveTableColumn(blockIndex: 0, from: 0, to: 99, in: p)
        )
    }

    // MARK: - End-to-end

    func test_dragSequence_rowDownToBottom_movesToBottom() throws {
        let p = projectTable(Self.markdown3x3)
        let rowHeights: [CGFloat] = [20, 30, 30, 30]
        let cursorY: CGFloat = 200
        let gap = EditingOps.dropGapIndex(
            segments: rowHeights, cursor: cursorY
        )
        XCTAssertEqual(gap, 4)
        let dst = EditingOps.moveDestinationIndex(from: 1, gap: gap)
        XCTAssertEqual(dst, 3)

        let r = try EditingOps.moveTableRow(
            blockIndex: 0, from: 1, to: dst, in: p
        )
        guard let after = unwrapTable(r.newProjection) else {
            XCTFail("Post-edit block was not a table"); return
        }
        XCTAssertEqual(after.rows[0].map { $0.rawText }, ["a1", "b1", "c1"])
        XCTAssertEqual(after.rows[1].map { $0.rawText }, ["a2", "b2", "c2"])
        XCTAssertEqual(after.rows[2].map { $0.rawText }, ["a0", "b0", "c0"])
    }
}
