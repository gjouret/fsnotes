//
//  ListNotesToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class ListNotesToolTests: XCTestCase {

    func testListsEveryNoteAcrossTheVault() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Inbox/a.md")
        fixture.makeNote(at: "Work/b.md")
        fixture.makeNote(at: "Work/Meetings/c.md")
        fixture.makeTextBundle(at: "Personal/d.textbundle")
        let tool = ListNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["totalCount"] as? Int, 4)
        let notes = result.payload?["notes"] as? [[String: Any]] ?? []
        let paths = Set(notes.compactMap { $0["path"] as? String })
        XCTAssertTrue(paths.contains("Inbox/a.md"))
        XCTAssertTrue(paths.contains("Work/b.md"))
        XCTAssertTrue(paths.contains("Work/Meetings/c.md"))
        XCTAssertTrue(paths.contains("Personal/d.textbundle"))
    }

    func testScopesToFolderWhenProvided() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Inbox/a.md")
        fixture.makeNote(at: "Work/b.md")
        fixture.makeNote(at: "Work/Meetings/c.md")
        let tool = ListNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["folder": "Work"])

        XCTAssertTrue(result.isSuccess)
        let notes = result.payload?["notes"] as? [[String: Any]] ?? []
        let paths = Set(notes.compactMap { $0["path"] as? String })
        XCTAssertEqual(paths, Set(["Work/b.md", "Work/Meetings/c.md"]))
    }

    func testReportsTruncationWhenOverMax() {
        let fixture = MCPTestFixture()
        for i in 0..<10 {
            fixture.makeNote(at: "Bulk/note-\(i).md")
        }
        let tool = ListNotesTool(server: fixture.makeServer(), maxResults: 4)

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["totalCount"] as? Int, 10)
        XCTAssertEqual(result.payload?["returnedCount"] as? Int, 4)
        XCTAssertEqual(result.payload?["truncated"] as? Bool, true)
    }

    func testFolderNotFound() {
        let fixture = MCPTestFixture()
        let tool = ListNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["folder": "NoSuchFolder"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("not found") ?? false)
    }
}
