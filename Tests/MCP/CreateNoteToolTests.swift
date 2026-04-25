//
//  CreateNoteToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class CreateNoteToolTests: XCTestCase {

    func testCreatesPlainMarkdownNote() {
        let fixture = MCPTestFixture()
        try? FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Inbox"),
            withIntermediateDirectories: true
        )
        let bridge = TestAppBridge()
        let tool = CreateNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "Idea",
            "folder": "Inbox",
            "content": "# Idea\n\nFirst draft.\n"
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["status"] as? String, "created")
        XCTAssertEqual(result.payload?["path"] as? String, "Inbox/Idea.md")
        let url = fixture.root.appendingPathComponent("Inbox/Idea.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let content = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "# Idea\n\nFirst draft.\n")
        XCTAssertEqual(bridge.notifications.count, 1)
    }

    func testRefusesIfDestinationExists() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Inbox/Existing.md", content: "old\n")
        let tool = CreateNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "Existing",
            "folder": "Inbox"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("already exists") ?? false)
    }

    func testRefusesIfFolderMissing() {
        let fixture = MCPTestFixture()
        let tool = CreateNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "X",
            "folder": "MissingFolder"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Folder does not exist") ?? false)
    }

    func testRejectsTitleWithSlash() {
        let fixture = MCPTestFixture()
        let tool = CreateNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "../escape",
            "folder": ""
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("slashes") ?? false)
    }

    func testDefaultContentWhenOmitted() {
        let fixture = MCPTestFixture()
        try? FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Inbox"),
            withIntermediateDirectories: true
        )
        let tool = CreateNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "Blank",
            "folder": "Inbox"
        ])

        XCTAssertTrue(result.isSuccess)
        let url = fixture.root.appendingPathComponent("Inbox/Blank.md")
        let content = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "# Blank\n")
    }

    func testRefusesWhenTextBundleWithSameTitleExists() {
        let fixture = MCPTestFixture()
        fixture.makeTextBundle(at: "Inbox/Clash.textbundle")
        let tool = CreateNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "Clash",
            "folder": "Inbox"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("TextBundle") ?? false)
    }
}
