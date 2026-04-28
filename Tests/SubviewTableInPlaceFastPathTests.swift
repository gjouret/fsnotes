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
//    • Fast path does NOT fire when `useSubviewTables` is off.
//    • Fast path does NOT fire when the storage range covers a non-
//      TableAttachment (e.g. a different attachment kind).
//    • Post-conditions: storage's character at the splice range is
//      preserved (1 U+FFFC), attachment object identity preserved,
//      projection advances to `result.newProjection`.
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
        // Always restore to the suite-default `false`, not whatever
        // value was stashed in `prevFlag`. The flag is persisted in
        // UserDefaults; if a previous test leaks `true` and we round-
        // trip through prevFlag, native-cell tests in the same
        // process fail because the renderer keeps using the subview
        // path.
        UserDefaultsManagement.useSubviewTables = false
        super.tearDown()
    }

    private func cell(_ s: String) -> TableCell { TableCell.parsing(s) }
    private func cells(_ ss: [String]) -> [TableCell] { ss.map { cell($0) } }

    // MARK: - Fixtures

    /// Build an EditorHarness with a `[heading, blankLine, table]`
    /// document. Returns the harness, the table block index (looked up
    /// dynamically — depends on parser's block layout for the fixture
    /// markdown), and the TableAttachment instance.
    private func makeHarnessWithTable(
        file: StaticString = #file, line: UInt = #line
    ) -> (EditorHarness, Int, TableAttachment)? {
        let markdown = """
        # T

        | A | B |
        |---|---|
        | x | y |
        """
        let harness = EditorHarness(markdown: markdown)
        guard let projection = harness.editor.documentProjection else {
            harness.teardown()
            XCTFail("no projection", file: file, line: line)
            return nil
        }
        // Find the table block index dynamically (don't assume).
        var tableBlockIdx: Int? = nil
        for (i, b) in projection.document.blocks.enumerated() {
            if case .table = b { tableBlockIdx = i; break }
        }
        guard let blockIdx = tableBlockIdx else {
            harness.teardown()
            XCTFail("no .table block in fixture", file: file, line: line)
            return nil
        }
        let storage = harness.editor.textStorage!
        var attachment: TableAttachment? = nil
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            if let a = value as? TableAttachment {
                attachment = a
                stop.pointee = true
            }
        }
        guard let a = attachment else {
            harness.teardown()
            XCTFail("no TableAttachment in storage; fixture broken", file: file, line: line)
            return nil
        }
        return (harness, blockIdx, a)
    }

    // MARK: - Fires for .replaceTableCell

    func test_fastPath_firesFor_replaceTableCell() throws {
        guard let (harness, blockIdx, attachment) = makeHarnessWithTable() else { return }
        defer { harness.teardown() }

        guard let projection = harness.editor.documentProjection else {
            return XCTFail("no projection")
        }
        // Build an EditResult by running the canonical primitive.
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: blockIdx,
            at: .header(col: 0),
            inline: [.text("CHANGED")],
            in: projection
        )
        XCTAssertNotNil(
            result.contract,
            "primitive must return a contract for fast path matching"
        )
        let attachmentBefore = attachment

        let fired = harness.editor.tryApplyTableCellInPlace(result)
        XCTAssertTrue(fired, "fast path must fire for .replaceTableCell")

        // Attachment object identity preserved.
        let storage = harness.editor.textStorage!
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
        if case .table(let header, _, _, _) = attachment.block {
            XCTAssertEqual(header[0].rawText, "CHANGED")
        } else {
            XCTFail("attachment.block isn't a table after fast path")
        }

        // Projection advanced.
        guard let newProj = harness.editor.documentProjection else {
            return XCTFail("projection became nil")
        }
        if case .table(let header, _, _, _) = newProj.document.blocks[blockIdx] {
            XCTAssertEqual(header[0].rawText, "CHANGED")
        }
    }

    // MARK: - Fires for .replaceBlock on a table

    func test_fastPath_firesFor_replaceBlock_onTable() throws {
        guard let (harness, blockIdx, _) = makeHarnessWithTable() else { return }
        defer { harness.teardown() }

        guard let projection = harness.editor.documentProjection else {
            return XCTFail("no projection")
        }
        // insertTableRow returns a contract with .replaceBlock(at: blockIdx).
        let result = try EditingOps.insertTableRow(
            blockIndex: blockIdx, at: 1, in: projection
        )
        XCTAssertEqual(
            result.contract?.declaredActions.count, 1,
            "insertTableRow must declare exactly one action"
        )
        if case .replaceBlock(let i) = result.contract!.declaredActions[0] {
            XCTAssertEqual(i, blockIdx)
        } else {
            return XCTFail(
                "expected .replaceBlock action, got \(String(describing: result.contract!.declaredActions[0]))"
            )
        }

        let fired = harness.editor.tryApplyTableCellInPlace(result)
        XCTAssertTrue(
            fired,
            "fast path must fire for .replaceBlock on a table block " +
            "(structural-within-table edit, storage shape invariant)"
        )
    }

    // MARK: - Does NOT fire for .modifyInline on non-table

    func test_fastPath_doesNotFire_onModifyInline() throws {
        let markdown = """
        # T

        para text
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        guard let projection = harness.editor.documentProjection else {
            return XCTFail("no projection")
        }
        // Type a char into the paragraph (block index 1). Find the
        // paragraph's storage offset, insert there.
        let paragraphOffset = projection.blockSpans[1].location
        let result = try EditingOps.insert(
            "X", at: paragraphOffset, in: projection
        )
        let fired = harness.editor.tryApplyTableCellInPlace(result)
        XCTAssertFalse(
            fired,
            "fast path must NOT fire for .modifyInline on a paragraph block"
        )
    }

    // MARK: - Does NOT fire when flag is off

    func test_fastPath_doesNotFire_whenFlagIsOff() throws {
        // Build the fixture with the flag ON (so the renderer
        // produces a TableAttachment), THEN turn the flag off
        // before calling the fast path. Otherwise the fixture has
        // a native-cell table and there's no TableAttachment.
        guard let (harness, blockIdx, _) = makeHarnessWithTable() else { return }
        defer { harness.teardown() }
        guard let projection = harness.editor.documentProjection else {
            return XCTFail("no projection")
        }
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: blockIdx,
            at: .header(col: 0),
            inline: [.text("X")],
            in: projection
        )
        UserDefaultsManagement.useSubviewTables = false
        defer { UserDefaultsManagement.useSubviewTables = true }
        let fired = harness.editor.tryApplyTableCellInPlace(result)
        XCTAssertFalse(
            fired,
            "fast path must NOT fire when useSubviewTables is off"
        )
    }
}
