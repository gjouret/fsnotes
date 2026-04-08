//
//  HorizontalRuleRoundTripTests.swift
//  FSNotesTests
//
//  Round-trip tests for horizontal rules (thematic breaks).
//
//      serialize(parse(markdown)) == markdown  (byte-equal)
//
//  Pure runs of 3+ identical `-`, `_`, or `*`.
//

import XCTest
@testable import FSNotes

class HorizontalRuleRoundTripTests: XCTestCase {

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

    // MARK: - Minimum-length runs

    func test_roundTrip_tripleDash() {
        assertRoundTrip("---\n")
    }

    func test_roundTrip_tripleUnderscore() {
        assertRoundTrip("___\n")
    }

    func test_roundTrip_tripleStar() {
        assertRoundTrip("***\n")
    }

    // MARK: - Longer runs preserve length

    func test_roundTrip_fiveDash() {
        assertRoundTrip("-----\n")
    }

    func test_roundTrip_tenDash() {
        assertRoundTrip("----------\n")
    }

    func test_roundTrip_sevenStar() {
        assertRoundTrip("*******\n")
    }

    // MARK: - HR surrounded by other blocks

    func test_roundTrip_hrBetweenParagraphs() {
        assertRoundTrip("before\n\n---\n\nafter\n")
    }

    func test_roundTrip_hrBetweenHeadings() {
        assertRoundTrip("# A\n\n---\n\n# B\n")
    }

    func test_roundTrip_twoConsecutiveHRs() {
        assertRoundTrip("---\n***\n")
    }

    // MARK: - Non-matching lines must NOT parse as HR

    func test_roundTrip_twoDash_notHR() {
        // Only 2 chars — below minimum length.
        assertRoundTrip("--\n")
    }

    func test_roundTrip_mixedChars_notHR() {
        // Mixed chars must NOT parse as HR.
        assertRoundTrip("--*\n")
    }

    func test_parse_dashWithSpace_isHR() {
        // CommonMark: spaces between HR chars are allowed.
        let doc = MarkdownParser.parse("- - -\n")
        guard case .horizontalRule(let char, let len) = doc.blocks[0] else {
            XCTFail("expected .horizontalRule, got \(doc.blocks[0])"); return
        }
        XCTAssertEqual(char, "-")
        XCTAssertEqual(len, 3)
    }

    // MARK: - Structural parse verification

    func test_parse_tripleDashIsHR() {
        let doc = MarkdownParser.parse("---\n")
        guard case .horizontalRule(let char, let len) = doc.blocks[0] else {
            XCTFail("expected .horizontalRule, got \(doc.blocks[0])"); return
        }
        XCTAssertEqual(char, "-")
        XCTAssertEqual(len, 3)
    }

    func test_parse_fiveStarIsHR() {
        let doc = MarkdownParser.parse("*****\n")
        guard case .horizontalRule(let char, let len) = doc.blocks[0] else {
            XCTFail("expected .horizontalRule"); return
        }
        XCTAssertEqual(char, "*")
        XCTAssertEqual(len, 5)
    }

    func test_parse_tripleUnderscoreIsHR() {
        let doc = MarkdownParser.parse("___\n")
        guard case .horizontalRule(let char, _) = doc.blocks[0] else {
            XCTFail("expected .horizontalRule"); return
        }
        XCTAssertEqual(char, "_")
    }
}
