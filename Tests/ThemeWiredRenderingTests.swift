//
//  ThemeWiredRenderingTests.swift
//  FSNotesTests
//
//  Phase 7.2 — wiring tests for the Theme struct into DocumentRenderer
//  and InlineRenderer. These tests prove two things:
//
//  1. Rendering with `Theme.shared` (the bundled default) matches the
//     pre-theme hardcoded spacing / typography values byte-for-byte.
//  2. Rendering with a custom theme produces the expected font sizes
//     and paragraph spacing — i.e. the theme is actually consumed, not
//     silently ignored.
//

import XCTest
@testable import FSNotes

class ThemeWiredRenderingTests: XCTestCase {

    // MARK: - Helpers

    private let baseFontSize: CGFloat = 14

    private func bodyFont(size: CGFloat? = nil) -> PlatformFont {
        return PlatformFont.systemFont(ofSize: size ?? baseFontSize)
    }

    private func codeFont(size: CGFloat? = nil) -> PlatformFont {
        return PlatformFont.monospacedSystemFont(
            ofSize: size ?? baseFontSize, weight: .regular
        )
    }

    /// Render a markdown string to a `RenderedDocument` under the given
    /// theme. Default body/code fonts track the theme's typography
    /// sizes so a custom theme's sizes flow through to the renderer.
    private func render(
        _ md: String,
        theme: Theme,
        bodyFont: PlatformFont? = nil,
        codeFont: PlatformFont? = nil
    ) -> RenderedDocument {
        let doc = MarkdownParser.parse(md)
        let body = bodyFont ?? PlatformFont.systemFont(
            ofSize: theme.typography.bodyFontSize
        )
        let code = codeFont ?? PlatformFont.monospacedSystemFont(
            ofSize: theme.typography.codeFontSize, weight: .regular
        )
        return DocumentRenderer.render(
            doc, bodyFont: body, codeFont: code, theme: theme
        )
    }

    /// Locate the paragraph style attached at the first occurrence of
    /// `substring` in the rendered document.
    private func paragraphStyle(
        in rendered: RenderedDocument,
        at substring: String
    ) -> NSParagraphStyle? {
        let str = rendered.attributed.string
        guard let range = str.range(of: substring) else { return nil }
        let loc = NSRange(range, in: str).location
        return rendered.attributed.attribute(
            .paragraphStyle, at: loc, effectiveRange: nil
        ) as? NSParagraphStyle
    }

    /// Locate the font at the first occurrence of `substring`.
    private func font(
        in rendered: RenderedDocument,
        at substring: String
    ) -> PlatformFont? {
        let str = rendered.attributed.string
        guard let range = str.range(of: substring) else { return nil }
        let loc = NSRange(range, in: str).location
        return rendered.attributed.attribute(
            .font, at: loc, effectiveRange: nil
        ) as? PlatformFont
    }

    // MARK: - Default theme: visual no-op gate

    /// Rendering a paragraph under the bundled default theme must
    /// produce the pre-theme hardcoded paragraph spacing
    /// (`baseSize * 0.85`). This is the gate that proves default-theme
    /// values exactly match the old file-local multipliers.
    func test_defaultTheme_paragraphSpacingMatchesHardcodedValue() {
        let rendered = render("Hello world\n", theme: .shared)
        let style = paragraphStyle(in: rendered, at: "Hello")
        XCTAssertNotNil(style, "Paragraph must have a paragraph style")
        // Pre-theme constant: paragraphSpacingMultiplier = 0.85.
        XCTAssertEqual(
            style!.paragraphSpacing,
            baseFontSize * 0.85,
            accuracy: 0.001,
            "Default theme paragraphSpacing must equal baseSize * 0.85"
        )
    }

    /// Structural blocks (code / list / blockquote / HR / table / html)
    /// must carry the pre-theme structural multiplier (1.1 × baseSize).
    func test_defaultTheme_structuralBlockSpacingMatchesHardcodedValue() {
        let rendered = render("```\nsome code\n```\n", theme: .shared)
        let style = paragraphStyle(in: rendered, at: "some code")
        XCTAssertNotNil(style, "Code block line must have paragraph style")
        XCTAssertEqual(
            style!.paragraphSpacing,
            baseFontSize * 1.1,
            accuracy: 0.001,
            "Default theme structural spacing must equal baseSize * 1.1"
        )
    }

    /// Heading spacing must match the pre-theme per-level hardcoded
    /// values:
    ///   H1 before = 1.2, H1 after = 0.67
    ///   H2 before = 1.0, H2 after = 0.5
    /// (The "before" value is only applied when the heading is not the
    /// first block in the document; we test that here.)
    func test_defaultTheme_h1HeadingSpacingMatchesHardcodedValues() {
        let rendered = render("Intro text\n\n# Title\n", theme: .shared)
        let style = paragraphStyle(in: rendered, at: "Title")
        XCTAssertNotNil(style)
        XCTAssertEqual(
            style!.paragraphSpacingBefore,
            baseFontSize * 1.2,
            accuracy: 0.001,
            "Default theme H1 spacing-before must equal baseSize * 1.2"
        )
        XCTAssertEqual(
            style!.paragraphSpacing,
            baseFontSize * 0.67,
            accuracy: 0.001,
            "Default theme H1 spacing-after must equal baseSize * 0.67"
        )
    }

    /// Default theme's super/subscript scaling must produce the pre-theme
    /// 0.75× body font size.
    func test_defaultTheme_superscriptFontSizeMatchesHardcodedValue() {
        let rendered = render("x<sup>2</sup>\n", theme: .shared)
        let supFont = font(in: rendered, at: "2")
        XCTAssertNotNil(supFont)
        XCTAssertEqual(
            supFont!.pointSize,
            baseFontSize * 0.75,
            accuracy: 0.01,
            "Default theme superscript font size must equal baseSize * 0.75"
        )
    }

    // MARK: - Custom themes drive the render

    /// A custom theme with `bodyFontSize = 24` must flow through — when
    /// the caller constructs the body font from `theme.typography.bodyFontSize`,
    /// the rendered paragraph carries a 24pt font.
    func test_customTheme_bodyFontSize_flowsToRenderedFont() {
        var custom = BlockStyleTheme.default
        custom.noteFontSize = 24

        let rendered = render("Body text\n", theme: custom)
        let f = font(in: rendered, at: "Body")
        XCTAssertNotNil(f)
        XCTAssertEqual(
            f!.pointSize, 24, accuracy: 0.01,
            "Custom theme bodyFontSize=24 must yield 24pt font"
        )
    }

    /// A custom theme that changes the H1 spacing multiplier array
    /// must change the rendered H1 paragraph spacing.
    func test_customTheme_headingSpacingAfter_flowsToParagraphStyle() {
        var custom = BlockStyleTheme.default
        // Shift H1 from 0.67 → 2.0 so the delta is visible and large.
        custom.headingSpacingAfter = [2.0, 0.5, 0.4, 0.35, 0.3, 0.25]

        let rendered = render("# Title\n", theme: custom)
        let style = paragraphStyle(in: rendered, at: "Title")
        XCTAssertNotNil(style)
        XCTAssertEqual(
            style!.paragraphSpacing,
            baseFontSize * 2.0,
            accuracy: 0.01,
            "Custom theme H1 spacing-after=2.0 must flow through"
        )
    }

    /// A custom theme with a larger paragraph spacing (via the
    /// underlying multiplier constant in `BlockStyleTheme.default`) —
    /// we can't mutate the nested-only `ThemeSpacing.paragraphSpacingMultiplier`
    /// without rebuilding the nested view, but we CAN mutate the flat
    /// `paragraphSpacing` (points) field, which the renderer also
    /// honors through the `theme.spacing` accessor for callers that
    /// prefer fixed-point spacing.
    ///
    /// For the multiplier path, prove the default theme default (0.85)
    /// is what's consumed — this is the byte-identical gate.
    func test_customTheme_paragraphSpacingMultiplier_matchesThemeDefault() {
        // Phase 7.2: paragraph spacing reads from
        // `theme.spacing.paragraphSpacingMultiplier`, which is a
        // nested-only field synthesized by ThemeAccess. Its value on
        // the default theme is 0.85 (matches the pre-theme hardcoded
        // constant). This test is the "default theme is a visual no-op"
        // gate for that specific multiplier.
        let renderedDefault = render("Hello\n", theme: .shared)
        let defaultStyle = paragraphStyle(in: renderedDefault, at: "Hello")
        XCTAssertNotNil(defaultStyle)
        XCTAssertEqual(
            defaultStyle!.paragraphSpacing,
            baseFontSize * 0.85,
            accuracy: 0.001
        )
    }

    /// Threading the custom theme's `paragraphSpacing` through to the
    /// renderer via the `theme.spacing.paragraphSpacing` field: the
    /// multiplier path is the *live* behaviour on the default renderer,
    /// and the fixed-point `paragraphSpacing` field is the flat
    /// override. Phase 7.2 keeps the multiplier path live; the fixed
    /// point value is Phase 7.5 scope. We prove the multiplier path
    /// responds to a re-rendered theme by picking a custom body font
    /// size: `paragraphSpacing = newBodySize * 0.85`.
    func test_customTheme_paragraphSpacingScalesWithBodyFontSize() {
        var custom = BlockStyleTheme.default
        custom.noteFontSize = 20

        let rendered = render("Paragraph\n", theme: custom)
        let style = paragraphStyle(in: rendered, at: "Paragraph")
        XCTAssertNotNil(style)
        XCTAssertEqual(
            style!.paragraphSpacing,
            20 * 0.85,
            accuracy: 0.01,
            "paragraphSpacing must scale with theme.bodyFontSize × default multiplier (0.85)"
        )
    }
}
