//
//  DocumentProjectionTests.swift
//  FSNotesTests
//
//  Tests for DocumentRenderer + DocumentProjection: the block-model
//  source map between textStorage coordinates and block-model
//  coordinates.
//

import XCTest
@testable import FSNotes

class DocumentProjectionTests: XCTestCase {

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

    // MARK: - Render structure

    func test_render_emptyDocument() {
        let p = project("")
        XCTAssertEqual(p.attributed.string, "")
        XCTAssertEqual(p.blockSpans, [])
    }

    func test_render_singleParagraph() {
        let p = project("hello\n")
        XCTAssertEqual(p.attributed.string, "hello\n")
        XCTAssertEqual(p.blockSpans.count, 1)
        XCTAssertEqual(p.blockSpans[0], NSRange(location: 0, length: 5))
    }

    func test_render_singleHeading() {
        let p = project("# Title\n")
        // Rendered: "Title" (trimmed suffix, no '#')
        XCTAssertEqual(p.attributed.string, "Title\n")
        XCTAssertEqual(p.blockSpans.count, 1)
        XCTAssertEqual(p.blockSpans[0], NSRange(location: 0, length: 5))
    }

    func test_render_twoParagraphs_separatedByBlank() {
        // Blank-line block between paragraphs
        let p = project("hello\n\nworld\n")
        // Blocks: paragraph("hello"), blankLine, paragraph("world")
        // Rendered: "hello\n\nworld\n"
        XCTAssertEqual(p.attributed.string, "hello\n\nworld\n")
        XCTAssertEqual(p.blockSpans.count, 3)
        XCTAssertEqual(p.blockSpans[0], NSRange(location: 0, length: 5))  // "hello"
        XCTAssertEqual(p.blockSpans[1].length, 0)                          // blankLine (empty)
        XCTAssertEqual(p.blockSpans[2].length, 5)                          // "world"
    }

    func test_render_headingThenParagraph() {
        let p = project("# Hi\nbody\n")
        // Blocks: heading(1, " Hi"), paragraph("body")
        // Rendered: "Hi\nbody\n"
        XCTAssertEqual(p.attributed.string, "Hi\nbody\n")
        XCTAssertEqual(p.blockSpans.count, 2)
        XCTAssertEqual(p.blockSpans[0], NSRange(location: 0, length: 2))   // "Hi"
        // Separator "\n" at position 2, then block 1 starts at 3
        XCTAssertEqual(p.blockSpans[1], NSRange(location: 3, length: 4))   // "body"
    }

    func test_render_trailingNewlineRespected() {
        let p1 = project("hello\n")
        XCTAssertEqual(p1.attributed.string, "hello\n")
        let p2 = project("hello")
        XCTAssertEqual(p2.attributed.string, "hello")
    }

    // MARK: - blockContaining

    func test_blockContaining_singleBlock_interior() {
        let p = project("hello\n")
        // "hello" is block 0, span [0,5)
        XCTAssertEqual(p.blockContaining(storageIndex: 0)?.blockIndex, 0)
        XCTAssertEqual(p.blockContaining(storageIndex: 0)?.offsetInBlock, 0)
        XCTAssertEqual(p.blockContaining(storageIndex: 3)?.blockIndex, 0)
        XCTAssertEqual(p.blockContaining(storageIndex: 3)?.offsetInBlock, 3)
        // End of block (insertion point BEFORE the trailing '\n')
        XCTAssertEqual(p.blockContaining(storageIndex: 5)?.blockIndex, 0)
        XCTAssertEqual(p.blockContaining(storageIndex: 5)?.offsetInBlock, 5)
    }

    func test_blockContaining_twoBlocks_boundary() {
        // Two consecutive non-blank lines would join into ONE paragraph.
        // Force two blocks with a heading (different block type).
        let p = project("# Hi\nyo\n")
        // Block 0 = heading "Hi" span [0,2), separator at 2, Block 1 = paragraph "yo" span [3,5)
        XCTAssertEqual(p.attributed.string, "Hi\nyo\n")
        XCTAssertEqual(p.blockContaining(storageIndex: 0)?.blockIndex, 0)
        XCTAssertEqual(p.blockContaining(storageIndex: 2)?.blockIndex, 0)   // end of block 0
        XCTAssertEqual(p.blockContaining(storageIndex: 2)?.offsetInBlock, 2)
        // Position 3 is start of block 1 (after the separator '\n' at 2)
        XCTAssertEqual(p.blockContaining(storageIndex: 3)?.blockIndex, 1)
        XCTAssertEqual(p.blockContaining(storageIndex: 3)?.offsetInBlock, 0)
        // Position 5 is end of block 1 (before trailing '\n')
        XCTAssertEqual(p.blockContaining(storageIndex: 5)?.blockIndex, 1)
        XCTAssertEqual(p.blockContaining(storageIndex: 5)?.offsetInBlock, 2)
    }

    func test_blockContaining_outsideAllBlocks() {
        let p = project("# Hi\nyo\n")
        // Length = 6 ("Hi\nyo\n"). Position 6 is past the trailing '\n'.
        XCTAssertNil(p.blockContaining(storageIndex: 6))
        // Negative
        XCTAssertNil(p.blockContaining(storageIndex: -1))
    }

    func test_blockContaining_blankLineBlock() {
        let p = project("a\n\nb\n")
        // Blocks: paragraph("a") [0,1), blankLine [2,2) (empty), paragraph("b") [3,4)
        XCTAssertEqual(p.blockContaining(storageIndex: 0)?.blockIndex, 0)
        XCTAssertEqual(p.blockContaining(storageIndex: 1)?.blockIndex, 0)   // end of "a"
        // Position 2: separator between blocks 0 and 1 (blankLine).
        // With blankLine at span [2,2) (length 0), and earlier-wins tie-break,
        // we expect block 0 to claim position 2... actually span[0]=[0,1),
        // upper=1. span[1]=[2,2), lower=2, upper=2. So 2 maps to block 1.
        let loc2 = p.blockContaining(storageIndex: 2)
        XCTAssertEqual(loc2?.blockIndex, 1)
        XCTAssertEqual(loc2?.offsetInBlock, 0)
    }
}
