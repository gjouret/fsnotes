//
//  ParagraphInlineRoundTripTests.swift
//  FSNotesTests
//
//  Round-trip tests for paragraphs carrying inline emphasis markers
//  (**bold**, *italic*). This is the FIRST block type where markers
//  appear MID-LINE rather than at the start — the hardest case for
//  the block-model architecture to support correctly.
//
//      serialize(parse(markdown)) == markdown  (byte-equal)
//

import XCTest
@testable import FSNotes

class ParagraphInlineRoundTripTests: XCTestCase {

    private func assertRoundTrip(
        _ markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let doc = MarkdownParser.parse(markdown)
        let out = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(
            out, markdown,
            "round-trip diverged\nexpected: \(quoted(markdown))\nactual:   \(quoted(out))",
            file: file, line: line
        )
    }

    private func quoted(_ s: String) -> String {
        return "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            + "\""
    }

    // MARK: - Plain paragraphs (no markers)

    func test_roundTrip_plainParagraph() {
        assertRoundTrip("hello world\n")
    }

    func test_roundTrip_twoLineSoftBreak() {
        assertRoundTrip("hello\nworld\n")
    }

    // MARK: - Bold

    func test_roundTrip_simpleBold() {
        assertRoundTrip("**bold**\n")
    }

    func test_roundTrip_boldInSentence() {
        assertRoundTrip("this is **bold** text\n")
    }

    func test_roundTrip_boldAtStart() {
        assertRoundTrip("**first** rest\n")
    }

    func test_roundTrip_boldAtEnd() {
        assertRoundTrip("rest **last**\n")
    }

    func test_roundTrip_twoBoldRuns() {
        assertRoundTrip("**one** and **two**\n")
    }

    // MARK: - Italic

    func test_roundTrip_simpleItalic() {
        assertRoundTrip("*italic*\n")
    }

    func test_roundTrip_italicInSentence() {
        assertRoundTrip("this is *italic* text\n")
    }

    // MARK: - Mixed emphasis

    func test_roundTrip_boldAndItalic_separate() {
        assertRoundTrip("**bold** and *italic*\n")
    }

    // MARK: - Unmatched / degenerate markers (preserved as literal text)

    func test_roundTrip_loneAsterisk() {
        assertRoundTrip("5 * 3 = 15\n")
    }

    func test_roundTrip_openBoldNoClose() {
        assertRoundTrip("**unterminated\n")
    }

    func test_roundTrip_openItalicNoClose() {
        assertRoundTrip("*unterminated\n")
    }

    func test_roundTrip_asterisksWithSpaceInside() {
        // "* x *" has spaces adjacent to markers — not valid emphasis.
        assertRoundTrip("* x *\n")
    }

    func test_roundTrip_boldWithTrailingSpaceInside() {
        // "**bold **" has a space before the close — not valid bold.
        assertRoundTrip("**bold **\n")
    }

    // MARK: - Structural parse verification

    func test_parse_simpleBold() {
        let doc = MarkdownParser.parse("**hi**\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(inline, [.bold([.text("hi")])])
    }

    func test_parse_simpleItalic() {
        let doc = MarkdownParser.parse("*hi*\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(inline, [.italic([.text("hi")])])
    }

    func test_parse_boldInMiddle() {
        let doc = MarkdownParser.parse("a **b** c\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(inline, [.text("a "), .bold([.text("b")]), .text(" c")])
    }

    func test_parse_noEmphasisForLoneAsterisk() {
        let doc = MarkdownParser.parse("a * b\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(inline, [.text("a * b")])
    }
}
