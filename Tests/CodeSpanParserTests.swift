//
//  CodeSpanParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Code-span combinator port tests.
//
//  The CommonMark spec corpus already pins the public-API behaviour
//  via `CommonMarkSpecTests.test_codeSpans` (22/22 examples). This
//  file pins the COMBINATOR DETECTOR directly so a regression in the
//  port is localised — without these tests, a combinator bug would
//  surface as one of the 22 spec-bucket failures and the trace would
//  walk through `parseInlines` before reaching the cause.
//

import XCTest
@testable import FSNotes

final class CodeSpanParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    // MARK: - Single-backtick spans

    func test_singleBacktick_basic_matches() {
        let input = chars("`code`")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "code")
        XCTAssertEqual(m.endIndex, 6)
    }

    func test_twoBackticks_alone_doNotClose() {
        // `` `` `` (two consecutive backticks with nothing else) is an
        // open run that never finds a same-length close. The original
        // imperative `tryMatchCodeSpan` returned nil for this; the
        // combinator port preserves the behavior.
        let input = chars("``")
        XCTAssertNil(CodeSpanParser.match(input, from: 0))
    }

    func test_singleBacktick_unclosed_returnsNil() {
        let input = chars("`code")
        XCTAssertNil(CodeSpanParser.match(input, from: 0))
    }

    func test_notAtBacktick_returnsNil() {
        let input = chars("plain")
        XCTAssertNil(CodeSpanParser.match(input, from: 0))
    }

    // MARK: - Multi-backtick spans

    func test_doubleBacktick_basic_matches() {
        let input = chars("``hi``")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "hi")
        XCTAssertEqual(m.endIndex, 6)
    }

    func test_tripleBacktick_basic_matches() {
        let input = chars("```code```")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "code")
        XCTAssertEqual(m.endIndex, 10)
    }

    func test_doubleBacktick_canContainSingleBacktick() {
        // CommonMark example: ``foo ` bar`` — the single backtick is
        // body content because the closing run must be exactly 2.
        let input = chars("``foo ` bar``")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "foo ` bar")
        XCTAssertEqual(m.endIndex, 13)
    }

    func test_singleBacktick_skipsLongerCloseRun() {
        // `foo`` — opening 1, closing 2: not a match because the
        // closing run length must equal the opening run length AND
        // we'd need to find an isolated single backtick. Since the
        // body+close scanner absorbs the `` and never sees a lone
        // closing `, this returns nil.
        let input = chars("`foo``bar")
        XCTAssertNil(CodeSpanParser.match(input, from: 0))
    }

    // MARK: - Spec post-processing rules

    func test_singleSpaceStrip_leadingAndTrailing() {
        // ` `code` ` (with both leading + trailing space) → "code"
        let input = chars("` code `")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "code")
    }

    func test_noSpaceStrip_whenOnlyLeading() {
        // ` code` (leading only) — no strip.
        let input = chars("` code`")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, " code")
    }

    func test_noSpaceStrip_whenAllSpaces() {
        // `  ` (all spaces, length 2) — no strip per CommonMark
        // §6.1 ("not all-spaces").
        let input = chars("`  `")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "  ")
    }

    func test_newlineCollapsesToSpace() {
        // `foo\nbar` — newline inside a code span becomes a space.
        let input = chars("`foo\nbar`")
        guard let m = CodeSpanParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "foo bar")
    }

    // MARK: - Cursor-position preconditions

    func test_precededByBacktick_returnsNil() {
        // `````code```` — start at index 1 (second backtick) — the
        // CommonMark precedence rule rejects a span that starts
        // immediately after another backtick because the longer run
        // is the actual opener.
        let input = chars("``code``")
        XCTAssertNil(CodeSpanParser.match(input, from: 1))
    }

    func test_pastEndOfInput_returnsNil() {
        let input = chars("abc")
        XCTAssertNil(CodeSpanParser.match(input, from: 3))
    }

    func test_atEndOfInput_returnsNil() {
        let input = chars("abc")
        XCTAssertNil(CodeSpanParser.match(input, from: 2))
    }

    // MARK: - End-to-end via MarkdownParser

    func test_endToEnd_codeSpanInParagraph_producesCodeInline() {
        let doc = MarkdownParser.parse("hello `world` rest")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        // Expected inline structure: text("hello "), code("world"), text(" rest")
        XCTAssertEqual(inline.count, 3)
        guard case .code(let inner) = inline[1] else {
            return XCTFail("expected code inline at index 1, got \(inline[1])")
        }
        XCTAssertEqual(inner, "world")
    }

    func test_endToEnd_unclosedBacktick_remainsLiteral() {
        let doc = MarkdownParser.parse("hello `world rest")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        // No code inline — the lone backtick is literal text.
        for ix in inline {
            if case .code = ix {
                XCTFail("unexpected code inline in unclosed-backtick input")
            }
        }
    }
}
