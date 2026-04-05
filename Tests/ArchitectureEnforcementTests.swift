//
//  ArchitectureEnforcementTests.swift
//  FSNotesTests
//
//  TRIPWIRE TESTS: These tests fail the build if the rendering pipeline
//  violates the architectural invariants of the block-model migration.
//
//  The invariants (see /Users/guido/.claude/plans/floofy-growing-thacker.md):
//
//    1. No `.kern`-based width collapse. Rendered output MUST NOT contain
//       any character with a negative `.kern` attribute.
//    2. No clear-color hiding. Rendered output MUST NOT contain any
//       character with `.foregroundColor == Color.clear`.
//    3. No markdown syntax in storage. Rendered output MUST NOT contain
//       markdown marker characters whose semantic role was consumed by the
//       parser (fences, leading '#', leading list markers, bold/italic
//       pairs, etc.).
//    4. Idempotence. Rendering the same input twice must produce byte-equal
//       attributed strings. The renderer is a pure function of the block
//       model.
//
//  Any new renderer MUST extend this file with its own enforcement checks.
//  Violating any of these invariants is an architectural regression, not
//  a cosmetic bug. These checks run on every PR.
//

import XCTest
#if os(OSX)
import AppKit
#else
import UIKit
#endif
@testable import FSNotes

class ArchitectureEnforcementTests: XCTestCase {

    // MARK: - Fixtures

    /// Code-block fixtures used by the enforcement tests. Every new renderer
    /// should append its own fixtures to exercise this test matrix.
    private static let codeBlockFixtures: [(name: String, lang: String?, content: String)] = [
        ("empty", nil, ""),
        ("noLang_oneLine", nil, "foo"),
        ("noLang_multi", nil, "foo\nbar\nbaz"),
        ("python", "python", "print('hello')"),
        ("swift", "swift", "let x = 1\nlet y = 2"),
        ("unknownLang", "brainfuck", "++[>+<-]"),
        ("contentWithBackticks", nil, "inline `code` inside block"),
        ("contentWithFenceLookalike", nil, "not ``` a real fence"),
        ("contentWithHashes", nil, "# not a heading"),
        ("contentWithAsterisks", nil, "**not bold**"),
        ("contentBlankLines", nil, "line1\n\nline3"),
    ]

    private func codeFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }

    // MARK: - Invariant 1: No kern hiding

    func test_codeBlockRenderer_noNegativeKern() {
        for fixture in Self.codeBlockFixtures {
            let rendered = CodeBlockRenderer.render(
                language: fixture.lang,
                content: fixture.content,
                codeFont: codeFont()
            )
            assertNoNegativeKern(rendered, fixture: fixture.name)
        }
    }

    private func assertNoNegativeKern(
        _ str: NSAttributedString,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.kern, in: full, options: []) { value, range, _ in
            guard let kern = value as? NSNumber else { return }
            if kern.doubleValue < 0 {
                XCTFail(
                    "ARCHITECTURE VIOLATION [\(fixture)]: negative .kern (\(kern)) at range \(range). " +
                    "The rendered output must not use kern-based width collapse to hide characters. " +
                    "If characters should not appear, do not put them in the rendered string.",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Invariant 2: No clear-color hiding

    func test_codeBlockRenderer_noClearForeground() {
        for fixture in Self.codeBlockFixtures {
            let rendered = CodeBlockRenderer.render(
                language: fixture.lang,
                content: fixture.content,
                codeFont: codeFont()
            )
            assertNoClearForeground(rendered, fixture: fixture.name)
        }
    }

    private func assertNoClearForeground(
        _ str: NSAttributedString,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let full = NSRange(location: 0, length: str.length)
        str.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let color = value as? PlatformColor else { return }
            // Detect clear via alpha channel (robust across Color.clear equivalents).
            var alpha: CGFloat = 0
            #if os(OSX)
            // NSColor requires a compatible color space for getRed; use the
            // sRGB conversion and guard against color-space mismatch.
            if let srgb = color.usingColorSpace(.sRGB) {
                alpha = srgb.alphaComponent
            } else {
                return
            }
            #else
            color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            #endif
            if alpha == 0 {
                XCTFail(
                    "ARCHITECTURE VIOLATION [\(fixture)]: clear foregroundColor at range \(range). " +
                    "The rendered output must not hide characters by making them transparent. " +
                    "If characters should not appear, do not put them in the rendered string.",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Invariant 3: No markdown syntax in storage

    func test_codeBlockRenderer_containsNoFenceCharacters() {
        // The rendered code block must contain ONLY the raw content string.
        // No fences, no language tag, no markers added by the renderer.
        for fixture in Self.codeBlockFixtures {
            let rendered = CodeBlockRenderer.render(
                language: fixture.lang,
                content: fixture.content,
                codeFont: codeFont()
            )
            XCTAssertEqual(
                rendered.string, fixture.content,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered .string diverges from raw content. " +
                "Parser markers (fences, lang tags) must not appear in the rendered output. " +
                "expected content: \(quoted(fixture.content)) | rendered: \(quoted(rendered.string))"
            )
        }
    }

    func test_codeBlockRenderer_stringEqualsContent_evenWhenContentLooksLikeMarkdown() {
        // Content that LOOKS like markdown (e.g. "# heading" or "**bold**")
        // must pass through as plain code text. The renderer does not re-parse
        // code-block content as markdown.
        let treacherous = "# not a heading\n**not bold**\n```nested```"
        let rendered = CodeBlockRenderer.render(
            language: nil,
            content: treacherous,
            codeFont: codeFont()
        )
        XCTAssertEqual(rendered.string, treacherous)
    }

    // MARK: - Invariant 4: Idempotence

    func test_codeBlockRenderer_isIdempotent() {
        for fixture in Self.codeBlockFixtures {
            let a = CodeBlockRenderer.render(
                language: fixture.lang,
                content: fixture.content,
                codeFont: codeFont()
            )
            let b = CodeBlockRenderer.render(
                language: fixture.lang,
                content: fixture.content,
                codeFont: codeFont()
            )
            XCTAssertEqual(
                a, b,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: render is not idempotent. " +
                "The renderer must be a pure function of its inputs."
            )
        }
    }

    // MARK: - Heading fixtures + invariants

    /// Heading fixtures. Every new block-level renderer appends its own
    /// fixtures here and verifies the SAME four invariants against its
    /// rendered output.
    private static let headingFixtures: [(name: String, level: Int, suffix: String)] = [
        ("h1_simple", 1, " Hello"),
        ("h2_simple", 2, " Hello"),
        ("h3_simple", 3, " Hello"),
        ("h4_simple", 4, " Hello"),
        ("h5_simple", 5, " Hello"),
        ("h6_simple", 6, " Hello"),
        ("h1_extraSpaces", 1, "  Extra  "),
        ("h1_empty", 1, ""),
        ("h1_onlySpace", 1, " "),
        ("h1_withHashInContent", 1, " the # symbol is fine here"),
        ("h1_withMarkdownLookalike", 1, " **not bold**"),
    ]

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }

    func test_headingRenderer_noNegativeKern() {
        for fixture in Self.headingFixtures {
            let rendered = HeadingRenderer.render(
                level: fixture.level,
                suffix: fixture.suffix,
                bodyFont: bodyFont()
            )
            assertNoNegativeKern(rendered, fixture: fixture.name)
        }
    }

    func test_headingRenderer_noClearForeground() {
        for fixture in Self.headingFixtures {
            let rendered = HeadingRenderer.render(
                level: fixture.level,
                suffix: fixture.suffix,
                bodyFont: bodyFont()
            )
            assertNoClearForeground(rendered, fixture: fixture.name)
        }
    }

    func test_headingRenderer_containsNoHashCharacters() {
        // The rendered heading must contain ONLY the trimmed displayed
        // text. No `#` characters, no leading/trailing whitespace from
        // the source line.
        for fixture in Self.headingFixtures {
            let rendered = HeadingRenderer.render(
                level: fixture.level,
                suffix: fixture.suffix,
                bodyFont: bodyFont()
            )
            let expected = fixture.suffix.trimmingCharacters(in: .whitespaces)
            // rendered.string == trimmed(suffix) enforces that no
            // leading `#` markers leaked through the parser. Note that
            // `#` may legitimately appear inside body content (e.g.
            // "the # symbol is fine"); that is not a violation.
            XCTAssertEqual(
                rendered.string, expected,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered heading string diverges from trimmed suffix. " +
                "Heading `#` markers must not appear in the rendered output. " +
                "expected: \(quoted(expected)) | rendered: \(quoted(rendered.string))"
            )
        }
    }

    func test_headingRenderer_isIdempotent() {
        for fixture in Self.headingFixtures {
            let a = HeadingRenderer.render(
                level: fixture.level, suffix: fixture.suffix, bodyFont: bodyFont()
            )
            let b = HeadingRenderer.render(
                level: fixture.level, suffix: fixture.suffix, bodyFont: bodyFont()
            )
            XCTAssertEqual(
                a, b,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: heading render is not idempotent. " +
                "The renderer must be a pure function of its inputs."
            )
        }
    }

    func test_parseAndRender_headingsProduceStorageWithoutHashMarkers() {
        // Full tracer-bullet flow: parse markdown with headings, render
        // each heading block, verify NO `#` in the rendered output.
        let inputs = [
            "# Title\nbody\n",
            "## Subtitle\n",
            "# A\n## B\n### C\n",
            "# heading with # inside the text\n",
        ]
        for input in inputs {
            let doc = MarkdownParser.parse(input)
            for block in doc.blocks {
                guard case .heading(let level, let suffix) = block else { continue }
                let rendered = HeadingRenderer.render(
                    level: level, suffix: suffix, bodyFont: bodyFont()
                )
                // The trimmed content may legitimately contain `#` as
                // a text character (mid-string). But the rendered
                // output must NEVER begin with `#` — that would mean
                // the leading marker leaked through.
                if let firstChar = rendered.string.first {
                    XCTAssertNotEqual(
                        firstChar, "#",
                        "ARCHITECTURE VIOLATION: rendered heading from \(quoted(input)) begins with '#'. " +
                        "Leading `#` markers must be consumed by the parser."
                    )
                }
            }
        }
    }

    // MARK: - Paragraph / inline emphasis fixtures + invariants

    /// Inline emphasis fixtures. Each entry is the RAW source text that
    /// would appear in a paragraph (no trailing newline). The expected
    /// rendered string is computed by stripping `**` and `*` pairs
    /// from the source — this encodes the invariant that no emphasis
    /// markers may appear in the rendered output.
    private static let paragraphFixtures: [(name: String, source: String, expectedRendered: String)] = [
        ("plainText",       "hello world",            "hello world"),
        ("simpleBold",      "**bold**",               "bold"),
        ("simpleItalic",    "*italic*",               "italic"),
        ("boldInSentence",  "the **bold** word",      "the bold word"),
        ("italicInSentence","the *italic* word",      "the italic word"),
        ("twoBolds",        "**one** and **two**",    "one and two"),
        ("mixed",           "**b** and *i*",          "b and i"),
        ("mathMultiply",    "5 * 3 = 15",             "5 * 3 = 15"),
        ("unterminatedBold","**unterminated",         "**unterminated"),
        ("spacedAsterisks", "* x *",                  "* x *"),
        ("simpleCode",      "`code`",                 "code"),
        ("codeInSentence",  "use `foo` to bar",       "use foo to bar"),
        ("codeWithStars",   "`**not bold**`",         "**not bold**"),
        ("boldAroundCode",  "**a `b` c**",            "a b c"),
        ("loneBacktick",    "a ` b",                  "a ` b"),
    ]

    func test_paragraphRenderer_noNegativeKern() {
        for fixture in Self.paragraphFixtures {
            let inline = MarkdownParser.parseInlines(fixture.source)
            let rendered = ParagraphRenderer.render(
                inline: inline, bodyFont: bodyFont()
            )
            assertNoNegativeKern(rendered, fixture: fixture.name)
        }
    }

    func test_paragraphRenderer_noClearForeground() {
        for fixture in Self.paragraphFixtures {
            let inline = MarkdownParser.parseInlines(fixture.source)
            let rendered = ParagraphRenderer.render(
                inline: inline, bodyFont: bodyFont()
            )
            assertNoClearForeground(rendered, fixture: fixture.name)
        }
    }

    func test_paragraphRenderer_containsNoEmphasisMarkers() {
        // Architectural invariant: the rendered paragraph contains
        // ONLY the displayed text. Emphasis markers (`**`, `*`) that
        // the parser matched into bold/italic MUST be absent from the
        // rendered output. Unmatched markers (mathMultiply, spaced,
        // unterminated) legitimately remain as plain text — those
        // cases are listed with expectedRendered preserving them.
        for fixture in Self.paragraphFixtures {
            let inline = MarkdownParser.parseInlines(fixture.source)
            let rendered = ParagraphRenderer.render(
                inline: inline, bodyFont: bodyFont()
            )
            XCTAssertEqual(
                rendered.string, fixture.expectedRendered,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered paragraph diverges from expected. " +
                "Parser-consumed emphasis markers must not appear in rendered output. " +
                "source: \(quoted(fixture.source)) | expected: \(quoted(fixture.expectedRendered)) | rendered: \(quoted(rendered.string))"
            )
        }
    }

    func test_paragraphRenderer_isIdempotent() {
        for fixture in Self.paragraphFixtures {
            let inline = MarkdownParser.parseInlines(fixture.source)
            let a = ParagraphRenderer.render(inline: inline, bodyFont: bodyFont())
            let b = ParagraphRenderer.render(inline: inline, bodyFont: bodyFont())
            XCTAssertEqual(
                a, b,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: paragraph render is not idempotent."
            )
        }
    }

    func test_paragraphRenderer_codeSpanAppliesMonospaceFont() {
        // Semantic check: an inline code span must render with a
        // monospace font at its range.
        let inline = MarkdownParser.parseInlines("use `foo` here")
        let rendered = ParagraphRenderer.render(inline: inline, bodyFont: bodyFont())

        let nsString = rendered.string as NSString
        let codeRange = nsString.range(of: "foo")
        XCTAssertNotEqual(codeRange.location, NSNotFound)

        let attrs = rendered.attributes(at: codeRange.location, effectiveRange: nil)
        guard let font = attrs[.font] as? PlatformFont else {
            XCTFail("no font attribute on code-span range"); return
        }
        #if os(OSX)
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.monoSpace),
            "inline code range must carry a monospace-trait font (got \(font.fontName))"
        )
        #else
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace),
            "inline code range must carry a monospace-trait font (got \(font.fontName))"
        )
        #endif
    }

    func test_paragraphRenderer_boldAppliesBoldFont() {
        // Beyond the string-content invariant: verify the semantic
        // transformation actually happened — bold runs must have a
        // bold font applied at their range.
        let inline = MarkdownParser.parseInlines("plain **bold** plain")
        let rendered = ParagraphRenderer.render(inline: inline, bodyFont: bodyFont())

        // Find the "bold" substring in the rendered output.
        let nsString = rendered.string as NSString
        let boldRange = nsString.range(of: "bold")
        XCTAssertNotEqual(boldRange.location, NSNotFound)

        let attrs = rendered.attributes(at: boldRange.location, effectiveRange: nil)
        guard let font = attrs[.font] as? PlatformFont else {
            XCTFail("no font attribute on bold range"); return
        }
        #if os(OSX)
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.bold),
            "bold inline range must carry a bold-trait font"
        )
        #else
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.traitBold),
            "bold inline range must carry a bold-trait font"
        )
        #endif
    }

    // MARK: - List fixtures + invariants

    /// List fixtures: each entry is the raw markdown source to parse,
    /// plus the expected rendered string. The expected-rendered string
    /// encodes the invariant that NO source markers (`-`, `*`, `+`,
    /// `N.`, `N)`) appear in the rendered output — unordered items
    /// render as "• ", ordered items re-emit the numeric marker as
    /// visual text, indentation is normalized to 2-space-per-level.
    private static let listFixtures: [(name: String, source: String, expectedRendered: String)] = [
        ("flat_dash_one",      "- a\n",                             "• a"),
        ("flat_dash_three",    "- a\n- b\n- c\n",                   "• a\n• b\n• c"),
        ("flat_star",          "* x\n* y\n",                        "• x\n• y"),
        ("flat_plus",          "+ x\n+ y\n",                        "• x\n• y"),
        ("ordered_dot",        "1. first\n2. second\n",             "1. first\n2. second"),
        ("ordered_paren",      "1) one\n2) two\n",                  "1) one\n2) two"),
        ("nested_two_deep",    "- a\n  - b\n  - c\n- d\n",          "• a\n  • b\n  • c\n• d"),
        ("nested_three_deep",  "- a\n  - b\n    - c\n- d\n",        "• a\n  • b\n    • c\n• d"),
        ("ordered_in_unord",   "- a\n  1. one\n  2. two\n",         "• a\n  1. one\n  2. two"),
        ("bold_in_item",       "- this is **bold** text\n",         "• this is bold text"),
        ("code_in_item",       "- call `foo()` here\n",             "• call foo() here"),
    ]

    func test_listRenderer_noNegativeKern() {
        for fixture in Self.listFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .list(let items) = doc.blocks[0] else {
                XCTFail("[\(fixture.name)] first block is not a list"); continue
            }
            let rendered = ListRenderer.render(items: items, bodyFont: bodyFont())
            assertNoNegativeKern(rendered, fixture: fixture.name)
        }
    }

    func test_listRenderer_noClearForeground() {
        for fixture in Self.listFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .list(let items) = doc.blocks[0] else {
                XCTFail("[\(fixture.name)] first block is not a list"); continue
            }
            let rendered = ListRenderer.render(items: items, bodyFont: bodyFont())
            assertNoClearForeground(rendered, fixture: fixture.name)
        }
    }

    func test_listRenderer_containsNoSourceMarkers() {
        // Architectural invariant: parsed source markers for unordered
        // items (`-`, `*`, `+`) MUST NOT appear in the rendered output.
        // The visual bullet is "•". Ordered-item markers round-trip as
        // visual text (that IS their display form).
        for fixture in Self.listFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .list(let items) = doc.blocks[0] else {
                XCTFail("[\(fixture.name)] first block is not a list"); continue
            }
            let rendered = ListRenderer.render(items: items, bodyFont: bodyFont())
            XCTAssertEqual(
                rendered.string, fixture.expectedRendered,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered list diverges from expected. " +
                "Source markers must not appear in the rendered output. " +
                "source: \(quoted(fixture.source)) | expected: \(quoted(fixture.expectedRendered)) | rendered: \(quoted(rendered.string))"
            )
        }
    }

    func test_listRenderer_noUnorderedMarkersInOutput() {
        // Stronger check for unordered-only fixtures: the rendered
        // string must contain ZERO `-`, `*`, `+` characters (the
        // visual bullet is "•", and none of the content in these
        // fixtures uses those characters).
        let unorderedOnly = Self.listFixtures.filter {
            $0.name.starts(with: "flat_dash") || $0.name.starts(with: "flat_star")
                || $0.name.starts(with: "flat_plus") || $0.name.starts(with: "nested_")
        }
        for fixture in unorderedOnly {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .list(let items) = doc.blocks[0] else { continue }
            let rendered = ListRenderer.render(items: items, bodyFont: bodyFont())
            for marker in ["-", "*", "+"] {
                XCTAssertFalse(
                    rendered.string.contains(marker),
                    "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered output contains '\(marker)'. " +
                    "Unordered markers must be replaced with the visual bullet glyph."
                )
            }
        }
    }

    func test_listRenderer_isIdempotent() {
        for fixture in Self.listFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .list(let items) = doc.blocks[0] else { continue }
            let a = ListRenderer.render(items: items, bodyFont: bodyFont())
            let b = ListRenderer.render(items: items, bodyFont: bodyFont())
            XCTAssertEqual(
                a, b,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: list render is not idempotent."
            )
        }
    }

    func test_listRenderer_boldInsideItemAppliesBoldFont() {
        // Semantic check: a bold run inside a list item carries the
        // bold font trait at its range.
        let doc = MarkdownParser.parse("- this is **bold** text\n")
        guard case .list(let items) = doc.blocks[0] else {
            XCTFail("expected list"); return
        }
        let rendered = ListRenderer.render(items: items, bodyFont: bodyFont())
        let nsString = rendered.string as NSString
        let boldRange = nsString.range(of: "bold")
        XCTAssertNotEqual(boldRange.location, NSNotFound)

        let attrs = rendered.attributes(at: boldRange.location, effectiveRange: nil)
        guard let font = attrs[.font] as? PlatformFont else {
            XCTFail("no font attribute on bold range"); return
        }
        #if os(OSX)
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.bold),
            "bold inline range inside list item must carry a bold-trait font"
        )
        #else
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.traitBold),
            "bold inline range inside list item must carry a bold-trait font"
        )
        #endif
    }

    // MARK: - Blockquote fixtures + invariants

    /// Blockquote fixtures: each entry is raw markdown to parse plus
    /// the expected rendered string. Source `>` markers must NEVER
    /// appear in the rendered output.
    private static let blockquoteFixtures: [(name: String, source: String, expectedRendered: String)] = [
        ("simple",          "> hello\n",                   "  hello"),
        ("twoLines",        "> a\n> b\n",                  "  a\n  b"),
        ("nestedTight",     ">> deep\n",                   "    deep"),
        ("nestedSpaced",    "> > deep\n",                  "    deep"),
        ("mixedLevels",     "> outer\n>> inner\n",         "  outer\n    inner"),
        ("boldInside",      "> this is **bold** text\n",   "  this is bold text"),
        ("codeInside",      "> call `foo()` here\n",       "  call foo() here"),
        ("emptyLine",       ">\n",                         "  "),
        ("noSpaceAfter",    ">hello\n",                    "  hello"),
    ]

    func test_blockquoteRenderer_noNegativeKern() {
        for fixture in Self.blockquoteFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .blockquote(let lines) = doc.blocks[0] else {
                XCTFail("[\(fixture.name)] first block is not a blockquote"); continue
            }
            let rendered = BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont())
            assertNoNegativeKern(rendered, fixture: fixture.name)
        }
    }

    func test_blockquoteRenderer_noClearForeground() {
        for fixture in Self.blockquoteFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .blockquote(let lines) = doc.blocks[0] else { continue }
            let rendered = BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont())
            assertNoClearForeground(rendered, fixture: fixture.name)
        }
    }

    func test_blockquoteRenderer_containsNoQuoteMarkers() {
        // Architectural invariant: parsed `>` markers MUST NOT
        // appear in rendered output. The visual form is indentation.
        for fixture in Self.blockquoteFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .blockquote(let lines) = doc.blocks[0] else {
                XCTFail("[\(fixture.name)] first block is not a blockquote"); continue
            }
            let rendered = BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont())
            XCTAssertFalse(
                rendered.string.contains(">"),
                "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered output contains '>'. " +
                "Quote markers must never appear in the rendered output."
            )
            XCTAssertEqual(
                rendered.string, fixture.expectedRendered,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered blockquote diverges. " +
                "source: \(quoted(fixture.source)) | expected: \(quoted(fixture.expectedRendered)) | rendered: \(quoted(rendered.string))"
            )
        }
    }

    func test_blockquoteRenderer_isIdempotent() {
        for fixture in Self.blockquoteFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .blockquote(let lines) = doc.blocks[0] else { continue }
            let a = BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont())
            let b = BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont())
            XCTAssertEqual(
                a, b,
                "ARCHITECTURE VIOLATION [\(fixture.name)]: blockquote render is not idempotent."
            )
        }
    }

    // MARK: - Horizontal rule invariants

    /// HR fixtures: every parse-able HR source must render without
    /// any of the source marker characters appearing in the output.
    private static let hrFixtures: [(name: String, source: String)] = [
        ("tripleDash",   "---\n"),
        ("tripleStar",   "***\n"),
        ("tripleUnder",  "___\n"),
        ("fiveDash",     "-----\n"),
        ("tenStar",      "**********\n"),
    ]

    func test_horizontalRuleRenderer_noNegativeKern() {
        let rendered = HorizontalRuleRenderer.render(bodyFont: bodyFont())
        assertNoNegativeKern(rendered, fixture: "hr")
    }

    func test_horizontalRuleRenderer_noClearForeground() {
        let rendered = HorizontalRuleRenderer.render(bodyFont: bodyFont())
        assertNoClearForeground(rendered, fixture: "hr")
    }

    func test_horizontalRuleRenderer_isIdempotent() {
        let a = HorizontalRuleRenderer.render(bodyFont: bodyFont())
        let b = HorizontalRuleRenderer.render(bodyFont: bodyFont())
        XCTAssertEqual(
            a, b,
            "ARCHITECTURE VIOLATION: HR render is not idempotent."
        )
    }

    func test_horizontalRuleRenderer_containsNoSourceMarkers() {
        // For every HR fixture, parse and render; the rendered
        // output must contain ZERO `-`, `_`, or `*` characters.
        for fixture in Self.hrFixtures {
            let doc = MarkdownParser.parse(fixture.source)
            guard case .horizontalRule = doc.blocks[0] else {
                XCTFail("[\(fixture.name)] first block is not a horizontalRule"); continue
            }
            let rendered = HorizontalRuleRenderer.render(bodyFont: bodyFont())
            for marker in ["-", "_", "*"] {
                XCTAssertFalse(
                    rendered.string.contains(marker),
                    "ARCHITECTURE VIOLATION [\(fixture.name)]: rendered HR contains '\(marker)'. " +
                    "HR source markers must never appear in the rendered output."
                )
            }
        }
    }

    // MARK: - Integration: parse -> render produces clean storage

    func test_parseAndRender_producesStorageWithoutMarkdownMarkers() {
        // Full tracer-bullet flow: parse markdown, render only the code-block
        // payloads, verify NO fence characters in the rendered output.
        let inputs = [
            "```python\nprint(1)\n```\n",
            "```\nfoo\n```\n",
            "```swift\nlet x = 1\n```\n",
        ]
        for input in inputs {
            let doc = MarkdownParser.parse(input)
            for block in doc.blocks {
                guard case .codeBlock(let lang, let content, _) = block else { continue }
                let rendered = CodeBlockRenderer.render(
                    language: lang,
                    content: content,
                    codeFont: codeFont()
                )
                // The rendered string must contain no triple-backtick sequence.
                XCTAssertFalse(
                    rendered.string.contains("```"),
                    "ARCHITECTURE VIOLATION: rendered output of \(quoted(input)) contains '```'. " +
                    "Fences must be consumed by the parser and never reach rendered output."
                )
                // And must contain no fence info tag.
                if let lang = lang {
                    XCTAssertFalse(
                        rendered.string.hasPrefix(lang + "\n") || rendered.string.hasPrefix("```" + lang),
                        "ARCHITECTURE VIOLATION: rendered output begins with the fence info tag."
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func quoted(_ s: String) -> String {
        return "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
