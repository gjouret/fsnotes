//
//  EditingOperationsTests.swift
//  FSNotesTests
//
//  Tests for block-model editing: insert / delete inside a single
//  block. Every edit is verified end-to-end:
//   1. The new Document serializes back to the expected markdown.
//   2. The new projection's rendered output matches applying the
//      splice to the old rendered output (the "splice invariant").
//   3. The splice range equals the old block's span.
//

import XCTest
@testable import FSNotes

class EditingOperationsTests: XCTestCase {

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

    /// Return the storage offset where the inline content of a list
    /// item begins. `blockIndex` selects the list block (default 0),
    /// `itemIndex` selects the flat-list entry (default 0). The offset
    /// is derived from the projection — NOT hardcoded — so it adapts
    /// automatically when the rendering format changes.
    private func listInlineStart(
        in proj: DocumentProjection,
        blockIndex: Int = 0,
        itemIndex: Int = 0
    ) -> Int {
        guard case .list(let items, _) = proj.document.blocks[blockIndex] else {
            fatalError("Block \(blockIndex) is not a list")
        }
        let entries = EditingOps.flattenListPublic(items)
        let entry = entries[itemIndex]
        return proj.blockSpans[blockIndex].location + entry.startOffset + entry.prefixLength
    }

    /// Apply an EditResult's splice to the old attributed string and
    /// assert it equals the new projection's rendered output. This is
    /// the "splice invariant": splicing the old storage produces the
    /// same visible content as constructing a fresh projection.
    private func assertSpliceInvariant(
        old: DocumentProjection,
        result: EditResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let m = NSMutableAttributedString(attributedString: old.attributed)
        m.replaceCharacters(in: result.spliceRange, with: result.spliceReplacement)
        XCTAssertEqual(
            m.string, result.newProjection.attributed.string,
            "splice did not reproduce new projection's rendered text",
            file: file, line: line
        )
    }

    // MARK: - Insert into paragraph

    func test_insert_paragraph_atStart() throws {
        let p = project("hello\n")
        let r = try EditingOps.insert("X", at: 0, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "Xhello\n")
        XCTAssertEqual(r.newProjection.attributed.string, "Xhello\n")
        XCTAssertEqual(r.spliceRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(r.spliceReplacement.string, "X")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_paragraph_atMiddle() throws {
        let p = project("hello\n")
        let r = try EditingOps.insert("X", at: 3, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "helXlo\n")
        XCTAssertEqual(r.newProjection.attributed.string, "helXlo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_paragraph_atEnd() throws {
        let p = project("hello\n")
        let r = try EditingOps.insert("!", at: 5, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "hello!\n")
        XCTAssertEqual(r.newProjection.attributed.string, "hello!\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_paragraph_multiChar() throws {
        let p = project("hello\n")
        let r = try EditingOps.insert(", world", at: 5, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "hello, world\n")
        XCTAssertEqual(r.newProjection.attributed.string, "hello, world\n")
        assertSpliceInvariant(old: p, result: r)
    }

    // MARK: - Insert into heading

    func test_insert_heading_atStart() throws {
        let p = project("# Title\n")
        // Rendered "Title\n", block[0].span = [0,5)
        let r = try EditingOps.insert("X", at: 0, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "# XTitle\n")
        XCTAssertEqual(r.newProjection.attributed.string, "XTitle\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_heading_atEnd() throws {
        let p = project("## Greeting\n")
        // Rendered "Greeting\n", block[0].span = [0,8)
        let r = try EditingOps.insert("s", at: 8, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "## Greetings\n")
        XCTAssertEqual(r.newProjection.attributed.string, "Greetings\n")
        assertSpliceInvariant(old: p, result: r)
    }

    /// REGRESSION: new-note seed "# " followed by typing the first
    /// character of the heading. The heading suffix must preserve its
    /// leading space so the serialized markdown reads "# H" and not "#H".
    /// Otherwise auto-rename-from-title reads the saved markdown back,
    /// the leading "# " strip in trimMDSyntax() does not match "#H", and
    /// the note gets renamed to "#".
    func test_insert_heading_emptyHeadingSeed_preservesSpace() throws {
        let p = project("# ")
        // Parse: `.heading(level:1, suffix:" ")`, displayed length 0.
        XCTAssertEqual(p.attributed.string, "")
        let r = try EditingOps.insert("H", at: 0, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "# H")
        XCTAssertEqual(r.newProjection.attributed.string, "H")
    }

    // MARK: - Insert into code block

    func test_insert_codeBlock_middle() throws {
        let md = "```\nlet x = 1\n```\n"
        let p = project(md)
        // Block 0 renders as "let x = 1" (9 chars), span = [0,9)
        XCTAssertEqual(p.attributed.string, "let x = 1\n")
        let r = try EditingOps.insert("0", at: 9, in: p)
        // Append '0' at end of content → "let x = 10"
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "```\nlet x = 10\n```\n")
        assertSpliceInvariant(old: p, result: r)
    }

    // MARK: - Multi-block: edit lands in correct block

    func test_insert_multiBlock_secondBlock() throws {
        // heading "# Title\n" then paragraph "body\n"
        let p = project("# Title\nbody\n")
        // Rendered: "Title\nbody\n"
        // block[0] span [0,5) = "Title", block[1] span [6,10) = "body"
        XCTAssertEqual(p.attributed.string, "Title\nbody\n")
        // Insert at position 8 → in "body" at offset 2 → "boXdy"
        let r = try EditingOps.insert("X", at: 8, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "# Title\nboXdy\n")
        XCTAssertEqual(r.newProjection.attributed.string, "Title\nboXdy\n")
        // Splice range is character-granular: just the insertion point
        XCTAssertEqual(r.spliceRange, NSRange(location: 8, length: 0))
        XCTAssertEqual(r.spliceReplacement.string, "X")
        assertSpliceInvariant(old: p, result: r)
    }

    // MARK: - Delete

    func test_delete_paragraph_oneChar() throws {
        let p = project("hello\n")
        // Delete 'l' at position 2 (offset 2, length 1) → "helo"
        let r = try EditingOps.delete(range: NSRange(location: 2, length: 1), in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "helo\n")
        XCTAssertEqual(r.newProjection.attributed.string, "helo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_paragraph_rangeMiddle() throws {
        let p = project("hello world\n")
        // Delete " worl" (positions 5..9, length 5)  → "hellod"
        let r = try EditingOps.delete(range: NSRange(location: 5, length: 5), in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "hellod\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_paragraph_allContent() throws {
        let p = project("hi\n")
        let r = try EditingOps.delete(range: NSRange(location: 0, length: 2), in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "\n")
        XCTAssertEqual(r.newProjection.attributed.string, "\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_heading_oneChar() throws {
        let p = project("# Title\n")
        // Delete 'T' at position 0
        let r = try EditingOps.delete(range: NSRange(location: 0, length: 1), in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "# itle\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_codeBlock_range() throws {
        let p = project("```\nlet x = 1\n```\n")
        // Delete " = 1" from "let x = 1" (positions 5..8, length 4) → "let x"
        let r = try EditingOps.delete(range: NSRange(location: 5, length: 4), in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "```\nlet x\n```\n")
        assertSpliceInvariant(old: p, result: r)
    }

    // MARK: - Error paths

    func test_insert_outsideDocument_throws() {
        let p = project("hi\n")
        // Length = 3 ("hi\n"). Position 3 is past trailing '\n'.
        XCTAssertThrowsError(try EditingOps.insert("X", at: 5, in: p)) { err in
            guard case EditingError.notInsideBlock = err else {
                XCTFail("expected notInsideBlock, got \(err)"); return
            }
        }
    }

    func test_delete_crossBlock_headingParagraph_merges() throws {
        // Adjacent heading + paragraph: merge produces a single paragraph
        // with the combined text content.
        let p = project("# Title\nbody\n")
        // Rendered "Title\nbody\n". Block 0 = [0,5), sep, Block 1 = [6,10)
        // Delete across separator: delete last char of heading "e", sep, first char of paragraph "b"
        // Result: "Titl" + "ody" = "Titlody"
        let r = try EditingOps.delete(range: NSRange(location: 4, length: 3), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        // The heading is downgraded to a paragraph on merge.
        XCTAssertTrue(serialized.contains("Titlody"), "Merged text should combine remaining heading and paragraph content")
        XCTAssertFalse(serialized.contains("#"), "Heading marker should not survive merge into paragraph")
    }

    func test_insert_unsupportedBlockType_throws() {
        let p = project("---\n")
        // Block 0 is horizontalRule. Rendered as glyph line. Span includes
        // the glyphs; inserting anywhere in that span should throw .unsupported.
        XCTAssertThrowsError(try EditingOps.insert("X", at: 0, in: p)) { err in
            guard case EditingError.unsupported = err else {
                XCTFail("expected unsupported, got \(err)"); return
            }
        }
    }

    // MARK: - Inline-tree navigation (Inline navigation)

    func test_insert_intoBold() throws {
        // "a **b** c\n" → rendered "a b c\n", paragraph has
        // [text("a "), bold([text("b")]), text(" c")]
        // Block rendered length = 5, storage spans [0,5).
        let p = project("a **b** c\n")
        XCTAssertEqual(p.attributed.string, "a b c\n")
        // Insert 'X' at offset 3 → inside bold leaf "b" at offset 1.
        // Expected rendered: "a bX c\n". Serialized: "a **bX** c\n".
        let r = try EditingOps.insert("X", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a bX c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a **bX** c\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_intoItalic() throws {
        // "a *b* c\n" → rendered "a b c\n"
        let p = project("a *b* c\n")
        XCTAssertEqual(p.attributed.string, "a b c\n")
        let r = try EditingOps.insert("X", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a bX c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a *bX* c\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_intoCodeSpan() throws {
        // "x `hi` y\n" → rendered "x hi y\n"
        let p = project("x `hi` y\n")
        XCTAssertEqual(p.attributed.string, "x hi y\n")
        // Offset 3 = inside code span at offset 1 ("h|i")
        let r = try EditingOps.insert("Z", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "x hZi y\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "x `hZi` y\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_atInlineBoundary_prefersEarlierLeaf() throws {
        // "a **b** c\n" → [text("a "), bold([text("b")]), text(" c")]
        // Leaf boundaries: offsets 0..2 in "a ", 2..3 in "b", 3..5 in " c".
        // Insert at offset 2 (text→bold boundary): earlier-wins → targets
        // end of "a ". Expected: "aX b c\n" serialized "aX **b** c\n".
        let p = project("a **b** c\n")
        let r = try EditingOps.insert("X", at: 2, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a Xb c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a X**b** c\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_intoNestedBoldItalic() throws {
        // "**a *b* c**\n" parses as bold containing [text, italic, text].
        // Rendered "a b c\n" (5 chars visible).
        let p = project("**a *b* c**\n")
        XCTAssertEqual(p.attributed.string, "a b c\n")
        // Insert at offset 3 — inside italic leaf "b" at offset 1.
        let r = try EditingOps.insert("X", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a bX c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "**a *bX* c**\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_withinBold() throws {
        // "a **bold** c\n" → rendered "a bold c\n"
        let p = project("a **bold** c\n")
        XCTAssertEqual(p.attributed.string, "a bold c\n")
        // Delete 'o' at rendered offset 3 (inside "bold" at offset 1)
        let r = try EditingOps.delete(range: NSRange(location: 3, length: 1), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a bld c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a **bld** c\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_crossInlineLeaf_throws() {
        // "a **b** c\n" rendered as "a b c\n"
        // Range [1,3) spans " " (in "a ") + "b" (in bold) → cross-leaf.
        let p = project("a **b** c\n")
        XCTAssertThrowsError(try EditingOps.delete(range: NSRange(location: 1, length: 2), in: p)) { err in
            guard case EditingError.crossInlineRange = err else {
                XCTFail("expected crossInlineRange, got \(err)"); return
            }
        }
    }

    func test_delete_withinCodeSpan() throws {
        // "x `hello` y\n" → rendered "x hello y\n"
        let p = project("x `hello` y\n")
        XCTAssertEqual(p.attributed.string, "x hello y\n")
        // Delete "ell" (offset 3, length 3) inside the code span
        let r = try EditingOps.delete(range: NSRange(location: 3, length: 3), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "x ho y\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "x `ho` y\n")
        assertSpliceInvariant(old: p, result: r)
    }

    // MARK: - Newline insertion / paragraph split (Paragraph split)

    func test_splitParagraph_atMiddle() throws {
        // "hello world\n" → paragraph(text("hello world")). Span [0,11).
        let p = project("hello world\n")
        // Insert "\n" at offset 5 → [paragraph("hello"), blankLine, paragraph(" world")]
        // (blankLine between paragraphs is required for round-trip: two
        // adjacent non-blank lines would be re-joined into one paragraph.)
        let r = try EditingOps.insert("\n", at: 5, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "hello\n\n world\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "hello\n\n world\n")
        // Splice is character-granular: only the changed portion.
        assertSpliceInvariant(old: p, result: r)
    }

    func test_splitParagraph_atStart() throws {
        let p = project("hello\n")
        // Split at offset 0 → [paragraph(""), paragraph("hello")]
        let r = try EditingOps.insert("\n", at: 0, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "\nhello\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_splitParagraph_atEnd() throws {
        let p = project("hello\n")
        // Split at offset 5 (end of "hello") → [paragraph("hello"), paragraph("")]
        let r = try EditingOps.insert("\n", at: 5, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "hello\n\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_splitParagraph_preservesBoldFormattingOnBothSides() throws {
        // "**hello**\n" → paragraph(bold([text("hello")])). Rendered "hello\n".
        let p = project("**hello**\n")
        XCTAssertEqual(p.attributed.string, "hello\n")
        // Split at offset 2 → [bold([text("he")]), blankLine, bold([text("llo")])] as paragraphs.
        let r = try EditingOps.insert("\n", at: 2, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "he\n\nllo\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "**he**\n\n**llo**\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_splitParagraph_atContainerBoundary() throws {
        // "a **b** c\n" → paragraph with [text("a "), bold([text("b")]), text(" c")].
        // Split at offset 3 (end of bold / start of " c").
        let p = project("a **b** c\n")
        let r = try EditingOps.insert("\n", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a b\n\n c\n")
        // bold fully on the left, " c" fully on the right.
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a **b**\n\n c\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_newline_insideCodeBlock_appendsToContent() throws {
        // "```\nlet x = 1\n```\n" → codeBlock content "let x = 1", rendered "let x = 1\n"
        let p = project("```\nlet x = 1\n```\n")
        XCTAssertEqual(p.attributed.string, "let x = 1\n")
        // Insert "\n" at offset 9 (end of "let x = 1") — content becomes "let x = 1\n"
        let r = try EditingOps.insert("\n", at: 9, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "```\nlet x = 1\n\n```\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_newline_inHeading_splitsHeading() throws {
        // "# Title\n" → rendered "Title\n"
        let p = project("# Title\n")
        XCTAssertEqual(p.attributed.string, "Title\n")
        // Insert "\n" at offset 3 (after "Tit") — splits heading into heading + blank + paragraph
        let r = try EditingOps.insert("\n", at: 3, in: p)
        // Heading keeps "Tit", blank line, then new paragraph gets "le"
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Tit\n"), "Should have heading 'Tit': \(serialized)")
        XCTAssertTrue(serialized.contains("le\n"), "Should have paragraph 'le': \(serialized)")
        // Cursor should be at start of new paragraph (after blank line)
        let paraBlockIdx = 2  // heading, blankLine, paragraph
        let paraBlockStart = r.newProjection.blockSpans[paraBlockIdx].location
        XCTAssertEqual(r.newCursorPosition, paraBlockStart)
        assertSpliceInvariant(old: p, result: r)
    }
    
    func test_newline_atEndOfHeading_createsParagraph() throws {
        // "# Title\n" → rendered "Title\n"
        let p = project("# Title\n")
        XCTAssertEqual(p.attributed.string, "Title\n")
        // Insert "\n" at offset 5 (end of "Title") — creates blank paragraph after
        let r = try EditingOps.insert("\n", at: 5, in: p)
        // Heading stays "# Title", new blank paragraph after
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Title\n"), "Should preserve heading: \(serialized)")
        // Should have a blank line after
        XCTAssertTrue(serialized.contains("\n\n") || serialized.hasSuffix("\n\n"), "Should have blank line: \(serialized)")
        // Cursor should be at start of new blank line
        let secondBlockStart = r.newProjection.blockSpans[1].location
        XCTAssertEqual(r.newCursorPosition, secondBlockStart)
        assertSpliceInvariant(old: p, result: r)
    }
    
    func test_newline_atStartOfHeading_createsParagraphBefore() throws {
        // "# Title\n" → rendered "Title\n"
        let p = project("# Title\n")
        XCTAssertEqual(p.attributed.string, "Title\n")
        // Insert "\n" at offset 0 (start of heading) — creates blank paragraph before
        let r = try EditingOps.insert("\n", at: 0, in: p)
        // First block becomes blank (or paragraph), heading keeps "Title"
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        // The heading text should be preserved
        XCTAssertTrue(serialized.contains("Title"), "Should preserve heading text: \(serialized)")
        // Should have 2 or 3 blocks (blank/para + heading, or blank + para if text moved)
        XCTAssertGreaterThan(r.newProjection.blockSpans.count, 1, "Should have created additional block")
        // Cursor should be at a valid position within the document
        XCTAssertGreaterThanOrEqual(r.newCursorPosition, 0)
        XCTAssertLessThanOrEqual(r.newCursorPosition, r.newProjection.attributed.length)
        assertSpliceInvariant(old: p, result: r)
    }

    func test_multilineInsert_intoHeading_throws() {
        // Multi-line paste into headings is not supported (Multi-line paste
        // only handles paragraphs and code blocks).
        let p = project("# Title\n")
        XCTAssertThrowsError(try EditingOps.insert("a\nb", at: 2, in: p)) { err in
            guard case EditingError.unsupported = err else {
                XCTFail("expected unsupported, got \(err)"); return
            }
        }
    }

    func test_splitParagraph_multiBlock() throws {
        // Two blocks; split the second paragraph.
        let p = project("# Title\nbody text\n")
        // Rendered "Title\nbody text\n". block[0]=[0,5) "Title", block[1]=[6,15) "body text".
        XCTAssertEqual(p.attributed.string, "Title\nbody text\n")
        // Split "body text" at offset 4 of its rendered content → storageIndex 10.
        let r = try EditingOps.insert("\n", at: 10, in: p)
        // Expected: "Title\nbody\n\n text\n" (blankLine between split halves).
        XCTAssertEqual(r.newProjection.attributed.string, "Title\nbody\n\n text\n")
        // Splice is character-granular: only the changed portion.
        assertSpliceInvariant(old: p, result: r)
    }

    // MARK: - Block merge on cross-boundary delete (Block merge)

    func test_merge_paragraphParagraph_backspaceAtStart() throws {
        // "abc\n\ndef\n" → [para("abc"), blankLine, para("def")]
        // Rendered: "abc\n\ndef\n". Spans: [0,3), [4,4), [5,8).
        let p = project("abc\n\ndef\n")
        XCTAssertEqual(p.attributed.string, "abc\n\ndef\n")
        // Backspace at start of block[2] (para "def"), storageIndex 5.
        // Deletes separator at position 4 → merges blankLine + para("def").
        let r = try EditingOps.delete(range: NSRange(location: 4, length: 1), in: p)
        // blankLine(nil) + paragraph("def") → paragraph("def").
        // New doc: [para("abc"), para("def")]. But adjacent paragraphs
        // still have a separator. Rendered: "abc\ndef\n".
        XCTAssertEqual(r.newProjection.attributed.string, "abc\ndef\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "abc\ndef\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_merge_twoParagraphsDirectly() throws {
        // Build doc with two adjacent paragraphs (no blank line): use
        // a heading + paragraph so the parser doesn't join them.
        // Actually, let's construct manually:
        let doc = Document(blocks: [
            .paragraph(inline: [.text("abc")]),
            .paragraph(inline: [.text("def")])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        // Rendered: "abc\ndef\n". Spans: [0,3), [4,7).
        XCTAssertEqual(p.attributed.string, "abc\ndef\n")
        // Backspace at start of block[1]: delete separator at position 3.
        let r = try EditingOps.delete(range: NSRange(location: 3, length: 1), in: p)
        // Merged: paragraph("abcdef"). Rendered: "abcdef\n".
        XCTAssertEqual(r.newProjection.attributed.string, "abcdef\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "abcdef\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_merge_preservesInlineFormatting() throws {
        // Two paragraphs: "**bold**" and "*italic*". Merge should
        // concatenate inline trees.
        let doc = Document(blocks: [
            .paragraph(inline: [.bold([.text("bold")])]),
            .paragraph(inline: [.italic([.text("italic")])])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        XCTAssertEqual(p.attributed.string, "bold\nitalic\n")
        let r = try EditingOps.delete(range: NSRange(location: 4, length: 1), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "bolditalic\n")
        XCTAssertEqual(
            MarkdownSerializer.serialize(r.newProjection.document),
            "**bold***italic*\n"
        )
        assertSpliceInvariant(old: p, result: r)
    }

    func test_merge_blankLineWithParagraph() throws {
        // [blankLine, paragraph("hello")]. Rendered: "\nhello\n".
        let doc = Document(blocks: [
            .blankLine,
            .paragraph(inline: [.text("hello")])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        XCTAssertEqual(p.attributed.string, "\nhello\n")
        // Spans: [0,0) for blankLine, [1,6) for paragraph.
        // Delete separator at position 0 → merges blankLine + paragraph.
        let r = try EditingOps.delete(range: NSRange(location: 0, length: 1), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "hello\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_merge_paragraphWithBlankLine() throws {
        // [paragraph("hello"), blankLine]. Rendered: "hello\n\n".
        let doc = Document(blocks: [
            .paragraph(inline: [.text("hello")]),
            .blankLine
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        XCTAssertEqual(p.attributed.string, "hello\n\n")
        // Spans: [0,5) for paragraph, [6,6) for blankLine.
        // Delete separator at position 5 → merges paragraph + blankLine.
        let r = try EditingOps.delete(range: NSRange(location: 5, length: 1), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "hello\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_merge_withPartialDeletion() throws {
        // Two paragraphs: "abc" and "xyz". Delete selection covering
        // "c\nx" (last char of first + separator + first char of second).
        let doc = Document(blocks: [
            .paragraph(inline: [.text("abc")]),
            .paragraph(inline: [.text("xyz")])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        XCTAssertEqual(p.attributed.string, "abc\nxyz\n")
        // Delete range [2, 5) covers "c" (offset 2 in block 0) + "\n" +
        // "x" (offset 0 in block 1).
        let r = try EditingOps.delete(range: NSRange(location: 2, length: 3), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "abyz\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "abyz\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_multipleBlocks_succeeds() throws {
        // Three paragraphs: "a", "b", "c". Delete all content across
        // all 3 blocks. Should produce a single empty paragraph.
        let doc = Document(blocks: [
            .paragraph(inline: [.text("a")]),
            .paragraph(inline: [.text("b")]),
            .paragraph(inline: [.text("c")])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        XCTAssertEqual(p.attributed.string, "a\nb\nc\n")
        // Delete [0,5) spans blocks 0 through 2 — removes "a\nb\nc".
        let r = try EditingOps.delete(range: NSRange(location: 0, length: 5), in: p)
        // Should leave empty paragraph.
        XCTAssertEqual(r.newProjection.document.blocks.count, 1)
    }

    func test_delete_middleBlocks_mergesBoundaries() throws {
        // Four paragraphs: "abc", "xx", "yy", "def". Delete selection
        // spanning from middle of first to middle of last: "c\nxx\nyy\nd"
        let doc = Document(blocks: [
            .paragraph(inline: [.text("abc")]),
            .paragraph(inline: [.text("xx")]),
            .paragraph(inline: [.text("yy")]),
            .paragraph(inline: [.text("def")])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        XCTAssertEqual(p.attributed.string, "abc\nxx\nyy\ndef\n")
        // Delete [2,11): "c\nxx\nyy\nd" → keeps "ab" + "ef"
        let r = try EditingOps.delete(range: NSRange(location: 2, length: 9), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "abef\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "abef\n")
    }

    func test_delete_multipleBlocks_preservesFormatting() throws {
        // Delete across 3 blocks, boundary blocks have formatting.
        let doc = Document(blocks: [
            .paragraph(inline: [.bold([.text("bold")])]),
            .paragraph(inline: [.text("middle")]),
            .paragraph(inline: [.italic([.text("italic")])])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        XCTAssertEqual(p.attributed.string, "bold\nmiddle\nitalic\n")
        // Delete from end of bold to start of italic: "d\nmiddle\n"
        // Keeps "bol" from first block, "italic" from last.
        let r = try EditingOps.delete(range: NSRange(location: 3, length: 9), in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "bolitalic\n")
    }

    func test_merge_headingWithParagraph_succeeds() throws {
        // Heading + paragraph merge: produces a paragraph with combined text.
        let p = project("# Title\nhello\n")
        // Delete separator between heading and paragraph.
        // Spans: [0,5) heading "Title", [6,11) paragraph "hello".
        let r = try EditingOps.delete(range: NSRange(location: 5, length: 1), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        // Heading is downgraded to paragraph.
        XCTAssertTrue(serialized.contains("Titlehello"), "Merge should combine heading text with paragraph text")
        XCTAssertFalse(serialized.contains("#"), "Heading marker should not survive merge into paragraph")
    }

    func test_merge_blankLineWithHeading_preservesHeading() throws {
        // BlankLine + heading: the blank is removed, heading is preserved.
        let p = project("\n## Hello\n")
        // Block 0 = blankLine (rendered as "\n" → span [0,0) empty),
        // Block 1 = heading "Hello".
        // Delete separator between blankLine and heading.
        let blankSpan = p.blockSpans[0]
        let headingSpan = p.blockSpans[1]
        let sepLoc = blankSpan.location + blankSpan.length
        let r = try EditingOps.delete(range: NSRange(location: sepLoc, length: 1), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("## Hello"), "Heading should be preserved when merging with blank line")
    }

    func test_merge_paragraphWithHeading_producesParagraph() throws {
        // Paragraph + heading: result is a paragraph (heading demoted).
        let p = project("text\n## Hello\n")
        // Delete the last char of paragraph + separator + first char of heading
        // to force cross-block merge.
        let paraSpan = p.blockSpans[0]
        let r = try EditingOps.delete(range: NSRange(location: paraSpan.length - 1, length: 2), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertFalse(serialized.contains("#"), "Heading should be demoted to paragraph when merging into paragraph")
    }

    // MARK: - Block swap (move up/down)

    func test_moveBlockUp_swapsWithPrevious() throws {
        let p = project("First\n## Second\n")
        let r = try EditingOps.moveBlockUp(blockIndex: 1, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.hasPrefix("## Second"), "Heading should move to top")
        XCTAssertTrue(serialized.contains("\nFirst\n"), "Paragraph should move below heading")
    }

    func test_moveBlockDown_swapsWithNext() throws {
        let p = project("## Title\nbody\n")
        let r = try EditingOps.moveBlockDown(blockIndex: 0, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.hasPrefix("body"), "Paragraph should move to top")
        XCTAssertTrue(serialized.contains("\n## Title\n"), "Heading should move below paragraph")
    }

    func test_moveBlockUp_firstBlock_throws() {
        let p = project("First\nSecond\n")
        XCTAssertThrowsError(try EditingOps.moveBlockUp(blockIndex: 0, in: p))
    }

    func test_moveBlockDown_lastBlock_throws() {
        let p = project("First\nSecond\n")
        let lastIdx = p.document.blocks.count - 1
        XCTAssertThrowsError(try EditingOps.moveBlockDown(blockIndex: lastIdx, in: p))
    }

    // MARK: - Cursor position after Return in lists/blockquotes

    func test_returnInList_cursorGoesToNewItem() throws {
        // "- hello" → press Return after "hel" → "- hel\n- lo"
        // Cursor should be at start of "lo" (after the bullet prefix of the new item).
        let p = project("- hello\n")
        let inlineStart = listInlineStart(in: p)
        let r = try EditingOps.insert("\n", at: inlineStart + 3, in: p) // 3 chars into "hello"
        let rendered = r.newProjection.attributed.string
        // Should contain two items: "• hel" and "• lo".
        XCTAssertTrue(rendered.contains("lo"), "New item should contain 'lo'")
        // Cursor should be at the start of "lo", not at position 0.
        XCTAssertGreaterThan(r.newCursorPosition, 0, "Cursor must not be at position 0")
        // Cursor should be after the "• " prefix of the new item.
        let cursorChar = rendered[rendered.index(rendered.startIndex, offsetBy: r.newCursorPosition)]
        XCTAssertEqual(String(cursorChar), "l", "Cursor should be at start of 'lo' text, got char at pos \(r.newCursorPosition): '\(cursorChar)'")
    }

    func test_returnInList_cursorGoesToEndOfPrefix() throws {
        // "- abc" → Return at end → "- abc\n- "
        // Cursor should be at the new empty item (after prefix).
        let p = project("- abc\n")
        let inlineStart = listInlineStart(in: p)
        let r = try EditingOps.insert("\n", at: inlineStart + 3, in: p) // end of "abc"
        XCTAssertGreaterThan(r.newCursorPosition, 0, "Cursor must not jump to top")
    }

    func test_returnInBlockquote_cursorGoesToNewLine() throws {
        // "> hello" → Return after "hel" → "> hel\n> lo"
        let p = project("> hello\n")
        // Rendered: "  hello\n" (2-char indent). "hel" starts at 2, so offset 5.
        let r = try EditingOps.insert("\n", at: 5, in: p)
        XCTAssertGreaterThan(r.newCursorPosition, 0, "Cursor must not jump to top")
    }

    // MARK: - Multi-line paste (Multi-line paste)

    func test_paste_twoLines_intoMiddle() throws {
        // Paste "abc\ndef" into "hello" at offset 2 → "heabc\ndefllo"
        let p = project("hello\n")
        let r = try EditingOps.insert("abc\ndef", at: 2, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "heabc\ndefllo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_twoLines_atStart() throws {
        // Paste "abc\ndef" at start of "xyz" → "abc\ndefxyz"
        let p = project("xyz\n")
        let r = try EditingOps.insert("abc\ndef", at: 0, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "abc\ndefxyz\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_twoLines_atEnd() throws {
        // Paste "abc\ndef" at end of "xyz" → "xyzabc\ndef"
        let p = project("xyz\n")
        let r = try EditingOps.insert("abc\ndef", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "xyzabc\ndef\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_trailingNewline() throws {
        // Paste "hello\n" at offset 2 of "abcd" → "abhello\ncd"
        // Trailing \n means the pasted text ends with an empty line,
        // which gets merged with the after-text.
        let p = project("abcd\n")
        let r = try EditingOps.insert("hello\n", at: 2, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "abhello\ncd\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_withBlankLine() throws {
        // Paste "a\n\nb" → three parts: "a", "", "b".
        // Empty middle line becomes blankLine.
        let p = project("xyz\n")
        let r = try EditingOps.insert("a\n\nb", at: 1, in: p)
        // "x" + "a" = first para, blankLine, "b" + "yz" = last para.
        XCTAssertEqual(r.newProjection.attributed.string, "xa\n\nbyz\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_threeLines() throws {
        // Paste "one\ntwo\nthree" → splits into 3 paragraphs.
        let p = project("hello\n")
        let r = try EditingOps.insert("one\ntwo\nthree", at: 5, in: p)
        // "hello" + "one" = first para, "two" = middle, "three" = last.
        XCTAssertEqual(r.newProjection.attributed.string, "helloone\ntwo\nthree\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_preservesInlineFormatting() throws {
        // Paste "x\ny" into bold paragraph at offset 2.
        // "**hello**\n" rendered "hello\n". Split at 2: bold("he") | bold("llo").
        // First para: bold("he") + text("x"). Last para: text("y") + bold("llo").
        let p = project("**hello**\n")
        XCTAssertEqual(p.attributed.string, "hello\n")
        let r = try EditingOps.insert("x\ny", at: 2, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "hex\nyllo\n")
        XCTAssertEqual(
            MarkdownSerializer.serialize(r.newProjection.document),
            "**he**x\ny**llo**\n"
        )
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_multilineIntoCodeBlock() throws {
        // Code blocks accept multi-line paste as raw content.
        let p = project("```\nabc\n```\n")
        XCTAssertEqual(p.attributed.string, "abc\n")
        // Paste "x\ny\nz" at offset 1 → content becomes "ax\ny\nzbc"
        let r = try EditingOps.insert("x\ny\nz", at: 1, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "ax\ny\nzbc\n")
        XCTAssertEqual(
            MarkdownSerializer.serialize(r.newProjection.document),
            "```\nax\ny\nzbc\n```\n"
        )
        assertSpliceInvariant(old: p, result: r)
    }

    func test_paste_multilineIntoHeading_throws() {
        let p = project("# Title\n")
        XCTAssertThrowsError(try EditingOps.insert("a\nb", at: 2, in: p)) { err in
            guard case EditingError.unsupported = err else {
                XCTFail("expected unsupported, got \(err)"); return
            }
        }
    }

    // MARK: - Chain of edits (round-trip stability)

    func test_chain_insertInsertDelete() throws {
        var p = project("hello\n")
        let r1 = try EditingOps.insert(", ", at: 5, in: p)
        p = r1.newProjection
        let r2 = try EditingOps.insert("world", at: 7, in: p)
        p = r2.newProjection
        XCTAssertEqual(MarkdownSerializer.serialize(p.document), "hello, world\n")
        // Now delete "hello, " → "world"
        let r3 = try EditingOps.delete(range: NSRange(location: 0, length: 7), in: p)
        p = r3.newProjection
        XCTAssertEqual(MarkdownSerializer.serialize(p.document), "world\n")
        XCTAssertEqual(p.attributed.string, "world\n")
    }

    // MARK: - List editing

    func test_insert_list_singleItem() throws {
        let p = project("- hello\n")
        let inl = listInlineStart(in: p)
        // Insert "X" at inline offset 2 → "heXllo"
        let r = try EditingOps.insert("X", at: inl + 2, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "- heXllo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_list_multiItem() throws {
        let p = project("- one\n- two\n")
        // Insert "X" at start of second item's inline content.
        let inl1 = listInlineStart(in: p, itemIndex: 1)
        let r = try EditingOps.insert("X", at: inl1, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "- one\n- Xtwo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_list_item() throws {
        let p = project("- hello\n")
        let inl = listInlineStart(in: p)
        // Delete "l" at inline offset 3 → "helo"
        let r = try EditingOps.delete(range: NSRange(location: inl + 3, length: 1), in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "- helo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_list_returnKey_splitsItem() throws {
        let p = project("- hello\n")
        let inl = listInlineStart(in: p)
        // Split "hello" at offset 3 → "hel" and "lo"
        let r = try EditingOps.insert("\n", at: inl + 3, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- hel\n- lo\n")
    }

    func test_insert_list_roundTrip() throws {
        let md = "- one\n- two\n- three\n"
        let p = project(md)
        let inl = listInlineStart(in: p)
        // Insert at end of first item ("one" = 3 chars)
        let r = try EditingOps.insert("!", at: inl + 3, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        let reparsed = MarkdownParser.parse(serialized)
        let reserialized = MarkdownSerializer.serialize(reparsed)
        XCTAssertEqual(serialized, reserialized, "List edit round-trip unstable")
    }

    // MARK: - Blockquote editing

    func test_insert_blockquote_singleLine() throws {
        let p = project("> hello\n")
        // Rendered: "hello" (5 chars). No space prefix — indentation is via paragraph style.
        // Insert "X" at inline offset 2 → "heXllo"
        let r = try EditingOps.insert("X", at: 2, in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "> heXllo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_blockquote_line() throws {
        let p = project("> hello\n")
        // Delete "l" at inline offset 3 (rendered: "hello", offset 3 = "l")
        let r = try EditingOps.delete(range: NSRange(location: 3, length: 1), in: p)
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "> helo\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_blockquote_returnKey_splitsLine() throws {
        let p = project("> hello\n")
        // Split at offset 3 in inline → "> hel" and "> lo"
        let r = try EditingOps.insert("\n", at: 3, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "> hel\n> lo\n")
    }

    func test_insert_blockquote_roundTrip() throws {
        let md = "> line one\n> line two\n"
        let p = project(md)
        // Insert at end of first line's inline content
        // Rendered: "line one\nline two" — "line one" = 8 chars
        let r = try EditingOps.insert("!", at: 8, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        let reparsed = MarkdownParser.parse(serialized)
        let reserialized = MarkdownSerializer.serialize(reparsed)
        XCTAssertEqual(serialized, reserialized, "Blockquote edit round-trip unstable")
    }

    // MARK: - Horizontal rule editing

    func test_insert_horizontalRule_throws() throws {
        let p = project("---\n")
        // HR is read-only. Inserting should throw.
        XCTAssertThrowsError(try EditingOps.insert("X", at: 0, in: p)) { err in
            guard case EditingError.unsupported = err else {
                XCTFail("expected unsupported, got \(err)"); return
            }
        }
    }

    func test_delete_horizontalRule_noop() throws {
        let p = project("---\n")
        // Delete within HR is a no-op (returns the same block).
        let r = try EditingOps.delete(range: NSRange(location: 0, length: 1), in: p)
        XCTAssertEqual(
            MarkdownSerializer.serialize(r.newProjection.document),
            "---\n"
        )
    }

    // MARK: - List Return key cursor position

    func test_list_returnKey_cursorPosition_endOfFirstItem() throws {
        let p = project("- item one\n- item two\n")
        let inl0 = listInlineStart(in: p, itemIndex: 0)
        // Press Return at end of "item one" (8 chars)
        let r = try EditingOps.insert("\n", at: inl0 + 8, in: p)

        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- item one\n- \n- item two\n")

        // Cursor should be at inline start of new empty item, not 0.
        let newInl = listInlineStart(in: r.newProjection, itemIndex: 1)
        XCTAssertGreaterThan(r.newCursorPosition, 0,
            "Cursor should not be at position 0 (top of list)")
        XCTAssertEqual(r.newCursorPosition, newInl,
            "Cursor should be at start of new item's inline content")
    }

    func test_list_returnKey_cursorPosition_midItem() throws {
        let p = project("- hello\n")
        let inl = listInlineStart(in: p)
        // Split "hello" 3 chars in → "hel"|"lo"
        let r = try EditingOps.insert("\n", at: inl + 3, in: p)

        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- hel\n- lo\n")

        // Cursor should be at inline start of second item ("lo").
        let newInl1 = listInlineStart(in: r.newProjection, itemIndex: 1)
        XCTAssertGreaterThan(r.newCursorPosition, 0,
            "Cursor should not be at position 0 (top of list)")
        XCTAssertEqual(r.newCursorPosition, newInl1,
            "Cursor should be at start of second item's inline content")
    }

    func test_list_returnKey_cursorPosition_threeItems_splitSecond() throws {
        let p = project("- one\n- two\n- three\n")
        let inl1 = listInlineStart(in: p, itemIndex: 1)
        // End of item 1 inline ("two" = 3 chars)
        let r = try EditingOps.insert("\n", at: inl1 + 3, in: p)

        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- one\n- two\n- \n- three\n")

        // New empty item is at index 2 in the result.
        let newInl2 = listInlineStart(in: r.newProjection, itemIndex: 2)
        XCTAssertGreaterThan(r.newCursorPosition, 0,
            "Cursor should not be at position 0 (top of list)")
        XCTAssertEqual(r.newCursorPosition, newInl2,
            "Cursor should be at start of new empty item's inline content")
    }

    func test_list_returnKey_cursorPosition_todoItem() throws {
        let p = project("- [ ] buy milk\n")
        let inl = listInlineStart(in: p)
        // End of inline "buy milk" (8 chars)
        let r = try EditingOps.insert("\n", at: inl + 8, in: p)

        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- [ ] buy milk\n- [ ] \n")

        XCTAssertGreaterThan(r.newCursorPosition, 0,
            "Cursor should not be at position 0 (top of list) for todo items")
    }

    func test_list_returnKey_cursorPosition_afterParagraph() throws {
        let p = project("Hello world\n\n- item one\n- item two\n")
        // Find list block index dynamically.
        let listBlockIdx = p.document.blocks.firstIndex {
            if case .list = $0 { return true }; return false
        }!
        let inl0 = listInlineStart(in: p, blockIndex: listBlockIdx, itemIndex: 0)
        // End of "item one" (8 chars)
        let r = try EditingOps.insert("\n", at: inl0 + 8, in: p)

        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("- item one\n- \n- item two\n"),
            "Should split item one and insert empty item")

        let listSpan = p.blockSpans[listBlockIdx]
        XCTAssertGreaterThan(r.newCursorPosition, listSpan.location,
            "Cursor should be within the list block, not at document start")
    }

    func test_list_returnKey_cursorPosition_nestedItem() throws {
        let p = project("- parent\n  - child\n")
        let inl0 = listInlineStart(in: p, itemIndex: 0)
        // End of "parent" (6 chars)
        let r = try EditingOps.insert("\n", at: inl0 + 6, in: p)

        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("- parent\n"),
            "Parent item should be preserved")
        XCTAssertGreaterThan(r.newCursorPosition, inl0 + 6,
            "Cursor should be past parent item, not at top of list")
    }

    func test_list_returnKey_cursorNotAtZero() throws {
        let p = project("- hello\n")
        let inl = listInlineStart(in: p)
        // End of "hello" (5 chars)
        let r = try EditingOps.insert("\n", at: inl + 5, in: p)

        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- hello\n- \n")

        // Cursor should be at inline start of new empty item.
        let newInl1 = listInlineStart(in: r.newProjection, itemIndex: 1)
        XCTAssertNotEqual(r.newCursorPosition, 0,
            "BUG: cursor went to position 0 (top of list) instead of new item")
        XCTAssertEqual(r.newCursorPosition, newInl1,
            "Cursor should be at inline start of new empty item")
    }
}
