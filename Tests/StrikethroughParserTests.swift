//
//  StrikethroughParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Strikethrough combinator port tests.
//

import XCTest
@testable import FSNotes

final class StrikethroughParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    func test_basic_matches() {
        let input = chars("~~gone~~")
        guard let m = StrikethroughParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "gone")
        XCTAssertEqual(m.endIndex, 8)
    }

    func test_innerSingleTilde_preserved() {
        // `~~a~b~~` — single `~` inside the body is content.
        let input = chars("~~a~b~~")
        guard let m = StrikethroughParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.inner, "a~b")
    }

    func test_tripleTildeOpen_returnsNil() {
        let input = chars("~~~bad~~~")
        XCTAssertNil(StrikethroughParser.match(input, from: 0))
    }

    func test_leadingWhitespace_rejected() {
        let input = chars("~~ x~~")
        XCTAssertNil(StrikethroughParser.match(input, from: 0))
    }

    func test_trailingWhitespace_rejected() {
        let input = chars("~~x ~~")
        XCTAssertNil(StrikethroughParser.match(input, from: 0))
    }

    func test_unterminated_returnsNil() {
        let input = chars("~~gone")
        XCTAssertNil(StrikethroughParser.match(input, from: 0))
    }

    func test_notAtTilde_returnsNil() {
        let input = chars("hello")
        XCTAssertNil(StrikethroughParser.match(input, from: 0))
    }

    func test_endToEnd_inParagraph_producesStrikeInline() {
        let doc = MarkdownParser.parse("see ~~old~~ thing")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let strikes = inline.compactMap { ix -> [Inline]? in
            if case .strikethrough(let inner) = ix { return inner } else { return nil }
        }
        XCTAssertEqual(strikes.count, 1)
        guard case .text(let s) = strikes[0][0] else {
            return XCTFail("expected text inline")
        }
        XCTAssertEqual(s, "old")
    }
}
