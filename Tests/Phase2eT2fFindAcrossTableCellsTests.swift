//
//  Phase2eT2fFindAcrossTableCellsTests.swift
//  FSNotesTests
//
//  Bug #60 verification - find across table cells.
//
//  Pins the end-to-end Bug #60 invariant for the subview-table route:
//  searching for text inside table cells succeeds even though the
//  parent NSTextStorage contains only one U+FFFC attachment character
//  for the table. The custom finder client exposes a virtual search
//  string that expands each table attachment into its cell text.
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase2eT2fFindAcrossTableCellsTests: XCTestCase {

    // MARK: - Fixture

    private static let tableMarkdown = """
    | Name  | Note         |
    | ---   | ---          |
    | Alice | findmeinside |
    | Bob   | plain        |
    """

    private func withSubviewTablesEnabled(_ body: () throws -> Void) rethrows {
        let old = UserDefaultsManagement.useSubviewTables
        UserDefaultsManagement.useSubviewTables = true
        defer { UserDefaultsManagement.useSubviewTables = old }
        try body()
    }

    // MARK: - 1. Bug #60 - searchable text contains cell content

    /// The canonical Bug #60 assertion for subview tables: the parent
    /// storage keeps the table as an attachment, while the finder
    /// adapter expands that attachment into searchable cell text.
    func test_phase2eT2f_subviewFindClientExposesTableCells() throws {
        try withSubviewTablesEnabled {
            let harness = EditorHarness(markdown: Self.tableMarkdown)
            defer { harness.teardown() }

            let storageString = harness.editor.textStorage?.string ?? ""
            let searchable = harness.editor.debugSubviewTableFindString()

            XCTAssertTrue(
                storageString.contains("\u{FFFC}"),
                "Subview table storage must carry the table as an attachment."
            )
            XCTAssertFalse(
                storageString.contains("findmeinside"),
                "The parent storage no longer carries table cell text directly."
            )
            XCTAssertTrue(
                searchable.contains("findmeinside"),
                "Bug #60: subview-table finder string must expose body cell text. " +
                "Got: \(searchable.debugDescription)"
            )
            XCTAssertTrue(searchable.contains("Alice"))
            XCTAssertTrue(searchable.contains("Bob"))
            XCTAssertTrue(searchable.contains("Name"))
        }
    }

    // MARK: - 2. Virtual cell separators

    /// The virtual finder string uses natural table text boundaries:
    /// tabs between cells, newlines between rows.
    func test_phase2eT2f_subviewFindStringKeepsCellAndRowBoundaries() throws {
        try withSubviewTablesEnabled {
            let harness = EditorHarness(markdown: Self.tableMarkdown)
            defer { harness.teardown() }

            let searchable = harness.editor.debugSubviewTableFindString()
            XCTAssertTrue(
                searchable.contains("Name\tNote\nAlice\tfindmeinside\nBob\tplain"),
                "Finder string should expose the table as readable text. " +
                "Got: \(searchable.debugDescription)"
            )
        }
    }

    // MARK: - 3. Default route

    func test_phase2eT2f_subviewTablesAreDefaultWhenUnset() throws {
        let oldDefaults = UserDefaultsManagement.shared
        let suiteName = "Phase2eT2fFindAcrossTableCellsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        UserDefaultsManagement.shared = suite
        defer {
            suite.removePersistentDomain(forName: suiteName)
            UserDefaultsManagement.shared = oldDefaults
        }

        XCTAssertTrue(
            UserDefaultsManagement.useSubviewTables,
            "Subview tables should be the production default."
        )
    }
}
