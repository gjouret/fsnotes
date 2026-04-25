//
//  GetTagsToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class GetTagsToolTests: XCTestCase {

    func testAggregatesTagsAcrossNotes() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "a.md", content: "Some text #work #urgent\n")
        fixture.makeNote(at: "b.md", content: "Note B #work #personal\n")
        fixture.makeNote(at: "c.md", content: "No tags here.\n")
        let tool = GetTagsTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        let tags = result.payload?["tags"] as? [[String: Any]] ?? []
        let counts = Dictionary(uniqueKeysWithValues: tags.compactMap { entry -> (String, Int)? in
            guard let name = entry["tag"] as? String,
                  let count = entry["noteCount"] as? Int else { return nil }
            return (name, count)
        })
        XCTAssertEqual(counts["work"], 2)
        XCTAssertEqual(counts["urgent"], 1)
        XCTAssertEqual(counts["personal"], 1)
    }

    func testTagsAreCountedOncePerNote() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "a.md", content: "#dup #dup #dup more #dup text.\n")
        let tool = GetTagsTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        let tags = result.payload?["tags"] as? [[String: Any]] ?? []
        XCTAssertEqual(tags.first?["tag"] as? String, "dup")
        XCTAssertEqual(tags.first?["noteCount"] as? Int, 1)
    }

    func testScopesToFolder() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/a.md", content: "#scope-test\n")
        fixture.makeNote(at: "Personal/b.md", content: "#other\n")
        let tool = GetTagsTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["folder": "Work"])

        XCTAssertTrue(result.isSuccess)
        let tags = result.payload?["tags"] as? [[String: Any]] ?? []
        let names = Set(tags.compactMap { $0["tag"] as? String })
        XCTAssertTrue(names.contains("scope-test"))
        XCTAssertFalse(names.contains("other"))
    }

    func testIgnoresEncryptedNotes() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "a.md", content: "#open\n")
        fixture.makeEncryptedNote(at: "Vault/b.etp")
        let tool = GetTagsTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        let tags = result.payload?["tags"] as? [[String: Any]] ?? []
        let names = Set(tags.compactMap { $0["tag"] as? String })
        XCTAssertEqual(names, Set(["open"]))
    }
}
