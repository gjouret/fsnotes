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

    // MARK: - TSV conversion tests

    func test_tsvToMarkdownTable_basicTable() {
        let tsv = "A\tB\n1\t2\n3\t4"
        let md = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("| A | B |"))
        XCTAssertTrue(md!.contains("| --- | --- |"))
        XCTAssertTrue(md!.contains("| 1 | 2 |"))
        XCTAssertTrue(md!.contains("| 3 | 4 |"))
    }

    func test_tsvToMarkdownTable_singleRow() {
        let tsv = "Name\tAge\tCity"
        let md = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("| Name | Age | City |"))
    }

    func test_tsvToMarkdownTable_emptyCells() {
        let tsv = "A\t\tC\n1\t2\t"
        let md = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("| A |  | C |"))
    }

    func test_tsvToMarkdownTable_invalid() {
        XCTAssertNil(EditTextView.tsvToMarkdownTable(""))
        XCTAssertNil(EditTextView.tsvToMarkdownTable("\n\n"))
    }

    func test_convertedMarkdown_parsesAsTable() {
        let tsv = "A\tB\n1\t2"
        guard let md = EditTextView.tsvToMarkdownTable(tsv) else {
            XCTFail("nil"); return
        }
        let doc = MarkdownParser.parse(md)
        guard case .table = doc.blocks[0] else {
            XCTFail("not a table: \(doc.blocks[0])"); return
        }
    }

    // MARK: - Integration: paste via NSPasteboard

    /// Put TSV on the real pasteboard, call paste(), verify table block.
    func test_pasteTSV_viaPasteboard_createsTableInWYSIWYG() {
        let h = EditorHarness(markdown: "before\n", windowActivation: .keyWindow)
        defer { h.teardown() }

        // Position cursor at end of "before"
        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: len, length: 0))

        // Put TSV data on the pasteboard — same format Numbers uses
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, .tabularText], owner: nil)
        pb.setString("A\tB\n1\t2", forType: .string)
        pb.setString("A\tB\n1\t2", forType: .tabularText)

        // Also declare the TSV UTI explicitly
        let tsvType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
        pb.setString("A\tB\n1\t2", forType: tsvType)

        // Call paste()
        h.editor.paste(nil)

        // After paste, document should contain a table block
        guard let doc = h.document else { XCTFail("no doc"); return }
        let hasTable = doc.blocks.contains { b in
            if case .table = b { return true }
            return false
        }
        XCTAssertTrue(
            hasTable,
            "Pasting TSV via pasteboard should create table block. " +
            "Blocks: \(doc.blocks.map { String(describing: $0) })"
        )
    }

    // MARK: - Integration: direct markdown insert (bypasses pasteboard)

    /// Paste into an empty note — blockContaining returns nil, must still work.
    func test_pasteTSV_intoEmptyNote_createsTable() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        h.editor.setSelectedRange(NSRange(location: 0, length: 0))

        let pb = NSPasteboard.general
        pb.clearContents()
        let tsvType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
        pb.declareTypes([.string, tsvType], owner: nil)
        pb.setString("A\tB\n1\t2", forType: .string)
        pb.setString("A\tB\n1\t2", forType: tsvType)

        h.editor.paste(nil)

        guard let doc = h.document else { XCTFail("no doc"); return }
        let hasTable = doc.blocks.contains { b in
            if case .table = b { return true }
            return false
        }
        XCTAssertTrue(
            hasTable,
            "Paste into empty note should create table. Blocks: \(doc.blocks.count)"
        )
    }

    /// Simulate the WYSIWYG code path with a markdown table string
    /// inserted into an existing note, verifying the full pipeline.
    func test_insertTableMarkdown_intoExistingNote_createsTable() {
        let h = EditorHarness(markdown: "before\n\nafter", windowActivation: .offscreen)
        defer { h.teardown() }

        // Cursor after "before\n" = position 7 (or wherever)
        let storageLen = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: storageLen, length: 0))

        guard let proj = h.editor.documentProjection,
              let note = h.editor.note
        else { XCTFail("no proj/note"); return }

        let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"

        // === This mirrors the TSV paste path exactly ===
        let cursorPos = h.editor.selectedRange().location
        guard let (blockIndex, _) = proj.blockContaining(
            storageIndex: cursorPos
        ) else {
            XCTFail("blockContaining returned nil at cursor=\(cursorPos)")
            return
        }

        let parsed = MarkdownParser.parse(markdown)
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

        guard let doc = h.document else { XCTFail("no doc"); return }
        let hasTable = doc.blocks.contains { b in
            if case .table = b { return true }
            return false
        }
        XCTAssertTrue(
            hasTable,
            "Markdown table insert should create table block. " +
            "Blocks: \(doc.blocks.map { String(describing: $0) })"
        )
    }
}
