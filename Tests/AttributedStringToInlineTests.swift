//
//  AttributedStringToInlineTests.swift
//  FSNotesTests
//
//  Contract tests for `InlineRenderer.inlineTreeFromAttributedString`
//  — the inverse of `InlineRenderer.render`. Stage 3 of the
//  InlineTableView refactor routes cell editing through this
//  converter: the field editor is populated with a rendered
//  attributed string (no markers, formatting as attributes), and on
//  every keystroke the converter walks the runs and rebuilds the
//  inline tree that gets pushed back into the Document.
//
//  This file exists to make that converter testable as a pure
//  function on value types — CLAUDE.md rule 3. No NSWindow, no
//  field editor, no AppKit UI — just `NSAttributedString` values
//  and `[Inline]` assertions.
//
//  The core round-trip contract:
//     inlineTree(from: render(x, baseAttrs: ...)) == x
//  must hold for every formatting combination we support in cells.
//

import XCTest
@testable import FSNotes

class AttributedStringToInlineTests: XCTestCase {

    // MARK: - Base setup

    private let body: NSFont = NSFont.systemFont(ofSize: 14)
    private var boldAttrs: [NSAttributedString.Key: Any] = [:]
    private var italicAttrs: [NSAttributedString.Key: Any] = [:]
    private var baseAttrs: [NSAttributedString.Key: Any] = [:]

    override func setUp() {
        super.setUp()
        baseAttrs = [.font: body, .foregroundColor: NSColor.textColor]
        let bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        boldAttrs = [.font: bold]
        italicAttrs = [.font: italic]
    }

    /// Simulates the widget's rendering pipeline: `InlineRenderer`
    /// produces an attributed string where `.rawHTML("<br>")` emits
    /// literal `<br>` text, then the widget post-processes the result
    /// to replace `<br>` with `\n` (so the cell displays as multi-line).
    /// The converter operates on the post-processed attributed string —
    /// `\n` characters become `.rawHTML("<br>")` nodes on the way back.
    private func render(_ tree: [Inline]) -> NSAttributedString {
        let raw = InlineRenderer.render(tree, baseAttributes: baseAttrs, note: nil)
        let mutable = NSMutableAttributedString(attributedString: raw)
        var searchStart = 0
        while searchStart < mutable.length {
            let searchRange = NSRange(location: searchStart, length: mutable.length - searchStart)
            let brRange = (mutable.string as NSString).range(
                of: "<br>", options: [.caseInsensitive], range: searchRange)
            if brRange.location == NSNotFound { break }
            mutable.replaceCharacters(in: brRange, with: "\n")
            searchStart = brRange.location + 1
        }
        return mutable
    }

    /// Thin helper so every test's assertion looks the same.
    private func roundTrip(_ tree: [Inline], file: StaticString = #filePath, line: UInt = #line) {
        let rendered = render(tree)
        let recovered = InlineRenderer.inlineTreeFromAttributedString(rendered)
        XCTAssertEqual(
            recovered, tree,
            "round-trip failed\nexpected: \(tree)\n got:     \(recovered)\nrendered string: '\(rendered.string)'",
            file: file, line: line
        )
    }

    // MARK: - Trivial cases

    func test_empty() {
        roundTrip([])
    }

    func test_plainText() {
        roundTrip([.text("hello")])
    }

    func test_plainText_withSpaces() {
        roundTrip([.text("the quick brown fox")])
    }

    // MARK: - Single-trait inline formatting

    func test_bold() {
        roundTrip([.bold([.text("bold")])])
    }

    func test_italic() {
        roundTrip([.italic([.text("italic")])])
    }

    func test_strikethrough() {
        roundTrip([.strikethrough([.text("gone")])])
    }

    func test_underline() {
        roundTrip([.underline([.text("hello")])])
    }

    func test_highlight() {
        roundTrip([.highlight([.text("yellow")])])
    }

    func test_code() {
        roundTrip([.code("let x = 1")])
    }

    // MARK: - Text + trait combinations

    func test_plain_then_bold() {
        roundTrip([.text("hello "), .bold([.text("world")])])
    }

    func test_bold_then_plain() {
        roundTrip([.bold([.text("hello")]), .text(" world")])
    }

    func test_plain_bold_plain() {
        roundTrip([
            .text("the "),
            .bold([.text("quick")]),
            .text(" brown fox")
        ])
    }

    func test_bold_and_italic_adjacent() {
        roundTrip([
            .bold([.text("bold")]),
            .text(" "),
            .italic([.text("italic")])
        ])
    }

    // MARK: - Nested traits

    func test_boldItalic_nested_bold_outer() {
        // **bold _italic_** → .bold([.italic([.text("italic")])])
        roundTrip([.bold([.italic([.text("italic")])])])
    }

    func test_boldItalic_nested_mixed() {
        // **bold _italic_ more bold**
        roundTrip([
            .bold([
                .text("bold "),
                .italic([.text("italic")]),
                .text(" more bold")
            ])
        ])
    }

    // MARK: - Multi-line content (the `<br>` → `\n` path)

    func test_plainText_withNewline() {
        // Cells store multi-line as `<br>` which Stage 2 post-processes
        // to `\n` in the rendered string. The converter must turn the
        // newline back into a `<br>` raw-html node so round-trip holds.
        roundTrip([.text("line1"), .rawHTML("<br>"), .text("line2")])
    }

    // MARK: - Link

    func test_link_plain() {
        roundTrip([.link(text: [.text("Google")], rawDestination: "https://google.com")])
    }

    // MARK: - Cell-shaped composites

    func test_sentence_with_bold_word() {
        roundTrip([
            .text("Be "),
            .bold([.text("bold")])
        ])
    }

    func test_sentence_with_italic_word() {
        roundTrip([
            .text("be "),
            .italic([.text("italics")])
        ])
    }

    func test_sentence_with_highlight_word() {
        roundTrip([
            .text("Be "),
            .highlight([.text("high")])
        ])
    }

    func test_sentence_with_strike_word() {
        roundTrip([
            .text("be "),
            .strikethrough([.text("strikethrough")])
        ])
    }

    func test_sentence_with_underline_word() {
        roundTrip([
            .text("be "),
            .underline([.text("under")])
        ])
    }

    // MARK: - Edge cases

    func test_literal_asterisk_survives() {
        // A user typing a bare `*` in a cell produces an attributed
        // string with a single plain `*` character. The converter
        // should emit `.text("*")`. No italic, no fancy interpretation.
        // (The serializer/parser round-trip later is where `*text*`
        // becomes italic — that's a property of markdown parsing,
        // not of the converter.)
        let attr = NSAttributedString(string: "*", attributes: baseAttrs)
        let recovered = InlineRenderer.inlineTreeFromAttributedString(attr)
        XCTAssertEqual(recovered, [.text("*")])
    }

    func test_completely_empty_attributed_string() {
        let attr = NSAttributedString(string: "", attributes: baseAttrs)
        let recovered = InlineRenderer.inlineTreeFromAttributedString(attr)
        XCTAssertEqual(recovered, [])
    }
}
