//
//  ATXHeadingReaderTests.swift
//  FSNotesTests
//
//  Phase 12.C.5 — ATX heading + setext underline reader port tests.
//

import XCTest
@testable import FSNotes

final class ATXHeadingReaderTests: XCTestCase {

    // MARK: - ATX detect

    func test_h1_basic() {
        let h = ATXHeadingReader.detect("# Hello")
        XCTAssertEqual(h?.level, 1)
        XCTAssertEqual(h?.suffix, " Hello")
    }

    func test_h6_basic() {
        let h = ATXHeadingReader.detect("###### Six")
        XCTAssertEqual(h?.level, 6)
        XCTAssertEqual(h?.suffix, " Six")
    }

    func test_emptyHeading() {
        let h = ATXHeadingReader.detect("###")
        XCTAssertEqual(h?.level, 3)
        XCTAssertEqual(h?.suffix, "")
    }

    func test_missingSpaceAfterMarker_returnsNil() {
        XCTAssertNil(ATXHeadingReader.detect("#Hello"))
    }

    func test_sevenMarkers_returnsNil() {
        XCTAssertNil(ATXHeadingReader.detect("####### too"))
    }

    func test_threeLeadingSpaces_allowed() {
        XCTAssertNotNil(ATXHeadingReader.detect("   # Indented"))
    }

    func test_read_returnsBlockAndAdvance() {
        let lines = ["## Title", "next"]
        guard let result = ATXHeadingReader.read(lines: lines, from: 0) else {
            return XCTFail("expected match")
        }
        guard case .heading(let level, let suffix) = result.block else {
            return XCTFail("expected heading, got \(result.block)")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(suffix, " Title")
        XCTAssertEqual(result.nextIndex, 1)
    }

    // MARK: - Setext underline detect

    func test_setextH1_equalsLine() {
        XCTAssertEqual(ATXHeadingReader.detectSetextUnderline("==="), 1)
    }

    func test_setextH2_threeDashes() {
        XCTAssertEqual(ATXHeadingReader.detectSetextUnderline("---"), 2)
    }

    func test_setextH2_singleDash_rejected() {
        // `-` alone is not a setext underline — disambiguates from a
        // bare list marker.
        XCTAssertNil(ATXHeadingReader.detectSetextUnderline("-"))
    }

    func test_setextH1_singleEquals_accepted() {
        XCTAssertEqual(ATXHeadingReader.detectSetextUnderline("="), 1)
    }

    func test_setext_trailingWhitespace_allowed() {
        XCTAssertEqual(ATXHeadingReader.detectSetextUnderline("===   "), 1)
    }

    func test_setext_extraneousChar_rejected() {
        XCTAssertNil(ATXHeadingReader.detectSetextUnderline("=== a"))
    }

    // MARK: - End-to-end

    func test_endToEnd_atxHeading() {
        let doc = MarkdownParser.parse("# Title")
        guard case .heading(let level, _) = doc.blocks[0] else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(level, 1)
    }

    func test_endToEnd_setextHeading() {
        let doc = MarkdownParser.parse("Title\n===\n")
        guard case .heading(let level, _) = doc.blocks[0] else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(level, 1)
    }
}
