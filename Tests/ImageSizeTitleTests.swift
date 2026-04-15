//
//  ImageSizeTitleTests.swift
//  FSNotesTests
//
//  Pure-function tests for the ImageSizeTitle helper — the parse / emit
//  round-trip for `width=N` size hints carried inside a CommonMark
//  image title field.
//

import XCTest
@testable import FSNotes

class ImageSizeTitleTests: XCTestCase {

    // MARK: - parse

    func test_parse_emptyString() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("")
        XCTAssertNil(preserved)
        XCTAssertNil(width)
    }

    func test_parse_bareSizeToken() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("width=300")
        XCTAssertNil(preserved)
        XCTAssertEqual(width, 300)
    }

    func test_parse_plainCaption() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("photo")
        XCTAssertEqual(preserved, "photo")
        XCTAssertNil(width)
    }

    func test_parse_captionWithSize() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("photo width=300")
        XCTAssertEqual(preserved, "photo")
        XCTAssertEqual(width, 300)
    }

    func test_parse_multiWordCaptionWithSize() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("photo from 2024 width=300")
        XCTAssertEqual(preserved, "photo from 2024")
        XCTAssertEqual(width, 300)
    }

    func test_parse_sizeTokenZeroIsInvalid() {
        // 0 is not a valid width — whole title treated as preserved.
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("photo width=0")
        XCTAssertEqual(preserved, "photo width=0")
        XCTAssertNil(width)
    }

    func test_parse_sizeTokenNegativeIsInvalid() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("photo width=-5")
        XCTAssertEqual(preserved, "photo width=-5")
        XCTAssertNil(width)
    }

    func test_parse_sizeTokenNonNumericIsInvalid() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("width=abc")
        XCTAssertEqual(preserved, "width=abc")
        XCTAssertNil(width)
    }

    func test_parse_sizeTokenAtWrongPositionIsNotMatched() {
        // "width=300 photo" — token not at the end, does not match
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("width=300 photo")
        XCTAssertEqual(preserved, "width=300 photo")
        XCTAssertNil(width)
    }

    func test_parse_wordStartingWithWide() {
        // Must not match "wide" as "width=..."
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("wide")
        XCTAssertEqual(preserved, "wide")
        XCTAssertNil(width)
    }

    func test_parse_largeWidth() {
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse("width=10000")
        XCTAssertNil(preserved)
        XCTAssertEqual(width, 10000)
    }

    // MARK: - emit

    func test_emit_nilNil() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: nil, width: nil)
        XCTAssertNil(result)
    }

    func test_emit_widthOnly() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: nil, width: 300)
        XCTAssertEqual(result, "width=300")
    }

    func test_emit_preservedOnly() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: "photo", width: nil)
        XCTAssertEqual(result, "photo")
    }

    func test_emit_bothPreservedAndWidth() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: "photo", width: 300)
        XCTAssertEqual(result, "photo width=300")
    }

    func test_emit_multiWordPreservedAndWidth() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: "photo from 2024", width: 300)
        XCTAssertEqual(result, "photo from 2024 width=300")
    }

    func test_emit_emptyPreservedTreatedAsNil() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: "", width: 300)
        XCTAssertEqual(result, "width=300")
    }

    func test_emit_whitespacePreservedTrimmed() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: "  photo  ", width: 300)
        XCTAssertEqual(result, "photo width=300")
    }

    func test_emit_zeroWidthTreatedAsNil() {
        let result = MarkdownParser.ImageSizeTitle.emit(preserved: "photo", width: 0)
        XCTAssertEqual(result, "photo")
    }

    // MARK: - Round-trip

    func test_roundTrip_bareWidth() {
        let original = "width=300"
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse(original)
        let emitted = MarkdownParser.ImageSizeTitle.emit(preserved: preserved, width: width)
        XCTAssertEqual(emitted, original)
    }

    func test_roundTrip_captionWithWidth() {
        let original = "photo width=300"
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse(original)
        let emitted = MarkdownParser.ImageSizeTitle.emit(preserved: preserved, width: width)
        XCTAssertEqual(emitted, original)
    }

    func test_roundTrip_multiWordCaptionWithWidth() {
        let original = "photo from 2024 width=300"
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse(original)
        let emitted = MarkdownParser.ImageSizeTitle.emit(preserved: preserved, width: width)
        XCTAssertEqual(emitted, original)
    }

    func test_roundTrip_captionOnly() {
        let original = "just a caption"
        let (preserved, width) = MarkdownParser.ImageSizeTitle.parse(original)
        let emitted = MarkdownParser.ImageSizeTitle.emit(preserved: preserved, width: width)
        XCTAssertEqual(emitted, original)
    }
}
