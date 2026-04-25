//
//  GetProjectsToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class GetProjectsToolTests: XCTestCase {

    func testListsTopLevelFoldersWithNoteCounts() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/a.md")
        fixture.makeNote(at: "Work/Meetings/b.md")
        fixture.makeNote(at: "Personal/c.md")
        let tool = GetProjectsTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        let projects = result.payload?["projects"] as? [[String: Any]] ?? []
        let nameToCount = Dictionary(uniqueKeysWithValues: projects.compactMap { project -> (String, Int)? in
            guard let name = project["name"] as? String,
                  let count = project["noteCount"] as? Int else { return nil }
            return (name, count)
        })
        XCTAssertEqual(nameToCount["Work"], 2)
        XCTAssertEqual(nameToCount["Personal"], 1)
    }

    func testIncludesRootProjectWhenNotesAtRoot() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "RootNote.md")
        fixture.makeNote(at: "Work/a.md")
        let tool = GetProjectsTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        let projects = result.payload?["projects"] as? [[String: Any]] ?? []
        let isRootEntries = projects.filter { ($0["isRoot"] as? Bool) == true }
        XCTAssertEqual(isRootEntries.count, 1, "exactly one synthetic root project")
        XCTAssertEqual(isRootEntries.first?["noteCount"] as? Int, 1)
    }

    func testEmptyVault() {
        let fixture = MCPTestFixture()
        let tool = GetProjectsTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["projectCount"] as? Int, 0)
    }
}
