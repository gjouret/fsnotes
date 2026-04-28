//
//  WikilinkParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Wikilink combinator port tests.
//

import XCTest
@testable import FSNotes

final class WikilinkParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    func test_basic_matches() {
        let input = chars("[[Foo]]")
        guard let m = WikilinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.target, "Foo")
        XCTAssertNil(m.display)
        XCTAssertEqual(m.endIndex, 7)
    }

    func test_targetWithDisplay_matches() {
        let input = chars("[[Foo|Bar]]")
        guard let m = WikilinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.target, "Foo")
        XCTAssertEqual(m.display, "Bar")
    }

    func test_emptyDisplay_returnsNilDisplay() {
        // `[[Foo|]]` — display is empty after the pipe, normalize to nil.
        let input = chars("[[Foo|]]")
        guard let m = WikilinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.target, "Foo")
        XCTAssertNil(m.display)
    }

    func test_emptyTarget_returnsNil() {
        // `[[|Bar]]` — target empty, reject.
        let input = chars("[[|Bar]]")
        XCTAssertNil(WikilinkParser.match(input, from: 0))
    }

    func test_emptyContent_returnsNil() {
        let input = chars("[[]]")
        XCTAssertNil(WikilinkParser.match(input, from: 0))
    }

    func test_bracketInBody_rejected() {
        let input = chars("[[a[b]]")
        XCTAssertNil(WikilinkParser.match(input, from: 0))
    }

    func test_newlineInBody_rejected() {
        let input = chars("[[a\nb]]")
        XCTAssertNil(WikilinkParser.match(input, from: 0))
    }

    func test_unterminated_returnsNil() {
        let input = chars("[[Foo")
        XCTAssertNil(WikilinkParser.match(input, from: 0))
    }

    func test_endToEnd_inParagraph_producesWikilinkInline() {
        let doc = MarkdownParser.parse("see [[Page|alias]] now")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let wikis = inline.compactMap { ix -> (String, String?)? in
            if case .wikilink(let target, let display) = ix {
                return (target, display)
            }
            return nil
        }
        XCTAssertEqual(wikis.count, 1)
        XCTAssertEqual(wikis[0].0, "Page")
        XCTAssertEqual(wikis[0].1, "alias")
    }
}
