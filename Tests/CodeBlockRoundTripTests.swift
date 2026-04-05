//
//  CodeBlockRoundTripTests.swift
//  FSNotesTests
//
//  Round-trip tests for the tracer-bullet parser + serializer:
//      serialize(parse(markdown)) == markdown  (byte-equal)
//
//  This is the single most important test for the architecture migration.
//  If round-trip fails, we lose user data on save. Zero tolerance.
//

import XCTest
@testable import FSNotes

class CodeBlockRoundTripTests: XCTestCase {

    // MARK: - Round-trip helper

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

    // MARK: - Empty / minimal

    func test_roundTrip_empty() {
        assertRoundTrip("")
    }

    func test_roundTrip_singleNewline() {
        assertRoundTrip("\n")
    }

    func test_roundTrip_plainTextNoTrailingNewline() {
        assertRoundTrip("hello")
    }

    func test_roundTrip_plainTextTrailingNewline() {
        assertRoundTrip("hello\n")
    }

    func test_roundTrip_twoLinesTrailingNewline() {
        assertRoundTrip("hello\nworld\n")
    }

    func test_roundTrip_blankLineBetween() {
        assertRoundTrip("hello\n\nworld\n")
    }

    func test_roundTrip_multipleBlankLines() {
        assertRoundTrip("a\n\n\nb\n")
    }

    // MARK: - Code blocks

    func test_roundTrip_emptyCodeBlock() {
        assertRoundTrip("```\n```\n")
    }

    func test_roundTrip_codeBlockNoLanguage() {
        assertRoundTrip("```\nfoo\n```\n")
    }

    func test_roundTrip_codeBlockWithLanguage() {
        assertRoundTrip("```python\nprint('hi')\n```\n")
    }

    func test_roundTrip_codeBlockMultipleLines() {
        assertRoundTrip("```swift\nlet x = 1\nlet y = 2\n```\n")
    }

    func test_roundTrip_codeBlockWithBlankLineInside() {
        assertRoundTrip("```\nfoo\n\nbar\n```\n")
    }

    func test_roundTrip_codeBlockSurroundedByText() {
        assertRoundTrip("before\n```\ncode\n```\nafter\n")
    }

    func test_roundTrip_codeBlockWithBlankLinesAround() {
        assertRoundTrip("before\n\n```py\ncode\n```\n\nafter\n")
    }

    func test_roundTrip_twoCodeBlocks() {
        assertRoundTrip("```\na\n```\n\n```\nb\n```\n")
    }

    func test_roundTrip_tildeFence() {
        assertRoundTrip("~~~\nfoo\n~~~\n")
    }

    func test_roundTrip_fourBacktickFence() {
        assertRoundTrip("````\nfoo\n````\n")
    }

    func test_roundTrip_noTrailingNewline() {
        assertRoundTrip("```\nfoo\n```")
    }

    // MARK: - Structural parse verification

    func test_parse_codeBlockStructure() {
        let doc = MarkdownParser.parse("```python\nprint(1)\n```\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .codeBlock(let lang, let content, let fence) = doc.blocks[0] else {
            XCTFail("expected codeBlock"); return
        }
        XCTAssertEqual(lang, "python")
        XCTAssertEqual(content, "print(1)")
        XCTAssertEqual(fence.character, .backtick)
        XCTAssertEqual(fence.length, 3)
        XCTAssertTrue(doc.trailingNewline)
    }

    func test_parse_noLanguage() {
        let doc = MarkdownParser.parse("```\nfoo\n```\n")
        guard case .codeBlock(let lang, _, _) = doc.blocks[0] else {
            XCTFail("expected codeBlock"); return
        }
        XCTAssertNil(lang)
    }

    func test_parse_emptyContent() {
        let doc = MarkdownParser.parse("```\n```\n")
        guard case .codeBlock(_, let content, _) = doc.blocks[0] else {
            XCTFail("expected codeBlock"); return
        }
        XCTAssertEqual(content, "")
    }

    func test_parse_unterminatedFenceTreatedAsRawText() {
        // Unterminated fence: the whole thing becomes raw text (preserves round-trip).
        let input = "```\nno close fence\n"
        let doc = MarkdownParser.parse(input)
        // Should NOT contain a codeBlock — everything is raw.
        for block in doc.blocks {
            if case .codeBlock = block {
                XCTFail("unterminated fence should not parse as codeBlock")
            }
        }
        // And must round-trip.
        XCTAssertEqual(MarkdownSerializer.serialize(doc), input)
    }
}
