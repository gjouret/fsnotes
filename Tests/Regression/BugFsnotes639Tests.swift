//
//  BugFsnotes639Tests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-639 (P2):
//  "Pasting table from Numbers does not work in WYSIWYG mode"
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes639Tests: XCTestCase {

    /// TSV → markdown table conversion produces correct pipe table.
    func test_tsvToMarkdownTable_basicTable() {
        let tsv = "A\tB\n1\t2\n3\t4"
        let md = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("| A | B |"))
        XCTAssertTrue(md!.contains("| --- | --- |"))
        XCTAssertTrue(md!.contains("| 1 | 2 |"))
        XCTAssertTrue(md!.contains("| 3 | 4 |"))
    }

    /// Single-row TSV produces valid table.
    func test_tsvToMarkdownTable_singleRow() {
        let tsv = "Name\tAge\tCity"
        let md = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("| Name | Age | City |"))
    }

    /// Empty cells handled correctly.
    func test_tsvToMarkdownTable_emptyCells() {
        let tsv = "A\t\tC\n1\t2\t"
        let md = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("| A |  | C |"))
        XCTAssertTrue(md!.contains("| 1 | 2 |  |"))
    }

    /// Invalid input returns nil.
    func test_tsvToMarkdownTable_invalid() {
        XCTAssertNil(EditTextView.tsvToMarkdownTable(""))
        XCTAssertNil(EditTextView.tsvToMarkdownTable("\n\n"))
    }

    /// Verify that parsing the converted markdown produces a table block.
    func test_convertedMarkdown_parsesAsTable() {
        let tsv = "A\tB\n1\t2"
        guard let md = EditTextView.tsvToMarkdownTable(tsv) else {
            XCTFail("tsvToMarkdownTable returned nil"); return
        }
        let doc = MarkdownParser.parse(md)
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .table = doc.blocks[0] else {
            XCTFail("Expected table block, got: \(doc.blocks[0])")
            return
        }
    }

    /// Simulate WYSIWYG paste: insert markdown into editor and verify
    /// the document has a table block after re-fill.
    func test_pasteTableIntoWYSIWYG_createsTableBlock() {
        let h = EditorHarness(markdown: "before", windowActivation: .offscreen)
        defer { h.teardown() }

        let tsv = "A\tB\n1\t2"
        guard let md = EditTextView.tsvToMarkdownTable(tsv) else {
            XCTFail("tsvToMarkdownTable nil"); return
        }

        // Simulate what the WYSIWYG paste path does
        guard let proj = h.editor.documentProjection,
              let note = h.editor.note
        else { XCTFail("no projection/note"); return }

        let cursorPos = h.editor.selectedRange().location
        guard let (blockIndex, _) = proj.blockContaining(storageIndex: cursorPos)
        else { XCTFail("no block"); return }

        let parsed = MarkdownParser.parse(md)
        var newDoc = proj.document
        for (offset, block) in parsed.blocks.enumerated() {
            newDoc.insertBlock(block, at: blockIndex + 1 + offset)
        }

        note.content = NSMutableAttributedString(
            string: MarkdownSerializer.serialize(newDoc)
        )
        note.cachedDocument = nil
        h.editor.hasUserEdits = true
        h.editor.fill(note: note)

        guard let doc = h.document else { XCTFail("no document"); return }
        let hasTable = doc.blocks.contains { block in
            if case .table = block { return true }
            return false
        }
        XCTAssertTrue(hasTable, "Document should contain a table block. Blocks: \(doc.blocks.count)")
    }
}
