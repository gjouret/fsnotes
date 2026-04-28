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

    // Phase 12.C.6.d — bracket-integrity: extra `[` immediately before
    // the opening `[[` rejects the wikilink. CommonMark spec #548
    // (`[[[foo]]]`) treats those bracket triples as plain text.
    func test_extraLeadingBracket_rejectsWikilink() {
        let input = chars("[[[foo]]]")
        // At start=1 we'd otherwise match `[[foo]]` — but chars[0]
        // is `[`, so the bracket-integrity rule fails the wikilink.
        XCTAssertNil(WikilinkParser.match(input, from: 1))
    }

    // Symmetric rule: extra `]` immediately after the closing `]]`
    // rejects the wikilink.
    func test_extraTrailingBracket_rejectsWikilink() {
        let input = chars("[[foo]]]")
        XCTAssertNil(WikilinkParser.match(input, from: 0))
    }

    // When the wikilink target also matches a link-reference-definition
    // label, the standard reference link wins. CommonMark spec #559.
    func test_endToEnd_targetMatchesRefDef_prefersRefLink() {
        let md = "[[*foo* bar]]\n\n[*foo* bar]: /url \"title\"\n"
        let doc = MarkdownParser.parse(md)
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let hasWikilink = inline.contains { ix in
            if case .wikilink = ix { return true }
            return false
        }
        XCTAssertFalse(hasWikilink, "wikilink should yield to ref-def match")
        let hasLink = inline.contains { ix in
            if case .link = ix { return true }
            return false
        }
        XCTAssertTrue(hasLink, "expected a regular ref-def link")
    }
}
