//
//  MarkdownParserImageSizeTests.swift
//  FSNotesTests
//
//  Tests that MarkdownParser extracts the `width=N` hint from the
//  CommonMark title segment of an image and populates Inline.image.width,
//  while leaving rawDestination byte-identical to the source.
//

import XCTest
@testable import FSNotes

class MarkdownParserImageSizeTests: XCTestCase {

    // MARK: - Helpers

    /// Parse a single paragraph containing one image and return the
    /// resolved .image inline (or XCTFail if not found).
    private func parseImage(_ markdown: String, file: StaticString = #file, line: UInt = #line) -> (alt: [Inline], rawDest: String, width: Int?)? {
        let doc = MarkdownParser.parse(markdown)
        guard case let .paragraph(inline) = doc.blocks[0] else {
            XCTFail("expected paragraph block, got \(doc.blocks[0])", file: file, line: line)
            return nil
        }
        guard inline.count == 1, case let .image(alt, rawDest, width) = inline[0] else {
            XCTFail("expected a single .image inline, got \(inline)", file: file, line: line)
            return nil
        }
        return (alt, rawDest, width)
    }

    // MARK: - Parsing

    func test_parse_bareImage_noWidth() {
        guard let img = parseImage("![alt](img.png)") else { return }
        XCTAssertEqual(img.rawDest, "img.png")
        XCTAssertNil(img.width)
    }

    func test_parse_imageWithWidthOnlyTitle() {
        guard let img = parseImage("![alt](img.png \"width=300\")") else { return }
        XCTAssertEqual(img.rawDest, "img.png \"width=300\"")
        XCTAssertEqual(img.width, 300)
    }

    func test_parse_imageWithCaptionAndWidth() {
        guard let img = parseImage("![alt](img.png \"photo width=300\")") else { return }
        XCTAssertEqual(img.rawDest, "img.png \"photo width=300\"")
        XCTAssertEqual(img.width, 300)
    }

    func test_parse_imageWithMultiWordCaptionAndWidth() {
        guard let img = parseImage("![alt](img.png \"photo from 2024 width=300\")") else { return }
        XCTAssertEqual(img.rawDest, "img.png \"photo from 2024 width=300\"")
        XCTAssertEqual(img.width, 300)
    }

    func test_parse_imageWithPlainTitleNoWidth() {
        guard let img = parseImage("![alt](img.png \"just a caption\")") else { return }
        XCTAssertEqual(img.rawDest, "img.png \"just a caption\"")
        XCTAssertNil(img.width)
    }

    func test_parse_imageWithInvalidWidth() {
        // Non-numeric width — treat as opaque title, no width extraction
        guard let img = parseImage("![alt](img.png \"width=abc\")") else { return }
        XCTAssertEqual(img.rawDest, "img.png \"width=abc\"")
        XCTAssertNil(img.width)
    }

    func test_parse_imageWithZeroWidth() {
        // 0 is not a valid width
        guard let img = parseImage("![alt](img.png \"width=0\")") else { return }
        XCTAssertNil(img.width)
    }

    func test_parse_imageWithAngleBracketedURL() {
        // Ensure the angle-bracket path doesn't break title parsing
        guard let img = parseImage("![alt](<img with space.png> \"width=200\")") else { return }
        XCTAssertEqual(img.width, 200)
    }
}
