//
//  MarkdownSerializerImageSizeTests.swift
//  FSNotesTests
//
//  Byte-identical round-trip tests for image serialization with the
//  `width=N` size hint. The serializer emits `rawDestination` verbatim,
//  so every image should round-trip exactly as-is regardless of whether
//  it carries a size hint.
//

import XCTest
@testable import FSNotes

class MarkdownSerializerImageSizeTests: XCTestCase {

    private func roundTrip(_ markdown: String, file: StaticString = #file, line: UInt = #line) {
        let doc = MarkdownParser.parse(markdown)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, markdown, "Round-trip mismatch", file: file, line: line)
    }

    func test_roundTrip_bareImage() {
        roundTrip("![alt](img.png)")
    }

    func test_roundTrip_imageWithWidthOnlyTitle() {
        roundTrip("![alt](img.png \"width=300\")")
    }

    func test_roundTrip_imageWithCaptionAndWidth() {
        roundTrip("![alt](img.png \"photo width=300\")")
    }

    func test_roundTrip_imageWithMultiWordCaptionAndWidth() {
        roundTrip("![alt](img.png \"photo from 2024 width=300\")")
    }

    func test_roundTrip_imageWithPlainTitleNoWidth() {
        roundTrip("![alt](img.png \"just a caption\")")
    }

    func test_roundTrip_imageInParagraph() {
        roundTrip("Here is ![inline](img.png \"width=200\") some text.")
    }

    func test_roundTrip_bareImageInParagraph() {
        roundTrip("Here is ![inline](img.png) some text.")
    }
}
