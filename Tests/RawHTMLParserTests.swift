//
//  RawHTMLParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Raw HTML combinator port tests.
//

import XCTest
@testable import FSNotes

final class RawHTMLParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    // MARK: - Comment

    func test_comment_basic_matches() {
        let input = chars("<!-- hi -->")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<!-- hi -->")
        XCTAssertEqual(m.endIndex, 11)
    }

    func test_comment_emptyShortForm_matches() {
        let input = chars("<!-->")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<!-->")
    }

    func test_comment_oneDashShortForm_matches() {
        let input = chars("<!--->")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<!--->")
    }

    func test_comment_unterminated_returnsNil() {
        let input = chars("<!-- bad")
        XCTAssertNil(RawHTMLParser.match(input, from: 0))
    }

    // MARK: - Processing instruction

    func test_processingInstruction_matches() {
        let input = chars("<?xml version='1.0'?>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<?xml version='1.0'?>")
    }

    // MARK: - CDATA

    func test_cdata_matches() {
        let input = chars("<![CDATA[x < y]]>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<![CDATA[x < y]]>")
    }

    // MARK: - Declaration

    func test_declaration_matches() {
        let input = chars("<!DOCTYPE html>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<!DOCTYPE html>")
    }

    // MARK: - Tags

    func test_openTag_basic_matches() {
        let input = chars("<a>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<a>")
    }

    func test_openTag_withAttributes_matches() {
        let input = chars("<a href=\"http://x\" class='c'>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<a href=\"http://x\" class='c'>")
    }

    func test_openTag_unquotedAttribute_matches() {
        let input = chars("<a href=plain>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<a href=plain>")
    }

    func test_openTag_selfClosing_matches() {
        let input = chars("<br/>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "<br/>")
    }

    func test_closingTag_matches() {
        let input = chars("</div>")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "</div>")
    }

    func test_closingTag_withWhitespace_matches() {
        let input = chars("</div   >")
        guard let m = RawHTMLParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.html, "</div   >")
    }

    func test_tagName_mustStartWithLetter() {
        let input = chars("<1tag>")
        XCTAssertNil(RawHTMLParser.match(input, from: 0))
    }

    func test_unterminatedAttribute_rejected() {
        let input = chars("<a href=\"")
        XCTAssertNil(RawHTMLParser.match(input, from: 0))
    }

    // MARK: - Surface checks

    func test_notAtAngle_returnsNil() {
        XCTAssertNil(RawHTMLParser.match(chars("foo"), from: 0))
    }

    func test_loneAngle_returnsNil() {
        XCTAssertNil(RawHTMLParser.match(chars("<"), from: 0))
    }

    func test_endToEnd_inParagraph_producesRawHTMLInline() {
        let doc = MarkdownParser.parse("see <span>x</span> here")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let htmls = inline.compactMap { ix -> String? in
            if case .rawHTML(let s) = ix { return s } else { return nil }
        }
        XCTAssertEqual(htmls, ["<span>", "</span>"])
    }
}
