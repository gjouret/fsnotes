//
//  ReadNoteToolTests.swift
//  FSNotesTests
//
//  Unit coverage for ReadNoteTool. Exercises the full
//  resolve / read / encrypt-skip pipeline with on-disk fixtures.
//

import XCTest
@testable import FSNotes

final class ReadNoteToolTests: XCTestCase {

    func testReadsPlainMarkdownByTitle() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Ideas.md", content: "# Ideas\n\nFirst.\n")
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["title": "Ideas"])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["title"] as? String, "Ideas")
        XCTAssertEqual(result.payload?["folder"] as? String, "")
        XCTAssertEqual(result.payload?["path"] as? String, "Ideas.md")
        XCTAssertEqual(result.payload?["content"] as? String, "# Ideas\n\nFirst.\n")
        XCTAssertEqual(result.payload?["isTextBundle"] as? Bool, false)
    }

    func testReadsNestedNoteByPath() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/Meetings/Standup.md", content: "Daily.\n")
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["path": "Work/Meetings/Standup.md"])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["title"] as? String, "Standup")
        XCTAssertEqual(result.payload?["folder"] as? String, "Work/Meetings")
        XCTAssertEqual(result.payload?["content"] as? String, "Daily.\n")
    }

    func testReadsTextBundleSurfacingFlag() {
        let fixture = MCPTestFixture()
        fixture.makeTextBundle(
            at: "Bundled.textbundle",
            markdown: "# Bundled\n\nWith assets.\n"
        )
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["title": "Bundled"])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["isTextBundle"] as? Bool, true)
        XCTAssertEqual(result.payload?["content"] as? String, "# Bundled\n\nWith assets.\n")
    }

    func testRefusesEncryptedEtpFile() {
        let fixture = MCPTestFixture()
        fixture.makeEncryptedNote(at: "Secret.etp")
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["title": "Secret"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("encrypted") ?? false,
                      "expected encrypted-note error, got \(String(describing: result.errorMessage))")
    }

    func testRefusesEncryptedTextBundle() {
        let fixture = MCPTestFixture()
        fixture.makeEncryptedNote(at: "SecretBundle.textbundle")
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["title": "SecretBundle"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("encrypted") ?? false)
    }

    func testReturnsNotFoundForMissingTitle() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Hello.md")
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["title": "Goodbye"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("not found") ?? false,
                      "expected not-found, got \(String(describing: result.errorMessage))")
    }

    func testDisambiguatesDuplicateTitlesAcrossFolders() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/Meeting Notes.md", content: "work\n")
        fixture.makeNote(at: "Personal/Meeting Notes.md", content: "personal\n")
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["title": "Meeting Notes"])

        XCTAssertFalse(result.isSuccess)
        let msg = result.errorMessage ?? ""
        XCTAssertTrue(msg.contains("Work/Meeting Notes"), "expected Work in disambiguation: \(msg)")
        XCTAssertTrue(msg.contains("Personal/Meeting Notes"), "expected Personal in disambiguation: \(msg)")
    }

    func testFolderQualifiedReadAvoidsDisambiguation() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/Meeting Notes.md", content: "work\n")
        fixture.makeNote(at: "Personal/Meeting Notes.md", content: "personal\n")
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "Meeting Notes",
            "folder": "Personal"
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["content"] as? String, "personal\n")
    }

    func testRejectsEmptyArgumentTrio() {
        let fixture = MCPTestFixture()
        let tool = ReadNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertFalse(result.isSuccess)
    }
}
