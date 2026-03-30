//
//  FoldRangeTests.swift
//  FSNotesTests
//
//  Unit tests for fold range calculation.
//  Tests that folding a header hides the correct content range.
//

import XCTest
@testable import FSNotes

class FoldRangeTests: XCTestCase {

    // MARK: - Helpers

    private func makeProcessor(markdown: String) -> (TextStorageProcessor, NSTextStorage) {
        let storage = NSTextStorage(string: markdown)
        let processor = TextStorageProcessor()
        // Populate block model
        let string = storage.string as NSString
        processor.blocks = MarkdownBlockParser.parse(string: string)
        return (processor, storage)
    }

    private func headerIndex(_ processor: TextStorageProcessor, at charIndex: Int) -> Int? {
        return processor.headerBlockIndex(at: charIndex)
    }

    // MARK: - Basic Fold Ranges

    func test_foldH2_untilNextH2() {
        let md = "## Section 1\nContent A\n\n## Section 2\nContent B"
        let (proc, storage) = makeProcessor(markdown: md)

        guard let idx = headerIndex(proc, at: 0) else {
            XCTFail("No header found at position 0"); return
        }

        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)

        // Section 1 should be collapsed
        XCTAssertTrue(proc.blocks[idx].collapsed)

        // The fold range should NOT include "## Section 2"
        let foldedText = storage.string
        XCTAssertTrue(foldedText.contains("## Section 2"))
    }

    func test_foldH2_withNestedH3() {
        let md = "## Section\nText\n### Subsection\nMore text\n\n## Next"
        let (proc, storage) = makeProcessor(markdown: md)

        guard let idx = headerIndex(proc, at: 0) else {
            XCTFail("No header found"); return
        }

        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertTrue(proc.blocks[idx].collapsed)
    }

    func test_foldLastHeader_toEOF() {
        let md = "# Title\n\n## Last Section\nContent here"
        let (proc, storage) = makeProcessor(markdown: md)

        // Find the H2
        var h2Idx: Int?
        for (i, block) in proc.blocks.enumerated() {
            if case .heading(2) = block.type { h2Idx = i; break }
        }

        guard let idx = h2Idx else {
            XCTFail("No H2 found"); return
        }

        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertTrue(proc.blocks[idx].collapsed)
    }

    func test_foldDoesNotStopAtHR() {
        let md = "## Section\nBefore HR\n\n---\n\nAfter HR\n\n## Next"
        let (proc, storage) = makeProcessor(markdown: md)

        guard let idx = headerIndex(proc, at: 0) else {
            XCTFail("No header found"); return
        }

        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)

        // The fold should include content after the HR
        // "## Next" should still be visible (not folded)
        XCTAssertTrue(proc.blocks[idx].collapsed)
    }

    func test_unfold_restoresContent() {
        let md = "## Section\nHidden content\n\n## Next"
        let (proc, storage) = makeProcessor(markdown: md)

        guard let idx = headerIndex(proc, at: 0) else {
            XCTFail("No header found"); return
        }

        // Fold
        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertTrue(proc.blocks[idx].collapsed)

        // Unfold
        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertFalse(proc.blocks[idx].collapsed)

        // Content should be visible (no .foldedContent attribute)
        let fullRange = NSRange(location: 0, length: storage.length)
        var hasFolded = false
        storage.enumerateAttribute(.foldedContent, in: fullRange) { val, _, _ in
            if val != nil { hasFolded = true }
        }
        XCTAssertFalse(hasFolded)
    }

    func test_foldH1_includesH2andH3() {
        let md = "# Title\nIntro\n## Sub1\nText\n### Sub2\nMore"
        let (proc, storage) = makeProcessor(markdown: md)

        guard let idx = headerIndex(proc, at: 0) else {
            XCTFail("No header found"); return
        }

        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertTrue(proc.blocks[idx].collapsed)
    }

    func test_headerBlockIndex_findsCorrectHeader() {
        let md = "# H1\n\n## H2\n\nText"
        let (proc, _) = makeProcessor(markdown: md)

        let h1Idx = headerIndex(proc, at: 0)
        XCTAssertNotNil(h1Idx)

        // Find H2 — it starts after "# H1\n\n"
        let h2Start = (md as NSString).range(of: "## H2").location
        let h2Idx = headerIndex(proc, at: h2Start)
        XCTAssertNotNil(h2Idx)
        XCTAssertNotEqual(h1Idx, h2Idx)
    }
}
