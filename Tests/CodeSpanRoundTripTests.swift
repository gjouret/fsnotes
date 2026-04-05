//
//  CodeSpanRoundTripTests.swift
//  FSNotesTests
//
//  Round-trip tests for inline code spans (`code`). Exercises the
//  parser/serializer precedence rule that code spans outrank emphasis
//  (per CommonMark): `**` inside backticks stays as literal text.
//

import XCTest
@testable import FSNotes

class CodeSpanRoundTripTests: XCTestCase {

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

    // MARK: - Basic code spans

    func test_roundTrip_simpleCodeSpan() {
        assertRoundTrip("`x`\n")
    }

    func test_roundTrip_codeSpanInSentence() {
        assertRoundTrip("use `foo` to bar\n")
    }

    func test_roundTrip_codeSpanAtStart() {
        assertRoundTrip("`first` word\n")
    }

    func test_roundTrip_codeSpanAtEnd() {
        assertRoundTrip("trailing `code`\n")
    }

    func test_roundTrip_twoCodeSpans() {
        assertRoundTrip("`one` and `two`\n")
    }

    // MARK: - Whitespace preservation (no CommonMark strip)

    func test_roundTrip_codeSpanLeadingSpace() {
        assertRoundTrip("` x`\n")
    }

    func test_roundTrip_codeSpanTrailingSpace() {
        assertRoundTrip("`x `\n")
    }

    // MARK: - Precedence: code > emphasis

    func test_roundTrip_asterisksInsideCode() {
        // `**x**` must parse as a code span containing "**x**", NOT as
        // bold wrapped around a code span.
        assertRoundTrip("`**x**`\n")
    }

    func test_roundTrip_boldContainingCode() {
        // Bold wraps around a code span. Inner ` must be parsed.
        assertRoundTrip("**bold `code` here**\n")
    }

    // MARK: - Unmatched / degenerate backticks

    func test_roundTrip_loneBacktick() {
        assertRoundTrip("a ` b\n")
    }

    func test_roundTrip_doubleBacktick_notCodeSpan() {
        // Double-backtick spans are out of tracer-bullet scope — must
        // round-trip verbatim as literal backticks.
        assertRoundTrip("``code``\n")
    }

    func test_roundTrip_backtickAtEnd() {
        assertRoundTrip("trailing `\n")
    }

    // MARK: - Structural parse verification

    func test_parse_simpleCodeSpan() {
        let doc = MarkdownParser.parse("`hi`\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(inline, [.code("hi")])
    }

    func test_parse_codeSpanInSentence() {
        let doc = MarkdownParser.parse("a `b` c\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(inline, [.text("a "), .code("b"), .text(" c")])
    }

    func test_parse_codeSpanPrecedesEmphasis() {
        let doc = MarkdownParser.parse("`**x**`\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        // Content of code span is literal: "**x**", NOT bold.
        XCTAssertEqual(inline, [.code("**x**")])
    }

    func test_parse_boldContainingCode() {
        let doc = MarkdownParser.parse("**a `b` c**\n")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph"); return
        }
        XCTAssertEqual(inline, [.bold([.text("a "), .code("b"), .text(" c")])])
    }
}
