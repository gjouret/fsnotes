//
//  EditingOpsSetImageSizeTests.swift
//  FSNotesTests
//
//  Tests for EditingOps.setImageSize — the surgical primitive that
//  writes a `width=N` hint into an image's CommonMark title field and
//  produces an EditResult via replaceBlock. Verifies that the resulting
//  Document serializes to the expected markdown and that
//  Inline.image.width is set correctly.
//

import XCTest
@testable import FSNotes

class EditingOpsSetImageSizeTests: XCTestCase {

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }
    private func project(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
    }

    /// Extract (rawDest, width) of the first image in the document.
    /// Expects the first block to be a paragraph containing exactly one
    /// .image inline at index 0.
    private func firstImage(_ doc: Document) -> (rawDest: String, width: Int?)? {
        guard case let .paragraph(inline) = doc.blocks[0] else { return nil }
        guard inline.count == 1, case let .image(_, rawDest, width) = inline[0] else { return nil }
        return (rawDest, width)
    }

    // MARK: - Set width on bare image

    func test_setWidth_onBareImage_writesBareWidthTitle() throws {
        let p = project("![alt](img.png)")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: 300, in: p
        )
        let img = try XCTUnwrap(firstImage(result.newProjection.document))
        XCTAssertEqual(img.width, 300)
        XCTAssertEqual(img.rawDest, "img.png \"width=300\"")

        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, "![alt](img.png \"width=300\")")
    }

    // MARK: - Set width on image with existing caption

    func test_setWidth_preservesExistingCaption() throws {
        let p = project("![alt](img.png \"photo from 2024\")")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: 300, in: p
        )
        let img = try XCTUnwrap(firstImage(result.newProjection.document))
        XCTAssertEqual(img.width, 300)
        XCTAssertEqual(img.rawDest, "img.png \"photo from 2024 width=300\"")

        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, "![alt](img.png \"photo from 2024 width=300\")")
    }

    // MARK: - Replace existing width

    func test_setWidth_replacesExistingWidth() throws {
        let p = project("![alt](img.png \"width=200\")")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: 500, in: p
        )
        let img = try XCTUnwrap(firstImage(result.newProjection.document))
        XCTAssertEqual(img.width, 500)
        XCTAssertEqual(img.rawDest, "img.png \"width=500\"")
    }

    func test_setWidth_replacesExistingWidth_preservingCaption() throws {
        let p = project("![alt](img.png \"photo width=200\")")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: 500, in: p
        )
        let img = try XCTUnwrap(firstImage(result.newProjection.document))
        XCTAssertEqual(img.width, 500)
        XCTAssertEqual(img.rawDest, "img.png \"photo width=500\"")
    }

    // MARK: - Clear width (nil)

    func test_setWidth_nilOnBareImageRemovesTitle() throws {
        let p = project("![alt](img.png \"width=300\")")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: nil, in: p
        )
        let img = try XCTUnwrap(firstImage(result.newProjection.document))
        XCTAssertNil(img.width)
        XCTAssertEqual(img.rawDest, "img.png")

        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, "![alt](img.png)")
    }

    func test_setWidth_nilPreservesExistingCaption() throws {
        let p = project("![alt](img.png \"photo width=300\")")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: nil, in: p
        )
        let img = try XCTUnwrap(firstImage(result.newProjection.document))
        XCTAssertNil(img.width)
        XCTAssertEqual(img.rawDest, "img.png \"photo\"")

        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, "![alt](img.png \"photo\")")
    }

    // MARK: - Full round-trip through parser

    func test_setWidth_roundTripViaParser() throws {
        // After setImageSize, re-parse the serialized output and confirm
        // the width field is populated identically.
        let p = project("![alt](img.png)")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: 250, in: p
        )
        let md = MarkdownSerializer.serialize(result.newProjection.document)
        let reparsed = MarkdownParser.parse(md)
        guard case let .paragraph(inline) = reparsed.blocks[0],
              case let .image(_, rawDest, width) = inline[0] else {
            XCTFail("round-tripped document has wrong shape")
            return
        }
        XCTAssertEqual(width, 250)
        XCTAssertEqual(rawDest, "img.png \"width=250\"")
    }

    // MARK: - Error cases

    func test_setWidth_onNonParagraphBlockThrows() {
        let p = project("# heading")
        XCTAssertThrowsError(
            try EditingOps.setImageSize(blockIndex: 0, inlinePath: [0], newWidth: 300, in: p)
        )
    }

    func test_setWidth_onParagraphWithoutImageThrows() {
        let p = project("just text")
        XCTAssertThrowsError(
            try EditingOps.setImageSize(blockIndex: 0, inlinePath: [0], newWidth: 300, in: p)
        )
    }

    func test_setWidth_outOfBoundsBlockThrows() {
        let p = project("![alt](img.png)")
        XCTAssertThrowsError(
            try EditingOps.setImageSize(blockIndex: 5, inlinePath: [0], newWidth: 300, in: p)
        )
    }

    func test_setWidth_invalidInlinePathThrows() {
        let p = project("![alt](img.png)")
        XCTAssertThrowsError(
            try EditingOps.setImageSize(blockIndex: 0, inlinePath: [99], newWidth: 300, in: p)
        )
    }
}
