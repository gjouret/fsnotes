//
//  MathParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Inline + display math combinator port tests.
//
//  Math is an FSNotes++ extension; the CommonMark spec corpus does
//  not cover it. These tests pin the detector behavior directly so a
//  regression in the port localises here rather than surfacing as
//  rendering glitches.
//

import XCTest
@testable import FSNotes

final class InlineMathParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    func test_basicInlineMath_matches() {
        let input = chars("$x+1$")
        guard let m = InlineMathParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.content, "x+1")
        XCTAssertEqual(m.endIndex, 5)
    }

    func test_emptyContent_returnsNil() {
        let input = chars("$$")
        // `$$` is display math, not empty inline math — InlineMathParser
        // explicitly skips this case.
        XCTAssertNil(InlineMathParser.match(input, from: 0))
    }

    func test_displayMathLooksLike_inlineParserSkips() {
        let input = chars("$$x$$")
        // First two `$`s are display open — inline parser skips.
        XCTAssertNil(InlineMathParser.match(input, from: 0))
    }

    func test_currencyAfterLetter_returnsNil() {
        // `cost: $5 USD` — InlineMathParser starting at the `$`
        // should not match because the predecessor is a letter
        // (boundary heuristic, not a true math context).
        let input = chars("USD$5")
        XCTAssertNil(InlineMathParser.match(input, from: 3))
    }

    func test_trailingSpaceRejected() {
        // `$x $` — content ends in space, rejected per spec.
        let input = chars("$x $")
        XCTAssertNil(InlineMathParser.match(input, from: 0))
    }

    func test_newlineInsideInline_returnsNil() {
        let input = chars("$x\ny$")
        XCTAssertNil(InlineMathParser.match(input, from: 0))
    }

    func test_unterminated_returnsNil() {
        let input = chars("$x+1")
        XCTAssertNil(InlineMathParser.match(input, from: 0))
    }

    func test_endToEnd_inParagraph_producesMathInline() {
        let doc = MarkdownParser.parse("compute $a+b$ now")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let mathInlines = inline.compactMap { ix -> String? in
            if case .math(let s) = ix { return s } else { return nil }
        }
        XCTAssertEqual(mathInlines, ["a+b"])
    }
}

final class DisplayMathParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    func test_basicDisplayMath_matches() {
        let input = chars("$$x+1$$")
        guard let m = DisplayMathParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.content, "x+1")
        XCTAssertEqual(m.endIndex, 7)
    }

    func test_displayMath_trimsWhitespace() {
        let input = chars("$$  x+1  $$")
        guard let m = DisplayMathParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.content, "x+1")
    }

    func test_displayMath_acceptsMultiline() {
        // Content between $$…$$ is preserved verbatim except for the
        // surrounding spaces/tabs trim (CharacterSet.whitespaces). Newlines
        // are content, not whitespace, so they survive the trim.
        let input = chars("$$\nfoo\nbar\n$$")
        guard let m = DisplayMathParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.content, "\nfoo\nbar\n")
    }

    func test_displayMath_emptyContent_returnsNil() {
        let input = chars("$$$$")
        XCTAssertNil(DisplayMathParser.match(input, from: 0))
    }

    func test_displayMath_singleDollar_returnsNil() {
        let input = chars("$x$")
        XCTAssertNil(DisplayMathParser.match(input, from: 0))
    }

    func test_displayMath_unterminated_returnsNil() {
        let input = chars("$$x+1")
        XCTAssertNil(DisplayMathParser.match(input, from: 0))
    }

    func test_endToEnd_inParagraph_producesDisplayMathInline() {
        let doc = MarkdownParser.parse("see $$\\sum x$$ here")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let dmInlines = inline.compactMap { ix -> String? in
            if case .displayMath(let s) = ix { return s } else { return nil }
        }
        XCTAssertEqual(dmInlines, ["\\sum x"])
    }
}
