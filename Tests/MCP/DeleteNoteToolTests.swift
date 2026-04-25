//
//  DeleteNoteToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class DeleteNoteToolTests: XCTestCase {

    func testDeletesPlainNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "Inbox/old.md", content: "x\n")
        let bridge = TestAppBridge()
        let tool = DeleteNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "old",
            "folder": "Inbox",
            "confirm": true
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(bridge.notifications.count, 1)
    }

    func testDeletesTextBundleAsAUnit() {
        let fixture = MCPTestFixture()
        let url = fixture.makeTextBundle(at: "Work/Bundle.textbundle")
        let tool = DeleteNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "Bundle",
            "source_folder": "Work",  // ignored — uses 'folder'
            "folder": "Work",
            "confirm": true
        ])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["isTextBundle"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRefusesWithoutConfirm() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let tool = DeleteNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("confirm") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRefusesWithExplicitFalseConfirm() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let tool = DeleteNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "confirm": false
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRefusesEncryptedNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeEncryptedNote(at: "Vault/secret.etp")
        let tool = DeleteNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "secret",
            "folder": "Vault",
            "confirm": true
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.lowercased().contains("encrypted") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRefusesWhenWriteLockDenied() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "draft.md", content: "wip\n")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.dirty = true
        bridge.grantWriteLock = false
        let tool = DeleteNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "draft",
            "confirm": true
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(bridge.lockRequests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNotFound() {
        let fixture = MCPTestFixture()
        let tool = DeleteNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "ghost",
            "confirm": true
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("not found") ?? false)
    }
}
