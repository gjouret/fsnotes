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

    // MARK: - Bug #27: image resize must preserve center alignment

    /// `DocumentRenderer` centers image-only paragraphs (`inline.count == 1,
    /// case .image`) by setting `NSParagraphStyle.alignment = .center` on
    /// the rendered block's paragraph style. After a resize via
    /// `setImageSize`, the resulting block is still an image-only paragraph
    /// and its rendered paragraph style must therefore still carry
    /// `.alignment = .center` — otherwise the image would draw left-aligned
    /// in the live editor (bug #27, data-path leg).
    func test_bug27_setWidth_preservesCenterAlignmentOnImageOnlyParagraph() throws {
        let p = project("![alt](img.png)")

        let beforeBlockSpan = p.blockSpans[0]
        XCTAssertGreaterThan(beforeBlockSpan.length, 0)
        let beforeStyle = p.attributed.attribute(
            .paragraphStyle, at: beforeBlockSpan.location, effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(beforeStyle?.alignment, .center,
                       "BEFORE: image-only paragraph should be centered by the renderer")

        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: 200, in: p
        )

        let afterBlockSpan = result.newProjection.blockSpans[0]
        XCTAssertGreaterThan(afterBlockSpan.length, 0)
        let afterStyle = result.newProjection.attributed.attribute(
            .paragraphStyle, at: afterBlockSpan.location, effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(afterStyle?.alignment, .center,
                       "AFTER setImageSize: image-only paragraph must remain centered (bug #27)")
    }

    /// Same invariant via the splice replacement that `commitImageResize`
    /// hands to `applyEditResultWithUndo` / `applyDocumentEdit`.
    func test_bug27_setWidth_spliceReplacementCarriesCenterAlignment() throws {
        let p = project("![alt](img.png)")
        let result = try EditingOps.setImageSize(
            blockIndex: 0, inlinePath: [0], newWidth: 200, in: p
        )

        XCTAssertGreaterThan(result.spliceReplacement.length, 0,
                             "splice replacement should not be empty after a resize")
        let spliceStyle = result.spliceReplacement.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(spliceStyle?.alignment, .center,
                       "splice replacement must carry centered paragraph style (bug #27)")
    }
}
