//
//  LinkParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Inline-link + image combinator port tests. The
//  CommonMark spec corpus already pins the public-API behaviour via
//  `CommonMarkSpecTests.test_links` (76/90) and `test_images` (21/22);
//  these tests pin the detector directly.
//

import XCTest
@testable import FSNotes

final class LinkParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    func test_basicLink_matches() {
        let input = chars("[text](url)")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "text")
        XCTAssertEqual(m.dest, "url")
        XCTAssertEqual(m.endIndex, 11)
    }

    func test_emptyDestination_matches() {
        let input = chars("[text]()")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "text")
        XCTAssertEqual(m.dest, "")
    }

    func test_angleBracketedDestination_matches() {
        let input = chars("[t](<http://x.y/with space>)")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "t")
        XCTAssertEqual(m.dest, "<http://x.y/with space>")
    }

    func test_destinationWithBalancedParens_matches() {
        let input = chars("[t](http://x.y/(a)b)")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "t")
        XCTAssertEqual(m.dest, "http://x.y/(a)b")
    }

    func test_destinationUnbalancedParen_returnsNil() {
        let input = chars("[t](http://x.y/(unbalanced)")
        XCTAssertNil(LinkParser.match(input, from: 0))
    }

    func test_titleQuoted_matches() {
        let input = chars("[t](url \"title\")")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "t")
        XCTAssertEqual(m.dest, "url \"title\"")
    }

    func test_titleSingleQuoted_matches() {
        let input = chars("[t](url 'title')")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.dest, "url 'title'")
    }

    func test_titleParenthesized_matches() {
        let input = chars("[t](url (title))")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.dest, "url (title)")
    }

    func test_nestedBrackets_inText_matches() {
        let input = chars("[outer [inner] text](url)")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "outer [inner] text")
    }

    func test_escapedBracketInText_handled() {
        let input = chars("[a\\]b](url)")
        guard let m = LinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "a\\]b")
    }

    func test_codeSpanInsideText_skipsBracketCount() {
        // `[a `]` b](u)` — the literal `]` inside the code span must
        // not close the link text. Caller passes the code-span range.
        let input = chars("[a `]` b](u)")
        // The code span `` `]` `` covers indices 3..6.
        let cs: [(start: Int, end: Int)] = [(3, 6)]
        guard let m = LinkParser.match(input, from: 0, codeSpanRanges: cs) else {
            return XCTFail("expected match with code span")
        }
        XCTAssertEqual(m.text, "a `]` b")
        XCTAssertEqual(m.dest, "u")
    }

    func test_unmatchedBracket_returnsNil() {
        let input = chars("[unmatched](url")
        XCTAssertNil(LinkParser.match(input, from: 0))
    }

    func test_notAtBracket_returnsNil() {
        XCTAssertNil(LinkParser.match(chars("hello"), from: 0))
    }

    func test_endToEnd_inParagraph_producesLinkInline() {
        let doc = MarkdownParser.parse("see [foo](http://x.y) end")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let links = inline.compactMap { ix -> (String, String)? in
            if case .link(let text, let dest) = ix {
                let textStr: String
                if case .text(let t) = text[0] {
                    textStr = t
                } else { textStr = "?" }
                return (textStr, dest)
            }
            return nil
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].0, "foo")
        XCTAssertEqual(links[0].1, "http://x.y")
    }
}

final class ImageParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    func test_basicImage_matches() {
        let input = chars("![alt](url)")
        guard let m = ImageParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "alt")  // `text` field doubles as alt
        XCTAssertEqual(m.dest, "url")
    }

    func test_imageWithoutBang_returnsNil() {
        let input = chars("[alt](url)")
        XCTAssertNil(ImageParser.match(input, from: 0))
    }

    func test_endToEnd_inParagraph_producesImageInline() {
        let doc = MarkdownParser.parse("see ![alt](http://x.y/img.png) end")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let images = inline.compactMap { ix -> String? in
            if case .image(_, let dest, _) = ix { return dest } else { return nil }
        }
        XCTAssertEqual(images, ["http://x.y/img.png"])
    }
}
