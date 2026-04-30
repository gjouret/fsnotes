//
//  SubviewTableInPlaceFastPathTests.swift
//  FSNotesTests
//
//  Phase 8 / Subview Tables — fast-path unit tests.
//
//  `EditTextView.tryApplyTableCellInPlace` is the in-place fast path
//  that skips the storage splice for cell-content and within-table
//  structural edits, mutating only the attachment's `block` payload
//  and the projection. It's on the hot path of cell typing and is
//  invariant-A-adjacent — see the comment block at the top of
//  `EditTextView+SubviewTables.swift` for the storage-shape-invariant
//  reasoning.
//
//  Coverage:
//    • Fast path FIRES for `.replaceTableCell` actions on the table.
//    • Fast path FIRES for `.replaceBlock` on a table block.
//    • Fast path does NOT fire for `.modifyInline` on a non-table block.
//    • Fast path does NOT fire when the storage range covers a non-
//      TableAttachment (e.g. a different attachment kind).
//    • Post-conditions: storage's character at the splice range is
//      preserved (1 U+FFFC), attachment object identity preserved,
//      projection advances to `result.newProjection`.
//
//  Phase 11 Slice F.4 — migrated off `makeHarnessWithTable()` factory
//  to `Given.note(markdown:)` + `firstTableBlockIndex` /
//  `firstAttachment(of:)` fixture helpers.
//

import XCTest
import AppKit
@testable import FSNotes

final class SubviewTableInPlaceFastPathTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaultsManagement.useSubviewTables = true
    }

    override func tearDown() {
        UserDefaultsManagement.useSubviewTables = true
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let markdown = """
    # T

    | A | B |
    |---|---|
    | x | y |
    """

    /// Build a `[heading, blankLine, table]` scenario and resolve the
    /// `TableAttachment` produced by the subview-tables path. Returns
    /// nil + `XCTFail` when any step doesn't materialise.
    private func scenarioWithTable(
        file: StaticString = #file, line: UInt = #line
    ) -> (
        scenario: EditorScenario,
        blockIdx: Int,
        attachment: TableAttachment
    )? {
        let scenario = Given.note(markdown: Self.markdown)
        guard let blockIdx = scenario.firstTableBlockIndex() else {
            XCTFail("no .table block in fixture", file: file, line: line)
            return nil
        }
        guard let hit = scenario.firstAttachment(of: TableAttachment.self)
        else {
            XCTFail("no TableAttachment in storage; fixture broken",
                    file: file, line: line)
            return nil
        }
        return (scenario, blockIdx, hit.attachment)
    }

    /// Build an offscreen editor scenario and manually mount a live
    /// table container in the editor's window. This keeps the test on
    /// the same first-responder and fast-path code without relying on
    /// TextKit's key-window provider lifecycle.
    private func mountedScenarioWithTable(
        markdown: String,
        file: StaticString = #file, line: UInt = #line
    ) -> (
        scenario: EditorScenario,
        attachment: TableAttachment,
        container: TableContainerView
    )? {
        let scenario = Given.note(markdown: markdown)
        guard let hit = scenario.firstAttachment(of: TableAttachment.self)
        else {
            XCTFail("no TableAttachment in storage; fixture broken",
                    file: file, line: line)
            return nil
        }
        let container = TableContainerView(
            block: hit.attachment.block,
            containerWidth: scenario.editor.bounds.width
        )
        container.frame = NSRect(
            x: 0,
            y: 0,
            width: scenario.editor.bounds.width,
            height: hit.attachment.bounds.height
        )
        scenario.editor.addSubview(container)
        hit.attachment.liveContainerView = container
        return (scenario, hit.attachment, container)
    }

    // MARK: - Fires for .replaceTableCell

    func test_fastPath_firesFor_replaceTableCell() throws {
        guard let ctx = scenarioWithTable() else { return }
        let scenario = ctx.scenario

        guard let projection = scenario.editor.documentProjection else {
            return XCTFail("no projection")
        }
        // Build an EditResult by running the canonical primitive.
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: ctx.blockIdx,
            at: .header(col: 0),
            inline: [.text("CHANGED")],
            in: projection
        )
        XCTAssertNotNil(
            result.contract,
            "primitive must return a contract for fast path matching"
        )
        let attachmentBefore = ctx.attachment

        let fired = scenario.editor.tryApplyTableCellInPlace(result)
        XCTAssertTrue(fired, "fast path must fire for .replaceTableCell")

        // Attachment object identity preserved.
        let storage = scenario.editor.textStorage!
        let postAttachment = storage.attribute(
            .attachment, at: 0, effectiveRange: nil
        ) ?? storage.attribute(
            .attachment, at: 1, effectiveRange: nil
        ) ?? storage.attribute(
            .attachment, at: 2, effectiveRange: nil
        ) ?? storage.attribute(
            .attachment, at: 3, effectiveRange: nil
        )
        XCTAssertTrue(
            (postAttachment as AnyObject?) === attachmentBefore,
            "attachment object identity broken by fast path"
        )

        // Block payload updated.
        if case .table(let header, _, _, _) = ctx.attachment.block {
            XCTAssertEqual(header[0].rawText, "CHANGED")
        } else {
            XCTFail("attachment.block isn't a table after fast path")
        }

        // Projection advanced.
        guard let newProj = scenario.editor.documentProjection else {
            return XCTFail("projection became nil")
        }
        if case .table(let header, _, _, _) = newProj.document.blocks[ctx.blockIdx] {
            XCTAssertEqual(header[0].rawText, "CHANGED")
        }
    }

    // MARK: - Fires for .replaceBlock on a table

    func test_fastPath_firesFor_replaceBlock_onTable() throws {
        guard let ctx = scenarioWithTable() else { return }
        let scenario = ctx.scenario

        guard let projection = scenario.editor.documentProjection else {
            return XCTFail("no projection")
        }
        // insertTableRow returns a contract with .replaceBlock(at: blockIdx).
        let result = try EditingOps.insertTableRow(
            blockIndex: ctx.blockIdx, at: 1, in: projection
        )
        XCTAssertEqual(
            result.contract?.declaredActions.count, 1,
            "insertTableRow must declare exactly one action"
        )
        if case .replaceBlock(let i) = result.contract!.declaredActions[0] {
            XCTAssertEqual(i, ctx.blockIdx)
        } else {
            return XCTFail(
                "expected .replaceBlock action, got \(String(describing: result.contract!.declaredActions[0]))"
            )
        }

        let fired = scenario.editor.tryApplyTableCellInPlace(result)
        XCTAssertTrue(
            fired,
            "fast path must fire for .replaceBlock on a table block " +
            "(structural-within-table edit, storage shape invariant)"
        )
    }

    // MARK: - Handle edits refresh focused cells

    func test_handleClearColumn_refreshesFocusedCell() {
        let markdown = """
        # T

        | A | B |
        |---|---|
        | keep | stale |
        | keep2 | other |
        """
        guard let ctx = mountedScenarioWithTable(markdown: markdown) else { return }
        guard let focusedCell = ctx.container.cellViewAt(row: 1, col: 1) else {
            return XCTFail("missing focused body cell")
        }
        guard let window = ctx.scenario.editor.window else {
            return XCTFail("missing editor window")
        }

        XCTAssertTrue(window.makeFirstResponder(focusedCell))
        XCTAssertTrue(window.firstResponder === focusedCell)

        ctx.scenario.editor.applyTableClearCells(
            attachment: ctx.attachment,
            target: .column(1)
        )

        XCTAssertTrue(window.firstResponder === ctx.scenario.editor)
        XCTAssertEqual(focusedCell.attributedString().string, "")
        XCTAssertEqual(
            ctx.container.cellViewAt(row: 2, col: 1)?.attributedString().string,
            ""
        )

        guard let blockIdx = ctx.scenario.firstTableBlockIndex(),
              let table = ctx.scenario.tableBlock(at: blockIdx) else {
            return XCTFail("missing table after clear")
        }
        XCTAssertEqual(table.rows[0][1].rawText, "")
        XCTAssertEqual(table.rows[1][1].rawText, "")
    }

    func test_handleSortRows_refreshesFocusedCell() {
        let markdown = """
        # T

        | Item | Qty |
        |---|---|
        | Banana | 2 |
        | Apple | 1 |
        """
        guard let ctx = mountedScenarioWithTable(markdown: markdown) else { return }
        guard let focusedCell = ctx.container.cellViewAt(row: 1, col: 0) else {
            return XCTFail("missing focused body cell")
        }
        guard let window = ctx.scenario.editor.window else {
            return XCTFail("missing editor window")
        }

        XCTAssertTrue(window.makeFirstResponder(focusedCell))
        XCTAssertTrue(window.firstResponder === focusedCell)

        ctx.scenario.editor.applyTableSortRows(
            attachment: ctx.attachment,
            col: 1,
            ascending: true
        )

        XCTAssertTrue(window.firstResponder === ctx.scenario.editor)
        XCTAssertEqual(focusedCell.attributedString().string, "Apple")
        XCTAssertEqual(
            ctx.container.cellViewAt(row: 2, col: 0)?.attributedString().string,
            "Banana"
        )

        guard let blockIdx = ctx.scenario.firstTableBlockIndex(),
              let table = ctx.scenario.tableBlock(at: blockIdx) else {
            return XCTFail("missing table after sort")
        }
        XCTAssertEqual(table.rows.map { $0.map(\.rawText) }, [
            ["Apple", "1"],
            ["Banana", "2"]
        ])
    }

    // MARK: - Does NOT fire for .modifyInline on non-table

    func test_fastPath_doesNotFire_onModifyInline() throws {
        let markdown = """
        # T

        para text
        """
        let scenario = Given.note(markdown: markdown)
        guard let projection = scenario.editor.documentProjection else {
            return XCTFail("no projection")
        }
        // Type a char into the paragraph (block index 1). Find the
        // paragraph's storage offset, insert there.
        let paragraphOffset = projection.blockSpans[1].location
        let result = try EditingOps.insert(
            "X", at: paragraphOffset, in: projection
        )
        let fired = scenario.editor.tryApplyTableCellInPlace(result)
        XCTAssertFalse(
            fired,
            "fast path must NOT fire for .modifyInline on a paragraph block"
        )
    }

    // MARK: - Legacy flag can no longer disable the route

    func test_fastPath_stillFires_whenLegacyFlagSetFalse() throws {
        guard let ctx = scenarioWithTable() else { return }
        let scenario = ctx.scenario
        guard let projection = scenario.editor.documentProjection else {
            return XCTFail("no projection")
        }
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: ctx.blockIdx,
            at: .header(col: 0),
            inline: [.text("X")],
            in: projection
        )
        UserDefaultsManagement.useSubviewTables = false
        defer { UserDefaultsManagement.useSubviewTables = true }
        let fired = scenario.editor.tryApplyTableCellInPlace(result)
        XCTAssertTrue(
            fired,
            "the retired native-table toggle must not disable subview-table editing"
        )
    }
}
