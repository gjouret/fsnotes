//
//  ApplyFormattingToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class ApplyFormattingToolTests: XCTestCase {

    func testRefusesWithNoOpenNote() {
        let fixture = MCPTestFixture()
        let tool = ApplyFormattingTool(server: fixture.makeServer())

        let result = tool.executeSync(input: ["command": "bold"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("None is currently open") ?? false)
    }

    func testRefusesInSourceMode() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "source"
        let tool = ApplyFormattingTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: ["command": "bold"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("WYSIWYG") ?? false)
    }

    func testRoutesBoldThroughBridge() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        bridge.formattingOutcome = .applied(info: ["selectionGrew": true])
        let tool = ApplyFormattingTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: ["command": "bold"])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(bridge.formattingCalls.count, 1)
        if case .toggleBold = bridge.formattingCalls.first?.command {
            // ok
        } else {
            XCTFail("expected toggleBold")
        }
    }

    func testHeadingCommandRequiresValidLevel() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        bridge.formattingOutcome = .applied(info: [:])
        let tool = ApplyFormattingTool(server: fixture.makeServer(bridge: bridge))

        // Out of range
        var result = tool.executeSync(input: ["command": "heading", "level": 7])
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("between 0 and 6") ?? false)

        // Valid level
        result = tool.executeSync(input: ["command": "heading", "level": 3])
        XCTAssertTrue(result.isSuccess)
        if case .toggleHeading(let level) = bridge.formattingCalls.last?.command {
            XCTAssertEqual(level, 3)
        } else {
            XCTFail("expected toggleHeading")
        }
    }

    func testReportsBridgeNotImplemented() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        let tool = ApplyFormattingTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: ["command": "italic"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Phase 3 follow-up") ?? false)
    }

    func testRejectsUnknownCommand() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        let tool = ApplyFormattingTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: ["command": "wibble"])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Unsupported") ?? false)
    }

    // MARK: - Happy-path test with a wired AppBridgeImpl

    /// End-to-end smoke test: the tool routes a `bold` toggle
    /// through a real `AppBridgeImpl` whose editor is a live
    /// `EditorHarness`. Verifies the WYSIWYG path actually mutates
    /// the projection.
    func testHappyPathTogglesBoldThroughWiredBridge() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "live.md", content: "Hello\n")
        let harness = AppBridgeImplTestHelper.makeHarness(at: url, markdown: "Hello\n")
        defer { harness.teardown() }
        // Select "Hello" so toggleBold has something to wrap.
        harness.editor.setSelectedRange(NSRange(location: 0, length: 5))
        let vc = ViewController()
        vc.editor = harness.editor
        let bridge = AppBridgeImpl(resolveViewController: { vc })
        let tool = ApplyFormattingTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: ["command": "bold"])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains("**Hello**"), "got: \(serialised)")
    }
}
