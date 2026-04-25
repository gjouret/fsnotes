//
//  GetCurrentNoteToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class GetCurrentNoteToolTests: XCTestCase {

    func testReportsOpenFalseWithNoBridge() {
        let fixture = MCPTestFixture()
        let tool = GetCurrentNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["open"] as? Bool, false)
    }

    func testReportsOpenNoteMetadata() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "Work/Meetings/Standup.md", content: "# Standup\n")
        let bridge = TestAppBridge()
        let openURL = fixture.root.appendingPathComponent("Work/Meetings/Standup.md")
        bridge.openPath = openURL.path
        bridge.dirty = true
        bridge.mode = "wysiwyg"
        bridge.cursor = CursorState(location: 12, length: 0)
        let tool = GetCurrentNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["open"] as? Bool, true)
        XCTAssertEqual(result.payload?["mode"] as? String, "wysiwyg")
        XCTAssertEqual(result.payload?["hasUnsavedChanges"] as? Bool, true)
        XCTAssertEqual(result.payload?["title"] as? String, "Standup")
        XCTAssertEqual(result.payload?["folder"] as? String, "Work/Meetings")
        XCTAssertEqual(result.payload?["relativePath"] as? String, "Work/Meetings/Standup.md")
        let cursor = result.payload?["cursor"] as? [String: Int]
        XCTAssertEqual(cursor?["location"], 12)
        XCTAssertEqual(cursor?["length"], 0)
    }

    func testRecognisesTextBundle() {
        let fixture = MCPTestFixture()
        let bundleURL = fixture.makeTextBundle(at: "Work/Bundled.textbundle")
        let bridge = TestAppBridge()
        bridge.openPath = bundleURL.path
        let tool = GetCurrentNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [:])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["isTextBundle"] as? Bool, true)
        XCTAssertEqual(result.payload?["title"] as? String, "Bundled")
    }
}
