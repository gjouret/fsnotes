//
//  ExportPDFToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class ExportPDFToolTests: XCTestCase {

    func testRefusesWhenNoteIsClosed() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "a.md")
        let tool = ExportPDFTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("WYSIWYG") ?? false)
    }

    func testRoutesThroughBridgeForOpenWysiwygNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        bridge.exportOutcome = .applied(info: ["pages": 2])
        let tool = ExportPDFTool(server: fixture.makeServer(bridge: bridge))

        let outURL = fixture.root.appendingPathComponent("out.pdf")
        let result = tool.executeSync(input: [
            "title": "a",
            "outputPath": outURL.path
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(bridge.exportCalls.count, 1)
        XCTAssertEqual(bridge.exportCalls.first?.outputURL.path, outURL.path)
        XCTAssertEqual(result.payload?["viaBridge"] as? Bool, true)
    }

    func testRefusesIfOutputExistsWithoutOverwrite() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let outURL = fixture.root.appendingPathComponent("out.pdf")
        try? "stub".write(to: outURL, atomically: true, encoding: .utf8)

        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        bridge.exportOutcome = .applied(info: [:])
        let tool = ExportPDFTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "outputPath": outURL.path
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("already exists") ?? false)
        // Bridge must not have been called.
        XCTAssertEqual(bridge.exportCalls.count, 0)
    }

    func testAllowsOverwriteWhenFlagSet() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let outURL = fixture.root.appendingPathComponent("out.pdf")
        try? "stub".write(to: outURL, atomically: true, encoding: .utf8)

        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        bridge.exportOutcome = .applied(info: [:])
        let tool = ExportPDFTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "outputPath": outURL.path,
            "overwrite": true
        ])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(bridge.exportCalls.count, 1)
    }

    func testReportsBridgeNotImplemented() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        // exportOutcome stays at default `.notImplemented`.
        let tool = ExportPDFTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: ["title": "a"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("WYSIWYG") ?? false)
    }
}
