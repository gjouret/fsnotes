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

    // MARK: - Happy-path test with a wired AppBridgeImpl

    /// End-to-end: routes export through a real `AppBridgeImpl` over
    /// a live `EditorHarness` and asserts the PDF file exists and
    /// is non-empty.
    func testHappyPathExportsRealPDFThroughWiredBridge() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "live.md", content: "# Heading\n\nBody.\n")
        let scenario = Given.mcpNote(
            at: url, markdown: "# Heading\n\nBody.\n"
        )
        let vc = ViewController()
        vc.editor = scenario.editor
        let bridge = AppBridgeImpl(resolveViewController: { vc })
        let tool = ExportPDFTool(server: fixture.makeServer(bridge: bridge))
        let outURL = fixture.root.appendingPathComponent("real.pdf")

        let result = tool.executeSync(input: [
            "title": "live",
            "outputPath": outURL.path
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["viaBridge"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let attr = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attr?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "exported PDF should be non-empty")
    }
}
