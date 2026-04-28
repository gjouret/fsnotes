//
//  HardLineBreakParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.2 — Hard-line-break combinator port tests.
//
//  The CommonMark spec corpus already pins the public-API behaviour
//  via `CommonMarkSpecTests.test_hardLineBreaks` (5/5 examples). This
//  file pins the COMBINATOR DETECTOR directly so a regression in the
//  port is localised — without these tests, a combinator bug would
//  surface as one of the 5 spec-bucket failures and the trace would
//  walk through `parseInlines` before reaching the cause.
//

import XCTest
@testable import FSNotes

final class HardLineBreakParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    // MARK: - Backslash-before-newline form

    func test_backslashNewline_atStart_matches() {
        let input = chars("\\\nrest")
        guard let m = HardLineBreakParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.raw, "\\\n")
        XCTAssertEqual(m.endIndex, 2)
    }

    func test_backslashNewline_inMiddle_matches() {
        // "abc\\\ndef" — match starts at index 3 (the backslash).
        let input = chars("abc\\\ndef")
        guard let m = HardLineBreakParser.match(input, from: 3) else {
            return XCTFail("expected match at index 3")
        }
        XCTAssertEqual(m.raw, "\\\n")
        XCTAssertEqual(m.endIndex, 5)
    }

    func test_lonebackslash_doesNotMatch() {
        // Backslash at end of input — no following newline.
        let input = chars("abc\\")
        XCTAssertNil(HardLineBreakParser.match(input, from: 3))
    }

    func test_backslashFollowedByNonNewline_doesNotMatch() {
        // \X where X is not newline — handled by the escape-char branch
        // in parseInlines, not by the hard-break combinator.
        let input = chars("\\xyz")
        XCTAssertNil(HardLineBreakParser.match(input, from: 0))
    }

    // MARK: - Two-or-more-spaces form

    func test_twoSpacesNewline_matches() {
        let input = chars("hello  \nworld")
        // Match starts at index 5 (first space).
        guard let m = HardLineBreakParser.match(input, from: 5) else {
            return XCTFail("expected match at index 5")
        }
        XCTAssertEqual(m.raw, "  \n")
        XCTAssertEqual(m.endIndex, 8)
    }

    func test_fourSpacesNewline_matches_consumesAllSpaces() {
        let input = chars("hello    \nworld")
        guard let m = HardLineBreakParser.match(input, from: 5) else {
            return XCTFail("expected match at index 5")
        }
        XCTAssertEqual(m.raw, "    \n")
        XCTAssertEqual(m.endIndex, 10)
    }

    func test_singleSpaceNewline_doesNotMatch_perSpec() {
        // Spec: ≥ 2 spaces required.
        let input = chars("hello \nworld")
        XCTAssertNil(HardLineBreakParser.match(input, from: 5))
    }

    func test_zeroSpaces_doesNotMatch() {
        // Pure newline (without any preceding spaces) is a soft break,
        // not a hard break — handled elsewhere in parseInlines.
        let input = chars("hello\nworld")
        XCTAssertNil(HardLineBreakParser.match(input, from: 5))
    }

    func test_spacesWithoutNewline_doesNotMatch() {
        // Trailing spaces but no newline (e.g. end of input) — no break.
        let input = chars("hello   ")
        XCTAssertNil(HardLineBreakParser.match(input, from: 5))
    }

    // MARK: - Cursor-bounds edge cases

    func test_cursorAtEndOfInput_returnsNil() {
        let input = chars("abc")
        XCTAssertNil(HardLineBreakParser.match(input, from: 3))
    }

    func test_cursorPastEndOfInput_returnsNil() {
        let input = chars("abc")
        XCTAssertNil(HardLineBreakParser.match(input, from: 99))
    }

    // MARK: - Round-trip via MarkdownParser (the real regression gate)

    func test_endToEnd_backslashBreak_producesLineBreakInline() {
        let md = "first\\\nsecond"
        let doc = MarkdownParser.parse(md)
        guard case .paragraph(let inline) = doc.blocks.first else {
            return XCTFail("not a paragraph: \(doc.blocks)")
        }
        let kinds = inline.map { kind(of: $0) }
        XCTAssertTrue(kinds.contains("lineBreak"), "no .lineBreak in \(kinds)")
    }

    func test_endToEnd_spacesBreak_producesLineBreakInline() {
        let md = "first  \nsecond"
        let doc = MarkdownParser.parse(md)
        guard case .paragraph(let inline) = doc.blocks.first else {
            return XCTFail("not a paragraph: \(doc.blocks)")
        }
        let kinds = inline.map { kind(of: $0) }
        XCTAssertTrue(kinds.contains("lineBreak"), "no .lineBreak in \(kinds)")
    }

    func test_endToEnd_singleSpaceNewline_producesSoftBreak_notHard() {
        let md = "first \nsecond"
        let doc = MarkdownParser.parse(md)
        guard case .paragraph(let inline) = doc.blocks.first else {
            return XCTFail("not a paragraph: \(doc.blocks)")
        }
        // Single trailing space + \n → not a hard break. The serializer
        // / renderer treats it as a soft break (rendered as a space).
        let kinds = inline.map { kind(of: $0) }
        XCTAssertFalse(kinds.contains("lineBreak"), "should NOT be hard break: \(kinds)")
    }

    /// Cheap kind-string for assertions. The tests here only need to
    /// distinguish `lineBreak` from everything else, so the catch-all
    /// covers the rest. (Inline has 18+ cases including some that
    /// might evolve; pinning every case here would be churn for no
    /// added test value.)
    private func kind(of inline: Inline) -> String {
        if case .lineBreak = inline { return "lineBreak" }
        if case .text = inline { return "text" }
        return "other"
    }
}
