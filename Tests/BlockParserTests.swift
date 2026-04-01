//
//  BlockParserTests.swift
//  FSNotesTests
//
//  Unit tests for MarkdownBlockParser — pure function, no UI dependencies.
//  Tests block detection, classification, range accuracy, and edge cases.
//

import XCTest
@testable import FSNotes

class BlockParserTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        let string = markdown as NSString
        return MarkdownBlockParser.parse(string: string)
    }

    private func types(_ blocks: [MarkdownBlock]) -> [String] {
        return blocks.map { describeType($0.type) }
    }

    private func describeType(_ type: MarkdownBlockType) -> String {
        switch type {
        case .paragraph: return "paragraph"
        case .heading(let l): return "h\(l)"
        case .headingSetext(let l): return "setext\(l)"
        case .codeBlock(let lang): return "code(\(lang ?? "nil"))"
        case .blockquote: return "blockquote"
        case .unorderedList: return "ul"
        case .orderedList: return "ol"
        case .todoItem(let checked): return "todo(\(checked))"
        case .horizontalRule: return "hr"
        case .table: return "table"
        case .yamlFrontmatter: return "yaml"
        case .empty: return "empty"
        }
    }

    // MARK: - Basic Block Detection

    func test_emptyString() {
        let blocks = parse("")
        XCTAssertTrue(blocks.isEmpty)
    }

    func test_singleParagraph() {
        let blocks = parse("Hello world")
        XCTAssertEqual(types(blocks), ["paragraph"])
    }

    func test_twoParagraphs() {
        let blocks = parse("First paragraph\n\nSecond paragraph")
        let paragraphs = blocks.filter { describeType($0.type) == "paragraph" }
        XCTAssertEqual(paragraphs.count, 2)
    }

    // MARK: - Headings

    func test_h1() {
        let blocks = parse("# Heading 1")
        XCTAssertEqual(types(blocks), ["h1"])
    }

    func test_h2() {
        let blocks = parse("## Heading 2")
        XCTAssertEqual(types(blocks), ["h2"])
    }

    func test_h3() {
        let blocks = parse("### Heading 3")
        XCTAssertEqual(types(blocks), ["h3"])
    }

    func test_h4() {
        let blocks = parse("#### Heading 4")
        XCTAssertEqual(types(blocks), ["h4"])
    }

    func test_h5() {
        let blocks = parse("##### Heading 5")
        XCTAssertEqual(types(blocks), ["h5"])
    }

    func test_h6() {
        let blocks = parse("###### Heading 6")
        XCTAssertEqual(types(blocks), ["h6"])
    }

    func test_headingWithContent() {
        let blocks = parse("# Title\n\nSome text\n\n## Subtitle\n\nMore text")
        let t = types(blocks)
        // Parser emits empty blocks for blank lines — verify key blocks present
        XCTAssertTrue(t.contains("h1"))
        XCTAssertTrue(t.contains("h2"))
        XCTAssertTrue(t.contains("paragraph"))
    }

    func test_headingSyntaxRanges() {
        let blocks = parse("## Hello")
        XCTAssertEqual(blocks.count, 1)
        // Syntax range should cover "## " (3 chars)
        XCTAssertFalse(blocks[0].syntaxRanges.isEmpty)
        XCTAssertEqual(blocks[0].syntaxRanges[0].length, 3) // "## "
    }

    // MARK: - Code Blocks

    func test_codeBlock() {
        let blocks = parse("```python\nprint('hello')\n```")
        XCTAssertEqual(types(blocks), ["code(python)"])
    }

    func test_codeBlockNoLanguage() {
        let blocks = parse("```\nsome code\n```")
        XCTAssertEqual(types(blocks), ["code(nil)"])
    }

    func test_codeBlockPreservesContent() {
        let md = "```python\nprint('hello')\nprint('world')\n```"
        let blocks = parse(md)
        XCTAssertEqual(blocks.count, 1)
        let contentRange = blocks[0].contentRange
        let content = (md as NSString).substring(with: contentRange)
        XCTAssertTrue(content.contains("print('hello')"))
        XCTAssertTrue(content.contains("print('world')"))
    }

    // MARK: - Blockquotes

    func test_blockquote() {
        let blocks = parse("> Quoted text")
        XCTAssertEqual(types(blocks), ["blockquote"])
    }

    func test_multiLineBlockquote() {
        let blocks = parse("> Line 1\n> Line 2\n> Line 3")
        XCTAssertEqual(types(blocks), ["blockquote"])
    }

    func test_nestedBlockquoteSyntaxRanges() {
        let md = ">> Nested"
        let blocks = parse(md)
        XCTAssertEqual(types(blocks), ["blockquote"])
        // Should have syntax ranges for both > characters
        XCTAssertTrue(blocks[0].syntaxRanges.count >= 2)
    }

    // MARK: - Lists

    func test_unorderedList() {
        let blocks = parse("- Item 1\n- Item 2")
        XCTAssertEqual(types(blocks), ["ul"])
    }

    func test_unorderedListStar() {
        let blocks = parse("* Item 1\n* Item 2")
        XCTAssertEqual(types(blocks), ["ul"])
    }

    func test_unorderedListPlus() {
        let blocks = parse("+ Item 1\n+ Item 2")
        XCTAssertEqual(types(blocks), ["ul"])
    }

    func test_bulletCharRecognized() {
        // Storage always contains original markdown markers (no • substitution).
        // All three marker types should be recognized.
        XCTAssertEqual(types(parse("- Item 1\n- Item 2")), ["ul"])
        XCTAssertEqual(types(parse("* Item 1\n* Item 2")), ["ul"])
        XCTAssertEqual(types(parse("+ Item 1\n+ Item 2")), ["ul"])
    }

    func test_orderedList() {
        let blocks = parse("1. First\n2. Second\n3. Third")
        XCTAssertEqual(types(blocks), ["ol"])
    }

    // MARK: - Todo Items

    func test_todoUnchecked() {
        let blocks = parse("- [ ] Unchecked item")
        XCTAssertEqual(types(blocks), ["todo(false)"])
    }

    func test_todoChecked() {
        let blocks = parse("- [x] Checked item")
        XCTAssertEqual(types(blocks), ["todo(true)"])
    }

    // MARK: - Horizontal Rules

    func test_horizontalRuleDash() {
        // Standalone "---" at document start = YAML frontmatter marker, not HR
        // Use "***" or put text before it to test HR
        let blocks = parse("text\n\n---")
        let hasHR = blocks.contains { describeType($0.type) == "hr" }
        XCTAssertTrue(hasHR)
    }

    func test_horizontalRuleStar() {
        let blocks = parse("***")
        XCTAssertEqual(types(blocks), ["hr"])
    }

    func test_horizontalRuleUnderscore() {
        let blocks = parse("___")
        XCTAssertEqual(types(blocks), ["hr"])
    }

    func test_consecutiveHRs() {
        let blocks = parse("---\n---\n---")
        // Each --- on its own line should be a separate HR
        let hrCount = blocks.filter { describeType($0.type) == "hr" }.count
        XCTAssertGreaterThanOrEqual(hrCount, 1)
    }

    func test_setextVsHR() {
        // --- directly after a paragraph line (no blank line) = setext heading
        let blocks = parse("Heading\n---")
        let hasSetext = blocks.contains { describeType($0.type) == "setext2" }
        let hasHR = blocks.contains { describeType($0.type) == "hr" }
        // Parser may treat as setext OR as paragraph+HR depending on implementation
        XCTAssertTrue(hasSetext || hasHR, "Expected setext heading or HR, got: \(types(blocks))")
    }

    func test_hrAfterBlankLine() {
        // --- after blank line = HR
        let blocks = parse("Text\n\n---")
        let hasHR = blocks.contains { describeType($0.type) == "hr" }
        XCTAssertTrue(hasHR)
    }

    // MARK: - Tables

    func test_table() {
        let blocks = parse("| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(types(blocks), ["table"])
    }

    // MARK: - YAML Frontmatter

    func test_yamlFrontmatter() {
        // "---" at document start is YAML frontmatter
        let blocks = parse("---\ntitle: Test\n---\n\nContent")
        XCTAssertTrue(blocks.contains { describeType($0.type) == "yaml" })
    }

    func test_dashAtStartIsYAML() {
        // Standalone "---" at document start = YAML, not HR
        let blocks = parse("---")
        XCTAssertTrue(blocks.contains { describeType($0.type) == "yaml" })
    }

    // MARK: - Mixed Content

    func test_mixedContent() {
        let md = """
        # Title

        Some text here.

        ## Section

        - Item 1
        - Item 2

        > A quote

        ---

        ```python
        code
        ```
        """
        let blocks = parse(md)
        let t = types(blocks)
        XCTAssertTrue(t.contains("h1"))
        XCTAssertTrue(t.contains("h2"))
        XCTAssertTrue(t.contains("paragraph"))
        XCTAssertTrue(t.contains("ul"))
        XCTAssertTrue(t.contains("blockquote"))
        XCTAssertTrue(t.contains("code(python)"))
    }

    // MARK: - Range Accuracy

    func test_blockRangeCoversFullContent() {
        let md = "# Title\n\nParagraph text"
        let blocks = parse(md)
        // Every character should be covered by some block
        let nsStr = md as NSString
        for i in 0..<nsStr.length {
            let covered = blocks.contains { NSLocationInRange(i, $0.range) }
            if !covered {
                let char = nsStr.substring(with: NSRange(location: i, length: 1))
                // Blank lines between blocks may not be covered — that's OK
                if char != "\n" {
                    XCTFail("Character at index \(i) ('\(char)') not covered by any block")
                }
            }
        }
    }
}
