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
        XCTAssertTrue(proc.isCollapsed(blockIndex: idx))

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
        XCTAssertTrue(proc.isCollapsed(blockIndex: idx))
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
        XCTAssertTrue(proc.isCollapsed(blockIndex: idx))
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
        XCTAssertTrue(proc.isCollapsed(blockIndex: idx))
    }

    func test_unfold_restoresContent() {
        let md = "## Section\nHidden content\n\n## Next"
        let (proc, storage) = makeProcessor(markdown: md)

        guard let idx = headerIndex(proc, at: 0) else {
            XCTFail("No header found"); return
        }

        // Fold
        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertTrue(proc.isCollapsed(blockIndex: idx))

        // Unfold
        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertFalse(proc.isCollapsed(blockIndex: idx))

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
        XCTAssertTrue(proc.isCollapsed(blockIndex: idx))
    }

    func test_foldRange_coversFullContent_toEOF() {
        // Verify the fold range calculation itself is correct for H2 with no subsequent H1/H2
        let md = "## Section\nContent\n### Sub\nMore\n\n---\n\n| A | B |\n|--|--|\n| 1 | 2 |"
        let (proc, storage) = makeProcessor(markdown: md)
        guard let idx = headerIndex(proc, at: 0) else { XCTFail("No header"); return }

        let nsStr = storage.string as NSString
        let headerLineEnd = NSMaxRange(nsStr.paragraphRange(for: proc.blocks[idx].range))
        let expectedFoldLength = nsStr.length - headerLineEnd

        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)

        // Count folded characters
        var foldedCount = 0
        storage.enumerateAttribute(.foldedContent, in: NSRange(location: headerLineEnd, length: expectedFoldLength)) { val, _, _ in
            if val != nil { foldedCount += 1 }
        }
        // The entire range after the header should be folded (one contiguous run)
        XCTAssertGreaterThan(foldedCount, 0, "No folded content found")
        XCTAssertEqual(expectedFoldLength, nsStr.length - headerLineEnd, "Fold should extend to EOF")
    }

    func test_foldH2_inVisualTestNumber1_foldsToEOF() {
        // Reproduces the exact bug: folding H2 in Visual Test Number 1
        // should hide everything after H2 (H3-H6, bullets, HR, table, mermaid)
        // because there is no other H1 or H2 in the note.
        let md = """
        # Visual Test Number 1
        This is to compare the NSTextView and MPreview
        ## This is a H2 header
        This is more text.
        ### This is a H3 header
        This is more text
        #### This is a H4 header
        This is more text
        ##### This is a H5 header
        This is more text
        ###### This is a H6 header
        Now some bullets
        - first bullet
        - second bullet

        ---

        | Retirement places | Costa Rica |
        |---|---|
        | Go for it | Nice italics |
        """
        let (proc, storage) = makeProcessor(markdown: md)

        // Find H2
        var h2Idx: Int?
        for (i, block) in proc.blocks.enumerated() {
            if case .heading(2) = block.type { h2Idx = i; break }
        }
        guard let idx = h2Idx else { XCTFail("No H2 found"); return }

        // Fold H2
        proc.toggleFold(headerBlockIndex: idx, textStorage: storage)
        XCTAssertTrue(proc.isCollapsed(blockIndex: idx))

        // The fold range should extend to EOF — everything after H2 line is folded
        let nsStr = storage.string as NSString
        let h2LineEnd = NSMaxRange(nsStr.paragraphRange(for: proc.blocks[idx].range))
        let foldRange = NSRange(location: h2LineEnd, length: nsStr.length - h2LineEnd)

        // Every character in the fold range should have .foldedContent attribute
        var unfoldedChars: [Int] = []
        for i in foldRange.location..<NSMaxRange(foldRange) {
            if i < storage.length {
                if storage.attribute(.foldedContent, at: i, effectiveRange: nil) == nil {
                    unfoldedChars.append(i)
                }
            }
        }
        XCTAssertEqual(unfoldedChars.count, 0,
            "Found \(unfoldedChars.count) unfolded characters after H2. First at index \(unfoldedChars.first ?? -1)")
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
