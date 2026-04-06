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
        // Rendered: "• Hello world"
        // "Hello" starts after "• " (2 chars). Select "Hello" (offset 2, length 5).
        let span = proj.blockSpans[0]
        let sel = NSRange(location: span.location + 2, length: 5)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        assertRoundTrip(result, expected: "- **Hello** world\n")
    }

    // MARK: - Bold in blockquote

    func test_toggleBold_inBlockquote() throws {
        let proj = project("> Hello world\n")
        // Rendered: "  Hello world" (2-space indent).
        // "Hello" starts at offset 2, length 5.
        let span = proj.blockSpans[0]
        let sel = NSRange(location: span.location + 2, length: 5)
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
        guard case .list(let items) = doc.blocks.first else {
            XCTFail("Expected list block"); return
        }
        XCTAssertNotNil(items.first?.checkbox, "Todo should have checkbox")
        XCTAssertEqual(items.first?.checkbox?.text, "[ ]")
        XCTAssertFalse(items.first?.isChecked ?? true)
    }

    func test_todoParser_checkedCheckbox() {
        let doc = MarkdownParser.parse("- [x] Done\n")
        guard case .list(let items) = doc.blocks.first else {
            XCTFail("Expected list block"); return
        }
        XCTAssertNotNil(items.first?.checkbox)
        XCTAssertTrue(items.first?.isChecked ?? false)
    }

    func test_todoParser_regularItemNoCheckbox() {
        let doc = MarkdownParser.parse("- Regular\n")
        guard case .list(let items) = doc.blocks.first else {
            XCTFail("Expected list block"); return
        }
        XCTAssertNil(items.first?.checkbox, "Regular item should not have checkbox")
    }

    // MARK: - Todo rendering

    func test_todoUnchecked_rendering() {
        let proj = project("- [ ] Task\n")
        // Rendered should contain ☐ (unchecked box), not "[ ]"
        let text = proj.attributed.string
        XCTAssertTrue(text.contains("\u{2610}"), "Unchecked todo should render ☐, got: \(text)")
        XCTAssertFalse(text.contains("[ ]"), "Rendered text should not contain raw checkbox syntax")
    }

    func test_todoChecked_rendering() {
        let proj = project("- [x] Done\n")
        // Rendered should contain ☑ (checked box)
        let text = proj.attributed.string
        XCTAssertTrue(text.contains("\u{2611}"), "Checked todo should render ☑, got: \(text)")
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
}
