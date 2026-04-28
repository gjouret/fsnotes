//
//  SubviewTableBodyTypingPreservesAttachmentTests.swift
//  FSNotesTests
//
//  Phase 8 / Subview Tables — regression test for the user-reported
//  bug: clicking right-of-table to place the caret in body, pressing
//  Return, then typing two characters causes the table attachment
//  to vanish from storage. Toggling markdown view and back restores
//  it (so the Document still contains the table — only the rendered
//  storage has lost the attachment).
//
//  This test puts the harness in the failure scenario without
//  involving any UI clicks: it places the cursor at the storage
//  offset immediately after the table block, presses Return, types
//  two characters, and asserts that the table's `U+FFFC` glyph and
//  its `TableAttachment` are still present in storage.
//

import XCTest
import AppKit
@testable import FSNotes

final class SubviewTableBodyTypingPreservesAttachmentTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaultsManagement.useSubviewTables = true
    }

    override func tearDown() {
        UserDefaultsManagement.useSubviewTables = false
        super.tearDown()
    }

    func test_typing_in_paragraph_after_table_does_not_remove_table() throws {
        // A note with a heading + table + a trailing paragraph. The
        // trailing paragraph gives us a stable storage offset to type
        // into without ambiguity at the document boundary.
        let markdown = """
        # Testy

        | A | B |
        |---|---|
        | x | y |

        """
        try runRegressionScenario(markdown: markdown, cursorAtTableStart: false)
    }

    func test_typing_after_table_at_end_of_document_does_not_remove_table() throws {
        // The user-reported scenario: a fresh note with `Insert Table`
        // produces [heading, table] with NO trailing paragraph.
        // Clicking right-of-table places the cursor at the storage
        // offset immediately after the U+FFFC, which is END_OF_DOCUMENT.
        // Pressing Return at end-of-document + typing must NOT remove
        // the table.
        let markdown = """
        # Testy

        | A | B |
        |---|---|
        | x | y |
        """
        try runRegressionScenario(markdown: markdown, cursorAtTableStart: false)
    }

    func test_typing_in_paragraph_below_table_keeps_TableContainerView_mounted() throws {
        // The user's actual scenario: insert a table, click right of
        // it, press Return to add a new paragraph below, type some
        // characters. The Document and storage stay correct (table is
        // preserved), but the user reports the table "disappears"
        // visually. Hypothesis: the splice on the body paragraph
        // evicts TK2's view-provider for the table without
        // re-mounting it, so the transparent placeholder image makes
        // the table appear empty.
        let markdown = """
        # Testy

        |  |  |
        |---|---|
        |  |  |
        """
        let harness = EditorHarness(markdown: markdown, windowActivation: .keyWindow)
        defer { harness.teardown() }

        // Confirm baseline: table is mounted at fill time.
        var initialContainer: TableContainerView? = nil
        harness.editor.subviews.forEach { _ = walk($0, &initialContainer) }
        XCTAssertNotNil(
            initialContainer,
            "baseline: TableContainerView should be mounted after fill"
        )

        // Find the table attachment offset.
        guard let storage = harness.editor.textStorage else {
            return XCTFail("no textStorage")
        }
        var tableOffset: Int? = nil
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if value is TableAttachment {
                tableOffset = range.location
                stop.pointee = true
            }
        }
        guard let tableOffset = tableOffset else {
            return XCTFail("no table attachment in initial storage")
        }

        // Reproduce: cursor right after table, Return, type 4 chars.
        harness.moveCursor(to: tableOffset + 1)
        harness.pressReturn()
        harness.type("a")
        harness.type("s")
        harness.type("d")
        harness.type("f")

        // Pump the run loop so viewport-layout has a chance to remount.
        if let tlm = harness.editor.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if let tlm = harness.editor.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        // Storage should still have the table attachment.
        var postAttachmentCount = 0
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if value is TableAttachment { postAttachmentCount += 1 }
        }
        XCTAssertEqual(
            postAttachmentCount, 1,
            "table attachment must remain in storage after body typing"
        )

        // And — the actual user-visible test — the TableContainerView
        // should STILL be in the editor's view tree.
        var postContainer: TableContainerView? = nil
        harness.editor.subviews.forEach { _ = walk($0, &postContainer) }
        XCTAssertNotNil(
            postContainer,
            "TableContainerView was evicted from the view tree after body typing — table appears 'disappeared' to the user"
        )
    }

    /// Recursively walk a subview tree, capturing the first
    /// TableContainerView found.
    @discardableResult
    private func walk(_ view: NSView, _ found: inout TableContainerView?) -> Bool {
        if let tcv = view as? TableContainerView {
            found = tcv
            return true
        }
        for sub in view.subviews {
            if walk(sub, &found) { return true }
        }
        return false
    }

    func test_typing_with_cursor_at_table_start_does_not_remove_table() throws {
        // Alternate hypothesis: TK2's hit-test for a click right-of-
        // table on the same y-band as the (now-tight) U+FFFC line
        // fragment may map the click to the start-of-line offset
        // (== table's U+FFFC offset) instead of end-of-line. Test
        // that scenario too.
        let markdown = """
        # Testy

        | A | B |
        |---|---|
        | x | y |
        """
        try runRegressionScenario(markdown: markdown, cursorAtTableStart: true)
    }

    private func runRegressionScenario(
        markdown: String,
        cursorAtTableStart: Bool = false
    ) throws {
        let harness = EditorHarness(markdown: markdown, windowActivation: .keyWindow)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            return XCTFail("no textStorage")
        }

        // Find the table attachment's storage offset.
        var tableAttachmentOffset: Int? = nil
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(
            .attachment, in: fullRange, options: []
        ) { value, range, stop in
            if value is TableAttachment {
                tableAttachmentOffset = range.location
                stop.pointee = true
            }
        }
        guard let tableOffset = tableAttachmentOffset else {
            return XCTFail("table attachment not found in storage; string=\(storage.string.debugDescription)")
        }

        // Place cursor either AT the table glyph offset (start of
        // block) or AFTER it (end of glyph / start of next block).
        // Both are positions the user might land at when clicking
        // right of the table — this exercises both.
        let cursorOffset = cursorAtTableStart ? tableOffset : tableOffset + 1
        harness.moveCursor(to: cursorOffset)

        // Press Return + type two characters — same sequence that
        // triggers the user-reported regression.
        harness.pressReturn()
        harness.type("a")
        harness.type("b")

        // The table attachment must still be in storage. Re-search.
        var tableStillThere = false
        let postRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(
            .attachment, in: postRange, options: []
        ) { value, _, stop in
            if value is TableAttachment {
                tableStillThere = true
                stop.pointee = true
            }
        }
        XCTAssertTrue(
            tableStillThere,
            "table attachment was removed from storage after Return + typing 'ab'. " +
            "post-edit storage string = \(storage.string.debugDescription)"
        )

        // Also assert the Document model still has a `.table` block —
        // if the storage lost the attachment but the Document still
        // has the table, then the bug is in the renderer/applier;
        // if the Document also lost it, the bug is in the EditingOps
        // primitive.
        guard let projection = harness.editor.documentProjection else {
            return XCTFail("documentProjection nil after typing")
        }
        let hasTableBlock = projection.document.blocks.contains { block in
            if case .table = block { return true }
            return false
        }
        XCTAssertTrue(
            hasTableBlock,
            "Document model lost the .table block after Return + typing — " +
            "the bug is upstream of rendering, in an EditingOps primitive."
        )
    }
}
