//
//  SearchNotesToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class SearchNotesToolTests: XCTestCase {

    func testFindsContentMatch() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "alpha.md", content: "talk about FOOBAR here\n")
        fixture.makeNote(at: "beta.md", content: "nothing of note\n")
        let tool = SearchNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["query": "foobar"])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["matchCount"] as? Int, 1)
        let matches = (result.payload?["matches"] as? [[String: Any]]) ?? []
        XCTAssertEqual(matches.first?["title"] as? String, "alpha")
        let snippet = matches.first?["snippet"] as? String ?? ""
        XCTAssertTrue(snippet.lowercased().contains("foobar"))
    }

    func testFindsTitleMatch() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Foobar Notes.md", content: "body unrelated\n")
        let tool = SearchNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["query": "foobar"])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["matchCount"] as? Int, 1)
    }

    func testFolderScopeLimitsResults() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/note1.md", content: "magic word\n")
        fixture.makeNote(at: "Personal/note2.md", content: "magic word\n")
        let tool = SearchNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "query": "magic word",
            "folder": "Work"
        ])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["matchCount"] as? Int, 1)
        let first = (result.payload?["matches"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["folder"] as? String, "Work")
    }

    func testRequiresQuery() {
        let fixture = MCPTestFixture()
        let tool = SearchNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertFalse(result.isSuccess)
    }

    func testSkipsEncryptedNotes() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "open.md", content: "secret in plain note\n")
        fixture.makeEncryptedNote(at: "vault.etp")
        let tool = SearchNotesTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["query": "secret"])

        XCTAssertTrue(result.isSuccess)
        // The encrypted file's body content can't be read in plain
        // text, so even if it contained "secret" it must not surface.
        let titles = ((result.payload?["matches"] as? [[String: Any]]) ?? [])
            .compactMap { $0["title"] as? String }
        XCTAssertTrue(titles.contains("open"))
        XCTAssertFalse(titles.contains("vault"))
    }
}
