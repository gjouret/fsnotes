//
//  BugFsnotes0gjTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-0gj:
//  deleting a selected table must be undoable as a table, and redo
//  must re-apply the deletion.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes0gjTests: XCTestCase {

    private static let markdown = """
    before

    | A | B |
    | --- | --- |
    | 1 | 2 |

    after
    """

    private func tableBlockIndex(in doc: Document) -> Int? {
        return doc.blocks.firstIndex {
            if case .table = $0 { return true }
            return false
        }
    }

    private func tableSpan(in editor: EditTextView) -> NSRange? {
        guard let projection = editor.documentProjection,
              let idx = tableBlockIndex(in: projection.document),
              idx < projection.blockSpans.count else {
            return nil
        }
        return projection.blockSpans[idx]
    }

    private func tableAttachment(in editor: EditTextView) -> TableAttachment? {
        guard let projection = editor.documentProjection,
              let storage = editor.textStorage,
              let idx = tableBlockIndex(in: projection.document),
              idx < projection.blockSpans.count else {
            return nil
        }
        let span = projection.blockSpans[idx]
        guard span.length > 0, span.location < storage.length else {
            return nil
        }
        return storage.attribute(
            .attachment, at: span.location, effectiveRange: nil
        ) as? TableAttachment
    }

    private func deleteSelectedTable(in editor: EditTextView) {
        guard let span = tableSpan(in: editor) else {
            return XCTFail("table span not found")
        }
        editor.setSelectedRange(span)
        let handled = editor.handleEditViaBlockModel(
            in: span,
            replacementString: ""
        )
        XCTAssertTrue(handled, "block model should delete selected table")
    }

    func test_deleteSelectedTable_thenUndoRestoresTableBlockAndAttachment() {
        let h = EditorHarness(
            markdown: Self.markdown,
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        XCTAssertNotNil(tableAttachment(in: h.editor), "precondition")
        deleteSelectedTable(in: h.editor)
        XCTAssertNil(tableBlockIndex(in: h.document ?? Document(blocks: [])))

        guard let undoManager = h.editor.undoManager ??
                h.editor.editorViewController?.editorUndoManager else {
            return XCTFail("undo manager unavailable")
        }
        XCTAssertTrue(undoManager.canUndo, "table deletion must register undo")
        undoManager.undo()

        guard let doc = h.document else {
            return XCTFail("no document after undo")
        }
        XCTAssertNotNil(tableBlockIndex(in: doc), "undo must restore table block")
        XCTAssertNotNil(
            tableAttachment(in: h.editor),
            "undo must restore the table storage attachment"
        )
        let markdown = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(markdown.contains("| A | B |"), markdown)
        XCTAssertTrue(markdown.contains("| 1 | 2 |"), markdown)
    }

    func test_deleteSelectedTable_undoThenRedoRemovesTableAgain() {
        let h = EditorHarness(
            markdown: Self.markdown,
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        deleteSelectedTable(in: h.editor)

        guard let undoManager = h.editor.undoManager ??
                h.editor.editorViewController?.editorUndoManager else {
            return XCTFail("undo manager unavailable")
        }
        undoManager.undo()
        XCTAssertNotNil(tableBlockIndex(in: h.document ?? Document(blocks: [])))

        XCTAssertTrue(undoManager.canRedo, "undo must expose redo")
        undoManager.redo()

        let doc = h.document ?? Document(blocks: [])
        XCTAssertNil(tableBlockIndex(in: doc), "redo must remove table again")
        let markdown = MarkdownSerializer.serialize(doc)
        XCTAssertFalse(markdown.contains("| A | B |"), markdown)
    }
}
