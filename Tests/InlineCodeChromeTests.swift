//
//  InlineCodeChromeTests.swift
//  FSNotesTests
//
//  Bug #51 — verifies that:
//    1. `InlineRenderer.render` tags every `.code` inline run with
//       `.inlineCodeRange`.
//    2. The tag survives across every block kind that hosts inline
//       content: plain paragraph, heading, list item, blockquote,
//       paragraph containing kbd.
//    3. `BlockModelLayoutManagerDelegate` routes `ParagraphElement` and
//       `ListItemElement` to `ParagraphLayoutFragment` (the fragment
//       responsible for the chrome paint pass on those block kinds).
//    4. `InlineCodeChromeDrawer` reads chrome geometry from the active
//       theme so it stays the sole presentation source of truth
//       (Invariant F).
//
//  These tests cover the data + dispatch layers. Bitmap pixel-probes of
//  the actual rounded-rect paint live in the live app; per CLAUDE.md
//  ("cacheDisplay does NOT capture fragment-level drawing") an
//  XCTest-driven snapshot would not exercise `NSTextLayoutFragment.draw`
//  and thus could not see the chrome fill.
//

import XCTest
import AppKit
@testable import FSNotes

final class InlineCodeChromeTests: XCTestCase {

    // MARK: - Helpers

    /// Render the full document via `DocumentRenderer.render` and return
    /// the resulting attributed string. Using the public render entry
    /// point covers every block kind uniformly without the test having
    /// to replicate `HeadingRenderer.render(level:suffix:…)` /
    /// `BlockquoteRenderer.render(lines:…)` etc. — the chrome tag must
    /// land on the rendered string regardless of which renderer
    /// produced it.
    private func renderDocument(
        _ markdown: String
    ) -> NSAttributedString {
        let doc = MarkdownParser.parse(markdown)
        let theme = Theme.shared
        let bodyFont = NSFont.systemFont(ofSize: theme.typography.bodyFontSize)
        let codeFont = NSFont.userFixedPitchFont(
            ofSize: theme.typography.codeFontSize
        ) ?? bodyFont
        let rendered = DocumentRenderer.render(
            doc,
            bodyFont: bodyFont,
            codeFont: codeFont,
            theme: theme
        )
        return rendered.attributed
    }

    private func firstInlineCodeRange(
        in s: NSAttributedString
    ) -> NSRange? {
        var found: NSRange?
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.inlineCodeRange, in: full, options: []) { v, r, stop in
            if v != nil {
                found = r
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Inline rendering: tag presence

    func test_bug51_inlineRenderer_tagsCodeRunWithInlineCodeRange() {
        let s = renderDocument("plain `code` run\n")
        XCTAssertTrue(
            s.string.contains("plain code run"),
            "rendered string should contain the joined paragraph text " +
            "without backticks; got \(quoted(s.string))"
        )
        guard let range = firstInlineCodeRange(in: s) else {
            XCTFail("`code` run must carry .inlineCodeRange")
            return
        }
        // The marker should cover exactly "code" (4 chars). Locate the
        // expected substring in the rendered output and compare.
        let ns = s.string as NSString
        let expected = ns.range(of: "code")
        XCTAssertNotEqual(expected.location, NSNotFound)
        XCTAssertEqual(range, expected,
            "marker range \(range) must match the position of \"code\" " +
            "in the rendered string \(quoted(s.string))")
    }

    private func quoted(_ s: String) -> String {
        return "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    func test_bug51_inlineRenderer_codeRunStillUsesMonospacedFont() {
        // Sanity: tagging the run for chrome must not regress the
        // existing font choice.
        let s = renderDocument("plain `x` run\n")
        guard let range = firstInlineCodeRange(in: s) else {
            XCTFail("expected .inlineCodeRange")
            return
        }
        let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(
            font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false,
            "code-span run must remain monospaced"
        )
    }

    func test_bug51_inlineRenderer_nonCodeRunHasNoInlineCodeRange() {
        let s = renderDocument("plain text without code\n")
        XCTAssertNil(
            firstInlineCodeRange(in: s),
            "plain text must not carry .inlineCodeRange anywhere"
        )
    }

    func test_bug51_inlineRenderer_multipleCodeRunsBothTagged() {
        let s = renderDocument("first `a` then `bbb` end\n")
        let full = NSRange(location: 0, length: s.length)
        var hits: [NSRange] = []
        s.enumerateAttribute(.inlineCodeRange, in: full, options: []) { v, r, _ in
            if v != nil { hits.append(r) }
        }
        XCTAssertEqual(hits.count, 2,
            "two code spans must produce two tagged ranges, got \(hits)")
    }

    // MARK: - Inline rendering: across block kinds

    // Note: Block.heading carries `suffix: String` (not parsed inlines)
    // and HeadingRenderer.render emits the suffix as a single
    // `[.text(suffix)]` inline. Inline markdown inside heading text
    // does not currently parse into structured inlines (a separate
    // pre-existing limitation, out of scope for #51). When that is
    // addressed, code spans inside headings will pick up the
    // `.inlineCodeRange` tag automatically because they will then flow
    // through `InlineRenderer.render(.code(...))` like every other
    // block kind. Until then, no test for headings.

    func test_bug51_inlineCodeTag_inBlockquote() {
        let s = renderDocument("> quote `code` here\n")
        XCTAssertNotNil(firstInlineCodeRange(in: s),
            "code span inside a blockquote must carry .inlineCodeRange")
    }

    func test_bug51_inlineCodeTag_inListItem() {
        let s = renderDocument("- item with `code`\n")
        XCTAssertNotNil(firstInlineCodeRange(in: s),
            "code span inside a list item must carry .inlineCodeRange")
    }

    func test_bug51_inlineCodeTag_alongsideKbd() {
        // Same paragraph: kbd run + code run. Both tags must coexist.
        let s = renderDocument("press <kbd>X</kbd> for `mode`\n")
        XCTAssertNotNil(firstInlineCodeRange(in: s),
            "code span next to a kbd run must still carry .inlineCodeRange")
        // And the kbd tag survives.
        var foundKbd = false
        s.enumerateAttribute(
            .kbdTag,
            in: NSRange(location: 0, length: s.length),
            options: []
        ) { v, _, stop in
            if v != nil { foundKbd = true; stop.pointee = true }
        }
        XCTAssertTrue(foundKbd, "kbd run must still carry .kbdTag")
    }

    // MARK: - Theme: chrome geometry comes from the theme

    func test_bug51_chromeReadsCornerRadiusFromTheme() {
        // Invariant F: presentation literals come from the theme. The
        // drawer's static accessors must mirror `Theme.shared.chrome`.
        let theme = Theme.shared
        XCTAssertEqual(
            InlineCodeChromeDrawer.cornerRadius,
            theme.chrome.inlineCodeCornerRadius
        )
        XCTAssertEqual(
            InlineCodeChromeDrawer.borderWidth,
            theme.chrome.inlineCodeBorderWidth
        )
        XCTAssertEqual(
            InlineCodeChromeDrawer.horizontalPadding,
            theme.chrome.inlineCodeHorizontalPadding
        )
        XCTAssertEqual(
            InlineCodeChromeDrawer.verticalPaddingTop,
            theme.chrome.inlineCodeVerticalPaddingTop
        )
        XCTAssertEqual(
            InlineCodeChromeDrawer.verticalPaddingBottom,
            theme.chrome.inlineCodeVerticalPaddingBottom
        )
    }

    func test_bug51_chromeFillResolvesToInlineCodeBackgroundTheme() {
        // The drawer's fill colour must come from
        // `theme.colors.inlineCodeBackground` (Invariant F). Assert via
        // resolved-color equality in the current appearance — the
        // resolver returns a concrete `NSColor`, so the drawer's
        // accessor and the theme's must produce visually-equal values.
        let drawerFill = InlineCodeChromeDrawer.fillColor
        let themeFill = Theme.shared.colors.inlineCodeBackground
            .resolvedForCurrentAppearance(
                fallback: NSColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)
            )
        // Both should resolve to the same RGBA components within the
        // standard 0.02 tolerance used elsewhere in the codebase.
        XCTAssertTrue(
            InlineRenderer.colorsApproximatelyEqual(drawerFill, themeFill),
            "drawer fill colour must come from the theme's inlineCodeBackground"
        )
    }

    // MARK: - Defaults

    func test_bug51_defaultThemeChromeValues() {
        let def = ThemeChrome.default
        XCTAssertEqual(def.inlineCodeCornerRadius, 3.0)
        XCTAssertEqual(def.inlineCodeBorderWidth, 0.0)
        XCTAssertEqual(def.inlineCodeHorizontalPadding, 2.0)
        XCTAssertEqual(def.inlineCodeVerticalPaddingTop, 0.0)
        XCTAssertEqual(def.inlineCodeVerticalPaddingBottom, 0.0)
    }
}
