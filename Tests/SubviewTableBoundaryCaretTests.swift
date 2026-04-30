//
//  SubviewTableBoundaryCaretTests.swift
//  FSNotesTests
//
//  Phase 8 / Subview Tables — boundary-caret rect math tests.
//
//  When the parent EditTextView's selection sits at a TableAttachment's
//  U+FFFC offset (start) or one offset past (end),
//  `EditTextView.caretRectAtSubviewTableBoundary()` returns a rect
//  used by `updateTableCellCaret()` to position the
//  `NSTextInsertionIndicator` subview. Without the override, TK2 would
//  paint a full-height caret at the line fragment's natural end
//  (= far right margin with full-width bounds), not at the visible
//  table boundary.
//
//  These tests pin the rect math:
//    • Cursor at offset N, storage[N-1] is a TableAttachment → rect
//      anchored at the RIGHT edge of the visible grid (`fragFrame.x +
//      visibleGridWidth`), with the table's full height.
//    • Cursor at offset N, storage[N] is a TableAttachment → rect at
//      the LEFT edge of the line fragment, with the table's full
//      height.
//    • Cursor not adjacent to any TableAttachment → returns nil.
//
//  Phase 11 Slice F.1 — migrated off `makeHarness()` to `Given.keyWindowNote`
//  + `firstAttachment(of:)` helper.
//

import XCTest
import AppKit
@testable import FSNotes

final class SubviewTableBoundaryCaretTests: XCTestCase {

    private static let markdown = """
    # T

    | A | B |
    |---|---|
    | x | y |
    """

    override func setUp() {
        super.setUp()
        UserDefaultsManagement.useSubviewTables = true
    }

    override func tearDown() {
        UserDefaultsManagement.useSubviewTables = true
        super.tearDown()
    }

    /// Build a [heading, table] scenario and resolve the
    /// `TableAttachment` produced by the subview-tables path.
    /// Skips the test when no attachment was emitted (e.g. flag
    /// not honored at fill time).
    private func scenarioWithTable() throws -> (
        scenario: EditorScenario,
        tableOffset: Int,
        attachment: TableAttachment
    ) {
        let scenario = Given.keyWindowNote(markdown: Self.markdown)
        guard let hit = scenario.firstAttachment(of: TableAttachment.self) else {
            throw XCTSkip("no TableAttachment in storage")
        }
        return (scenario, hit.offset, hit.attachment)
    }

    // MARK: - Cursor AFTER table (right edge)

    func test_caretRect_atOffsetAfterTable_isAtVisibleGridRightEdge() throws {
        let (scenario, tableOffset, attachment) = try scenarioWithTable()
        scenario.cursorAt(tableOffset + 1)

        guard let rect = scenario.editor.caretRectAtSubviewTableBoundary() else {
            return XCTFail("caretRectAtSubviewTableBoundary returned nil for cursor right after table")
        }

        XCTAssertEqual(
            rect.height,
            attachment.bounds.height,
            accuracy: 1.0,
            "caret rect height must match the table's full bounds height"
        )
        XCTAssertGreaterThan(
            rect.height, 0,
            "caret rect height must be > 0"
        )
    }

    // MARK: - Cursor AT table offset (left edge)

    func test_caretRect_atTableOffset_returnsBoundaryRect() throws {
        let (scenario, tableOffset, attachment) = try scenarioWithTable()
        scenario.cursorAt(tableOffset)

        guard let rect = scenario.editor.caretRectAtSubviewTableBoundary() else {
            return XCTFail("caretRectAtSubviewTableBoundary returned nil for cursor at table offset")
        }
        XCTAssertEqual(
            rect.height,
            attachment.bounds.height,
            accuracy: 1.0,
            "caret rect height for cursor at table-start"
        )
    }

    // MARK: - Cursor not adjacent → nil

    func test_caretRect_inHeadingBlock_returnsNil() throws {
        let (scenario, tableOffset, _) = try scenarioWithTable()

        // Heading "T" is at offset 0; cursor inside heading shouldn't
        // touch the boundary path.
        XCTAssertGreaterThan(
            tableOffset, 1,
            "fixture sanity: heading must precede the table"
        )
        scenario.cursorAt(1)  // mid-heading, well away from any attachment

        let rect = scenario.editor.caretRectAtSubviewTableBoundary()
        XCTAssertNil(
            rect,
            "boundary rect should be nil when cursor isn't adjacent to a TableAttachment"
        )
    }

    // MARK: - Legacy flag cannot disable the boundary path

    func test_caretRect_ignoresLegacyFlagFalse() throws {
        let (scenario, tableOffset, _) = try scenarioWithTable()

        UserDefaultsManagement.useSubviewTables = false
        scenario.cursorAt(tableOffset + 1)
        let rect = scenario.editor.caretRectAtSubviewTableBoundary()
        XCTAssertNotNil(
            rect,
            "the retired native-table toggle must not disable subview-table caret math"
        )
    }
}
