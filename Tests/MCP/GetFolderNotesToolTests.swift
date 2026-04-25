//
//  GetFolderNotesToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class GetFolderNotesToolTests: XCTestCase {

    func testReturnsNotesInFolder() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/standup.md")
        fixture.makeNote(at: "Work/sprint.md")
        fixture.makeNote(at: "Personal/journal.md")
        let tool = GetFolderNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["folder": "Work"])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["noteCount"] as? Int, 2)
        let titles = ((result.payload?["notes"] as? [[String: Any]]) ?? [])
            .compactMap { $0["title"] as? String }
            .sorted()
        XCTAssertEqual(titles, ["sprint", "standup"])
    }

    func testEmptyFolderReturnsEmptyArray() {
        let fixture = MCPTestFixture()
        // Create the folder but no notes
        try? FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Empty"),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let tool = GetFolderNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["folder": "Empty"])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["noteCount"] as? Int, 0)
    }

    func testMissingFolderReturnsError() {
        let fixture = MCPTestFixture()
        let tool = GetFolderNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["folder": "DoesNotExist"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("not found") ?? false)
    }

    func testRecursiveIncludesSubfolders() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/note.md")
        fixture.makeNote(at: "Work/Sub/deep.md")
        let tool = GetFolderNotesTool(server: fixture.makeServer())

        let resultShallow = tool.executeSync(input: ["folder": "Work"])
        XCTAssertEqual(resultShallow.payload?["noteCount"] as? Int, 1)

        let resultDeep = tool.executeSync(input: ["folder": "Work", "recursive": true])
        XCTAssertEqual(resultDeep.payload?["noteCount"] as? Int, 2)
    }

    func testTextBundleSurfacesAsNote() {
        let fixture = MCPTestFixture()
        fixture.makeTextBundle(at: "Work/Bundle.textbundle")
        fixture.makeNote(at: "Work/Plain.md")
        let tool = GetFolderNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["folder": "Work"])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["noteCount"] as? Int, 2)
        let bundleEntries = ((result.payload?["notes"] as? [[String: Any]]) ?? [])
            .filter { ($0["isTextBundle"] as? Bool) == true }
        XCTAssertEqual(bundleEntries.count, 1)
        XCTAssertEqual(bundleEntries.first?["title"] as? String, "Bundle")
    }
}
