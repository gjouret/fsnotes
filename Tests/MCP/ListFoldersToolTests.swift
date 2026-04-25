//
//  ListFoldersToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class ListFoldersToolTests: XCTestCase {

    func testListsTopLevelFoldersOnly() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/Meetings/note.md")
        fixture.makeNote(at: "Personal/note.md")
        fixture.makeNote(at: "Journal/2026/April/today.md")
        let tool = ListFoldersTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        let folders = result.payload?["folders"] as? [String] ?? []
        XCTAssertEqual(Set(folders), Set(["Work", "Personal", "Journal"]))
    }

    func testRecursiveReturnsFullTree() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/Meetings/note.md")
        fixture.makeNote(at: "Journal/2026/April/today.md")
        let tool = ListFoldersTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["recursive": true])

        XCTAssertTrue(result.isSuccess)
        let folders = Set(result.payload?["folders"] as? [String] ?? [])
        XCTAssertTrue(folders.contains("Work"))
        XCTAssertTrue(folders.contains("Work/Meetings"))
        XCTAssertTrue(folders.contains("Journal"))
        XCTAssertTrue(folders.contains("Journal/2026"))
        XCTAssertTrue(folders.contains("Journal/2026/April"))
    }

    func testTextBundlesAreNotListedAsFolders() {
        let fixture = MCPTestFixture()
        fixture.makeTextBundle(at: "BundledNote.textbundle")
        fixture.makeNote(at: "Real Folder/note.md")
        let tool = ListFoldersTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["recursive": true])

        XCTAssertTrue(result.isSuccess)
        let folders = Set(result.payload?["folders"] as? [String] ?? [])
        XCTAssertTrue(folders.contains("Real Folder"))
        XCTAssertFalse(folders.contains("BundledNote.textbundle"),
                       "TextBundle directories must not appear as folders")
    }
}
