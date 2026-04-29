//
//  EditNoteToolTests.swift
//  FSNotesTests
//

import XCTest
@testable import FSNotes

final class EditNoteToolTests: XCTestCase {

    private let threeBlockMarkdown = """
        # Heading

        First paragraph.

        Second paragraph.
        """

    func testReplacesBlockOnClosedNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: threeBlockMarkdown + "\n")
        let tool = EditNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "replace_block",
            "blockIndex": 1,
            "markdown": "Replaced first paragraph."
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        let final = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(final.contains("Replaced first paragraph."))
        XCTAssertFalse(final.contains("First paragraph."))
        XCTAssertTrue(final.contains("Second paragraph."))
    }

    func testInsertBeforeAtStart() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: threeBlockMarkdown + "\n")
        let tool = EditNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "insert_before",
            "blockIndex": 0,
            "markdown": "Preface block."
        ])

        XCTAssertTrue(result.isSuccess)
        let final = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(final.hasPrefix("Preface block.\n\n"))
    }

    func testInsertBeforeAtEnd() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: threeBlockMarkdown + "\n")
        let tool = EditNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "insert_before",
            "blockIndex": 3,  // == blockCount, allowed for insert
            "markdown": "Tail block."
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        let final = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(final.hasSuffix("Tail block.\n"))
    }

    func testDeleteBlock() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: threeBlockMarkdown + "\n")
        let tool = EditNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "delete_block",
            "blockIndex": 1
        ])

        XCTAssertTrue(result.isSuccess)
        let final = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertFalse(final.contains("First paragraph."))
        XCTAssertTrue(final.contains("Second paragraph."))
    }

    func testReplaceDocument() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: "old\n")
        let tool = EditNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "replace_document",
            "markdown": "# Brand new\n"
        ])

        XCTAssertTrue(result.isSuccess)
        let final = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final, "# Brand new\n")
    }

    func testOutOfRangeBlockIndex() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "a.md", content: threeBlockMarkdown + "\n")
        let tool = EditNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "replace_block",
            "blockIndex": 99,
            "markdown": "x"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("out of range") ?? false)
    }

    func testFencedCodeBlockHeldIntact() {
        let fixture = MCPTestFixture()
        let content = """
            Pre paragraph.

            ```swift
            let x = 1

            let y = 2
            ```

            Post paragraph.

            """
        let url = fixture.makeNote(at: "a.md", content: content)
        let tool = EditNoteTool(server: fixture.makeServer())

        // Parse: 3 blocks. Replace block 1 (the code fence).
        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "replace_block",
            "blockIndex": 1,
            "markdown": "Replaced code section."
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        let final = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertFalse(final.contains("```"))
        XCTAssertTrue(final.contains("Replaced code section."))
        XCTAssertTrue(final.contains("Post paragraph."))
    }

    func testRoutesThroughBridgeForOpenWysiwygNote() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: threeBlockMarkdown + "\n")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        bridge.editOutcome = .applied(info: ["editId": "deadbeef"])
        let tool = EditNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "replace_block",
            "blockIndex": 0,
            "markdown": "X"
        ])

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.payload?["viaBridge"] as? Bool, true)
        XCTAssertEqual(bridge.editCalls.count, 1)
        if case .replaceBlock(let idx, let md) = bridge.editCalls.first?.request.kind {
            XCTAssertEqual(idx, 0)
            XCTAssertEqual(md, "X")
        } else {
            XCTFail("expected replaceBlock request")
        }
    }

    func testWysiwygBridgeNotImplementedReportsCleanly() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "a.md", content: threeBlockMarkdown + "\n")
        let bridge = TestAppBridge()
        bridge.openPath = url.path
        bridge.mode = "wysiwyg"
        let tool = EditNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "delete_block",
            "blockIndex": 1
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Phase 3 follow-up") ?? false)
        // No filesystem write must have happened on this path.
        let final = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(final, threeBlockMarkdown + "\n")
    }

    func testMalformedOperation() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "a.md")
        let tool = EditNoteTool(server: fixture.makeServer())

        let result = tool.executeSync(input: [
            "title": "a",
            "operation": "wibble"
        ])

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("Unsupported operation") ?? false)
    }

    // MARK: - Happy-path tests with a wired AppBridgeImpl

    /// End-to-end smoke test: the tool routes a `replace_block`
    /// through a real `AppBridgeImpl` whose editor is a live
    /// `EditorHarness`. Verifies the WYSIWYG path actually mutates
    /// the projection.
    func testHappyPathRoutesReplaceBlockThroughWiredBridge() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "live.md", content: threeBlockMarkdown + "\n")
        let scenario = Given.mcpNote(
            at: url, markdown: threeBlockMarkdown + "\n"
        )
        let vc = ViewController()
        vc.editor = scenario.editor
        let bridge = AppBridgeImpl(resolveViewController: { vc })
        let tool = EditNoteTool(server: fixture.makeServer(bridge: bridge))

        let result = tool.executeSync(input: [
            "title": "live",
            "operation": "replace_block",
            "blockIndex": 1,
            "markdown": "Replaced first paragraph."
        ])

        XCTAssertTrue(result.isSuccess, "got \(String(describing: result.errorMessage))")
        XCTAssertEqual(result.payload?["viaBridge"] as? Bool, true)
        let serialised = MarkdownSerializer.serialize(scenario.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains("Replaced first paragraph."))
        XCTAssertFalse(serialised.contains("First paragraph."))
    }
}
