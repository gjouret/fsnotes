//
//  Phase5dCopyPasteSlicingTests.swift
//  FSNotesTests
//
//  Phase 5d — pure-function tests for the Copy/Paste primitives:
//   - `DocumentProjection.slice(in:)` extracts a Document fragment
//     from a selection range (whole / partial blocks).
//   - `EditingOps.insertFragment(_:at:in:)` splices a Document
//     fragment into a host projection at a DocumentCursor.
//
//  These are value-type tests — no NSWindow, no layout manager. The
//  primitives operate on `Document` / `DocumentProjection` and return
//  `EditResult` with `EditContract`, same contract shape used by the
//  harness tests.
//

import XCTest
@testable import FSNotes

final class Phase5dCopyPasteSlicingTests: XCTestCase {

    // MARK: - Setup helpers

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }
    private func project(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(
            document: doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )
    }

    // MARK: - Document.slice (via DocumentProjection)

    func test_5d_slice_emptyRange_returnsEmptyDoc() {
        let proj = project("hello world\n")
        // Zero-length range at offset 3 overlaps the paragraph block; the
        // partial overlap of zero length yields an empty paragraph.
        let sliced = proj.slice(in: NSRange(location: 3, length: 0))
        // Either an empty doc or a doc containing a single empty
        // paragraph is acceptable (the partial branch is defined to
        // produce one). Accept both.
        if sliced.blocks.isEmpty {
            XCTAssertTrue(sliced.blocks.isEmpty)
        } else {
            XCTAssertEqual(sliced.blocks.count, 1)
            if case .paragraph(let inline) = sliced.blocks[0] {
                XCTAssertEqual(
                    MarkdownSerializer.serializeInlines(inline), ""
                )
            } else {
                XCTFail("expected empty paragraph, got \(sliced.blocks[0])")
            }
        }
    }

    func test_5d_slice_rangeWithinOneBlock_partialParagraph() {
        // "hello world" — select "llo wor" (chars 2..=8)
        let proj = project("hello world\n")
        let sliced = proj.slice(in: NSRange(location: 2, length: 7))
        XCTAssertEqual(sliced.blocks.count, 1)
        XCTAssertFalse(sliced.trailingNewline)
        let md = MarkdownSerializer.serialize(sliced)
        XCTAssertEqual(md, "llo wor")
    }

    func test_5d_slice_wholeBlock_paragraphPreservesFormatting() {
        // Fully covering a paragraph should copy the block verbatim —
        // inline formatting (bold, link) must survive.
        let proj = project("hello **world**\n")
        let span = proj.blockSpans[0]
        let sliced = proj.slice(in: span)
        XCTAssertEqual(sliced.blocks.count, 1)
        let md = MarkdownSerializer.serialize(sliced)
        XCTAssertEqual(md, "hello **world**")
    }

    func test_5d_slice_rangeSpanningTwoBlocks_partialFirstWholeSecond() {
        // "abc\n\ndef\n" → two paragraphs + blank line: blocks = [P(abc), blank, P(def)]
        // Select from middle of first paragraph to end of second:
        // ensure both paragraphs appear (partial + whole).
        let proj = project("abc\n\ndef\n")
        let firstSpan = proj.blockSpans[0]
        let lastSpan = proj.blockSpans[proj.blockSpans.count - 1]
        // Select from offset 1 in first block to end of last block.
        let start = firstSpan.location + 1 // "bc"
        let end = lastSpan.location + lastSpan.length
        let sliced = proj.slice(in: NSRange(location: start, length: end - start))
        XCTAssertGreaterThanOrEqual(sliced.blocks.count, 2)
        let md = MarkdownSerializer.serialize(sliced)
        // The slice should contain both "bc" and "def".
        XCTAssertTrue(md.contains("bc"), "expected 'bc' in slice, got: \(md)")
        XCTAssertTrue(md.contains("def"), "expected 'def' in slice, got: \(md)")
    }

    func test_5d_slice_multipleWholeBlocks_preservesStructure() {
        // Two-block paragraph document, select everything: serialize
        // should reproduce structure (two paragraphs with blank line).
        let proj = project("first para\n\nsecond para\n")
        let total = NSRange(location: 0, length: proj.attributed.length)
        let sliced = proj.slice(in: total)
        XCTAssertGreaterThanOrEqual(sliced.blocks.count, 2)
        let md = MarkdownSerializer.serialize(sliced)
        XCTAssertTrue(md.contains("first para"))
        XCTAssertTrue(md.contains("second para"))
    }

    // MARK: - EditingOps.insertFragment

    func test_5d_insertFragment_emptyFragment_isNoop() throws {
        let proj = project("hello\n")
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 5)
        let fragment = Document(blocks: [], trailingNewline: false)
        let result = try EditingOps.insertFragment(fragment, at: cursor, in: proj)
        XCTAssertEqual(result.spliceRange.length, 0)
        XCTAssertEqual(result.spliceReplacement.length, 0)
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            proj.document.blocks.count
        )
        XCTAssertEqual(result.newProjection.attributed.string, proj.attributed.string)
    }

    func test_5d_insertFragment_atBlockBoundary_insertsAsNewBlock() throws {
        // Host: heading + paragraph. Insert a paragraph fragment at
        // start of the heading block (cursor offset 0 in heading).
        // Expected: fragment lands BEFORE the heading (or appropriate
        // boundary per primitive spec — we accept either before or
        // merged behavior, but block count must increase by 1).
        let proj = project("# title\n\nbody\n")
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 0)
        let fragment = Document(
            blocks: [.paragraph(inline: [.text("inserted")])],
            trailingNewline: false
        )
        let result = try EditingOps.insertFragment(fragment, at: cursor, in: proj)
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            proj.document.blocks.count + 1
        )
        // The inserted paragraph should serialize somewhere in the doc.
        let serialized = MarkdownSerializer.serialize(
            result.newProjection.document
        )
        XCTAssertTrue(serialized.contains("inserted"),
                      "expected 'inserted' in: \(serialized)")
        XCTAssertTrue(serialized.contains("# title"))
        XCTAssertTrue(serialized.contains("body"))
    }

    func test_5d_insertFragment_midParagraph_splitsAndMerges() throws {
        // "hello world" — insert fragment "INS" as a paragraph at offset 6
        // (between "hello " and "world"). The fragment's single
        // paragraph should merge with both halves, yielding one
        // paragraph "hello INSworld" (no blank line break — the fragment
        // is itself a single paragraph).
        let proj = project("hello world\n")
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 6)
        let fragment = Document(
            blocks: [.paragraph(inline: [.text("INS")])],
            trailingNewline: false
        )
        let result = try EditingOps.insertFragment(fragment, at: cursor, in: proj)
        // Block count unchanged: single-paragraph fragment merges into
        // the host paragraph.
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            proj.document.blocks.count
        )
        let serialized = MarkdownSerializer.serialize(
            result.newProjection.document
        )
        XCTAssertTrue(serialized.contains("hello INSworld"),
                      "expected 'hello INSworld', got: \(serialized)")
    }

    func test_5d_insertFragment_midParagraph_multiBlock() throws {
        // Host: "hello world", insert a TWO-block fragment (two
        // paragraphs). The paragraph splits: first fragment paragraph
        // merges with the "hello " half, second fragment paragraph
        // merges with the "world" half. Net result: one more paragraph
        // block in the document.
        let proj = project("hello world\n")
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 6)
        let fragment = Document(
            blocks: [
                .paragraph(inline: [.text("A")]),
                .paragraph(inline: [.text("B")])
            ],
            trailingNewline: false
        )
        let result = try EditingOps.insertFragment(fragment, at: cursor, in: proj)
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            proj.document.blocks.count + 1
        )
        let serialized = MarkdownSerializer.serialize(
            result.newProjection.document
        )
        XCTAssertTrue(serialized.contains("hello A"), "got: \(serialized)")
        XCTAssertTrue(serialized.contains("Bworld"), "got: \(serialized)")
    }

    func test_5d_insertFragment_returnsContract_withReplaceBlock() throws {
        let proj = project("hello\n")
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 5)
        let fragment = Document(
            blocks: [.paragraph(inline: [.text("X")])],
            trailingNewline: false
        )
        let result = try EditingOps.insertFragment(fragment, at: cursor, in: proj)
        XCTAssertNotNil(result.contract)
        let actions = result.contract!.declaredActions
        // Every insertFragment result must declare at least the target
        // block as replaced; additional inserts are allowed.
        XCTAssertTrue(
            actions.contains(.replaceBlock(at: 0)),
            "expected .replaceBlock(at: 0) in \(actions)"
        )
    }

    func test_5d_insertFragment_splice_appliedToAttributedMatchesNewProjection() throws {
        // Invariant: splicing the EditResult onto the old projection's
        // attributed string reproduces the new projection's text.
        let proj = project("hello world\n")
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 6)
        let fragment = Document(
            blocks: [.paragraph(inline: [.text("INS")])],
            trailingNewline: false
        )
        let result = try EditingOps.insertFragment(fragment, at: cursor, in: proj)

        let m = NSMutableAttributedString(attributedString: proj.attributed)
        m.replaceCharacters(in: result.spliceRange, with: result.spliceReplacement)
        XCTAssertEqual(m.string, result.newProjection.attributed.string)
    }

    // MARK: - Copy-path wire-in (markdownForCopy → slice → serialize)

    func test_5d_copy_singleParagraph_wholeBlock_viaSlice() {
        // Selecting the entire paragraph span should produce exactly the
        // paragraph's markdown (no trailing newline, no surrounding
        // whitespace).
        let proj = project("hello world\n")
        let span = proj.blockSpans[0]
        let md = EditTextView.markdownForCopy(projection: proj, range: span)
        XCTAssertEqual(md, "hello world")
    }

    func test_5d_copy_wholeBlock_preservesInlineFormatting() {
        // Inline markers (bold, italic, links) must survive whole-
        // block copy via slice.
        let proj = project("say **hello** _world_\n")
        let span = proj.blockSpans[0]
        let md = EditTextView.markdownForCopy(projection: proj, range: span)
        XCTAssertEqual(md, "say **hello** _world_")
    }

    func test_5d_copy_spanningTwoParagraphs_viaSlice() {
        // Two paragraphs separated by a blank line. Selecting the
        // entire document should produce both paragraphs joined by
        // a blank line (the serializer handles block separators).
        let proj = project("first\n\nsecond\n")
        let total = NSRange(location: 0, length: proj.attributed.length)
        let md = EditTextView.markdownForCopy(projection: proj, range: total)
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("first"))
        XCTAssertTrue(md!.contains("second"))
    }
}
