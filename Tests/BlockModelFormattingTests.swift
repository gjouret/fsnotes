//
//  BlockModelFormattingTests.swift
//  FSNotesTests
//
//  Tests for block-model formatting operations: heading level change,
//  inline trait toggle (bold/italic/code), list/blockquote conversion,
//  and horizontal rule insertion.
//

import XCTest
@testable import FSNotes

class BlockModelFormattingTests: XCTestCase {

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

    /// Assert the splice invariant: applying the splice to the old
    /// attributed string produces the same result as the new projection.
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
            "Splice invariant violated",
            file: file, line: line
        )
    }

    /// Round-trip: serialize the result document and verify it matches expected markdown.
    private func assertRoundTrip(
        _ result: EditResult,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, expected, "Round-trip mismatch", file: file, line: line)
    }

    // MARK: - Heading level change

    func test_changeHeadingLevel_paragraphToH1() throws {
        let proj = project("Hello world\n")
        let result = try EditingOps.changeHeadingLevel(1, at: 0, in: proj)
        assertRoundTrip(result, expected: "# Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_changeHeadingLevel_paragraphToH2() throws {
        let proj = project("Hello world\n")
        let result = try EditingOps.changeHeadingLevel(2, at: 0, in: proj)
        assertRoundTrip(result, expected: "## Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_changeHeadingLevel_h1ToH3() throws {
        let proj = project("# Title\n")
        let result = try EditingOps.changeHeadingLevel(3, at: 0, in: proj)
        assertRoundTrip(result, expected: "### Title\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_changeHeadingLevel_toggleOff() throws {
        let proj = project("## Title\n")
        // Same level as current → toggle off to paragraph.
        let result = try EditingOps.changeHeadingLevel(2, at: 0, in: proj)
        assertRoundTrip(result, expected: "Title\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_changeHeadingLevel_level0ToParagraph() throws {
        let proj = project("# Title\n")
        let result = try EditingOps.changeHeadingLevel(0, at: 0, in: proj)
        assertRoundTrip(result, expected: "Title\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_changeHeadingLevel_paragraphLevel0NoOp() throws {
        let proj = project("Hello\n")
        let result = try EditingOps.changeHeadingLevel(0, at: 0, in: proj)
        // Should be a no-op — already a paragraph.
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, "Hello\n")
    }

    // MARK: - Inline trait toggle: bold

    func test_toggleBold_wrapSelection() throws {
        let proj = project("Hello world\n")
        // Select "world" (offset 6, length 5).
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello **world**\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleBold_unwrapSelection() throws {
        let proj = project("Hello **world**\n")
        // In the rendered output "Hello world", "world" is at offset 6 length 5.
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleBold_partialUnwrap_middleWord() throws {
        // "**these three words**" → select "three" → unbold
        // Expected: "**these **three** words**"
        // i.e., "these " stays bold, "three" becomes plain, " words" stays bold
        let proj = project("**these three words**\n")
        // Rendered: "these three words" (17 chars). "three" is at offset 6, length 5.
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "**these **three** words**\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleBold_partialUnwrap_firstWord() throws {
        // "**these three words**" → select "these" → unbold
        let proj = project("**these three words**\n")
        // "these" is at offset 0, length 5.
        let sel = NSRange(location: 0, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "these** three words**\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleBold_partialUnwrap_lastWord() throws {
        // "**these three words**" → select "words" → unbold
        let proj = project("**these three words**\n")
        // "words" is at offset 12, length 5.
        let sel = NSRange(location: 12, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "**these three **words\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleBold_zeroLengthNoOp() throws {
        let proj = project("Hello\n")
        let sel = NSRange(location: 3, length: 0)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        // No-op: can't wrap nothing.
        XCTAssertEqual(
            MarkdownSerializer.serialize(result.newProjection.document),
            "Hello\n"
        )
    }

    // MARK: - Inline trait toggle: italic

    func test_toggleItalic_wrapSelection() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.italic, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello *world*\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleItalic_unwrapSelection() throws {
        let proj = project("Hello *world*\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.italic, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    // MARK: - Inline trait toggle: code

    func test_toggleCode_wrapSelection() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.code, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello `world`\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleCode_unwrapSelection() throws {
        let proj = project("Hello `world`\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.code, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    // MARK: - Toggle list

    func test_toggleList_paragraphToList() throws {
        let proj = project("Hello world\n")
        let result = try EditingOps.toggleList(marker: "-", at: 0, in: proj)
        assertRoundTrip(result, expected: "- Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleList_listToParagraph() throws {
        let proj = project("- Hello world\n")
        // "• Hello world" — cursor at offset 2 (inside inline content).
        let span = proj.blockSpans[0]
        let result = try EditingOps.toggleList(at: span.location + 2, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleList_orderedList() throws {
        let proj = project("Hello world\n")
        let result = try EditingOps.toggleList(marker: "1.", at: 0, in: proj)
        assertRoundTrip(result, expected: "1. Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    // MARK: - Inline trait toggle: strikethrough

    func test_toggleStrikethrough_wrapSelection() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.strikethrough, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello ~~world~~\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleStrikethrough_unwrapSelection() throws {
        let proj = project("Hello ~~world~~\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.strikethrough, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    // MARK: - Strikethrough round-trip

    func test_strikethrough_parseSerializeRoundTrip() {
        let md = "Hello ~~world~~\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md)
    }

    // MARK: - Toggle blockquote

    func test_toggleBlockquote_paragraphToQuote() throws {
        let proj = project("Hello world\n")
        let result = try EditingOps.toggleBlockquote(at: 0, in: proj)
        assertRoundTrip(result, expected: "> Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleBlockquote_quoteToParagraph() throws {
        let proj = project("> Hello world\n")
        // Rendered: "  Hello world" (2 spaces indent per level).
        let span = proj.blockSpans[0]
        let result = try EditingOps.toggleBlockquote(at: span.location + 2, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    // MARK: - Insert horizontal rule

    func test_insertHorizontalRule() throws {
        let proj = project("Hello\n")
        let result = try EditingOps.insertHorizontalRule(at: 0, in: proj)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        // Should have the HR after the paragraph.
        XCTAssertTrue(serialized.contains("---"), "Expected HR in serialized output: \(serialized)")
        // The document should have 2 blocks: paragraph + HR.
        XCTAssertEqual(result.newProjection.document.blocks.count, 2)
    }

    // MARK: - Unsupported block types

    func test_changeHeadingLevel_codeBlockThrows() {
        let proj = project("```\ncode\n```\n")
        XCTAssertThrowsError(
            try EditingOps.changeHeadingLevel(1, at: 0, in: proj)
        )
    }

    func test_toggleList_codeBlockThrows() {
        let proj = project("```\ncode\n```\n")
        XCTAssertThrowsError(
            try EditingOps.toggleList(at: 0, in: proj)
        )
    }

    func test_toggleBlockquote_codeBlockThrows() {
        let proj = project("```\ncode\n```\n")
        XCTAssertThrowsError(
            try EditingOps.toggleBlockquote(at: 0, in: proj)
        )
    }

    // MARK: - Bold in list items

    func test_toggleBold_inListItem() throws {
        let proj = project("- Hello world\n")
        // "Hello" starts after the attachment prefix. Derive offset
        // from flattenList so it adapts to rendering format changes.
        guard case .list(let items, _) = proj.document.blocks[0] else {
            XCTFail("expected list"); return
        }
        let entries = EditingOps.flattenListPublic(items)
        let inlineStart = proj.blockSpans[0].location + entries[0].startOffset + entries[0].prefixLength
        let sel = NSRange(location: inlineStart, length: 5) // "Hello"
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "- **Hello** world\n")
    }

    // MARK: - Bold in blockquote

    func test_toggleBold_inBlockquote() throws {
        let proj = project("> Hello world\n")
        // Rendered: "Hello world" (indentation via paragraph style, no space chars).
        // "Hello" starts at offset 0, length 5.
        let span = proj.blockSpans[0]
        let sel = NSRange(location: span.location, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "> **Hello** world\n")
    }

    // MARK: - Todo checkbox: parse/serialize round-trip

    func test_todoUnchecked_roundTrip() {
        let md = "- [ ] Buy milk\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "Unchecked todo should round-trip")
    }

    func test_todoChecked_roundTrip() {
        let md = "- [x] Done task\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "Checked todo should round-trip")
    }

    func test_todoCheckedUppercase_roundTrip() {
        let md = "- [X] Done task\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "Uppercase [X] should round-trip")
    }

    func test_todoNested_roundTrip() {
        let md = "- [ ] Parent\n  - [x] Child done\n  - [ ] Child todo\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "Nested todos should round-trip")
    }

    func test_todoMixed_roundTrip() {
        let md = "- Regular item\n- [ ] Todo item\n- [x] Done item\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "Mixed regular + todo items should round-trip")
    }

    func test_todoStarMarker_roundTrip() {
        let md = "* [ ] Star todo\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "Star marker todo should round-trip")
    }

    func test_todoPlusMarker_roundTrip() {
        let md = "+ [ ] Plus todo\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "Plus marker todo should round-trip")
    }

    // MARK: - Todo checkbox: parser model

    func test_todoParser_setsCheckbox() {
        let doc = MarkdownParser.parse("- [ ] Task\n")
        guard case .list(let items, _) = doc.blocks.first else {
            XCTFail("Expected list block"); return
        }
        XCTAssertNotNil(items.first?.checkbox, "Todo should have checkbox")
        XCTAssertEqual(items.first?.checkbox?.text, "[ ]")
        XCTAssertFalse(items.first?.isChecked ?? true)
    }

    func test_todoParser_checkedCheckbox() {
        let doc = MarkdownParser.parse("- [x] Done\n")
        guard case .list(let items, _) = doc.blocks.first else {
            XCTFail("Expected list block"); return
        }
        XCTAssertNotNil(items.first?.checkbox)
        XCTAssertTrue(items.first?.isChecked ?? false)
    }

    func test_todoParser_regularItemNoCheckbox() {
        let doc = MarkdownParser.parse("- Regular\n")
        guard case .list(let items, _) = doc.blocks.first else {
            XCTFail("Expected list block"); return
        }
        XCTAssertNil(items.first?.checkbox, "Regular item should not have checkbox")
    }

    // MARK: - Todo rendering

    func test_todoUnchecked_rendering() {
        let proj = project("- [ ] Task\n")
        // Rendered should contain attachment character (checkbox is an NSTextAttachment)
        let text = proj.attributed.string
        XCTAssertTrue(text.contains("\u{FFFC}"), "Unchecked todo should render as attachment, got: \(text)")
        XCTAssertFalse(text.contains("[ ]"), "Rendered text should not contain raw checkbox syntax")
    }

    func test_todoChecked_rendering() {
        let proj = project("- [x] Done\n")
        // Rendered should contain attachment character (checkbox is an NSTextAttachment)
        let text = proj.attributed.string
        XCTAssertTrue(text.contains("\u{FFFC}"), "Checked todo should render as attachment, got: \(text)")
        XCTAssertFalse(text.contains("[x]"), "Rendered text should not contain raw checkbox syntax")
    }

    func test_todoChecked_strikethrough() {
        let proj = project("- [x] Done\n")
        // The inline content "Done" should have strikethrough
        let text = proj.attributed.string
        if let range = text.range(of: "Done") {
            let nsRange = NSRange(range, in: text)
            let strike = proj.attributed.attribute(
                .strikethroughStyle, at: nsRange.location, effectiveRange: nil
            ) as? Int
            XCTAssertNotNil(strike, "Checked todo content should have strikethrough")
        } else {
            XCTFail("Could not find 'Done' in rendered text")
        }
    }

    // MARK: - Todo toggle operations

    func test_toggleTodoCheckbox_uncheckedToChecked() throws {
        let proj = project("- [ ] Task\n")
        let result = try EditingOps.toggleTodoCheckbox(at: 0, in: proj)
        assertRoundTrip(result, expected: "- [x] Task\n")
    }

    func test_toggleTodoCheckbox_checkedToUnchecked() throws {
        let proj = project("- [x] Done\n")
        let result = try EditingOps.toggleTodoCheckbox(at: 0, in: proj)
        assertRoundTrip(result, expected: "- [ ] Done\n")
    }

    func test_toggleTodoList_paragraphToTodo() throws {
        let proj = project("Hello world\n")
        let result = try EditingOps.toggleTodoList(at: 0, in: proj)
        assertRoundTrip(result, expected: "- [ ] Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleTodoList_todoToRegularList() throws {
        let proj = project("- [ ] Task\n")
        let result = try EditingOps.toggleTodoList(at: 0, in: proj)
        assertRoundTrip(result, expected: "- Task\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_toggleTodoList_regularListToTodo() throws {
        let proj = project("- Hello\n")
        let result = try EditingOps.toggleTodoList(at: 0, in: proj)
        assertRoundTrip(result, expected: "- [ ] Hello\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    // MARK: - syncBlocksFromProjection Tests

    func test_syncBlocks_populatesHeadings() {
        let md = "# Heading 1\n\nParagraph\n\n## Heading 2\n\nMore text\n"
        let proj = project(md)
        let processor = TextStorageProcessor()
        processor.syncBlocksFromProjection(proj)

        // Should have blocks for each Document block
        XCTAssertEqual(processor.blocks.count, proj.document.blocks.count)

        // First block should be heading level 1
        if case .heading(let level) = processor.blocks[0].type {
            XCTAssertEqual(level, 1)
        } else {
            XCTFail("Expected heading(1), got \(processor.blocks[0].type)")
        }

        // Find heading level 2
        let h2 = processor.blocks.first { block in
            if case .heading(let l) = block.type { return l == 2 }
            return false
        }
        XCTAssertNotNil(h2, "Should find a heading level 2 block")
    }

    func test_syncBlocks_populatesListBlocks() {
        let md = "- item one\n- item two\n"
        let proj = project(md)
        let processor = TextStorageProcessor()
        processor.syncBlocksFromProjection(proj)

        let listBlock = processor.blocks.first { block in
            if case .unorderedList = block.type { return true }
            return false
        }
        XCTAssertNotNil(listBlock, "Should find an unordered list block")
    }

    func test_syncBlocks_preservesCollapsedState() {
        let md = "# Heading\n\nBody\n"
        let proj = project(md)
        let processor = TextStorageProcessor()

        // First sync: set collapsed on first block
        processor.syncBlocksFromProjection(proj)
        processor.blocks[0].collapsed = true

        // Re-sync: collapsed should be preserved
        processor.syncBlocksFromProjection(proj)
        XCTAssertTrue(processor.blocks[0].collapsed,
                      "Collapsed state should survive re-sync")
    }

    func test_syncBlocks_rangesMatchBlockSpans() {
        let md = "# Title\n\nParagraph text\n\n## Sub\n"
        let proj = project(md)
        let processor = TextStorageProcessor()
        processor.syncBlocksFromProjection(proj)

        // Each block's range should match the corresponding blockSpan
        for (i, block) in processor.blocks.enumerated() {
            XCTAssertEqual(block.range, proj.blockSpans[i],
                           "Block \(i) range should match blockSpan")
        }
    }

    func test_syncBlocks_headerBlockIndex_works() {
        let md = "# H1\n\nPara\n\n## H2\n\nMore\n"
        let proj = project(md)
        let processor = TextStorageProcessor()
        processor.syncBlocksFromProjection(proj)

        // The first block is a heading — headerBlockIndex at its
        // range location should return index 0
        let h1Loc = processor.blocks[0].range.location
        let idx = processor.headerBlockIndex(at: h1Loc)
        XCTAssertEqual(idx, 0, "Should find header block at index 0")
    }

    func test_syncBlocks_todoDetection() {
        let md = "- [ ] task one\n- [x] done\n"
        let proj = project(md)
        let processor = TextStorageProcessor()
        processor.syncBlocksFromProjection(proj)

        let todoBlock = processor.blocks.first { block in
            if case .todoItem = block.type { return true }
            return false
        }
        XCTAssertNotNil(todoBlock, "Should find a todo block")
    }

    // MARK: - Rendered attributes for all formatting types

    /// Helper: extract NSFont traits from rendered attributed string at a given offset.
    private func fontTraits(in proj: DocumentProjection, at offset: Int) -> NSFontDescriptor.SymbolicTraits {
        let attrs = proj.attributed.attributes(at: offset, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return [] }
        return font.fontDescriptor.symbolicTraits
    }

    /// Helper: check if rendered text has underline at a given offset.
    private func hasUnderline(in proj: DocumentProjection, at offset: Int) -> Bool {
        let attrs = proj.attributed.attributes(at: offset, effectiveRange: nil)
        if let style = attrs[.underlineStyle] as? Int {
            return style == NSUnderlineStyle.single.rawValue
        }
        return false
    }

    /// Helper: check if rendered text has strikethrough at a given offset.
    private func hasStrikethrough(in proj: DocumentProjection, at offset: Int) -> Bool {
        let attrs = proj.attributed.attributes(at: offset, effectiveRange: nil)
        if let style = attrs[.strikethroughStyle] as? Int {
            return style == NSUnderlineStyle.single.rawValue
        }
        return false
    }

    /// Helper: check if rendered text has highlight (yellow background) at a given offset.
    private func hasHighlight(in proj: DocumentProjection, at offset: Int) -> Bool {
        let attrs = proj.attributed.attributes(at: offset, effectiveRange: nil)
        guard let color = attrs[.backgroundColor] as? NSColor else { return false }
        // InlineTagRegistry uses yellow with alpha 0.5 for <mark>.
        let r = CGFloat(1.0), g = CGFloat(0.9), b = CGFloat(0.0)
        let converted = color.usingColorSpace(.genericRGB)
        guard let c = converted else { return false }
        return abs(c.redComponent - r) < 0.05 &&
               abs(c.greenComponent - g) < 0.05 &&
               abs(c.blueComponent - b) < 0.05
    }

    // MARK: Bold rendering

    func test_bold_renderedAttributes() throws {
        let proj = project("Hello **world**\n")
        // "Hello world" — "Hello " is plain (0-5), "world" is bold (6-10)
        let plainTraits = fontTraits(in: proj, at: 0)
        let boldTraits = fontTraits(in: proj, at: 6)
        XCTAssertFalse(plainTraits.contains(.bold), "Plain text should not be bold")
        XCTAssertTrue(boldTraits.contains(.bold), "Bold text should have bold trait")
    }

    func test_bold_toggleWrapPreservesRendering() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        let newProj = result.newProjection
        // "world" at offset 6 should now be bold.
        let traits = fontTraits(in: newProj, at: 6)
        XCTAssertTrue(traits.contains(.bold), "Wrapped text should render bold")
        // "Hello " should remain plain.
        let plainTraits = fontTraits(in: newProj, at: 0)
        XCTAssertFalse(plainTraits.contains(.bold), "Surrounding text stays plain")
    }

    func test_bold_toggleUnwrapPreservesRendering() throws {
        let proj = project("Hello **world**\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        let newProj = result.newProjection
        // After unwrap, "world" should not be bold.
        let traits = fontTraits(in: newProj, at: 6)
        XCTAssertFalse(traits.contains(.bold), "Unwrapped text should not be bold")
    }

    // MARK: Italic rendering

    func test_italic_renderedAttributes() throws {
        let proj = project("Hello *world*\n")
        let plainTraits = fontTraits(in: proj, at: 0)
        let italicTraits = fontTraits(in: proj, at: 6)
        XCTAssertFalse(plainTraits.contains(.italic), "Plain text should not be italic")
        XCTAssertTrue(italicTraits.contains(.italic), "Italic text should have italic trait")
    }

    func test_italic_toggleWrapPreservesRendering() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.italic, range: sel, in: proj)
        let traits = fontTraits(in: result.newProjection, at: 6)
        XCTAssertTrue(traits.contains(.italic), "Wrapped text should render italic")
    }

    // MARK: Strikethrough rendering

    func test_strikethrough_renderedAttributes() throws {
        let proj = project("Hello ~~world~~\n")
        XCTAssertFalse(hasStrikethrough(in: proj, at: 0), "Plain text should not have strikethrough")
        XCTAssertTrue(hasStrikethrough(in: proj, at: 6), "Strikethrough text should render with strikethrough")
    }

    func test_strikethrough_toggleWrapPreservesRendering() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.strikethrough, range: sel, in: proj)
        XCTAssertTrue(hasStrikethrough(in: result.newProjection, at: 6), "Wrapped text should render strikethrough")
        XCTAssertFalse(hasStrikethrough(in: result.newProjection, at: 0), "Surrounding text stays plain")
    }

    // MARK: Underline rendering (HTML tag)

    func test_underline_renderedAttributes() throws {
        let proj = project("Hello <u>world</u>\n")
        XCTAssertFalse(hasUnderline(in: proj, at: 0), "Plain text should not have underline")
        XCTAssertTrue(hasUnderline(in: proj, at: 6), "Underlined text should render with underline")
    }

    func test_underline_toggleWrapPreservesRendering() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.underline, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello <u>world</u>\n")
        assertSpliceInvariant(old: proj, result: result)
        XCTAssertTrue(hasUnderline(in: result.newProjection, at: 6), "Wrapped text should render underlined")
    }

    func test_underline_toggleUnwrapPreservesRendering() throws {
        let proj = project("Hello <u>world</u>\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.underline, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
        XCTAssertFalse(hasUnderline(in: result.newProjection, at: 6), "Unwrapped text should not be underlined")
    }

    // MARK: Highlight rendering (HTML tag)

    func test_highlight_renderedAttributes() throws {
        let proj = project("Hello <mark>world</mark>\n")
        XCTAssertFalse(hasHighlight(in: proj, at: 0), "Plain text should not have highlight")
        XCTAssertTrue(hasHighlight(in: proj, at: 6), "Highlighted text should have yellow background")
    }

    func test_highlight_toggleWrapPreservesRendering() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.highlight, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello <mark>world</mark>\n")
        assertSpliceInvariant(old: proj, result: result)
        XCTAssertTrue(hasHighlight(in: result.newProjection, at: 6), "Wrapped text should render highlighted")
    }

    func test_highlight_toggleUnwrapPreservesRendering() throws {
        let proj = project("Hello <mark>world</mark>\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.highlight, range: sel, in: proj)
        assertRoundTrip(result, expected: "Hello world\n")
        assertSpliceInvariant(old: proj, result: result)
        XCTAssertFalse(hasHighlight(in: result.newProjection, at: 6), "Unwrapped text should not be highlighted")
    }

    // MARK: Stacked formatting (bold + italic, bold + underline, etc.)

    func test_boldItalic_stackedRendering() throws {
        let proj = project("Hello ***world***\n")
        let traits = fontTraits(in: proj, at: 6)
        XCTAssertTrue(traits.contains(.bold), "Should be bold")
        XCTAssertTrue(traits.contains(.italic), "Should be italic")
    }

    func test_boldThenItalic_stackedToggle() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        // Apply bold first.
        let afterBold = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        // Apply italic on top. Cursor/selection position preserved.
        let selAfterBold = NSRange(location: afterBold.newCursorPosition, length: afterBold.newSelectionLength)
        let afterBothResult = try EditingOps.toggleInlineTrait(.italic, range: selAfterBold, in: afterBold.newProjection)
        let traits = fontTraits(in: afterBothResult.newProjection, at: afterBothResult.newCursorPosition)
        XCTAssertTrue(traits.contains(.bold), "Should still be bold after adding italic")
        XCTAssertTrue(traits.contains(.italic), "Should also be italic")
    }

    func test_boldPlusUnderline_stackedToggle() throws {
        let proj = project("Hello **world**\n")
        let sel = NSRange(location: 6, length: 5)
        // Apply underline on top of bold.
        let result = try EditingOps.toggleInlineTrait(.underline, range: sel, in: proj)
        let newProj = result.newProjection
        let traits = fontTraits(in: newProj, at: result.newCursorPosition)
        XCTAssertTrue(traits.contains(.bold), "Should still be bold after adding underline")
        XCTAssertTrue(hasUnderline(in: newProj, at: result.newCursorPosition), "Should also be underlined")
    }

    func test_boldPlusHighlight_stackedToggle() throws {
        let proj = project("Hello **world**\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.highlight, range: sel, in: proj)
        let newProj = result.newProjection
        let traits = fontTraits(in: newProj, at: result.newCursorPosition)
        XCTAssertTrue(traits.contains(.bold), "Should still be bold after adding highlight")
        XCTAssertTrue(hasHighlight(in: newProj, at: result.newCursorPosition), "Should also be highlighted")
    }

    // MARK: Replace preserves formatting

    func test_replace_inBoldPreservesBold() throws {
        let proj = project("Hello **world**\n")
        // "world" is at rendered offset 6, length 5.
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.replace(range: sel, with: "x", in: proj)
        assertRoundTrip(result, expected: "Hello **x**\n")
        assertSpliceInvariant(old: proj, result: result)
        // Verify "x" is bold.
        let traits = fontTraits(in: result.newProjection, at: 6)
        XCTAssertTrue(traits.contains(.bold), "Replacement text should preserve bold")
    }

    func test_replace_inItalicPreservesItalic() throws {
        let proj = project("Hello *world*\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.replace(range: sel, with: "x", in: proj)
        assertRoundTrip(result, expected: "Hello *x*\n")
        assertSpliceInvariant(old: proj, result: result)
        let traits = fontTraits(in: result.newProjection, at: 6)
        XCTAssertTrue(traits.contains(.italic), "Replacement text should preserve italic")
    }

    func test_replace_inStrikethroughPreservesStrikethrough() throws {
        let proj = project("Hello ~~world~~\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.replace(range: sel, with: "x", in: proj)
        assertRoundTrip(result, expected: "Hello ~~x~~\n")
        assertSpliceInvariant(old: proj, result: result)
        XCTAssertTrue(hasStrikethrough(in: result.newProjection, at: 6),
                       "Replacement text should preserve strikethrough")
    }

    func test_replace_inPlainStaysPlain() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.replace(range: sel, with: "x", in: proj)
        assertRoundTrip(result, expected: "Hello x\n")
        assertSpliceInvariant(old: proj, result: result)
        let traits = fontTraits(in: result.newProjection, at: 6)
        XCTAssertFalse(traits.contains(.bold), "Plain replacement stays plain")
    }

    // MARK: Selection preservation

    func test_bold_selectionPreserved() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        XCTAssertEqual(result.newSelectionLength, 5, "Selection length should be preserved after bold")
    }

    func test_italic_selectionPreserved() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.italic, range: sel, in: proj)
        XCTAssertEqual(result.newSelectionLength, 5, "Selection length should be preserved after italic")
    }

    func test_underline_selectionPreserved() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.underline, range: sel, in: proj)
        XCTAssertEqual(result.newSelectionLength, 5, "Selection length should be preserved after underline")
    }

    func test_highlight_selectionPreserved() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.highlight, range: sel, in: proj)
        XCTAssertEqual(result.newSelectionLength, 5, "Selection length should be preserved after highlight")
    }

    func test_strikethrough_selectionPreserved() throws {
        let proj = project("Hello world\n")
        let sel = NSRange(location: 6, length: 5)
        let result = try EditingOps.toggleInlineTrait(.strikethrough, range: sel, in: proj)
        XCTAssertEqual(result.newSelectionLength, 5, "Selection length should be preserved after strikethrough")
    }
}
