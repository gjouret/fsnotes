//
//  EntityParserTests.swift
//  FSNotesTests
//
//  Phase 12.C.3 — Entity-reference combinator port tests.
//

import XCTest
@testable import FSNotes

final class EntityParserTests: XCTestCase {

    private func chars(_ s: String) -> [Character] { Array(s) }

    // MARK: - Named

    func test_named_amp_matches() {
        let input = chars("&amp;")
        guard let m = EntityParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.entity, "&amp;")
        XCTAssertEqual(m.endIndex, 5)
    }

    func test_named_unknown_returnsNil() {
        let input = chars("&fooxyz;")
        XCTAssertNil(EntityParser.match(input, from: 0))
    }

    func test_named_unterminated_returnsNil() {
        let input = chars("&amp")
        XCTAssertNil(EntityParser.match(input, from: 0))
    }

    // MARK: - Decimal numeric

    func test_decimalNumeric_matches() {
        let input = chars("&#65;")
        guard let m = EntityParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.entity, "&#65;")
        XCTAssertEqual(m.endIndex, 5)
    }

    func test_decimalNumeric_tooManyDigits_returnsNil() {
        let input = chars("&#12345678;")  // 8 digits, max 7
        XCTAssertNil(EntityParser.match(input, from: 0))
    }

    func test_decimalNumeric_outOfRange_returnsNil() {
        // 0x110000 = 1114112 — beyond 0x10FFFF (1114111).
        let input = chars("&#1114112;")
        XCTAssertNil(EntityParser.match(input, from: 0))
    }

    // MARK: - Hex numeric

    func test_hexNumeric_matches() {
        let input = chars("&#x41;")
        guard let m = EntityParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.entity, "&#x41;")
        XCTAssertEqual(m.endIndex, 6)
    }

    func test_hexNumeric_uppercaseX_matches() {
        let input = chars("&#X41;")
        guard let m = EntityParser.match(input, from: 0) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(m.entity, "&#X41;")
    }

    func test_hexNumeric_tooManyDigits_returnsNil() {
        let input = chars("&#x1234567;")  // 7 hex digits, max 6
        XCTAssertNil(EntityParser.match(input, from: 0))
    }

    // MARK: - Surface checks

    func test_notAtAmp_returnsNil() {
        XCTAssertNil(EntityParser.match(chars("foo"), from: 0))
    }

    func test_loneAmp_returnsNil() {
        XCTAssertNil(EntityParser.match(chars("&"), from: 0))
    }

    func test_endToEnd_inParagraph_producesEntityInline() {
        let doc = MarkdownParser.parse("&amp; here")
        guard case .paragraph(let inline) = doc.blocks[0] else {
            return XCTFail("expected paragraph")
        }
        let entities = inline.compactMap { ix -> String? in
            if case .entity(let e) = ix { return e } else { return nil }
        }
        XCTAssertEqual(entities, ["&amp;"])
    }
}
