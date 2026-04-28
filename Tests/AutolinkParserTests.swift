//
//  AutolinkParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Autolink combinator port tests.
//

import XCTest
@testable import FSNotes

final class AutolinkParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    // MARK: - URI form

    func test_httpURL_matches() {
        let input = chars("<http://example.com>")
        guard let m = AutolinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "http://example.com")
        XCTAssertFalse(m.isEmail)
        XCTAssertEqual(m.endIndex, 20)
    }

    func test_schemeWithPlusDot_matches() {
        // CommonMark allows + . - in scheme: `<irc.example:foo>`
        let input = chars("<irc.example:foo>")
        guard let m = AutolinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "irc.example:foo")
        XCTAssertFalse(m.isEmail)
    }

    func test_schemeTooShort_returnsNil() {
        // Single-letter scheme is rejected (spec: ≥ 2).
        let input = chars("<a:foo>")
        XCTAssertNil(AutolinkParser.match(input, from: 0))
    }

    // MARK: - Email form

    func test_basicEmail_matches() {
        let input = chars("<user@example.com>")
        guard let m = AutolinkParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.text, "user@example.com")
        XCTAssertTrue(m.isEmail)
    }

    func test_emailWithoutAt_returnsNil() {
        // Plain `foo` is neither a URI (no scheme:) nor an email.
        let input = chars("<foo>")
        XCTAssertNil(AutolinkParser.match(input, from: 0))
    }

    // MARK: - Surface checks

    func test_unterminated_returnsNil() {
        let input = chars("<http://example.com")
        XCTAssertNil(AutolinkParser.match(input, from: 0))
    }

    func test_spaceInBody_returnsNil() {
        let input = chars("<http://e xample.com>")
        XCTAssertNil(AutolinkParser.match(input, from: 0))
    }

    func test_notAtAngle_returnsNil() {
        XCTAssertNil(AutolinkParser.match(chars("foo"), from: 0))
    }

    func test_endToEnd_inParagraph_producesAutolinkInline() {
        let doc = MarkdownParser.parse("see <http://x.y/>")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let autos = inline.compactMap { ix -> (String, Bool)? in
            if case .autolink(let t, let e) = ix { return (t, e) } else { return nil }
        }
        XCTAssertEqual(autos.count, 1)
        XCTAssertEqual(autos[0].0, "http://x.y/")
        XCTAssertFalse(autos[0].1)
    }
}
