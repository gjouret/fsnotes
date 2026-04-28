//
//  HtmlBlockReaderTests.swift
//  FSNotesTests
//
//  Phase 12.C.5 — HTML block reader port tests.
//

import XCTest
@testable import FSNotes

final class HtmlBlockReaderTests: XCTestCase {

    // MARK: - detect()

    func test_detect_type1_pre() {
        XCTAssertEqual(HtmlBlockReader.detect("<pre>"), 1)
        XCTAssertEqual(HtmlBlockReader.detect("<pre>foo</pre>"), 1)
        XCTAssertEqual(HtmlBlockReader.detect("<PRE>"), 1)
    }

    func test_detect_type1_script_style_textarea() {
        XCTAssertEqual(HtmlBlockReader.detect("<script>"), 1)
        XCTAssertEqual(HtmlBlockReader.detect("<style type=\"text/css\">"), 1)
        XCTAssertEqual(HtmlBlockReader.detect("<textarea>"), 1)
    }

    func test_detect_type2_comment() {
        XCTAssertEqual(HtmlBlockReader.detect("<!-- comment"), 2)
        XCTAssertEqual(HtmlBlockReader.detect("<!-- inline -->"), 2)
    }

    func test_detect_type3_processingInstruction() {
        XCTAssertEqual(HtmlBlockReader.detect("<?xml version=\"1.0\"?>"), 3)
        XCTAssertEqual(HtmlBlockReader.detect("<?php"), 3)
    }

    func test_detect_type4_declaration() {
        XCTAssertEqual(HtmlBlockReader.detect("<!DOCTYPE html>"), 4)
        XCTAssertEqual(HtmlBlockReader.detect("<!ENTITY foo"), 4)
        // Lowercase third char does NOT trigger type 4.
        XCTAssertNotEqual(HtmlBlockReader.detect("<!doctype html>"), 4)
    }

    func test_detect_type5_cdata() {
        XCTAssertEqual(HtmlBlockReader.detect("<![CDATA[ text"), 5)
    }

    func test_detect_type6_blockTag() {
        XCTAssertEqual(HtmlBlockReader.detect("<div>"), 6)
        XCTAssertEqual(HtmlBlockReader.detect("<table class=\"x\">"), 6)
        XCTAssertEqual(HtmlBlockReader.detect("</p>"), 6)
        XCTAssertEqual(HtmlBlockReader.detect("<DIV>"), 6)
    }

    func test_detect_type7_completeOpenTag() {
        XCTAssertEqual(HtmlBlockReader.detect("<a href=\"x\">"), 7)
        XCTAssertEqual(HtmlBlockReader.detect("<custom-tag />"), 7)
        XCTAssertEqual(HtmlBlockReader.detect("</a>"), 7)
    }

    func test_detect_rejects_4plusLeadingSpaces() {
        // 4-space indent → indented code context, not HTML block.
        XCTAssertNil(HtmlBlockReader.detect("    <div>"))
    }

    func test_detect_acceptsUpTo3LeadingSpaces() {
        XCTAssertEqual(HtmlBlockReader.detect("   <div>"), 6)
        XCTAssertEqual(HtmlBlockReader.detect("  <pre>"), 1)
    }

    func test_detect_rejects_nonAngle() {
        XCTAssertNil(HtmlBlockReader.detect("plain text"))
        XCTAssertNil(HtmlBlockReader.detect(""))
    }

    func test_detect_rejects_unknownTagName() {
        // Type 6 requires the tag to be in the block-level set; type 7
        // would still match if the tag is well-formed. Bare "<xyz" is
        // not a complete tag (no >), so type 7 is also rejected.
        XCTAssertNil(HtmlBlockReader.detect("<unknownTagName"))
    }

    // MARK: - read() — type 1 (pre/script/style/textarea)

    func test_read_type1_singleLine_endsImmediately() {
        let lines = ["<pre>foo</pre>", "after"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 1)
        guard case .htmlBlock(let raw) = result.block else {
            return XCTFail("expected htmlBlock")
        }
        XCTAssertEqual(raw, "<pre>foo</pre>")
    }

    func test_read_type1_multiLine_endsAtClosingTag() {
        let lines = ["<pre>", "code", "</pre>", "after"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 3)
        guard case .htmlBlock(let raw) = result.block else {
            return XCTFail("expected htmlBlock")
        }
        XCTAssertEqual(raw, "<pre>\ncode\n</pre>")
    }

    func test_read_type1_unclosed_extendsToEnd() {
        let lines = ["<pre>", "code", "more"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 3)
    }

    // MARK: - read() — type 2 (comment)

    func test_read_type2_multiLineComment() {
        let lines = ["<!--", "line", "-->", "after"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 3)
        guard case .htmlBlock(let raw) = result.block else {
            return XCTFail("expected htmlBlock")
        }
        XCTAssertEqual(raw, "<!--\nline\n-->")
    }

    // MARK: - read() — type 6 (block tags) ends at blank line

    func test_read_type6_endsAtBlankLine_exclusive() {
        let lines = ["<div>", "content", "", "after"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        // blank line at index 2 closes; nextIndex points AT the blank
        // line (exclusive close — block loop will handle it).
        XCTAssertEqual(result.nextIndex, 2)
        guard case .htmlBlock(let raw) = result.block else {
            return XCTFail("expected htmlBlock")
        }
        XCTAssertEqual(raw, "<div>\ncontent")
    }

    func test_read_type6_runsToEndIfNoBlankLine() {
        let lines = ["<div>", "content"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 2)
    }

    // MARK: - read() — type 7 (paragraph-interrupt gate)

    func test_read_type7_blockedWhenRawBufferNonEmpty() {
        let lines = ["<a href=\"x\">"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: false
        )
        XCTAssertNil(r, "type 7 must not interrupt an open paragraph")
    }

    func test_read_type7_acceptedWhenRawBufferEmpty() {
        let lines = ["<a href=\"x\">", "content"]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 2)
    }

    // MARK: - trailingNewline handling

    func test_read_skipsTrailingSyntheticEmptyLine() {
        // Input "<div>\ncontent\n" splits to ["<div>", "content", ""].
        let lines = ["<div>", "content", ""]
        let r = HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: true, rawBufferEmpty: true
        )
        guard let result = r else { return XCTFail("expected match") }
        // The trailing empty line is the document terminator, NOT the
        // type-6 blank-line closer; reader must skip it as a closer.
        // Without trailingNewline=true, the empty line at index 2
        // would be a real blank line that closes type 6.
        XCTAssertEqual(result.nextIndex, 2)
    }

    // MARK: - endsOnLine()

    func test_endsOnLine_type1_sameLine() {
        XCTAssertTrue(HtmlBlockReader.endsOnLine("<pre>x</pre>", type: 1))
        XCTAssertTrue(HtmlBlockReader.endsOnLine("<style>x</style>", type: 1))
        XCTAssertFalse(HtmlBlockReader.endsOnLine("<pre>", type: 1))
    }

    func test_endsOnLine_type2_commentSameLine() {
        XCTAssertTrue(HtmlBlockReader.endsOnLine("<!-- x -->", type: 2))
        XCTAssertFalse(HtmlBlockReader.endsOnLine("<!-- x", type: 2))
    }

    func test_endsOnLine_type6and7_alwaysFalse() {
        XCTAssertFalse(HtmlBlockReader.endsOnLine("<div>foo</div>", type: 6))
        XCTAssertFalse(HtmlBlockReader.endsOnLine("<a href=\"x\">", type: 7))
    }

    // MARK: - End-to-end: full MarkdownParser pipeline

    func test_endToEnd_type6_viaParse() {
        let doc = MarkdownParser.parse("<div>\ncontent\n</div>\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .htmlBlock(let raw) = doc.blocks[0] else {
            return XCTFail("expected htmlBlock, got \(doc.blocks)")
        }
        XCTAssertEqual(raw, "<div>\ncontent\n</div>")
    }

    func test_endToEnd_type1_styleBlock_viaParse() {
        let doc = MarkdownParser.parse("<style>\n.x{color:red;}\n</style>\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .htmlBlock(let raw) = doc.blocks[0] else {
            return XCTFail("expected htmlBlock, got \(doc.blocks)")
        }
        XCTAssertTrue(raw.contains(".x{color:red;}"))
    }

    func test_endToEnd_type2_commentBlock_viaParse() {
        let doc = MarkdownParser.parse("<!--\nfoo\n-->\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .htmlBlock = doc.blocks[0] else {
            return XCTFail("expected htmlBlock")
        }
    }

    func test_endToEnd_type7_doesNotInterruptParagraph() {
        // Type 7 in the middle of a paragraph stays paragraph content;
        // the rawBuffer-empty gate enforces this.
        let doc = MarkdownParser.parse("Hello\n<a href=\"x\">\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .paragraph = doc.blocks[0] else {
            return XCTFail("expected paragraph absorbing the type 7 tag, got \(doc.blocks)")
        }
    }

    func test_endToEnd_type6_interruptsParagraph() {
        // Type 6 CAN interrupt a paragraph.
        let doc = MarkdownParser.parse("Hello\n<div>\ncontent\n</div>\n")
        XCTAssertEqual(doc.blocks.count, 2)
        guard case .paragraph = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        guard case .htmlBlock = doc.blocks[1] else {
            return XCTFail("expected htmlBlock")
        }
    }

    // MARK: - Negative

    func test_read_returnsNil_whenNotHTMLBlock() {
        let lines = ["plain paragraph"]
        XCTAssertNil(HtmlBlockReader.read(
            lines: lines, from: 0, trailingNewline: false, rawBufferEmpty: true
        ))
    }
}
