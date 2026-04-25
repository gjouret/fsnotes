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
        // Adjacent heading + paragraph: per ARCHITECTURE.md §192,
        // "heading | paragraph → Heading with paragraph's inlines
        // appended to suffix". The heading level is preserved.
        let p = project("# Title\nbody\n")
        // Rendered "Title\nbody\n". Block 0 = [0,5), sep, Block 1 = [6,10)
        // Delete across separator: last char of heading "e", sep, first char of paragraph "b"
        // Result: heading " Titl" + paragraph-text "ody" → "# Titlody"
        let r = try EditingOps.delete(range: NSRange(location: 4, length: 3), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Titlody"),
                      "Heading should survive merge with paragraph's text appended (got: \(serialized))")
    }

    func test_insert_atomicBlock_createsParagraphSibling() throws {
        let p = project("---\n")
        // Block 0 is horizontalRule (atomic attachment). Inserting at offset 0
        // creates a paragraph SIBLING before the HR (new UX contract — see
        // insertAroundAtomicBlock). HR is preserved; the new text lives in a
        // new paragraph block.
        let r = try EditingOps.insert("X", at: 0, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("X"), "inserted text must appear (got: \(serialized))")
        XCTAssertTrue(serialized.contains("---"), "HR must be preserved (got: \(serialized))")
    }

    // MARK: - Inline-tree navigation (Inline navigation)

    func test_insert_intoBold() throws {
        // "a **b** c\n" → rendered "a b c\n", paragraph has
        // [text("a "), bold([text("b")]), text(" c")].
        // Offset 3 is the CLOSING fence of **b** (end-of-bold boundary).
        // Per markdown fence semantics, typing past the closing `**` is
        // OUTSIDE bold → plain sibling.
        let p = project("a **b** c\n")
        XCTAssertEqual(p.attributed.string, "a b c\n")
        let r = try EditingOps.insert("X", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a bX c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a **b**X c\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_insert_intoItalic() throws {
        // "a *b* c\n" → rendered "a b c\n". Offset 3 = closing-fence
        // boundary. New char becomes a plain sibling outside italic.
        let p = project("a *b* c\n")
        XCTAssertEqual(p.attributed.string, "a b c\n")
        let r = try EditingOps.insert("X", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a bX c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a *b*X c\n")
        assertSpliceInvariant(old: p, result: r)
    }

    /// Inserting STRICTLY inside a multi-char bold span extends the span.
    func test_insert_trulyInsideBold_extendsSpan() throws {
        let p = project("a **bold** c\n")
        // Rendered "a bold c". Offset 4 = between 'o' and 'l'.
        let r = try EditingOps.insert("X", at: 4, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a boXld c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "a **boXld** c\n")
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
        // Offset 3 is the CLOSING-fence boundary of the inner italic
        // *b* — still inside the outer bold. Expected: bold preserved,
        // italic NOT extended; new char is a plain sibling inside bold.
        let p = project("**a *b* c**\n")
        XCTAssertEqual(p.attributed.string, "a b c\n")
        let r = try EditingOps.insert("X", at: 3, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "a bX c\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "**a *b*X c**\n")
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
        // Insert "\n" at offset 3 (after "Tit") — splits heading into
        // heading + paragraph (no interstitial blankLine; paragraphSpacing
        // and the serializer's blank-separator logic handle the gap).
        let r = try EditingOps.insert("\n", at: 3, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Tit\n"), "Should have heading 'Tit': \(serialized)")
        XCTAssertTrue(serialized.contains("le\n"), "Should have paragraph 'le': \(serialized)")
        // Two blocks only: [heading, paragraph]. Cursor at start of paragraph.
        XCTAssertEqual(r.newProjection.document.blocks.count, 2)
        let paraBlockStart = r.newProjection.blockSpans[1].location
        XCTAssertEqual(r.newCursorPosition, paraBlockStart)
        assertSpliceInvariant(old: p, result: r)
    }
    
    func test_newline_atEndOfHeading_createsParagraph() throws {
        // "# Title\n" → rendered "Title\n"
        let p = project("# Title\n")
        XCTAssertEqual(p.attributed.string, "Title\n")
        // Insert "\n" at offset 5 (end of "Title") — creates empty paragraph after.
        // Per the corrected Return-in-heading rule, this produces
        // [heading, paragraph(inline:[])] with NO blankLine between.
        let r = try EditingOps.insert("\n", at: 5, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Title\n"), "Should preserve heading: \(serialized)")
        // Exactly two blocks: heading + empty paragraph.
        XCTAssertEqual(r.newProjection.document.blocks.count, 2)
        if case .paragraph(let inline) = r.newProjection.document.blocks[1] {
            XCTAssertTrue(inline.isEmpty, "Second block should be empty paragraph")
        } else {
            XCTFail("Second block should be a paragraph")
        }
        // Cursor at start of the new empty paragraph.
        let secondBlockStart = r.newProjection.blockSpans[1].location
        XCTAssertEqual(r.newCursorPosition, secondBlockStart)
        assertSpliceInvariant(old: p, result: r)
    }
    
    func test_newline_atStartOfHeading_createsParagraphBefore() throws {
        // Bug #6 (Slice B): Return at start of heading must produce
        //   block[0] = empty paragraph
        //   block[1] = heading preserved (kind, level, suffix unchanged)
        //   cursor at start of block[1] (the preserved heading)
        // Previously the heading degraded to a `blankLine` and the
        // suffix was promoted into a fresh paragraph — the heading was
        // lost.
        let p = project("# Title\n")
        XCTAssertEqual(p.attributed.string, "Title\n")
        let r = try EditingOps.insert("\n", at: 0, in: p)

        // Exactly two blocks.
        XCTAssertEqual(r.newProjection.document.blocks.count, 2)

        // Block 0: empty paragraph.
        if case .paragraph(let inline) = r.newProjection.document.blocks[0] {
            XCTAssertTrue(inline.isEmpty, "Block 0 must be an empty paragraph")
        } else {
            XCTFail("Block 0 must be a paragraph, got \(r.newProjection.document.blocks[0])")
        }

        // Block 1: heading(level: 1) preserved with the original suffix
        // (so the leading-space marker survives and the title text is
        // intact).
        if case .heading(let level, let suffix) = r.newProjection.document.blocks[1] {
            XCTAssertEqual(level, 1, "Heading level must be preserved")
            XCTAssertEqual(suffix, " Title", "Heading suffix must be preserved verbatim")
        } else {
            XCTFail("Block 1 must be a heading, got \(r.newProjection.document.blocks[1])")
        }

        // Cursor at the start of the preserved heading.
        let headingBlockStart = r.newProjection.blockSpans[1].location
        XCTAssertEqual(r.newCursorPosition, headingBlockStart,
                       "Cursor must land at the start of the preserved heading")

        // Round-trip: serialize must contain the heading marker + title.
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Title"),
                      "Serialized markdown must preserve `# Title`: \(serialized)")

        assertSpliceInvariant(old: p, result: r)
    }

    /// Slice B #6 generalization: same expected shape for H3.
    func test_newline_atStartOfH3_preservesHeading() throws {
        let p = project("### Sub\n")
        XCTAssertEqual(p.attributed.string, "Sub\n")
        let r = try EditingOps.insert("\n", at: 0, in: p)

        XCTAssertEqual(r.newProjection.document.blocks.count, 2)
        if case .paragraph(let inline) = r.newProjection.document.blocks[0] {
            XCTAssertTrue(inline.isEmpty)
        } else {
            XCTFail("Block 0 must be an empty paragraph")
        }
        if case .heading(let level, let suffix) = r.newProjection.document.blocks[1] {
            XCTAssertEqual(level, 3)
            XCTAssertEqual(suffix, " Sub")
        } else {
            XCTFail("Block 1 must be a heading(level:3)")
        }
        XCTAssertEqual(r.newCursorPosition, r.newProjection.blockSpans[1].location)
        assertSpliceInvariant(old: p, result: r)
    }

    func test_multilineInsert_intoHeading_convertsToParagraph() throws {
        // Multi-line paste into headings now converts the heading to paragraphs
        let p = project("# Title\n")
        let r = try EditingOps.insert("a\nb", at: 2, in: p)
        // Heading should be converted to paragraph(s) - verify it doesn't throw
        // and produces valid output with more than one block or multi-line content
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("a") && serialized.contains("b"),
            "Pasted content should appear in output: \(serialized)")
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
        // Deletes separator at position 4 → merges both paragraphs into one.
        // The blank line is removed and the preceding paragraph absorbs the
        // following one, producing a single merged paragraph.
        let r = try EditingOps.delete(range: NSRange(location: 4, length: 1), in: p)
        // Merged: [para("abcdef")]. Rendered: "abcdef\n".
        XCTAssertEqual(r.newProjection.attributed.string, "abcdef\n")
        XCTAssertEqual(MarkdownSerializer.serialize(r.newProjection.document), "abcdef\n")
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
        // ARCHITECTURE.md §192: heading + paragraph → Heading with
        // paragraph's inlines appended to suffix. Heading level preserved.
        let p = project("# Title\nhello\n")
        // Delete separator between heading and paragraph.
        let r = try EditingOps.delete(range: NSRange(location: 5, length: 1), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Titlehello"),
                      "Heading should survive merge with paragraph text appended (got: \(serialized))")
    }

    func test_merge_blankLineWithHeading_preservesHeading() throws {
        // BlankLine + heading: the blank is removed, heading is preserved.
        let p = project("\n## Hello\n")
        // Block 0 = blankLine (rendered as "\n" → span [0,0) empty),
        // Block 1 = heading "Hello".
        // Delete separator between blankLine and heading.
        let blankSpan = p.blockSpans[0]
        let _ = p.blockSpans[1]
        let sepLoc = blankSpan.location + blankSpan.length
        let r = try EditingOps.delete(range: NSRange(location: sepLoc, length: 1), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("## Hello"), "Heading should be preserved when merging with blank line")
    }

    func test_merge_paragraphWithHeading_appendsText() throws {
        // ARCHITECTURE.md §192: paragraph + heading → Paragraph with
        // heading suffix appended (heading marker dropped, text retained).
        let p = project("text\n## Hello\n")
        // Delete the last char of paragraph + separator + first char of heading
        // to force cross-block merge.
        let paraSpan = p.blockSpans[0]
        let r = try EditingOps.delete(range: NSRange(location: paraSpan.length - 1, length: 2), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertFalse(serialized.contains("#"),
                       "Heading marker should be dropped when merging into preceding paragraph")
        XCTAssertTrue(serialized.contains("texHello"),
                      "Paragraph should absorb heading suffix text (got: \(serialized))")
    }

    // MARK: - Cross-Block Merge table rows (ARCHITECTURE.md §192)

    func test_merge_headingWithHeading_keepsFirstLevel() throws {
        // heading | heading → First heading with second's suffix appended.
        let p = project("# Alpha\n## Beta\n")
        // Delete the separator between the two headings (the last char of
        // "Alpha" doesn't matter — merge with endOffset=0 on second heading).
        let firstSpan = p.blockSpans[0]
        let r = try EditingOps.delete(range: NSRange(location: firstSpan.length, length: 1), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.hasPrefix("# AlphaBeta"),
                      "First heading's level should win with second's text appended (got: \(serialized))")
    }

    func test_merge_listWithParagraph_appendsToLastLeaf() throws {
        // list | paragraph → Paragraph inlines appended to last list item.
        let p = project("- alpha\n- beta\n\ntail\n")
        // Doc: [list([alpha, beta]), blankLine, para("tail")].
        // Find the blankLine and delete it to force list + paragraph merge.
        let blankIdx = p.document.blocks.firstIndex { if case .blankLine = $0 { return true }; return false }!
        let blankSpan = p.blockSpans[blankIdx]
        // Delete from end of blankLine back through the separator.
        let sepLoc = blankSpan.location + blankSpan.length
        let r = try EditingOps.delete(range: NSRange(location: sepLoc - 1, length: 2), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("- betatail"),
                      "Paragraph text should be appended to last list item (got: \(serialized))")
        XCTAssertFalse(serialized.contains("\ntail\n"),
                       "Standalone paragraph should be gone after merge into list")
    }

    func test_merge_paragraphWithList_firstItemOnly() throws {
        // paragraph | list → Paragraph (list's first item inlines appended).
        // Remaining list items survive as a reduced list.
        let doc = Document(blocks: [
            .paragraph(inline: [.text("head")]),
            .list(items: [
                ListItem(indent: "", marker: "-", afterMarker: " ", inline: [.text("one")], children: []),
                ListItem(indent: "", marker: "-", afterMarker: " ", inline: [.text("two")], children: [])
            ])
        ], trailingNewline: true)
        let p = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        // Spans: [0,4) head, [5,...) list (first item glyph + "one", sep, glyph + "two").
        // Delete the "\n" separator between paragraph and list.
        let r = try EditingOps.delete(range: NSRange(location: 4, length: 1), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.hasPrefix("headone"),
                      "Paragraph should absorb list's first item inlines (got: \(serialized))")
        XCTAssertTrue(serialized.contains("- two"),
                      "Second list item should survive as a continuing list (got: \(serialized))")
    }

    func test_merge_anyWithBlockquote_firstLineOnly() throws {
        // any | blockquote → first line's inlines appended; remaining
        // lines survive as a trailing blockquote block.
        let p = project("head\n\n> line one\n> line two\n> line three\n")
        // Doc: [para("head"), blankLine, blockquote(3 lines)].
        // Delete forward across blankLine into blockquote start.
        let blankIdx = p.document.blocks.firstIndex { if case .blankLine = $0 { return true }; return false }!
        let blankSpan = p.blockSpans[blankIdx]
        // Swallow the separator after blankLine so paragraph merges with blockquote.
        let sepLoc = blankSpan.location + blankSpan.length
        let r = try EditingOps.delete(range: NSRange(location: sepLoc - 1, length: 2), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("headline one"),
                      "First blockquote line should merge into paragraph (got: \(serialized))")
        XCTAssertTrue(serialized.contains("> line two"),
                      "Second blockquote line should survive (got: \(serialized))")
        XCTAssertTrue(serialized.contains("> line three"),
                      "Third blockquote line should survive (got: \(serialized))")
    }

    func test_merge_anyWithHorizontalRule_dropsHR() throws {
        // any | horizontalRule → HR removed, block A preserved (type kept).
        let p = project("# Title\n\n---\n")
        // Doc: [heading, blankLine, HR].
        // First delete the blankLine separator so heading is adjacent to HR.
        // Then delete the separator between heading and HR to trigger merge.
        let blankIdx = p.document.blocks.firstIndex { if case .blankLine = $0 { return true }; return false }!
        let blankSpan = p.blockSpans[blankIdx]
        let sepBefore = blankSpan.location - 1   // newline after heading
        // Delete from end of heading through entire blankLine span + following newline.
        let r = try EditingOps.delete(
            range: NSRange(location: sepBefore, length: blankSpan.length + 2),
            in: p
        )
        // Heading survives; HR should be gone from the doc.
        let hasHR = r.newProjection.document.blocks.contains {
            if case .horizontalRule = $0 { return true }; return false
        }
        XCTAssertFalse(hasHR, "HR should be removed after merge")
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("# Title"),
                      "Heading should be preserved across merge with HR (got: \(serialized))")
    }

    func test_multiBlockDelete_acrossBlanksIntoFirstListItem_preservesRemainingItems() throws {
        // Regression: selecting [blank1, blank2, firstListItem] and
        // deleting previously nuked the ENTIRE list because
        // `deleteInBlock(list, from:0, to:endOffset)` threw on any
        // boundary-spanning offset and `try?` degraded the whole list
        // to nil ("block B fully consumed"). Verify remaining items
        // survive as a continuing list.
        let p = project("before\n\n\n- one\n- two\n- three\n")
        // Doc: [paragraph("before"), blankLine, blankLine, list(3 items)]
        let listIdx = p.document.blocks.firstIndex {
            if case .list = $0 { return true }; return false
        }!
        let listSpan = p.blockSpans[listIdx]
        // Rendered list: "\u{...}one\n\u{...}two\n\u{...}three" — first
        // item ends at listSpan.location + 1 (bullet) + 3 ("one") = +4.
        // Select from start of first blankLine to end of first list item.
        let firstBlankIdx = p.document.blocks.firstIndex {
            if case .blankLine = $0 { return true }; return false
        }!
        let selectionStart = p.blockSpans[firstBlankIdx].location
        let selectionEnd = listSpan.location + 1 + "one".count
        let r = try EditingOps.delete(
            range: NSRange(location: selectionStart, length: selectionEnd - selectionStart),
            in: p
        )
        // The remaining list should still contain "two" and "three".
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("- two"),
                      "Second list item must survive (got: \(serialized))")
        XCTAssertTrue(serialized.contains("- three"),
                      "Third list item must survive (got: \(serialized))")
        // And the surviving document should still have a list block.
        let hasList = r.newProjection.document.blocks.contains {
            if case .list = $0 { return true }; return false
        }
        XCTAssertTrue(hasList, "List block must persist after partial deletion")
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
        // Paste "hello\n" at offset 2 of "abcd" → "abhellocd".
        // CommonMark parses "hello\n" as a single paragraph with its
        // trailing newline consumed. After the bug 39 paste rewrite,
        // pasteIntoParagraph routes through the real parser instead of
        // splitting on every raw `\n`, so the paragraph is spliced in
        // as a single block with no soft-break at the trailing position.
        let p = project("abcd\n")
        let r = try EditingOps.insert("hello\n", at: 2, in: p)
        XCTAssertEqual(r.newProjection.attributed.string, "abhellocd\n")
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

    func test_paste_multilineIntoHeading_convertsToParagraph() throws {
        // Multi-line paste into headings now converts the heading to paragraphs
        let p = project("# Title\n")
        let r = try EditingOps.insert("a\nb", at: 2, in: p)
        // Heading should be converted to paragraph(s) - verify it doesn't throw
        // and produces valid output with the pasted content
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("a") && serialized.contains("b"),
            "Pasted content should appear in output: \(serialized)")
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

    // MARK: - Multi-item list deletion (Bug fix: WYSIWYG delete sync issue)

    func test_delete_across_two_list_items() throws {
        // Selecting from middle of first item to middle of second item
        let md = "- one\n- two\n- three\n"
        let p = project(md)
        // Entry 0: one (inline starts at offset 1, length 3)
        // Entry 1: two (inline starts at offset 5, length 3)
        // Select from offset 2 (middle of "one") to offset 6 (middle of "two")
        // This should delete "ne\n- t" leaving "- owo\n- three\n"
        let startOffset = 2 // "o" in "one"
        let endOffset = 6   // "w" in "two"
        let r = try EditingOps.delete(range: NSRange(location: startOffset, length: endOffset - startOffset), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        // The surviving text from first item is "o", from second is "wo"
        // These should be merged: "owo"
        XCTAssertEqual(serialized, "- owo\n- three\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_multiple_complete_list_items() throws {
        // Selecting entire middle item
        let md = "- one\n- two\n- three\n"
        let p = project(md)
        // Entry 1 ("two") starts at offset 5, inline at 6, length 3, ends at 8
        // Delete the entire second item by selecting from offset 5 to 9
        // (includes the "\n" separator)
        let r = try EditingOps.delete(range: NSRange(location: 5, length: 4), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- one\n- three\n")
        assertSpliceInvariant(old: p, result: r)
    }

    func test_delete_first_two_list_items() throws {
        // Delete from start of first item through end of second
        let md = "- one\n- two\n- three\n"
        let p = project(md)
        // First item inline starts at 1, ends at 4
        // Second item ends at 8
        // Select from 0 (before first bullet) to 9 (after "\n" following "two")
        let r = try EditingOps.delete(range: NSRange(location: 0, length: 9), in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertEqual(serialized, "- three\n")
        assertSpliceInvariant(old: p, result: r)
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

    func test_insert_horizontalRule_createsParagraphSibling() throws {
        let p = project("---\n")
        // HR is atomic; inserting creates a paragraph sibling around it rather
        // than throwing. Content preservation + new text presence is the contract.
        let r = try EditingOps.insert("X", at: 0, in: p)
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        XCTAssertTrue(serialized.contains("X"), "inserted text must appear (got: \(serialized))")
        XCTAssertTrue(serialized.contains("---"), "HR must be preserved (got: \(serialized))")
    }

    func test_delete_horizontalRule_fullSpan_removesBlock() throws {
        let p = project("---\n")
        // HR is an atomic attachment block: selecting its full span
        // and pressing delete REMOVES the block (replacing it with
        // an empty paragraph), same as selecting a table. Previously
        // this was a silent no-op — `deleteInBlock(.horizontalRule)`
        // returned the block unchanged — which is the same bug that
        // made `select-table + delete` do nothing. See
        // `TableCellEditingRefactorTests.test_delete_selectedTable_removesTheBlock`.
        let r = try EditingOps.delete(range: NSRange(location: 0, length: 1), in: p)
        let hasHR = r.newProjection.document.blocks.contains { block in
            if case .horizontalRule = block { return true } else { return false }
        }
        XCTAssertFalse(hasHR, "HR should be removed after full-span delete")
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

    // MARK: - Bug fixes for list editing

    /// Bug #21: Return on an empty middle list item must split the list
    /// into [items before] + empty paragraph + [items after] and put the
    /// cursor on the new paragraph. The earlier behavior collapsed the
    /// list and jumped the cursor to the end of the previous item, which
    /// is surprising and inconsistent with the non-empty Return path.
    func test_bug21_returnOnEmptyMiddleItem_producesEmptyParagraph() throws {
        let p = project("- one\n- two\n- three\n- four\n- five\n")
        let inl1 = listInlineStart(in: p, itemIndex: 1) // "two"

        // Press Return at end of "two" (3 chars) → creates empty item at index 2
        let r1 = try EditingOps.insert("\n", at: inl1 + 3, in: p)
        let serialized1 = MarkdownSerializer.serialize(r1.newProjection.document)
        XCTAssertEqual(serialized1, "- one\n- two\n- \n- three\n- four\n- five\n")

        let newEmptyInl = listInlineStart(in: r1.newProjection, itemIndex: 2)
        XCTAssertEqual(r1.newCursorPosition, newEmptyInl)

        // Press Return on the empty item — Bug #21 contract: produce an
        // empty paragraph in place, cursor on the paragraph, list split.
        let r2 = try EditingOps.returnOnEmptyListItem(at: r1.newCursorPosition, in: r1.newProjection)
        let serialized2 = MarkdownSerializer.serialize(r2.newProjection.document)

        // Expect: list("one","two") + paragraph(empty) + list("three","four","five").
        // The empty paragraph contributes no characters; MarkdownSerializer
        // emits a single blank-line separator between the two lists.
        XCTAssertEqual(serialized2, "- one\n- two\n\n- three\n- four\n- five\n")

        // Document structure: 3 blocks (list + paragraph + list).
        XCTAssertEqual(r2.newProjection.document.blocks.count, 3,
                       "expected [list, paragraph, list]; got \(r2.newProjection.document.blocks)")
        guard case .paragraph(let inlines) = r2.newProjection.document.blocks[1] else {
            XCTFail("middle block must be a paragraph; got \(r2.newProjection.document.blocks[1])")
            return
        }
        XCTAssertTrue(inlines.isEmpty, "middle paragraph must be empty (the dropped marker)")

        // Cursor sits at the start of the new empty paragraph.
        let paraSpan = r2.newProjection.blockSpans[1]
        XCTAssertEqual(r2.newCursorPosition, paraSpan.location,
            "Cursor must land on the new empty paragraph, not jump back to the previous item")
    }

    /// Bug: When creating a new todo item with Return, the new item should
    /// always have an unchecked checkbox, regardless of the next item's state.
    func test_returnInTodoItem_newItemIsAlwaysUnchecked() throws {
        // Start with: unchecked item, checked item (simulating item 2 and 3)
        let md = "- [ ] first\n- [x] second\n"
        let p = project(md)
        
        let inl0 = listInlineStart(in: p, itemIndex: 0) // "first"
        
        // Press Return at end of "first" (5 chars)
        let r = try EditingOps.insert("\n", at: inl0 + 5, in: p)
        
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        // Should have: first, empty unchecked item, second (still checked)
        XCTAssertEqual(serialized, "- [ ] first\n- [ ] \n- [x] second\n")
        
        // Verify the new item (index 1) has an unchecked checkbox
        if case .list(let items, _) = r.newProjection.document.blocks[0] {
            XCTAssertEqual(items.count, 3)
            // New middle item should have unchecked checkbox
            XCTAssertNotNil(items[1].checkbox)
            XCTAssertFalse(items[1].checkbox!.isChecked,
                "New todo item should have unchecked checkbox")
            // Last item should still be checked
            XCTAssertTrue(items[2].checkbox!.isChecked,
                "Original checked item should remain checked")
        } else {
            XCTFail("Expected list block")
        }
        
        // DEBUG: Check splice replacement for attachment characters
        let spliceStr = r.spliceReplacement.string
        let attachmentChar = "\u{FFFC}"
        let attachmentCount = spliceStr.components(separatedBy: attachmentChar).count - 1
        print("DEBUG: Splice string: '\(spliceStr)'")
        print("DEBUG: Splice range: \(r.spliceRange)")
        print("DEBUG: Attachment characters in splice: \(attachmentCount)")
        
        // The splice should contain exactly 1 checkbox attachment (the new unchecked one)
        // plus the newline separator
        XCTAssertGreaterThanOrEqual(attachmentCount, 1, "Splice should contain at least 1 checkbox attachment")
    }

    // MARK: - Bug #38: list exit-to-body must preserve slot UUID

    /// Bug #38: Pressing Return on an empty top-level list item triggers
    /// the FSM transition `(.listItem(_, _), .returnOnEmpty) → .exitToBody`,
    /// which converts the list block in-place into a paragraph. The
    /// resulting paragraph occupies the SAME positional slot as the
    /// original list block, so the slot's `Block.id` (in
    /// `Document.blockIds`) must be preserved. Re-minting the UUID would
    /// split what should be one undo entry under `UndoJournal` and break
    /// future identity-stable diffing.
    private func runBug38_exitToBody_preservesSlotIdentity(seed: String) throws {
        let p = project(seed)
        // Block index 2 is the list (after "first" + blankLine separator).
        XCTAssertEqual(p.document.blocks.count, 5, "seed must parse to 5 blocks")
        guard case .list = p.document.blocks[2] else {
            XCTFail("seed block 2 must be a list; got \(p.document.blocks[2])")
            return
        }
        let originalListId = p.document.blockIds[2]

        // Cursor at home of the empty list item (one prefix char into the block).
        let cursor = p.blockSpans[2].location + 1
        let r = try EditingOps.returnOnEmptyListItem(at: cursor, in: p)

        // Block at index 2 in the post-edit doc must be a paragraph and
        // must carry the original list block's slot id.
        XCTAssertGreaterThan(r.newProjection.document.blocks.count, 2)
        guard case .paragraph = r.newProjection.document.blocks[2] else {
            XCTFail("post-edit block 2 must be paragraph; got \(r.newProjection.document.blocks[2])")
            return
        }
        XCTAssertEqual(
            r.newProjection.document.blockIds[2], originalListId,
            "Slot identity at index 2 not preserved by exit-to-body: " +
            "before=\(originalListId) after=\(r.newProjection.document.blockIds[2])"
        )
    }

    func test_bug38_returnOnEmptyListItem_preservesSlotIdentity_bullet() throws {
        try runBug38_exitToBody_preservesSlotIdentity(seed: "first\n\n- \n\nafter\n")
    }

    func test_bug38_returnOnEmptyListItem_preservesSlotIdentity_numbered() throws {
        try runBug38_exitToBody_preservesSlotIdentity(seed: "first\n\n1. \n\nafter\n")
    }

    func test_bug38_returnOnEmptyListItem_preservesSlotIdentity_todo() throws {
        try runBug38_exitToBody_preservesSlotIdentity(seed: "first\n\n- [ ] \n\nafter\n")
    }

    /// Bug #38 — combinatorial harness reproducer. The harness's
    /// `onEmptyBlock + intraBlock` tuple selects 1 char starting at the
    /// home offset of the empty bullet. For an empty bullet with span
    /// `(loc, 1)` (the bullet attachment only), `homeOffset = loc + 1`
    /// equals `blockEnd`, so `min(homeOffset, blockEnd-1)` clamps the
    /// selection start to `loc` — covering the bullet attachment, not
    /// the inline content. `pressReturn` then routes through
    /// `handleEditViaBlockModel`'s replace branch (range.length=1 +
    /// replacement="\n"), which falls back to delete+insert. Without
    /// the fix the delete leaves `.list(items: [])` and the insert
    /// throws, sending the editor through `clearBlockModelAndRefill`
    /// and re-minting every slot UUID.
    private func runBug38_intraBlockReturn_preservesSlotIdentity(seed: String) throws {
        let p = project(seed)
        let originalListId = p.document.blockIds[2]
        let homeOffset = p.blockSpans[2].location + 1

        // Step 1: delete the bullet attachment (selection start clamps
        // to span.location; length 1 = the attachment).
        let deleteRange = NSRange(location: p.blockSpans[2].location, length: 1)
        let r1 = try EditingOps.delete(range: deleteRange, in: p)

        // After the fix: the only-item list collapses to an empty
        // paragraph, NOT an empty list. The slot id at index 2
        // survives the kind change.
        XCTAssertEqual(r1.newProjection.document.blockIds[2], originalListId)
        guard case .paragraph = r1.newProjection.document.blocks[2] else {
            XCTFail("post-delete block 2 must be paragraph; got \(r1.newProjection.document.blocks[2])")
            return
        }

        // Step 2: insert "\n" at the same offset on the post-delete
        // projection. This used to throw on `.list(items: [])`; with
        // the fix the target is `.paragraph(inline: [])`, which
        // splits cleanly.
        let r2 = try EditingOps.insert("\n", at: homeOffset - 1, in: r1.newProjection)
        XCTAssertEqual(r2.newProjection.document.blockIds[2], originalListId,
                       "End-to-end slot identity at index 2 must survive delete + insert")
    }

    func test_bug38_intraBlockReturn_emptyBullet() throws {
        try runBug38_intraBlockReturn_preservesSlotIdentity(seed: "first\n\n- \n\nafter\n")
    }

    func test_bug38_intraBlockReturn_emptyNumbered() throws {
        try runBug38_intraBlockReturn_preservesSlotIdentity(seed: "first\n\n1. \n\nafter\n")
    }

    func test_bug38_intraBlockReturn_emptyTodo() throws {
        try runBug38_intraBlockReturn_preservesSlotIdentity(seed: "first\n\n- [ ] \n\nafter\n")
    }

    // MARK: - Bug: Heading conversion affects all paragraphs

    func test_changeHeadingLevel_onlyAffectsSelectedBlock() throws {
        // Three paragraphs - clicking in the middle one and applying H2
        // should only convert the middle one, not all three
        let md = "First paragraph\n\nSecond paragraph\n\nThird paragraph"
        let p = project(md)
        
        // Find the offset of "Second paragraph" - should be around the middle
        // "First paragraph\n\n" = 17 chars, so Second starts at 17
        let secondParaOffset = 17
        
        // Apply H2 at that offset
        let r = try EditingOps.changeHeadingLevel(2, at: secondParaOffset, in: p)
        
        // Serialize and verify only the second paragraph became a heading
        let serialized = MarkdownSerializer.serialize(r.newProjection.document)
        print("DEBUG: Serialized result:\n\(serialized)")
        
        // Expected: First and Third stay as paragraphs, Second becomes H2
        let expected = "First paragraph\n\n## Second paragraph\n\nThird paragraph"
        XCTAssertEqual(serialized, expected)
        
        // Also verify the block structure
        XCTAssertEqual(r.newProjection.document.blocks.count, 5) // para, blank, heading, blank, para
        
        // Check each block type
        if case .paragraph = r.newProjection.document.blocks[0] {
            // OK
        } else {
            XCTFail("First block should be paragraph")
        }
        
        if case .heading(let level, _) = r.newProjection.document.blocks[2] {
            XCTAssertEqual(level, 2, "Third block should be H2")
        } else {
            XCTFail("Third block should be heading")
        }
        
        if case .paragraph = r.newProjection.document.blocks[4] {
            // OK
        } else {
            XCTFail("Fifth block should be paragraph")
        }
    }
}
