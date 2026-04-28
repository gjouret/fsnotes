//
//  HorizontalRuleReaderTests.swift
//  FSNotesTests
//
//  Phase 12.C.5 — HR reader port tests.
//

import XCTest
@testable import FSNotes

final class HorizontalRuleReaderTests: XCTestCase {

    func test_threeDashes_matches() {
        let m = HorizontalRuleReader.detect("---")
        XCTAssertEqual(m?.character, "-")
        XCTAssertEqual(m?.length, 3)
    }

    func test_threeAsterisks_matches() {
        let m = HorizontalRuleReader.detect("***")
        XCTAssertEqual(m?.character, "*")
        XCTAssertEqual(m?.length, 3)
    }

    func test_threeUnderscores_matches() {
        let m = HorizontalRuleReader.detect("___")
        XCTAssertEqual(m?.character, "_")
        XCTAssertEqual(m?.length, 3)
    }

    func test_spacedDashes_matches() {
        // `- - -` is a valid HR — spaces between marker chars are allowed.
        let m = HorizontalRuleReader.detect("- - -")
        XCTAssertEqual(m?.character, "-")
        XCTAssertEqual(m?.length, 3)
    }

    func test_threeLeadingSpaces_allowed() {
        XCTAssertNotNil(HorizontalRuleReader.detect("   ---"))
    }

    func test_fourLeadingSpaces_rejected() {
        XCTAssertNil(HorizontalRuleReader.detect("    ---"))
    }

    func test_twoDashes_rejected() {
        XCTAssertNil(HorizontalRuleReader.detect("--"))
    }

    func test_dashesWithLetters_rejected() {
        XCTAssertNil(HorizontalRuleReader.detect("--- foo"))
    }

    func test_read_returnsBlockAndAdvance() {
        let lines = ["---", "next"]
        guard let result = HorizontalRuleReader.read(lines: lines, from: 0) else {
            return XCTFail("expected match")
        }
        guard case .horizontalRule(let ch, let len) = result.block else {
            return XCTFail("expected horizontalRule, got \(result.block)")
        }
        XCTAssertEqual(ch, "-")
        XCTAssertEqual(len, 3)
        XCTAssertEqual(result.nextIndex, 1)
    }

    func test_endToEnd_viaParse() {
        let doc = MarkdownParser.parse("foo\n\n---\n\nbar\n")
        let hrs = doc.blocks.compactMap { b -> Bool? in
            if case .horizontalRule = b { return true } else { return nil }
        }
        XCTAssertEqual(hrs.count, 1)
    }
}
