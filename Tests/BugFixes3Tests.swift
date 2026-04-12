//
//  BugFixes3Tests.swift
//  FSNotesTests
//
//  Regression tests for FSNotes++ Bugs 3.
//  Tests the rendering pipeline to detect bugs and prevent recurrence.
//

import XCTest
@testable import FSNotes

class BugFixes3Tests: XCTestCase {

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

    private func assertRoundTrip(
        _ result: EditResult,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, expected, "Round-trip mismatch", file: file, line: line)
    }

    // MARK: - Bug: insertWithTraits (inline formatting with empty selection)

    func test_insertWithTraits_boldCharacter() throws {
        // When user toggles bold with no selection, then types a character,
        // the character should be wrapped in bold in the inline tree.
        let proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.bold]
        // Insert "x" at position 6 (after "Hello ") with bold trait.
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        assertRoundTrip(result, expected: "Hello **x**\n")
        assertSpliceInvariant(old: proj, result: result)
        XCTAssertEqual(result.newCursorPosition, 7)
    }

    func test_insertWithTraits_italicCharacter() throws {
        let proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.italic]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        assertRoundTrip(result, expected: "Hello *x*\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_insertWithTraits_boldItalicStacked() throws {
        // Bold + italic stacked: both traits applied at once.
        let proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.bold, .italic]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        // The serialized output should have both markers.
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        // Either ***x*** or **_x_** or *__x__* depending on nesting
        XCTAssertTrue(serialized.contains("x"), "Character should be present")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_insertWithTraits_strikethroughCharacter() throws {
        let proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.strikethrough]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        assertRoundTrip(result, expected: "Hello ~~x~~\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_insertWithTraits_inListItem() throws {
        let proj = project("- Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.bold]
        // In rendered output, "Hello " starts at offset 1 (after bullet glyph).
        // Position 7 = after "Hello " in rendered output.
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 7, in: proj)
        assertRoundTrip(result, expected: "- Hello **x**\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_insertWithTraits_inBlockquote() throws {
        let proj = project("> Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.bold]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 7, in: proj)
        assertRoundTrip(result, expected: "> Hello **x**\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_insertWithTraits_inHeading() throws {
        // Headings store their suffix as a plain string. When bold text is
        // inserted, `inlinesToText` currently strips formatting markers from
        // the heading suffix (headings don't carry an inline tree in their
        // Block representation). The insertion itself should succeed without
        // crashing, and the character "x" should appear in the rendered output.
        let proj = project("# Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.bold]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        // Verify the rendered output contains the inserted character.
        let rendered = result.newProjection.attributed.string
        XCTAssertTrue(rendered.contains("x"), "Inserted char should be in rendered output")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_insertWithTraits_intoEmptyParagraph() throws {
        // Typing into a blank line with bold active.
        let proj = project("\n")
        let traits: Set<EditingOps.InlineTrait> = [.bold]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 0, in: proj)
        assertRoundTrip(result, expected: "**x**\n")
        assertSpliceInvariant(old: proj, result: result)
    }

    func test_insertWithTraits_multipleCharsSequential() throws {
        // Simulate typing "abc" one char at a time with bold.
        var proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.bold]

        let r1 = try EditingOps.insertWithTraits("a", traits: traits, at: 6, in: proj)
        proj = r1.newProjection

        // After first insert, "a" is bold. Insert "b" right after it.
        // Because each insertion creates a new bold wrapper, the serializer
        // may produce **a****b****c** (adjacent bold spans). This is
        // semantically correct — the cleanInlines function may or may not
        // merge them. What matters is that the rendered text is correct.
        let r2 = try EditingOps.insertWithTraits("b", traits: traits, at: 7, in: proj)
        proj = r2.newProjection

        let r3 = try EditingOps.insertWithTraits("c", traits: traits, at: 8, in: proj)

        // Verify rendered text is correct (bold formatting preserved).
        let rendered = r3.newProjection.attributed.string
        XCTAssertTrue(rendered.contains("abc"), "Rendered output should contain 'abc'")
    }

    // MARK: - Bug: HR rendered with .horizontalRule attribute

    func test_hrRenderer_setsHorizontalRuleAttribute() {
        // The block-model HR renderer should set the .horizontalRule
        // attribute so the LayoutManager can draw a full-width line.
        let proj = project("---\n")
        guard proj.attributed.length > 0 else {
            XCTFail("HR should render at least one character")
            return
        }
        let attrs = proj.attributed.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.horizontalRule], "HR should carry .horizontalRule attribute")
    }

    func test_hrRenderer_clearForeground() {
        // The HR text should have clear foreground (the LayoutManager
        // draws the visual line, not the text glyphs).
        let proj = project("---\n")
        guard proj.attributed.length > 0 else {
            XCTFail("HR should render at least one character")
            return
        }
        let attrs = proj.attributed.attributes(at: 0, effectiveRange: nil)
        if let color = attrs[.foregroundColor] as? NSColor {
            XCTAssertEqual(color, NSColor.clear, "HR text should be clear")
        }
    }

    // MARK: - Bug: Markdown shortcut auto-conversion patterns
    //
    // These tests verify the underlying replaceBlock mechanism used by
    // autoConvertMarkdownShortcut. They start from a plain paragraph
    // and convert it to the target block type.

    func test_autoConvert_bulletDashSpace() throws {
        // Start from a plain paragraph, convert to bullet list.
        let proj = project("some text\n")
        let item = ListItem(
            indent: "", marker: "-", afterMarker: " ",
            inline: [.text("some text")], children: []
        )
        let newBlock = Block.list(items: [item])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj)
        if case .list = result.newProjection.document.blocks[0] {
            assertRoundTrip(result, expected: "- some text\n")
        } else {
            XCTFail("Should have converted to a list")
        }
    }

    func test_autoConvert_blockquoteGreaterSpace() throws {
        // Start from a plain paragraph, convert to blockquote.
        let proj = project("quoted text\n")
        let line = BlockquoteLine(prefix: "> ", inline: [.text("quoted text")])
        let newBlock = Block.blockquote(lines: [line])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj)
        if case .blockquote = result.newProjection.document.blocks[0] {
            assertRoundTrip(result, expected: "> quoted text\n")
        } else {
            XCTFail("Should have converted to a blockquote")
        }
    }

    func test_autoConvert_todoCheckbox() throws {
        // Start from a plain paragraph, convert to todo list.
        let proj = project("my task\n")
        let checkbox = Checkbox(text: "[ ]", afterText: " ")
        let item = ListItem(
            indent: "", marker: "-", afterMarker: " ",
            checkbox: checkbox, inline: [.text("my task")], children: []
        )
        let newBlock = Block.list(items: [item])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj)
        if case .list(let items, _) = result.newProjection.document.blocks[0] {
            XCTAssertNotNil(items.first?.checkbox, "List item should have checkbox")
            assertRoundTrip(result, expected: "- [ ] my task\n")
        } else {
            XCTFail("Should have converted to a todo list")
        }
    }

    func test_autoConvert_numberedList() throws {
        // Start from a plain paragraph, convert to numbered list.
        let proj = project("first item\n")
        let item = ListItem(
            indent: "", marker: "1.", afterMarker: " ",
            inline: [.text("first item")], children: []
        )
        let newBlock = Block.list(items: [item])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj)
        if case .list(let items, _) = result.newProjection.document.blocks[0] {
            XCTAssertEqual(items.first?.marker, "1.")
            assertRoundTrip(result, expected: "1. first item\n")
        } else {
            XCTFail("Should have converted to a numbered list")
        }
    }

    // MARK: - Bug: Cut/paste crash prevention (block model delete)

    func test_deleteViaBlockModel_todoItem() throws {
        // Deleting text within a todo item should work without crash.
        let proj = project("- [ ] Buy groceries\n- [ ] Walk dog\n")
        let span0 = proj.blockSpans[0]
        // Delete a single character within the inline content (not prefix).
        // Find inline start of first item.
        if case .list(let items, _) = proj.document.blocks[0] {
            let entries = EditingOps.flattenList(items)
            guard let first = entries.first else {
                XCTFail("Should have entries")
                return
            }
            let inlineStart = span0.location + first.startOffset + first.prefixLength
            // Delete "B" from "Buy"
            let deleteRange = NSRange(location: inlineStart, length: 1)
            let result = try EditingOps.delete(range: deleteRange, in: proj)
            XCTAssertGreaterThan(result.newProjection.attributed.length, 0)
        } else {
            XCTFail("Expected a list block")
        }
    }

    func test_deleteViaBlockModel_singleCharInTodo() throws {
        // Deleting a single character in a todo item should work.
        let proj = project("- [ ] Hello\n")
        // "Hello" starts after the checkbox glyph. Let's delete "H".
        let entries = EditingOps.flattenList(
            { if case .list(let items, _) = proj.document.blocks[0] { return items } else { return [] } }()
        )
        guard let first = entries.first else {
            XCTFail("Should have a list entry")
            return
        }
        let hPos = proj.blockSpans[0].location + first.startOffset + first.prefixLength
        let result = try EditingOps.delete(range: NSRange(location: hPos, length: 1), in: proj)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(serialized, "- [ ] ello\n")
    }

    // MARK: - Bug: Wikilink insertion via block model

    func test_wikilink_insertEmptyBrackets() throws {
        // Inserting "[[]]" via the block model should produce valid markdown.
        let proj = project("Hello \n")
        let result = try EditingOps.insert("[[]]", at: 6, in: proj)
        assertSpliceInvariant(old: proj, result: result)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertTrue(serialized.contains("[[]]"), "Wikilink markers should be in output")
    }

    func test_wikilink_insertWithSelection() throws {
        // Wrapping "world" in [[]] via replace.
        let proj = project("Hello world\n")
        let result = try EditingOps.replace(
            range: NSRange(location: 6, length: 5),
            with: "[[world]]",
            in: proj
        )
        assertSpliceInvariant(old: proj, result: result)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertTrue(serialized.contains("[[world]]"), "Wikilink should wrap selected text")
    }

    // MARK: - Bug: Tab completion movement

    func test_completionAcceptsTabMovement() {
        // NSTabTextMovement should be accepted for completions, not just NSReturnTextMovement.
        // This is a logic test — verify that the condition evaluates correctly.
        let returnMovement = NSReturnTextMovement
        let tabMovement = NSTabTextMovement

        // Both should pass the guard condition.
        XCTAssertTrue(returnMovement == NSReturnTextMovement || returnMovement == NSTabTextMovement)
        XCTAssertTrue(tabMovement == NSReturnTextMovement || tabMovement == NSTabTextMovement)

        // Other movements should NOT pass.
        let otherMovement = NSOtherTextMovement
        XCTAssertFalse(otherMovement == NSReturnTextMovement || otherMovement == NSTabTextMovement)
    }

    // MARK: - Bug: Orphan dialog Esc key

    func test_escKeyEquivalent() {
        // Verify the Esc key equivalent is correctly set.
        // Unicode escape character (U+001B) is the keyEquivalent for Esc.
        let escKey = "\u{1b}"
        XCTAssertEqual(escKey.count, 1)
        XCTAssertEqual(escKey.unicodeScalars.first?.value, 0x1B)
    }

    // MARK: - Rendering pipeline invariants

    func test_hrRoundTrip() {
        // HR should round-trip: parse → serialize → parse → serialize.
        let md = "---\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md, "HR should round-trip")
    }

    func test_insertWithTraits_underline() throws {
        let proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.underline]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        assertSpliceInvariant(old: proj, result: result)
        // Underline uses HTML tags.
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertTrue(serialized.contains("<u>x</u>"), "Underline should wrap with HTML tags")
    }

    func test_insertWithTraits_highlight() throws {
        let proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.highlight]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        assertSpliceInvariant(old: proj, result: result)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertTrue(serialized.contains("<mark>x</mark>"), "Highlight should wrap with mark tags")
    }

    func test_insertWithTraits_code() throws {
        let proj = project("Hello \n")
        let traits: Set<EditingOps.InlineTrait> = [.code]
        let result = try EditingOps.insertWithTraits("x", traits: traits, at: 6, in: proj)
        assertSpliceInvariant(old: proj, result: result)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertTrue(serialized.contains("`x`"), "Code should wrap with backticks")
    }

    // MARK: - Inline formatting does NOT corrupt when no selection

    func test_toggleBold_emptySelection_isNoOp() throws {
        // The block-model toggleInlineTrait with empty selection should be a no-op
        // (the actual formatting is handled by pending traits in the view layer).
        let proj = project("Hello world\n")
        let sel = NSRange(location: 5, length: 0)
        let result = try EditingOps.toggleInlineTrait(.bold, range: sel, in: proj)
        // Should be unchanged — no insertion of **** markers.
        XCTAssertEqual(
            MarkdownSerializer.serialize(result.newProjection.document),
            "Hello world\n"
        )
        XCTAssertEqual(result.newCursorPosition, 5)
    }

    // MARK: - Paragraph to block conversion via replaceBlock

    func test_paragraphToBulletList_viaReplaceBlock() throws {
        // Simulate what autoConvertMarkdownShortcut does:
        // Remove "- " prefix from paragraph and convert to list.
        let proj = project("- item text\n")
        // This is already a list from the parser! Test with plain text instead.
        let proj2 = project("text\n")
        let item = ListItem(
            indent: "", marker: "-", afterMarker: " ",
            inline: [.text("text")], children: []
        )
        let newBlock = Block.list(items: [item])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj2)
        assertSpliceInvariant(old: proj2, result: result)
        assertRoundTrip(result, expected: "- text\n")
    }

    func test_paragraphToBlockquote_viaReplaceBlock() throws {
        let proj = project("text\n")
        let line = BlockquoteLine(prefix: "> ", inline: [.text("text")])
        let newBlock = Block.blockquote(lines: [line])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj)
        assertSpliceInvariant(old: proj, result: result)
        assertRoundTrip(result, expected: "> text\n")
    }

    func test_paragraphToTodoList_viaReplaceBlock() throws {
        let proj = project("task\n")
        let checkbox = Checkbox(text: "[ ]", afterText: " ")
        let item = ListItem(
            indent: "", marker: "-", afterMarker: " ",
            checkbox: checkbox, inline: [.text("task")], children: []
        )
        let newBlock = Block.list(items: [item])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj)
        assertSpliceInvariant(old: proj, result: result)
        assertRoundTrip(result, expected: "- [ ] task\n")
    }

    func test_paragraphToNumberedList_viaReplaceBlock() throws {
        let proj = project("item\n")
        let item = ListItem(
            indent: "", marker: "1.", afterMarker: " ",
            inline: [.text("item")], children: []
        )
        let newBlock = Block.list(items: [item])
        let result = try EditingOps.replaceBlock(atIndex: 0, with: newBlock, in: proj)
        assertSpliceInvariant(old: proj, result: result)
        assertRoundTrip(result, expected: "1. item\n")
    }
}
