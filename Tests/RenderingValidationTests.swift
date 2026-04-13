//
//  RenderingValidationTests.swift
//  FSNotesTests
//
//  Comprehensive rendering validation: verifies BOTH the HTML output
//  (via CommonMarkHTMLRenderer) AND NSAttributedString attributes
//  (via DocumentProjection) for every major block and inline type.
//

import XCTest
@testable import FSNotes

class RenderingValidationTests: XCTestCase {

    // MARK: - Helpers

    private let baseFontSize: CGFloat = 14

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: baseFontSize)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
    }

    private func parse(_ md: String) -> Document {
        return MarkdownParser.parse(md)
    }

    private func html(_ md: String) -> String {
        let doc = parse(md)
        return CommonMarkHTMLRenderer.render(doc)
    }

    private func project(_ md: String) -> DocumentProjection {
        let doc = parse(md)
        return DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
    }

    /// Find the first range in the attributed string matching `substring`
    /// and return its attributes.
    private func attributes(
        in projection: DocumentProjection,
        at substring: String
    ) -> [NSAttributedString.Key: Any]? {
        let str = projection.attributed
        guard let range = str.string.range(of: substring) else { return nil }
        let nsRange = NSRange(range, in: str.string)
        guard nsRange.location < str.length else { return nil }
        return str.attributes(at: nsRange.location, effectiveRange: nil)
    }

    /// Extract the font from attributes at a given substring.
    private func font(
        in projection: DocumentProjection,
        at substring: String
    ) -> PlatformFont? {
        return attributes(in: projection, at: substring)?[.font] as? PlatformFont
    }

    // MARK: - Headings

    func testHeading1_HTML() {
        let output = html("# Title\n")
        XCTAssertTrue(output.contains("<h1>Title</h1>"), "H1 should render as <h1>: \(output)")
    }

    func testHeading2_HTML() {
        let output = html("## Subtitle\n")
        XCTAssertTrue(output.contains("<h2>Subtitle</h2>"), "H2 should render as <h2>: \(output)")
    }

    func testHeading3_HTML() {
        let output = html("### Section\n")
        XCTAssertTrue(output.contains("<h3>Section</h3>"), "H3 should render as <h3>: \(output)")
    }

    func testHeading1_AttributedString() {
        let proj = project("# Title\n")
        let f = font(in: proj, at: "Title")
        XCTAssertNotNil(f, "Heading should have a font")
        // H1 is body size * 2.0
        let expectedSize = baseFontSize * 2.0
        XCTAssertEqual(f!.pointSize, expectedSize, accuracy: 0.5,
                       "H1 font size should be \(expectedSize), got \(f!.pointSize)")
        #if os(OSX)
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.bold),
                      "H1 font should be bold")
        #endif
    }

    func testHeading2_AttributedString() {
        let proj = project("## Subtitle\n")
        let f = font(in: proj, at: "Subtitle")
        XCTAssertNotNil(f)
        let expectedSize = baseFontSize * 1.7
        XCTAssertEqual(f!.pointSize, expectedSize, accuracy: 0.5,
                       "H2 font size should be \(expectedSize)")
    }

    func testHeadingWithInlineFormatting_HTML() {
        let output = html("# **Bold** Title\n")
        XCTAssertTrue(output.contains("<h1>"), "Should have <h1>")
        XCTAssertTrue(output.contains("<strong>Bold</strong>"),
                      "Bold inside heading should render as <strong>")
    }

    // MARK: - Bold / Italic / Strikethrough

    func testBold_HTML() {
        let output = html("**bold text**\n")
        XCTAssertTrue(output.contains("<strong>bold text</strong>"),
                      "Bold should render as <strong>: \(output)")
    }

    func testBold_AttributedString() {
        let proj = project("**bold text**\n")
        let f = font(in: proj, at: "bold text")
        XCTAssertNotNil(f, "Bold text should have a font")
        #if os(OSX)
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.bold),
                      "Bold text should have bold trait")
        #endif
    }

    func testItalic_HTML() {
        let output = html("*italic text*\n")
        XCTAssertTrue(output.contains("<em>italic text</em>"),
                      "Italic should render as <em>: \(output)")
    }

    func testItalic_AttributedString() {
        let proj = project("*italic text*\n")
        let f = font(in: proj, at: "italic text")
        XCTAssertNotNil(f)
        #if os(OSX)
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.italic),
                      "Italic text should have italic trait")
        #endif
    }

    func testBoldItalic_HTML() {
        let output = html("***bold italic***\n")
        XCTAssertTrue(output.contains("<strong><em>bold italic</em></strong>") ||
                      output.contains("<em><strong>bold italic</strong></em>"),
                      "Bold+italic should render with both tags: \(output)")
    }

    func testBoldItalic_AttributedString() {
        let proj = project("***bold italic***\n")
        let f = font(in: proj, at: "bold italic")
        XCTAssertNotNil(f)
        #if os(OSX)
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.bold),
                      "Bold-italic text should have bold trait")
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.italic),
                      "Bold-italic text should have italic trait")
        #endif
    }

    func testStrikethrough_HTML() {
        let output = html("~~deleted~~\n")
        XCTAssertTrue(output.contains("<del>deleted</del>"),
                      "Strikethrough should render as <del>: \(output)")
    }

    func testStrikethrough_AttributedString() {
        let proj = project("~~deleted~~\n")
        let attrs = attributes(in: proj, at: "deleted")
        XCTAssertNotNil(attrs)
        let strikeStyle = attrs?[.strikethroughStyle] as? Int
        XCTAssertNotNil(strikeStyle, "Strikethrough text should have strikethroughStyle attribute")
        XCTAssertEqual(strikeStyle, NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Inline Code

    func testInlineCode_HTML() {
        let output = html("Use `print()` here\n")
        XCTAssertTrue(output.contains("<code>print()</code>"),
                      "Inline code should render as <code>: \(output)")
    }

    func testInlineCode_AttributedString() {
        let proj = project("Use `print()` here\n")
        let f = font(in: proj, at: "print()")
        XCTAssertNotNil(f, "Inline code should have a font")
        #if os(OSX)
        XCTAssertTrue(f!.isFixedPitch, "Inline code font should be monospaced")
        #endif
    }

    // MARK: - Code Blocks

    func testFencedCodeBlock_HTML() {
        let md = "```python\nprint('hello')\n```\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<pre>"), "Code block should have <pre>: \(output)")
        XCTAssertTrue(output.contains("<code"), "Code block should have <code>: \(output)")
        XCTAssertTrue(output.contains("class=\"language-python\""),
                      "Code block should have language class: \(output)")
        XCTAssertTrue(output.contains("print(&#39;hello&#39;)") ||
                      output.contains("print('hello')"),
                      "Code block should contain the code: \(output)")
    }

    func testFencedCodeBlock_AttributedString() {
        let proj = project("```python\nprint('hello')\n```\n")
        let f = font(in: proj, at: "print")
        XCTAssertNotNil(f, "Code block content should have a font")
        #if os(OSX)
        XCTAssertTrue(f!.isFixedPitch, "Code block font should be monospaced")
        #endif
    }

    func testFencedCodeBlockNoLanguage_HTML() {
        let md = "```\nsome code\n```\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<pre><code>"), "Plain code block: \(output)")
        XCTAssertTrue(output.contains("some code"), "Should contain code text")
    }

    // MARK: - Mermaid Code Blocks

    func testMermaidCodeBlock_HTML() {
        let md = "```mermaid\ngraph TD\nA-->B\n```\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<pre>"), "Mermaid block should have <pre>")
        XCTAssertTrue(output.contains("graph TD"), "Mermaid source should be in output")
    }

    func testMermaidCodeBlock_AttributedString() {
        let proj = project("```mermaid\ngraph TD\nA-->B\n```\n")
        let f = font(in: proj, at: "graph TD")
        XCTAssertNotNil(f, "Mermaid block should have a font")
        #if os(OSX)
        XCTAssertTrue(f!.isFixedPitch, "Mermaid block should use monospace font")
        #endif
    }

    // MARK: - Math Code Blocks

    func testMathCodeBlock_HTML() {
        let md = "```math\nE=mc^2\n```\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<pre>"), "Math block should have <pre>")
        XCTAssertTrue(output.contains("E=mc^2"), "Math source should be in output")
    }

    func testMathCodeBlock_AttributedString() {
        let proj = project("```math\nE=mc^2\n```\n")
        let f = font(in: proj, at: "E=mc^2")
        XCTAssertNotNil(f, "Math block should have a font")
        #if os(OSX)
        XCTAssertTrue(f!.isFixedPitch, "Math block should use monospace font")
        #endif
    }

    // MARK: - Inline Math

    func testInlineMath_AttributedString() {
        let proj = project("The equation $x^2$ is simple\n")
        let f = font(in: proj, at: "x^2")
        XCTAssertNotNil(f, "Inline math should have a font")
        #if os(OSX)
        XCTAssertTrue(f!.isFixedPitch, "Inline math should use monospace font")
        XCTAssertTrue(f!.fontDescriptor.symbolicTraits.contains(.italic),
                      "Inline math should be italic")
        #endif

        let attrs = attributes(in: proj, at: "x^2")
        #if os(OSX)
        let color = attrs?[.foregroundColor] as? NSColor
        XCTAssertNotNil(color, "Inline math should have a foreground color")
        XCTAssertEqual(color, NSColor.systemPurple, "Inline math should be purple")
        #endif

        // Verify the .inlineMathSource marker attribute is set — this is
        // what renderInlineMathViaBlockModel() enumerates to find spans
        // that need MathJax rendering.
        let mathSource = attrs?[.inlineMathSource] as? String
        XCTAssertEqual(mathSource, "x^2",
                       "Inline math should carry .inlineMathSource attribute with the LaTeX content")
    }

    // MARK: - Images

    func testImage_HTML() {
        let output = html("![alt text](image.png)\n")
        XCTAssertTrue(output.contains("<img"), "Image should render as <img>: \(output)")
        XCTAssertTrue(output.contains("alt=\"alt text\""),
                      "Image should have alt attribute: \(output)")
        XCTAssertTrue(output.contains("src=\"image.png\""),
                      "Image should have src attribute: \(output)")
    }

    func testImage_AttributedString_FallbackToAltText() {
        // Without a Note, images fall back to rendering alt text
        let proj = project("![alt text](image.png)\n")
        let str = proj.attributed.string
        // Should contain the alt text since there's no note to resolve the path
        XCTAssertTrue(str.contains("alt text"),
                      "Without a note, image should render as alt text: \(str)")
    }

    // MARK: - Links

    func testLink_HTML() {
        let output = html("[click here](https://example.com)\n")
        XCTAssertTrue(output.contains("<a href=\"https://example.com\">click here</a>"),
                      "Link should render as <a>: \(output)")
    }

    func testLink_AttributedString() {
        let proj = project("[click here](https://example.com)\n")
        let attrs = attributes(in: proj, at: "click here")
        XCTAssertNotNil(attrs, "Link text should have attributes")
        let linkValue = attrs?[.link]
        XCTAssertNotNil(linkValue, "Link text should have .link attribute")
        if let url = linkValue as? URL {
            XCTAssertEqual(url.absoluteString, "https://example.com")
        } else if let str = linkValue as? String {
            XCTAssertEqual(str, "https://example.com")
        } else {
            XCTFail("Link attribute should be URL or String, got: \(String(describing: linkValue))")
        }
    }

    func testLinkWithFormatting_HTML() {
        let output = html("[**bold link**](https://example.com)\n")
        XCTAssertTrue(output.contains("<a href="), "Should have link: \(output)")
        XCTAssertTrue(output.contains("<strong>bold link</strong>"),
                      "Bold inside link: \(output)")
    }

    // MARK: - Autolinks

    func testAutolink_HTML() {
        let output = html("<https://example.com>\n")
        XCTAssertTrue(output.contains("<a href=\"https://example.com\">"),
                      "Autolink should render as <a>: \(output)")
    }

    func testAutolink_AttributedString() {
        let proj = project("<https://example.com>\n")
        let attrs = attributes(in: proj, at: "https://example.com")
        XCTAssertNotNil(attrs)
        let linkValue = attrs?[.link]
        XCTAssertNotNil(linkValue, "Autolink should have .link attribute")
    }

    // MARK: - Lists

    func testUnorderedList_HTML() {
        let md = "- item one\n- item two\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<ul>"), "UL list should have <ul>: \(output)")
        XCTAssertTrue(output.contains("<li>"), "UL list should have <li>: \(output)")
        XCTAssertTrue(output.contains("item one"), "Should contain item text")
        XCTAssertTrue(output.contains("item two"), "Should contain item text")
    }

    func testOrderedList_HTML() {
        let md = "1. first\n2. second\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<ol>"), "OL list should have <ol>: \(output)")
        XCTAssertTrue(output.contains("<li>"), "OL list should have <li>: \(output)")
    }

    func testUnorderedList_AttributedString() {
        let proj = project("- item one\n- item two\n")
        let str = proj.attributed.string
        XCTAssertTrue(str.contains("item one"), "List item text should appear: \(str)")
        XCTAssertTrue(str.contains("item two"), "List item text should appear: \(str)")

        // Check paragraph style has indent
        let attrs = attributes(in: proj, at: "item one")
        XCTAssertNotNil(attrs)
        #if os(OSX)
        if let paraStyle = attrs?[.paragraphStyle] as? NSParagraphStyle {
            XCTAssertGreaterThan(paraStyle.headIndent, 0,
                                "List items should have head indent > 0")
        }
        #endif
    }

    func testTodoList_HTML() {
        let md = "- [ ] unchecked\n- [x] checked\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<li>"), "Todo list should have <li>")
        XCTAssertTrue(output.contains("unchecked"), "Should contain todo text")
        XCTAssertTrue(output.contains("checked"), "Should contain todo text")
    }

    func testTodoList_AttributedString() {
        let proj = project("- [ ] unchecked\n- [x] checked\n")
        let str = proj.attributed.string
        XCTAssertTrue(str.contains("unchecked"), "Todo item text: \(str)")
        XCTAssertTrue(str.contains("checked"), "Todo item text: \(str)")
    }

    // MARK: - Blockquotes

    func testBlockquote_HTML() {
        let md = "> quoted text\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<blockquote>"),
                      "Blockquote should have <blockquote>: \(output)")
        XCTAssertTrue(output.contains("quoted text"), "Should contain text")
    }

    func testBlockquote_AttributedString() {
        let proj = project("> quoted text\n")
        let str = proj.attributed.string
        XCTAssertTrue(str.contains("quoted text"), "Blockquote text should appear: \(str)")

        let attrs = attributes(in: proj, at: "quoted text")
        XCTAssertNotNil(attrs)
        #if os(OSX)
        if let paraStyle = attrs?[.paragraphStyle] as? NSParagraphStyle {
            XCTAssertGreaterThan(paraStyle.headIndent, 0,
                                "Blockquote should have head indent > 0")
        }
        #endif
    }

    func testNestedBlockquote_HTML() {
        let md = "> > nested\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<blockquote>"),
                      "Nested blockquote should have <blockquote>: \(output)")
    }

    // MARK: - Horizontal Rules

    func testHorizontalRule_HTML() {
        let md = "---\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<hr"), "HR should render as <hr>: \(output)")
    }

    func testHorizontalRuleVariants_HTML() {
        for marker in ["---\n", "***\n", "___\n"] {
            let output = html(marker)
            XCTAssertTrue(output.contains("<hr"),
                          "\(marker.trimmingCharacters(in: .newlines)) should render as <hr>: \(output)")
        }
    }

    func testHorizontalRule_AttributedString() {
        let proj = project("---\n")
        // HR renders as a special character or empty block
        XCTAssertGreaterThan(proj.attributed.length, 0,
                             "HR should produce some attributed content")
    }

    // MARK: - Tables

    func testTable_HTML() {
        let md = "| Header 1 | Header 2 |\n| --- | --- |\n| cell 1 | cell 2 |\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<table>"), "Table should have <table>: \(output)")
        XCTAssertTrue(output.contains("<th>"), "Table should have <th>: \(output)")
        XCTAssertTrue(output.contains("<td>"), "Table should have <td>: \(output)")
        XCTAssertTrue(output.contains("Header 1"), "Should contain header text")
        XCTAssertTrue(output.contains("cell 1"), "Should contain cell text")
    }

    func testTableAlignment_HTML() {
        let md = "| Left | Center | Right |\n| :--- | :---: | ---: |\n| a | b | c |\n"
        let output = html(md)
        XCTAssertTrue(output.contains("align=\"left\"") || output.contains("<td>a"),
                      "Left-aligned column: \(output)")
        XCTAssertTrue(output.contains("align=\"center\"") || output.contains("center"),
                      "Center-aligned column: \(output)")
        XCTAssertTrue(output.contains("align=\"right\"") || output.contains("right"),
                      "Right-aligned column: \(output)")
    }

    // MARK: - Mixed Content

    func testParagraphWithMultipleInlines_HTML() {
        let md = "Hello **bold** and *italic* and `code` world\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<p>"), "Should be a paragraph")
        XCTAssertTrue(output.contains("<strong>bold</strong>"), "Bold")
        XCTAssertTrue(output.contains("<em>italic</em>"), "Italic")
        XCTAssertTrue(output.contains("<code>code</code>"), "Code")
        XCTAssertTrue(output.contains("Hello"), "Plain text before")
        XCTAssertTrue(output.contains("world"), "Plain text after")
    }

    func testParagraphWithMultipleInlines_AttributedString() {
        let proj = project("Hello **bold** and *italic* and `code` world\n")
        let str = proj.attributed.string
        // All visible text should be present, no markdown markers
        XCTAssertTrue(str.contains("Hello"), "Plain text")
        XCTAssertTrue(str.contains("bold"), "Bold text")
        XCTAssertTrue(str.contains("italic"), "Italic text")
        XCTAssertTrue(str.contains("code"), "Code text")
        XCTAssertTrue(str.contains("world"), "Trailing text")
        XCTAssertFalse(str.contains("**"), "No bold markers in rendered string")
        XCTAssertFalse(str.contains("`"), "No code markers in rendered string")

        // Verify each inline has correct font traits
        #if os(OSX)
        let boldFont = font(in: proj, at: "bold")
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let italicFont = font(in: proj, at: "italic")
        XCTAssertTrue(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)

        let codeFont = font(in: proj, at: "code")
        XCTAssertTrue(codeFont?.isFixedPitch == true)
        #endif
    }

    // MARK: - Blank Lines and Paragraphs

    func testMultipleParagraphs_HTML() {
        let md = "First paragraph\n\nSecond paragraph\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<p>First paragraph</p>"), "First para: \(output)")
        XCTAssertTrue(output.contains("<p>Second paragraph</p>"), "Second para: \(output)")
    }

    func testMultipleParagraphs_AttributedString() {
        let proj = project("First paragraph\n\nSecond paragraph\n")
        let str = proj.attributed.string
        XCTAssertTrue(str.contains("First paragraph"))
        XCTAssertTrue(str.contains("Second paragraph"))
    }

    // MARK: - Edge Cases

    func testEmptyDocument() {
        let doc = parse("")
        let output = CommonMarkHTMLRenderer.render(doc)
        // Empty doc should produce empty or minimal output
        XCTAssertTrue(output.isEmpty || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "Empty doc should produce empty HTML: \(output)")
    }

    func testOnlyWhitespace() {
        let proj = project("   \n")
        // Should not crash and should produce some output
        XCTAssertTrue(proj.attributed.length >= 0)
    }

    func testHeadingFollowedByParagraph_HTML() {
        let md = "# Title\n\nSome text\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<h1>Title</h1>"), "Heading: \(output)")
        XCTAssertTrue(output.contains("<p>Some text</p>"), "Paragraph: \(output)")
    }

    func testHeadingFollowedByParagraph_AttributedString() {
        let proj = project("# Title\n\nSome text\n")
        let titleFont = font(in: proj, at: "Title")
        let bodyTextFont = font(in: proj, at: "Some text")
        XCTAssertNotNil(titleFont)
        XCTAssertNotNil(bodyTextFont)
        XCTAssertGreaterThan(titleFont!.pointSize, bodyTextFont!.pointSize,
                             "Heading font should be larger than body font")
    }

    // MARK: - HTML Blocks

    func testHTMLBlock_HTML() {
        let md = "<div>\nhello\n</div>\n"
        let output = html(md)
        XCTAssertTrue(output.contains("<div>"), "HTML block should pass through: \(output)")
    }

    // MARK: - HTML and Attributed String Agreement
    //
    // These tests verify that HTML rendering and NSAttributedString rendering
    // agree on what text is visible and that markdown markers are stripped.

    func testHTMLAndAttributedStringAgree_Heading() {
        let md = "# Agreement Test\n"
        let output = html(md)
        let proj = project(md)
        // Both should contain the text
        XCTAssertTrue(output.contains("Agreement Test"))
        XCTAssertTrue(proj.attributed.string.contains("Agreement Test"))
    }

    func testHTMLAndAttributedStringAgree_Bold() {
        let md = "**agreement**\n"
        let output = html(md)
        let proj = project(md)
        // HTML has the text, attributed string has the text without markers
        XCTAssertTrue(output.contains("agreement"))
        XCTAssertTrue(proj.attributed.string.contains("agreement"))
        XCTAssertFalse(proj.attributed.string.contains("**"),
                       "Attributed string should not contain markdown markers")
    }

    func testHTMLAndAttributedStringAgree_CodeBlock() {
        let md = "```\ncode here\n```\n"
        let output = html(md)
        let proj = project(md)
        XCTAssertTrue(output.contains("code here"))
        XCTAssertTrue(proj.attributed.string.contains("code here"))
        XCTAssertFalse(proj.attributed.string.contains("```"),
                       "Attributed string should not contain fence markers")
    }

    func testHTMLAndAttributedStringAgree_List() {
        let md = "- apple\n- banana\n"
        let output = html(md)
        let proj = project(md)
        XCTAssertTrue(output.contains("apple"))
        XCTAssertTrue(output.contains("banana"))
        XCTAssertTrue(proj.attributed.string.contains("apple"))
        XCTAssertTrue(proj.attributed.string.contains("banana"))
    }

    func testHTMLAndAttributedStringAgree_Link() {
        let md = "[visit](https://example.com)\n"
        let output = html(md)
        let proj = project(md)
        XCTAssertTrue(output.contains("visit"))
        XCTAssertTrue(proj.attributed.string.contains("visit"))
        XCTAssertFalse(proj.attributed.string.contains("["),
                       "No link markers in rendered string")
        XCTAssertFalse(proj.attributed.string.contains("]("),
                       "No link markers in rendered string")
    }
}
