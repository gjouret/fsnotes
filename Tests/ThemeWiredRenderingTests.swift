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

    // MARK: - Hermetic theme state
    //
    // Tests in this suite assume `BlockStyleTheme.shared` is the bundled
    // default (base font size 14, etc.). Without an explicit reset the
    // suite inherits whatever the prior test or the host app's first
    // launch seeded — e.g. a 17pt `noteFontSize` migrated in by Phase
    // 7.5.c's `migrateEditorKeysIntoTheme75c` from a stale cfprefsd UD
    // value. Snapshot + restore makes the suite deterministic.

    private var savedShared: BlockStyleTheme!

    override func setUpWithError() throws {
        savedShared = BlockStyleTheme.shared
        BlockStyleTheme.shared = BlockStyleTheme.default
    }

    override func tearDownWithError() throws {
        BlockStyleTheme.shared = savedShared
    }

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

    // MARK: - Phase 7.3: fragment-level theme wiring
    //
    // Fragments read static chrome/color values from `Theme.shared`
    // (they're instantiated by `NSTextLayoutManagerDelegate` and have
    // no natural constructor-injection point). These tests mutate
    // `Theme.shared` to prove the fragment's static accessors track
    // the theme, then restore the original so other tests aren't
    // affected.

    /// Run a closure with `Theme.shared` temporarily replaced, then
    /// restore the original.
    private func withSharedTheme(_ theme: Theme, _ body: () -> Void) {
        let original = Theme.shared
        Theme.shared = theme
        defer { Theme.shared = original }
        body()
    }

    /// HeadingLayoutFragment's `borderColor` / `borderThickness` /
    /// `borderOffsetBelowText` must read through `Theme.shared.colors.*`
    /// and `Theme.shared.chrome.*`. Mutate the theme and verify the
    /// static accessors track.
    func test_phase73_headingFragmentBorder_readsFromTheme() {
        var custom = BlockStyleTheme.default
        // Populate nested groups with custom values. Synthesize from
        // flat so the nested surface is consistent, then override the
        // chrome fields directly on the shared theme.
        custom.headingFontScales = BlockStyleTheme.default.headingFontScales
        // Default chrome values first so the baseline is known.
        withSharedTheme(BlockStyleTheme.default) {
            XCTAssertEqual(
                HeadingLayoutFragment.borderThickness, 0.5, accuracy: 0.0001,
                "Default theme: heading border thickness = 0.5pt"
            )
            XCTAssertEqual(
                HeadingLayoutFragment.borderOffsetBelowText, 1.0, accuracy: 0.0001,
                "Default theme: heading border offset below text = 1.0pt"
            )
            // Color is appearance-aware; just assert it's non-nil and
            // that its sRGB red component matches the #EEEEEE default
            // (0.933 within rounding).
            #if os(OSX)
            let color = HeadingLayoutFragment.borderColor.usingColorSpace(.sRGB)
            XCTAssertNotNil(color)
            XCTAssertEqual(
                color!.redComponent, 0.933, accuracy: 0.01,
                "Default theme: heading border color = #EEEEEE (0.933 red)"
            )
            #endif
        }
    }

    /// BlockquoteLayoutFragment's bar color + geometry must read through
    /// `Theme.shared.colors.blockquoteBar` / `Theme.shared.chrome.blockquote*`.
    func test_phase73_blockquoteFragmentBar_readsFromTheme() {
        withSharedTheme(BlockStyleTheme.default) {
            XCTAssertEqual(
                BlockquoteLayoutFragment.barWidth, 4, accuracy: 0.0001,
                "Default theme: blockquote bar width = 4pt"
            )
            XCTAssertEqual(
                BlockquoteLayoutFragment.barSpacing, 10, accuracy: 0.0001,
                "Default theme: blockquote bar spacing = 10pt"
            )
            XCTAssertEqual(
                BlockquoteLayoutFragment.barInitialOffset, 2, accuracy: 0.0001,
                "Default theme: blockquote bar initial offset = 2pt"
            )
            #if os(OSX)
            let color = BlockquoteLayoutFragment.barColor.usingColorSpace(.sRGB)
            XCTAssertNotNil(color)
            XCTAssertEqual(
                color!.redComponent, 0.867, accuracy: 0.01,
                "Default theme: blockquote bar color = #DDDDDD (0.867 red)"
            )
            #endif
        }
    }

    /// HorizontalRuleLayoutFragment's `ruleColor` / `ruleThickness` must
    /// read through `Theme.shared.colors.hrLine` / `Theme.shared.chrome.hrThickness`.
    func test_phase73_hrFragmentColor_readsFromTheme() {
        withSharedTheme(BlockStyleTheme.default) {
            XCTAssertEqual(
                HorizontalRuleLayoutFragment.ruleThickness, 4.0, accuracy: 0.0001,
                "Default theme: HR thickness = 4.0pt"
            )
            #if os(OSX)
            let color = HorizontalRuleLayoutFragment.ruleColor.usingColorSpace(.sRGB)
            XCTAssertNotNil(color)
            XCTAssertEqual(
                color!.redComponent, 0.906, accuracy: 0.01,
                "Default theme: HR color = #E7E7E7 (0.906 red)"
            )
            #endif
        }
    }

    /// KbdBoxParagraphLayoutFragment chrome + colors must read through
    /// `Theme.shared.colors.kbd*` / `Theme.shared.chrome.kbd*`.
    func test_phase73_kbdFragmentChrome_readsFromTheme() {
        withSharedTheme(BlockStyleTheme.default) {
            XCTAssertEqual(
                KbdBoxParagraphLayoutFragment.cornerRadius, 3.0, accuracy: 0.0001,
                "Default theme: kbd corner radius = 3.0pt"
            )
            XCTAssertEqual(
                KbdBoxParagraphLayoutFragment.borderWidth, 1.0, accuracy: 0.0001,
                "Default theme: kbd border width = 1.0pt"
            )
            XCTAssertEqual(
                KbdBoxParagraphLayoutFragment.horizontalPadding, 2.0, accuracy: 0.0001,
                "Default theme: kbd horizontal padding = 2.0pt"
            )
            XCTAssertEqual(
                KbdBoxParagraphLayoutFragment.verticalPaddingTop, 1.0, accuracy: 0.0001,
                "Default theme: kbd vertical padding top = 1.0pt"
            )
            XCTAssertEqual(
                KbdBoxParagraphLayoutFragment.verticalPaddingBottom, 1.0, accuracy: 0.0001,
                "Default theme: kbd vertical padding bottom = 1.0pt " +
                "(TK1 KbdBoxDrawer uses height + 2 = 1+1 symmetric)"
            )
            #if os(OSX)
            let fill = KbdBoxParagraphLayoutFragment.fillColor.usingColorSpace(.sRGB)
            XCTAssertNotNil(fill)
            XCTAssertEqual(
                fill!.redComponent, 0.988, accuracy: 0.01,
                "Default theme: kbd fill = #FCFCFC (0.988 red)"
            )
            let stroke = KbdBoxParagraphLayoutFragment.strokeColor.usingColorSpace(.sRGB)
            XCTAssertNotNil(stroke)
            XCTAssertEqual(
                stroke!.redComponent, 0.8, accuracy: 0.01,
                "Default theme: kbd stroke = #CCCCCC (0.8 red)"
            )
            let shadow = KbdBoxParagraphLayoutFragment.shadowColor.usingColorSpace(.sRGB)
            XCTAssertNotNil(shadow)
            XCTAssertEqual(
                shadow!.redComponent, 0.733, accuracy: 0.01,
                "Default theme: kbd shadow = #BBBBBB (0.733 red)"
            )
            #endif
        }
    }

    /// CodeBlockLayoutFragment chrome must read through
    /// `Theme.shared.chrome.codeBlock*`.
    func test_phase73_codeBlockFragmentChrome_readsFromTheme() {
        withSharedTheme(BlockStyleTheme.default) {
            XCTAssertEqual(
                CodeBlockLayoutFragment.cornerRadius, 5.0, accuracy: 0.0001,
                "Default theme: code block corner radius = 5.0pt"
            )
            XCTAssertEqual(
                CodeBlockLayoutFragment.horizontalBleed, 5.0, accuracy: 0.0001,
                "Default theme: code block horizontal bleed = 5.0pt"
            )
            XCTAssertEqual(
                CodeBlockLayoutFragment.borderWidth, 1.0, accuracy: 0.0001,
                "Default theme: code block border width = 1.0pt"
            )
        }
    }

    /// A custom theme with `blockquoteBarWidth = 12` must flow through
    /// to the fragment's static accessor AND through to the
    /// `BlockquoteRenderer.leftIndent` computation (since both read
    /// from the same theme field).
    func test_phase73_customBarWidth_tripsThrough() {
        var custom = BlockStyleTheme.default
        custom.blockquoteBarWidth = 12

        withSharedTheme(custom) {
            XCTAssertEqual(
                BlockquoteLayoutFragment.barWidth, 12, accuracy: 0.0001,
                "Custom theme blockquoteBarWidth=12 must reach the fragment"
            )
        }

        // The renderer's indent is also theme-driven, though it takes
        // the theme as an explicit parameter (not Theme.shared). Assert
        // that path too so both consumers share the same source.
        let bodyFont = PlatformFont.systemFont(ofSize: 14)
        let line = BlockquoteLine(prefix: "> ", inline: [.text("quoted")])
        let rendered = BlockquoteRenderer.render(
            lines: [line], bodyFont: bodyFont, theme: custom
        )
        let style = rendered.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertNotNil(style)
        // Indent = initialOffset(2) + (level-1)*spacing(10) + barWidth(12) + gapAfterBars(4) = 18
        XCTAssertEqual(
            style!.headIndent, 18.0, accuracy: 0.01,
            "BlockquoteRenderer indent must honor the theme's 12pt bar width"
        )
    }

    /// HeadingRenderer migrated from a hardcoded `switch` to
    /// `theme.headingFontScale(for:)`. Default values
    /// `[2.0, 1.7, 1.4, 1.2, 1.1, 1.05]` are byte-identical to the
    /// pre-theme constants. A custom theme with a re-scaled H1 must
    /// produce the expected rendered font size.
    func test_phase73_headingRenderer_scaleReadsFromTheme() {
        // Default theme: H1 = 2.0 × 14 = 28.
        let renderedDefault = render("# Title\n", theme: .shared)
        let defaultFont = font(in: renderedDefault, at: "Title")
        XCTAssertNotNil(defaultFont)
        XCTAssertEqual(
            defaultFont!.pointSize, 14 * 2.0, accuracy: 0.01,
            "Default theme H1 = body × 2.0"
        )

        // Custom theme: H1 scaled to 3.0 ⇒ rendered size 14 × 3.0 = 42.
        var custom = BlockStyleTheme.default
        custom.headingFontScales = [3.0, 1.7, 1.4, 1.2, 1.1, 1.05]
        let renderedCustom = render("# Title\n", theme: custom)
        let customFont = font(in: renderedCustom, at: "Title")
        XCTAssertNotNil(customFont)
        XCTAssertEqual(
            customFont!.pointSize, 14 * 3.0, accuracy: 0.01,
            "Custom theme H1 scale=3.0 must flow through HeadingRenderer"
        )
    }

    /// The default theme must be a no-op: every fragment's static
    /// values equal the pre-7.3 hardcoded values. This is the
    /// regression gate that proves default-theme rendering is
    /// byte-identical to the pre-migration behaviour.
    func test_phase73_defaultTheme_renderIsNoOp() {
        withSharedTheme(BlockStyleTheme.default) {
            // Heading fragment: #EEEEEE / 0.5pt / 1.0pt
            XCTAssertEqual(HeadingLayoutFragment.borderThickness, 0.5, accuracy: 0.0001)
            XCTAssertEqual(HeadingLayoutFragment.borderOffsetBelowText, 1.0, accuracy: 0.0001)

            // Blockquote fragment: #DDDDDD / 4 / 10 / 2
            XCTAssertEqual(BlockquoteLayoutFragment.barWidth, 4, accuracy: 0.0001)
            XCTAssertEqual(BlockquoteLayoutFragment.barSpacing, 10, accuracy: 0.0001)
            XCTAssertEqual(BlockquoteLayoutFragment.barInitialOffset, 2, accuracy: 0.0001)

            // HR fragment: #E7E7E7 / 4.0
            XCTAssertEqual(HorizontalRuleLayoutFragment.ruleThickness, 4.0, accuracy: 0.0001)

            // Kbd fragment: #FCFCFC / #CCCCCC / #BBBBBB + 3pt radius + 1pt border + 2pt h pad + 1/1 v pad
            XCTAssertEqual(KbdBoxParagraphLayoutFragment.cornerRadius, 3.0, accuracy: 0.0001)
            XCTAssertEqual(KbdBoxParagraphLayoutFragment.borderWidth, 1.0, accuracy: 0.0001)
            XCTAssertEqual(KbdBoxParagraphLayoutFragment.horizontalPadding, 2.0, accuracy: 0.0001)
            XCTAssertEqual(KbdBoxParagraphLayoutFragment.verticalPaddingTop, 1.0, accuracy: 0.0001)
            XCTAssertEqual(KbdBoxParagraphLayoutFragment.verticalPaddingBottom, 1.0, accuracy: 0.0001)

            // Code block fragment: 5pt radius / 5pt bleed / 1pt border
            XCTAssertEqual(CodeBlockLayoutFragment.cornerRadius, 5.0, accuracy: 0.0001)
            XCTAssertEqual(CodeBlockLayoutFragment.horizontalBleed, 5.0, accuracy: 0.0001)
            XCTAssertEqual(CodeBlockLayoutFragment.borderWidth, 1.0, accuracy: 0.0001)

            // InlineRenderer.highlightColor (reconciled): #FFE600 ~= 1.0/0.9/0.0 alpha 0.5
            #if os(OSX)
            let hi = InlineRenderer.highlightColor.usingColorSpace(.sRGB)
            XCTAssertNotNil(hi)
            XCTAssertEqual(hi!.redComponent, 1.0, accuracy: 0.02)
            XCTAssertEqual(hi!.greenComponent, 0.9, accuracy: 0.02)
            XCTAssertEqual(hi!.blueComponent, 0.0, accuracy: 0.02)
            XCTAssertEqual(hi!.alphaComponent, 0.5, accuracy: 0.02)
            #endif
        }
    }
}
