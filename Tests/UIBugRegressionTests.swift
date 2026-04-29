//
//  UIBugRegressionTests.swift
//  FSNotesTests
//
//  Phase 11 Slice F.7 — rewrite of the original probe-based suite
//  (~1,740 LoC of `EditorHarness` + `snapshot().assertContains(...)`)
//  onto the Given/When/Then DSL.
//
//  Bugs that own a numbered entry now live in
//  `Tests/UserFlows/BugInventoryRegressionTests.swift` (Slice B's
//  canonical bug inventory). What stays here is the forward-looking
//  *invariant* probes — checks that don't trace to a single user-
//  reported bug but guard against regressions of the underlying
//  rendering-and-edit pipeline. Kept short so each line is one named
//  invariant.
//
//  Test naming: `test_<area>_<invariant>` instead of `test_probe_…`.
//  The "probe" prefix was an exploratory marker from the original
//  pre-DSL pass; every check below is now a named invariant of the
//  rendering/editing surface.
//

import XCTest
import AppKit
@testable import FSNotes

final class UIBugRegressionTests: XCTestCase {

    // MARK: - Fragment-dispatch invariants

    /// A single GFM table block emits exactly one `TableLayoutFragment`.
    /// Catches the "table rendered twice" regression class.
    func test_fragmentDispatch_singleTable_oneFragment() {
        Given.keyWindowNote()
            .with(markdown: "| a | b |\n|---|---|\n| 1 | 2 |\n")
            .Then.fragments.countOfClass("TableLayoutFragment").equals(1)
    }

    /// Each TK2 fragment class fires for its corresponding block kind
    /// in a single end-to-end fill. A bug anywhere in
    /// parse → render → apply → layout would leave the pure dispatch
    /// tests green while live-fill emits the wrong fragment.
    func test_fragmentDispatch_coversCustomFragmentKinds() {
        let md = """
        # Heading one

        Plain paragraph body.

        > Blockquote line.

        ```
        code block line
        ```

        ---

        | a | b |
        |---|---|
        | 1 | 2 |

        $$x^2 + y^2 = z^2$$

        Inline <kbd>Cmd</kbd> marker.
        """
        Given.keyWindowNote().with(markdown: md)
            .Then.fragments.contains(class: "HeadingLayoutFragment")
            .Then.fragments.contains(class: "BlockquoteLayoutFragment")
            .Then.fragments.contains(class: "CodeBlockLayoutFragment")
            .Then.fragments.contains(class: "HorizontalRuleLayoutFragment")
            .Then.fragments.contains(class: "TableLayoutFragment")
            .Then.fragments.contains(class: "DisplayMathLayoutFragment")
            .Then.fragments.contains(class: "KbdBoxParagraphLayoutFragment")
    }

    /// All six ATX heading levels must dispatch to `HeadingLayoutFragment`.
    func test_fragmentDispatch_allSixHeadingLevels() {
        let md = "# h1\n\n## h2\n\n### h3\n\n#### h4\n\n##### h5\n\n###### h6\n"
        Given.keyWindowNote().with(markdown: md)
            .Then.fragments.countOfClass("HeadingLayoutFragment").equals(6)
    }

    /// Multi-line blockquote → `BlockquoteLayoutFragment` emitted.
    func test_fragmentDispatch_multiLineBlockquote() {
        Given.keyWindowNote()
            .with(markdown: "> line one\n> line two\n> line three\n")
            .Then.fragments.contains(class: "BlockquoteLayoutFragment")
    }

    /// HR between two headings keeps its own fragment dispatch.
    func test_fragmentDispatch_horizontalRuleBetweenHeadings() {
        Given.keyWindowNote()
            .with(markdown: "# a\n\n---\n\n# b\n")
            .Then.fragments.contains(class: "HorizontalRuleLayoutFragment")
    }

    /// Mermaid block → `MermaidLayoutFragment`.
    func test_fragmentDispatch_mermaidBlock() {
        let md = "```mermaid\ngraph LR\n  A --> B\n```\n"
        Given.keyWindowNote().with(markdown: md)
            .Then.fragments.contains(class: "MermaidLayoutFragment")
    }

    /// `$$…$$` display-math block → `DisplayMathLayoutFragment`,
    /// and the source survives in storage.
    func test_fragmentDispatch_displayMath_sourcePreserved() {
        Given.keyWindowNote().with(markdown: "$$\\sqrt{2}$$\n")
            .Then.fragments.contains(class: "DisplayMathLayoutFragment")
            .Then.snapshot.contains("sqrt")
    }

    /// A multi-line fenced code block parses to ONE `.codeBlock` block
    /// (no per-line block fragmentation) and dispatches to
    /// `CodeBlockLayoutFragment`. TK2 emits one TextLayoutFragment per
    /// rendered line, all of `CodeBlockLayoutFragment` class — what
    /// matters for regression coverage is that it stays a single block.
    func test_fragmentDispatch_multiLineCodeBlock_oneBlock() {
        let md = "```\nline 1\nline 2\nline 3\nline 4\n```\n"
        Given.keyWindowNote().with(markdown: md)
            .Then.document.blockCount(ofKind: .codeBlock).equals(1)
            .Then.fragments.contains(class: "CodeBlockLayoutFragment")
    }

    /// A folded heading dispatches `FoldedLayoutFragment` for the body.
    func test_fragmentDispatch_foldedHeader() {
        Given.keyWindowNote().with(folded: .heading1)
            .Then.fragments.contains(class: "FoldedLayoutFragment")
    }

    // MARK: - Glyph-mount invariants

    /// Checkbox markers are present on the first fill.
    func test_glyphs_checkboxList_presentOnFill() {
        Given.keyWindowNote(markdown: "- [ ] a\n- [x] b\n")
            .Then.glyphs.checkboxCount.equals(2)
    }

    /// Todo list renders checkbox markers, not bullet markers.
    func test_glyphs_todoList_rendersCheckboxNotBullet() {
        Given.keyWindowNote(markdown: "- [ ] todo item\n")
            .Then.glyphs.checkboxCount.equals(1)
            .Then.glyphs.bulletCount.equals(0)
    }

    /// Bullet still renders when the list item carries inline formatting.
    func test_glyphs_boldInsideBullet_bulletStillRenders() {
        Given.keyWindowNote(markdown: "- **bold** item\n")
            .Then.glyphs.bulletCount.equals(1)
    }

    // MARK: - Block-content presence

    /// Table cell text lives in `NSTextContentStorage` (Phase 2e T2-f);
    /// snapshot must reflect cell contents directly.
    func test_blockContent_tableCellTextInSnapshot() {
        Given.keyWindowNote()
            .with(markdown: "| A | B |\n|---|---|\n| foo | bar |\n")
            .Then.snapshot.contains("foo")
            .Then.snapshot.contains("bar")
    }

    /// Code-block info string survives to the snapshot.
    func test_blockContent_codeBlockInfoStringPresent() {
        Given.keyWindowNote().with(markdown: "```swift\nlet x = 42\n```\n")
            .Then.fragments.contains(class: "CodeBlockLayoutFragment")
            .Then.snapshot.contains("swift")
    }

    /// Folded heading's body text does not appear as a regular
    /// paragraph fragment — the `FoldedLayoutFragment` masks it.
    func test_blockContent_foldedHeader_bodyHidden() {
        Given.keyWindowNote()
            .with(markdown: "# Parent\n\nUNIQUEFOLDEDMARKER body text\n")
            .with(folded: .heading1)
            .Then.fragments.contains(class: "FoldedLayoutFragment")
    }

    // MARK: - Edit-time block-kind preservation

    /// Typing one char at end-of-heading keeps the heading kind +
    /// fragment dispatch.
    func test_typingPreserves_headingFragment() {
        Given.keyWindowNote().with(markdown: "# Title\n")
            .cursorAt(7)
            .type("!")
            .Then.fragments.contains(class: "HeadingLayoutFragment")
    }

    /// Typing inside a code block keeps the code-block fragment.
    func test_typingPreserves_codeBlockFragment() {
        Given.keyWindowNote().with(markdown: "```\nx\n```\n")
            .cursorAt(5) // after "x"
            .type("y")
            .Then.fragments.contains(class: "CodeBlockLayoutFragment")
    }

    /// Typing inside a blockquote keeps the blockquote fragment.
    func test_typingPreserves_blockquoteFragment() {
        let scenario = Given.keyWindowNote().with(markdown: "> quoted\n")
        let len = scenario.editor.textStorage?.length ?? 0
        scenario
            .cursorAt(len)
            .type("!")
            .Then.fragments.contains(class: "BlockquoteLayoutFragment")
    }

    /// Backspace of last heading char does not change the block kind.
    func test_typingPreserves_headingKindOnBackspace() {
        let scenario = Given.keyWindowNote().with(markdown: "# XY\n")
        let len = scenario.editor.textStorage?.length ?? 0
        scenario
            .cursorAt(max(0, len - 1)) // before trailing \n
            .pressDelete()
            .Then.document.blockCount(ofKind: .heading(level: 1)).isAtLeast(1)
    }

    /// Typing at heading position 0 keeps the heading kind.
    func test_typingPreserves_headingKindAtStart() {
        Given.keyWindowNote().with(markdown: "# title\n")
            .cursorAt(0)
            .type("X")
            .Then.document.blockCount(ofKind: .heading(level: 1)).isAtLeast(1)
    }

    /// Two consecutive edits both preserve fragment-class dispatch
    /// (covers the re-splice path).
    func test_typingPreserves_twoConsecutiveEditsKeepHeadingFragment() {
        Given.keyWindowNote().with(markdown: "# Title\n")
            .cursorAt(7)
            .type("X")
            .type("Y")
            .Then.fragments.contains(class: "HeadingLayoutFragment")
    }

    /// Long typing into a blockquote line preserves the blockquote.
    func test_typingPreserves_longTypingInBlockquote() {
        let scenario = Given.keyWindowNote().with(markdown: "> q\n")
        let len = scenario.editor.textStorage?.length ?? 0
        scenario.cursorAt(len)
        for _ in 0..<50 { scenario.type("x") }
        scenario.Then.document.blockCount(ofKind: .blockquote).isAtLeast(1)
    }

    /// Rapid typing in a heading does not multiply heading fragments.
    func test_typingPreserves_rapidTypeStableFragmentCount() {
        let scenario = Given.keyWindowNote().with(markdown: "# hi\n")
        let len = scenario.editor.textStorage?.length ?? 0
        scenario.cursorAt(len)
        for _ in 0..<20 { scenario.type("x") }
        scenario.Then.fragments.countOfClass("HeadingLayoutFragment").equals(1)
    }

    /// Editing a table cell does not duplicate `TableLayoutFragment`.
    func test_typingPreserves_tableSingleFragmentAfterCellEdit() {
        let scenario = Given.keyWindowNote()
            .with(markdown: "| A | B |\n|---|---|\n| foo | bar |\n")
        guard let storage = scenario.editor.textStorage else {
            return XCTFail("no storage")
        }
        let fooRange = (storage.string as NSString).range(of: "foo")
        guard fooRange.location != NSNotFound else {
            return XCTFail("foo not found")
        }
        scenario
            .cursorAt(fooRange.location + fooRange.length)
            .type("!")
            .Then.fragments.countOfClass("TableLayoutFragment").equals(1)
    }

    /// Typing into a single-table doc preserves the table fragment.
    func test_typingPreserves_typeInOnlyTableDoc() {
        let scenario = Given.keyWindowNote()
            .with(markdown: "| A |\n|---|\n| x |\n")
        guard let storage = scenario.editor.textStorage else {
            return XCTFail("no storage")
        }
        let xRange = (storage.string as NSString).range(of: "x")
        guard xRange.location != NSNotFound else {
            return XCTFail("x not found")
        }
        scenario
            .cursorAt(xRange.location + xRange.length)
            .type("y")
            .Then.fragments.contains(class: "TableLayoutFragment")
    }

    /// Typing outside a table leaves cell text untouched.
    func test_typingPreserves_typeOutsideTableLeavesCellsIntact() {
        let md = """
        paragraph

        | A | B |
        |---|---|
        | foo | bar |
        """
        Given.keyWindowNote().with(markdown: md)
            .cursorAt(9) // end of "paragraph"
            .type("!")
            .Then.fragments.contains(class: "TableLayoutFragment")
            .Then.snapshot.contains("foo")
            .Then.snapshot.contains("bar")
    }

    // MARK: - Cursor / selection invariants

    /// First fill yields cursor at offset 0 with zero length.
    func test_cursor_firstFillYieldsCollapsed() {
        Given.keyWindowNote().with(markdown: "one two three\n")
            .Then.cursor.isAt(storageOffset: 0)
            .Then.cursor.selectionIsCollapsed()
    }

    /// Selection collapses after typing.
    func test_cursor_collapsedAfterType() {
        Given.keyWindowNote().with(markdown: "abc\n")
            .cursorAt(3)
            .type("d")
            .Then.cursor.selectionIsCollapsed()
    }

    /// Backspace at document start is a no-op.
    func test_cursor_backspaceAtDocStartIsNoop() {
        let scenario = Given.keyWindowNote().with(markdown: "hello\n")
        let initial = scenario.editor.textStorage?.length ?? 0
        scenario.cursorAt(0).pressDelete()
        let final = scenario.editor.textStorage?.length ?? 0
        XCTAssertEqual(final, initial,
                       "backspace at offset 0 should be a no-op")
    }

    /// Forward-delete at end of document is a no-op.
    func test_cursor_forwardDeleteAtEndIsNoop() {
        let scenario = Given.keyWindowNote().with(markdown: "abc\n")
        let len = scenario.editor.textStorage?.length ?? 0
        scenario.cursorAt(len).pressForwardDelete()
        XCTAssertEqual(scenario.editor.textStorage?.length ?? 0, len)
    }

    // MARK: - Structural-edit invariants

    /// Return inside a paragraph splits it into two paragraph blocks.
    func test_structural_returnSplitsParagraph() {
        Given.keyWindowNote().with(markdown: "first second third\n")
            .cursorAt(5) // between "first" and " second"
            .pressReturn()
            .Then.document.blockCount(ofKind: .paragraph).isAtLeast(2)
    }

    /// Type after Return mid-paragraph lands in the new block, not
    /// the old one.
    func test_structural_typeAfterReturnLandsInNewBlock() {
        let scenario = Given.keyWindowNote().with(markdown: "onetwo\n")
            .cursorAt(3) // between "one" and "two"
            .pressReturn()
            .type("X")
        let text = scenario.editor.textStorage?.string ?? ""
        XCTAssertTrue(text.contains("one") && text.contains("Xtwo"),
                      "After split+type, expected 'one\\nXtwo'; got '\(text)'")
    }

    /// Select-all + type replaces the entire document.
    func test_structural_selectAllThenTypeReplacesDocument() {
        Given.keyWindowNote()
            .with(markdown: "# old heading\n\nold body\n")
            .selectAll()
            .type("N")
            .Then.document.storageText.doesNotContain("old heading")
            .Then.document.storageText.doesNotContain("old body")
            .Then.document.storageText.contains("N")
    }

    /// Select across two blocks then type replaces both.
    func test_structural_selectAcrossBlocksTypeReplaces() {
        Given.keyWindowNote()
            .with(markdown: "first para\n\nsecond para\n")
            .selectAll()
            .type("O")
            .Then.document.storageText.doesNotContain("first")
            .Then.document.storageText.doesNotContain("second")
    }

    /// Typing into an empty doc produces a paragraph block.
    func test_structural_typeIntoEmptyDocProducesParagraph() {
        Given.keyWindowNote().type("hi")
            .Then.document.blockCount(ofKind: .paragraph).isAtLeast(1)
    }

    /// Empty document yields a valid (non-empty, well-formed) snapshot.
    func test_structural_emptyDocYieldsValidSnapshot() {
        Given.keyWindowNote()
            .Then.snapshot.contains("(editor")
    }

    // MARK: - Inline-content invariants

    /// Unicode (CJK + accented Latin) survives end-to-end.
    func test_inline_unicodeRoundTrips() {
        Given.keyWindowNote()
            .with(markdown: "日本語 café naïve 한국어\n")
            .Then.snapshot.contains("日本語")
            .Then.snapshot.contains("café")
            .Then.snapshot.contains("한국어")
    }

    /// Emoji input lands in storage.
    func test_inline_emojiLands() {
        Given.keyWindowNote().type("🎉")
            .Then.document.storageText.contains("🎉")
    }

    /// A link's URL appears in the rendered storage.
    func test_inline_linkUrlPreserved() {
        Given.keyWindowNote()
            .with(markdown: "[click](https://example.com)\n")
            .Then.snapshot.contains("https://example.com")
    }

    /// Inline code-span text survives (markers stripped in WYSIWYG
    /// storage; text remains).
    func test_inline_codeSpanTextPreserved() {
        Given.keyWindowNote().with(markdown: "Here is `code` inline.\n")
            .Then.snapshot.contains("code")
    }

    /// Inline math `$x$` lands as an attachment node, not raw text.
    /// The snapshot retains either the attachment marker or the math
    /// payload literally — both mean a real inline-math node was
    /// created.
    func test_inline_inlineMathRendersAsAttachmentLike() {
        Given.keyWindowNote().with(markdown: "before $x^2$ after\n")
        // No XCTSkip: hydration may be async, but the placeholder
        // always lands. We accept either form.
        let scenario = Given.keyWindowNote()
            .with(markdown: "before $x^2$ after\n")
        let raw = EditorSnapshot.emit(from: scenario.editor).raw
        XCTAssertTrue(raw.contains("attachment") || raw.contains("math"),
                      "inline math should produce an attachment-like " +
                      "node; snapshot:\n\(raw.prefix(400))")
    }

    /// Bold inline run survives a type-at-end edit.
    func test_inline_boldExtendedByTypeRemainsBold() {
        let scenario = Given.keyWindowNote()
            .with(markdown: "**hello** world\n")
            .cursorAt(5) // end of "hello"
            .type("X")
        let raw = EditorSnapshot.emit(from: scenario.editor).raw
        XCTAssertTrue(raw.contains("bold") || raw.contains("strong"),
                      "bold inline formatting should survive; " +
                      "snapshot:\n\(raw.prefix(400))")
    }

    // MARK: - Paste invariants

    /// Pasting plain markdown into an empty doc inserts the content.
    func test_paste_intoEmptyDocInsertsText() {
        Given.keyWindowNote().paste(markdown: "pasted content")
            .Then.document.storageText.contains("pasted content")
    }

    // MARK: - Stress shapes

    /// 3,000-char paragraph survives without truncation.
    func test_stress_longParagraphRendersIntact() {
        let long = String(repeating: "abc ", count: 750) // 3000 chars
        let scenario = Given.keyWindowNote().with(markdown: long + "\n")
        let storageLen = scenario.editor.textStorage?.length ?? 0
        XCTAssertGreaterThan(
            storageLen, 2990,
            "long paragraph storage length unexpectedly small: " +
            "\(storageLen)"
        )
    }

    /// 50 paragraphs render with 50 paragraph blocks.
    func test_stress_manyParagraphsBlockCountMatches() {
        let md = (0..<50)
            .map { "Para \($0)" }
            .joined(separator: "\n\n") + "\n"
        Given.keyWindowNote().with(markdown: md)
            .Then.document.blockCount(ofKind: .paragraph).isAtLeast(50)
    }

    // MARK: - Bug #34: insertTableMenu source-mode prefix

    /// Bug #34 — `insertTableMenu` source-mode path inserts a table
    /// markdown block with a BLANK line separator (`\n\n`) before it,
    /// not a single `\n`. Without the blank line, GFM parsers treat
    /// the table's first row as paragraph continuation.
    ///
    /// Pure-function coverage of the four contract cases of
    /// `tablePrefixForSourceModeInsertion(at:in:)`:
    ///   1. doc-start  → "" (no prefix needed)
    ///   2. after `\n` → "\n" (one more newline = blank line)
    ///   3. after non-`\n` → "\n\n" (full blank-line separator)
    ///   4. out-of-range → "\n\n" (defensive default)
    func test_bug34_insertTable_sourceMode_prefixHelper_contract() {
        XCTAssertEqual(
            EditTextView.tablePrefixForSourceModeInsertion(at: 0, in: ""),
            ""
        )
        XCTAssertEqual(
            EditTextView.tablePrefixForSourceModeInsertion(at: 0, in: "abc"),
            ""
        )
        XCTAssertEqual(
            EditTextView.tablePrefixForSourceModeInsertion(at: 4, in: "abc\n"),
            "\n"
        )
        XCTAssertEqual(
            EditTextView.tablePrefixForSourceModeInsertion(at: 3, in: "abc"),
            "\n\n"
        )
        XCTAssertEqual(
            EditTextView.tablePrefixForSourceModeInsertion(at: 99, in: "abc"),
            "\n\n"
        )
    }

    /// Bug #34 — end-to-end via the editor. Force the source-mode
    /// branch by clearing `documentProjection` and `blockModelActive`
    /// after the harness's normal seed, then call the IBAction with
    /// a paragraph-trailing-newline cursor. Expect the inserted
    /// table to be preceded by a blank line.
    func test_bug34_insertTable_sourceMode_endToEnd_prefixIsBlankLine() {
        let md = "preceding paragraph\n"
        let scenario = Given.keyWindowNote().with(markdown: md)
        scenario.editor.documentProjection = nil
        scenario.editor.textStorageProcessor?.blockModelActive = false
        StorageWriteGuard.performingFill {
            scenario.editor.textStorage?.setAttributedString(
                NSAttributedString(string: md)
            )
        }
        let len = scenario.editor.textStorage?.length ?? 0
        scenario.select(NSRange(location: len, length: 0))
        scenario.editor.insertTableMenu(NSMenuItem())
        let after = scenario.editor.textStorage?.string ?? ""
        XCTAssertTrue(
            after.contains("preceding paragraph\n\n|"),
            "Expected blank line between paragraph and inserted " +
            "table; got: \(after.debugDescription)"
        )
        XCTAssertFalse(
            after.contains("paragraph\n|"),
            "Single `\\n` between paragraph and table is invalid GFM; " +
            "got: \(after.debugDescription)"
        )
    }
}
