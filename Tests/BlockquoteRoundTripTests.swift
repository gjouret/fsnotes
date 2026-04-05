//
//  BlockquoteRoundTripTests.swift
//  FSNotesTests
//
//  Round-trip tests for blockquotes — multi-line, nested, with
//  inline emphasis and mixed prefix styles.
//
//      serialize(parse(markdown)) == markdown  (byte-equal)
//

import XCTest
@testable import FSNotes

class BlockquoteRoundTripTests: XCTestCase {

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
        return "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // MARK: - Single-line quotes

    func test_roundTrip_simpleQuote() {
        assertRoundTrip("> hello\n")
    }

    func test_roundTrip_noSpaceAfterMarker() {
        assertRoundTrip(">hello\n")
    }

    func test_roundTrip_twoSpacesAfterMarker() {
        assertRoundTrip(">  two spaces\n")
    }

    func test_roundTrip_emptyQuoteLine() {
        assertRoundTrip(">\n")
    }

    // MARK: - Multi-line quotes

    func test_roundTrip_twoLineQuote() {
        assertRoundTrip("> first\n> second\n")
    }

    func test_roundTrip_threeLineQuote() {
        assertRoundTrip("> a\n> b\n> c\n")
    }

    // MARK: - Nested quotes

    func test_roundTrip_nested_tightForm() {
        assertRoundTrip(">> deep\n")
    }

    func test_roundTrip_nested_spacedForm() {
        assertRoundTrip("> > deep\n")
    }

    func test_roundTrip_nestedMultiLine() {
        assertRoundTrip("> outer\n>> inner\n> outer again\n")
    }

    // MARK: - Quotes with inline emphasis

    func test_roundTrip_boldInQuote() {
        assertRoundTrip("> this is **bold** text\n")
    }

    func test_roundTrip_codeInQuote() {
        assertRoundTrip("> call `foo()` here\n")
    }

    // MARK: - Quotes surrounded by other blocks

    func test_roundTrip_quoteAfterHeading() {
        assertRoundTrip("# Title\n> quote\n")
    }

    func test_roundTrip_quoteBeforeParagraph() {
        assertRoundTrip("> a\n> b\n\npara\n")
    }

    func test_roundTrip_twoQuotesSeparatedByBlank() {
        assertRoundTrip("> one\n\n> two\n")
    }

    // MARK: - Structural parse verification

    func test_parse_simpleQuote() {
        let doc = MarkdownParser.parse("> hi\n")
        guard case .blockquote(let lines) = doc.blocks[0] else {
            XCTFail("expected .blockquote"); return
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].prefix, "> ")
        XCTAssertEqual(lines[0].inline, [.text("hi")])
        XCTAssertEqual(lines[0].level, 1)
    }

    func test_parse_nestedLevels() {
        let doc = MarkdownParser.parse("> a\n>> b\n> > c\n")
        guard case .blockquote(let lines) = doc.blocks[0] else {
            XCTFail("expected .blockquote"); return
        }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].level, 1)
        XCTAssertEqual(lines[1].level, 2)
        XCTAssertEqual(lines[2].level, 2)
    }

    func test_parse_quoteWithBold() {
        let doc = MarkdownParser.parse("> a **b** c\n")
        guard case .blockquote(let lines) = doc.blocks[0] else {
            XCTFail("expected .blockquote"); return
        }
        XCTAssertEqual(
            lines[0].inline,
            [.text("a "), .bold([.text("b")]), .text(" c")]
        )
    }

    func test_parse_emptyQuoteLine() {
        let doc = MarkdownParser.parse(">\n")
        guard case .blockquote(let lines) = doc.blocks[0] else {
            XCTFail("expected .blockquote"); return
        }
        XCTAssertEqual(lines[0].prefix, ">")
        XCTAssertEqual(lines[0].inline, [])
    }
}
