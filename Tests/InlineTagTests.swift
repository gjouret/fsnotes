//
//  InlineTagTests.swift
//  FSNotesTests
//
//  Unit tests for the InlineTagRegistry processing.
//  Verifies that HTML tags are correctly detected, styled, and hidden.
//

import XCTest
@testable import FSNotes

class InlineTagTests: XCTestCase {

    // MARK: - Helpers

    private func process(_ markdown: String) -> NSMutableAttributedString {
        let attrStr = NSMutableAttributedString(string: markdown, attributes: [
            .font: NSFont.systemFont(ofSize: 14)
        ])
        let defs = buildInlineTagDefinitions(baseFont: NSFont.systemFont(ofSize: 14))
        processInlineTags(
            definitions: defs,
            in: attrStr,
            string: markdown,
            range: NSRange(location: 0, length: (markdown as NSString).length),
            syntaxColor: NSColor.gray,
            hideSyntax: true,
            hideSyntaxFunc: { range in
                NotesTextProcessor.applySyntaxHiding(in: attrStr, range: range)
            }
        )
        return attrStr
    }

    // MARK: - Underline

    func test_underlineTag() {
        let result = process("Some <u>underlined</u> text")
        // Content "underlined" should have underline attribute
        let ulValue = result.attribute(.underlineStyle, at: 10, effectiveRange: nil) as? Int
        XCTAssertEqual(ulValue, NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Kbd

    func test_kbdTag() {
        let result = process("Press <kbd>Ctrl</kbd> key")
        // "Press " = 6, "<kbd>" = 5 hidden, "Ctrl" starts at index 11
        let kbdValue = result.attribute(.kbdTag, at: 11, effectiveRange: nil)
        XCTAssertNotNil(kbdValue)
        let font = result.attribute(.font, at: 11, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
    }

    // MARK: - Mark

    func test_markTag() {
        let result = process("This is <mark>highlighted</mark> text")
        // "This is " = 8, "<mark>" = 6 hidden, "highlighted" starts at index 14
        let bg = result.attribute(.backgroundColor, at: 14, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(bg)
    }

    // MARK: - Tag Hiding

    func test_tagsHiddenInWYSIWYG() {
        let result = process("<u>text</u>")
        // "<u>" at positions 0-2 should have clear foreground color
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.clear)
        // "</u>" at positions 7-10 should also be clear
        let closeColor = result.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor
        XCTAssertEqual(closeColor, NSColor.clear)
    }

    // MARK: - Edge Cases

    func test_emptyTag() {
        // Should not crash
        let result = process("<kbd></kbd>")
        XCTAssertNotNil(result)
    }

    func test_unclosedTag() {
        // Should not crash or apply styling
        let result = process("<mark>no close tag")
        let bg = result.attribute(.backgroundColor, at: 6, effectiveRange: nil) as? NSColor
        XCTAssertNil(bg) // No match since tag isn't closed
    }

    func test_multipleTagsSameLine() {
        let result = process("<u>one</u> and <kbd>two</kbd>")
        // "<u>" = 3, "one" at index 3, "</u>" at 6, " and " at 10, "<kbd>" at 15, "two" at 20
        let ulValue = result.attribute(.underlineStyle, at: 3, effectiveRange: nil) as? Int
        XCTAssertEqual(ulValue, NSUnderlineStyle.single.rawValue)
        let kbdValue = result.attribute(.kbdTag, at: 20, effectiveRange: nil)
        XCTAssertNotNil(kbdValue)
    }
}
