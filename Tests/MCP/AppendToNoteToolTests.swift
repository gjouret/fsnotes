//
//  AppendToNoteToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class AppendToNoteToolTests: XCTestCase {

    func testAppendsToClosedNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: "Existing line.\n")
        let bridge = TestAppBridge()
        let tool = AppendToNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "content": "Appended line."
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        let final = try? String(contentsOf: url, encoding: .utf8)
        // Single trailing \n on the existing content means we insert
        // one more \n so the appended block starts on a fresh
        // paragraph boundary (markdown block separator).
        XCTAssertEqual(final, "Existing line.\n\nAppended line.\n")
        XCTAssertEqual(bridge.notifications.count, 1)
        XCTAssertEqual(result.payload?["mode"] as? String, "closed")
    }

    func testInsertsBlankLineWhenContentLacksTrailingNewline() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: "abc")
        let tool = AppendToNoteTool(server: fixture.makeServer())

        _ = tool.executeSync(input: [
            "title": "a",
            "content": "def"
        ])

        let final = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final, "abc\n\ndef\n")
    }

    func testRoutesThroughBridgeForOpenWysiwygNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: "x\n")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        bridge.appendOutcome = .applied(info: ["blocksAppended": 1])
        let tool = AppendToNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "content": "Hello"
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["viaBridge"] as? Bool, true)
        XCTAssertEqual(bridge.appendCalls.count, 1)
        XCTAssertEqual(bridge.appendCalls.first?.markdown, "Hello")

        // Filesystem must be untouched on the WYSIWYG path — the
        // bridge owns the write.
        let final = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final, "x\n")
    }

    func testReportsBridgeNotImplementedForWysiwygOpenNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: "x\n")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        // appendOutcome stays at the default `.notImplemented`.
        let tool = AppendToNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "content": "Hello"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Phase 3 follow-up") ?? false)
        // Filesystem must NOT have been written by the fallback path —
        // the WYSIWYG branch must hand off to the bridge or refuse,
        // never reach past it.
        let final = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final, "x\n")
    }

    func testSourceModeOpenNoteUsesDirectAppend() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: "x\n")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "source"
        let tool = AppendToNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "content": "Y"
        ])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["mode"] as? String, "source")
        XCTAssertEqual(result.payload?["viaBridge"] as? Bool, false)
        let final = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final, "x\n\nY\n")
    }

    func testRefusesWhenWriteLockDenied() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: "x\n")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "source"
        bridge.dirty = true
        bridge.grantWriteLock = false
        let tool = AppendToNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "content": "Y"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("write lock") ?? false)
    }
}
