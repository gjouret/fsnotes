//
//  BugFsnotes7arTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-7ar:
//  undoing one formatting operation must preserve earlier formatting,
//  and redo must be available afterward.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes7arTests: XCTestCase {

    func test_undoFormattingPreservesEarlierFormattingAndRedoRestoresIt() {
        let h = EditorHarness(
            markdown: "Title\n\nquote\n\nbody",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        h.editor.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(h.editor.changeHeadingLevelViaBlockModel(1))

        let storage = h.editor.textStorage?.string as NSString? ?? ""
        let quoteRange = storage.range(of: "quote")
        XCTAssertNotEqual(quoteRange.location, NSNotFound)
        h.editor.setSelectedRange(quoteRange)
        XCTAssertTrue(h.editor.toggleBlockquoteViaBlockModel())

        guard let undoManager = h.editor.undoManager ??
                h.editor.editorViewController?.editorUndoManager else {
            return XCTFail("undo manager unavailable")
        }
        undoManager.undo()

        var markdown = MarkdownSerializer.serialize(
            h.document ?? Document(blocks: [])
        )
        XCTAssertTrue(markdown.contains("# Title"), markdown)
        XCTAssertFalse(markdown.contains("> quote"), markdown)
        XCTAssertTrue(undoManager.canRedo, "undo must expose redo")

        undoManager.redo()

        markdown = MarkdownSerializer.serialize(h.document ?? Document(blocks: []))
        XCTAssertTrue(markdown.contains("# Title"), markdown)
        XCTAssertTrue(markdown.contains("> quote"), markdown)
    }
}
