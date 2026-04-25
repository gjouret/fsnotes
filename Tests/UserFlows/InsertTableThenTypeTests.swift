//
//  InsertTableThenTypeTests.swift
//  FSNotesTests
//
//  Phase 11 Slice A — demonstration test for the composable user-flow
//  harness. Captures the bug fixed in commit `c08d3ee`: clicking
//  "Insert Table" then typing must land the typed character inside
//  the new table's top-left cell.
//
//  This test exists primarily to validate the Given / When / Then
//  API surface. The same regression coverage existed pre-Slice-A as
//  `TableCellHitTestTests.test_insertTableThenType_landsInTopLeftCell`
//  (~30 lines of imperative setup); rewritten in the new shape it
//  fits in 6 readable lines, which is the API ergonomic contract
//  Slice A is supposed to deliver.
//

import XCTest
@testable import FSNotes

final class InsertTableThenTypeTests: XCTestCase {

    /// User-flow regression: insert a table via the IBAction, type
    /// "X". The character MUST land inside cell (0, 0) of the new
    /// table — the top-left header cell. Pre-`c08d3ee`, the cursor
    /// stayed at the pre-insert position and "X" landed outside the
    /// table.
    func test_insertTable_thenType_landsInTopLeftCell() {
        Given.note().with(paragraph: "p")
            .insertTable()
            .type("X")
            .Then.cursor.isInCell(row: 0, col: 0)
            .Then.tableContent.cell(0, 0).equals("X")
    }
}
