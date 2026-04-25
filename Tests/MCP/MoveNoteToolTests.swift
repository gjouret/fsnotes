//
//  MoveNoteToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

// TestAppBridge is defined in MCPTestFixture.swift and shared
// across the MCP test suite.

final class MoveNoteToolTests: XCTestCase {

    func testMovesPlainMarkdownNote() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Inbox/idea.md", content: "an idea\n")
        // Destination folder must exist already.
        try? FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Archive"),
            withIntermediateDirectories: true
        )
        let bridge = TestAppBridge()
        let tool = MoveNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "idea",
            "source_folder": "Inbox",
            "destination_folder": "Archive"
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["newPath"] as? String, "Archive/idea.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Archive/idea.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Inbox/idea.md").path
        ))
        XCTAssertEqual(bridge.notifications.count, 2,
                       "expected notifyFileChanged for both old and new paths")
    }

    func testMovesTextBundleAsAUnit() {
        let fixture = MCPTestFixture()
        fixture.makeTextBundle(at: "Work/Bundle.textbundle", markdown: "body\n")
        try? FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Personal"),
            withIntermediateDirectories: true
        )
        let tool = MoveNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "Bundle",
            "source_folder": "Work",
            "destination_folder": "Personal"
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["isTextBundle"] as? Bool, true)
        let movedURL = fixture.root.appendingPathComponent("Personal/Bundle.textbundle")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "TextBundle should remain a directory after move")
        // Inner text.md should be present.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: movedURL.appendingPathComponent("text.md").path
        ))
    }

    func testRefusesIfDestinationExists() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Inbox/clash.md", content: "src\n")
        fixture.makeNote(at: "Archive/clash.md", content: "dst\n")
        let tool = MoveNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "clash",
            "source_folder": "Inbox",
            "destination_folder": "Archive"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("already exists") ?? false)
        // Source must be unchanged.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Inbox/clash.md").path
        ))
    }

    func testRefusesEncryptedNote() {
        let fixture = MCPTestFixture()
        fixture.makeEncryptedNote(at: "Vault/secret.etp")
        try? FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Archive"),
            withIntermediateDirectories: true
        )
        let tool = MoveNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "secret",
            "source_folder": "Vault",
            "destination_folder": "Archive"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.lowercased().contains("encrypted") ?? false)
    }

    func testRefusesWhenWriteLockDenied() {
        let fixture = MCPTestFixture()
        let src = fixture.makeNote(at: "Inbox/draft.md", content: "wip\n")
        try? FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Archive"),
            withIntermediateDirectories: true
        )
        let bridge = TestAppBridge()
        bridge.openPath = src.path
        bridge.dirty = true
        bridge.grantWriteLock = false
        let tool = MoveNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "draft",
            "source_folder": "Inbox",
            "destination_folder": "Archive"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(bridge.lockRequests.count, 1,
                       "expected requestWriteLock to be called once")
        // Source must still be in place.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testRefusesIfDestinationFolderMissing() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Inbox/idea.md", content: "x\n")
        let tool = MoveNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "idea",
            "source_folder": "Inbox",
            "destination_folder": "MissingArchive"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Destination folder") ?? false)
    }
}
