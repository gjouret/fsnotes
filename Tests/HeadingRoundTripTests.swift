//
//  HeadingRoundTripTests.swift
//  FSNotesTests
//
//  Round-trip tests for ATX headings:
//      serialize(parse(markdown)) == markdown  (byte-equal)
//
//  Headings are the SECOND block type proved by the tracer bullet
//  (code blocks were first). They establish that the architecture
//  generalizes past code blocks.
//

import XCTest
@testable import FSNotes

class HeadingRoundTripTests: XCTestCase {

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

    // MARK: - Round-trip: each heading level

    func test_roundTrip_h1() { assertRoundTrip("# Hello\n") }
    func test_roundTrip_h2() { assertRoundTrip("## Hello\n") }
    func test_roundTrip_h3() { assertRoundTrip("### Hello\n") }
    func test_roundTrip_h4() { assertRoundTrip("#### Hello\n") }
    func test_roundTrip_h5() { assertRoundTrip("##### Hello\n") }
    func test_roundTrip_h6() { assertRoundTrip("###### Hello\n") }

    // MARK: - Round-trip: whitespace preservation

    func test_roundTrip_headingExtraSpaces() {
        assertRoundTrip("#  Two leading spaces\n")
    }

    func test_roundTrip_headingTrailingSpaces() {
        assertRoundTrip("# Hello   \n")
    }

    func test_roundTrip_headingTab() {
        assertRoundTrip("#\tHello\n")
    }

    // MARK: - Round-trip: empty / edge

    func test_roundTrip_emptyH1_noSpace() {
        // "#" at end of line is a valid empty h1 per CommonMark.
        assertRoundTrip("#\n")
    }

    func test_roundTrip_emptyH1_withSpace() {
        assertRoundTrip("# \n")
    }

    func test_roundTrip_headingNoTrailingNewline() {
        assertRoundTrip("# Hello")
    }

    // MARK: - Round-trip: mixed with other blocks

    func test_roundTrip_headingThenText() {
        assertRoundTrip("# Title\nbody text\n")
    }

    func test_roundTrip_headingWithBlankLinesAround() {
        assertRoundTrip("before\n\n# Title\n\nafter\n")
    }

    func test_roundTrip_multipleHeadings() {
        assertRoundTrip("# One\n## Two\n### Three\n")
    }

    func test_roundTrip_headingsAroundCodeBlock() {
        assertRoundTrip("# Intro\n```\ncode\n```\n## Next\n")
    }

    // MARK: - Round-trip: non-heading lines (must NOT become headings)

    func test_roundTrip_hashWithoutSpace_isRawText() {
        assertRoundTrip("#NotAHeading\n")
    }

    func test_roundTrip_sevenHashes_isRawText() {
        assertRoundTrip("####### too many\n")
    }

    func test_roundTrip_hashMidLine_isRawText() {
        assertRoundTrip("some text # with hash\n")
    }

    // MARK: - Structural parse verification

    func test_parse_headingStructure() {
        let doc = MarkdownParser.parse("## Hello\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .heading(let level, let suffix) = doc.blocks[0] else {
            XCTFail("expected heading"); return
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(suffix, " Hello")
    }

    func test_parse_emptyHeading() {
        let doc = MarkdownParser.parse("###\n")
        guard case .heading(let level, let suffix) = doc.blocks[0] else {
            XCTFail("expected heading"); return
        }
        XCTAssertEqual(level, 3)
        XCTAssertEqual(suffix, "")
    }

    func test_parse_hashWithoutSpace_isNotHeading() {
        let doc = MarkdownParser.parse("#NotHeading\n")
        for block in doc.blocks {
            if case .heading = block {
                XCTFail("must not parse as heading (missing required space)")
            }
        }
    }
}
