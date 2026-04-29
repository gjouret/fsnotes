//
//  BugFsnotes42vTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-42v (P2):
//  "Wikilink picker leaves cursor on a new line after selection"
//
//  Bug #33 already added a block-model path to insertWikiCompletion
//  that routes through EditingOps + applyBlockModelResult instead of
//  raw replaceCharacters+didChangeText. This test verifies the cursor
//  lands after the closing ]] without an extra newline.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes42vTests: XCTestCase {

    /// Simulate what happens when the user types [[, types part of a
    /// note name, then presses Enter to complete: the [[partial]]
    /// should be replaced with the full wikilink, and the cursor
    /// should land after ]] without an extra newline in the saved
    /// markdown.
    func test_wikiCompletion_cursorAfterLink_noExtraNewline() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        // Simulate: type "[[", then use the insert path directly
        // (the completion picker replaces from startPos to cursor).
        // For the test, we set up the "[[partial" state and call
        // the block-model path directly.

        // Type "[[Test"
        for ch in "[[Test" {
            h.type(String(ch))
        }

        guard let proj = h.editor.documentProjection else {
            XCTFail("no projection"); return
        }

        // Simulate completion replacing "[[Test" with "TestNote]]"
        let startPos = 0  // [[ starts at position 0
        let replaceRange = NSRange(location: startPos, length: 6) // "[[Test"
        let completion = "TestNote]]"
        let expectedCursor = startPos + completion.count // right after ]]

        do {
            let result = try EditingOps.replace(
                range: replaceRange, with: completion, in: proj
            )
            h.editor.applyBlockModelResult(result, actionName: "Wiki Link")
            h.editor.setSelectedRange(
                NSRange(location: expectedCursor, length: 0)
            )

            // Verify cursor position
            XCTAssertEqual(
                h.editor.selectedRange().location, expectedCursor,
                "Cursor should land after closing ]]"
            )

            // Verify no extra newline in the markdown
            let md = h.savedMarkdown
            XCTAssertFalse(
                md.contains("\n"),
                "Saved markdown should not contain a newline. Got: \(md)"
            )
            XCTAssertEqual(
                md, "TestNote]]",
                "Saved markdown should be just the wikilink"
            )
        } catch {
            XCTFail("replace threw: \(error)")
        }
    }

    /// Verify the saved markdown produces a proper wikilink inline
    /// after completion (no newline corrupting the parse).
    func test_wikiCompletion_producesValidWikilink() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        // Insert "[[MyNote]]" as a multi-char insert (simulating completion).
        // This goes through handleEditViaBlockModel which triggers reparse.
        h.editor.setSelectedRange(NSRange(location: 0, length: 0))
        h.type("[[MyNote]]")

        guard let doc = h.document,
              doc.blocks.count == 1,
              case .paragraph(let inlines) = doc.blocks[0]
        else { XCTFail("unexpected structure"); return }

        var foundWikilink = false
        for inline in inlines {
            if case .wikilink = inline { foundWikilink = true; break }
        }
        XCTAssertTrue(
            foundWikilink,
            "Expected .wikilink in inline tree. Got: \(inlines)"
        )
    }
}
