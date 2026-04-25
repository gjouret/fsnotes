//
//  HeadingLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2c — Custom NSTextLayoutFragment for headings.
//
//  Pairs with `HeadingElement`. Draws the hairline bottom border below
//  H1 and H2 headings after delegating text drawing to super.
//
//  Under TK1, the hairline was drawn by `LayoutManager.drawHeaderBottomBorders`
//  via the layoutManager's side-drawing path. That path is never invoked
//  under TK2 — TK2 composes rendering exclusively through
//  `NSTextLayoutFragment.draw(at:in:)`. This fragment is the TK2
//  equivalent so the H1/H2 visual contract survives the Phase 2 migration.
//
//  Level lookup reads `.headingLevel` off the element's backing
//  attributed string (set by `DocumentRenderer` alongside
//  `.blockModelKind = .heading`). Levels > 2 render plain — no hairline.
//
//  Folded-state indicator: when the content immediately after the
//  heading carries `.foldedContent`, the fragment paints a small
//  rounded-rect chip with the text "..." at the trailing edge of the
//  heading's last line. Purely cosmetic — clicking the indicator has
//  no effect; fold/unfold flows through the gutter as usual.
//

import AppKit

public final class HeadingLayoutFragment: NSTextLayoutFragment {

    // MARK: - Drawing constants (phase 7.3 — read from Theme.shared)
    //
    // These are static computed properties so existing external
    // references (`HeadingLayoutFragment.borderColor`) and the live
    // drawing path both read the same theme-backed values. The
    // `ThemeColors.headingBorder` / `ThemeChrome.headingBorder*` default
    // values in `ThemeSchema.swift` match the pre-theme hardcoded
    // constants byte-for-byte so default-theme rendering is a visual
    // no-op.

    /// Hairline color. Default theme = `#EEEEEE` (RGB 0.933 × 3),
    /// matching the pre-theme TK1 hardcoded `drawHeaderBottomBorders`
    /// value exactly.
    public static var borderColor: NSColor {
        Theme.shared.colors.headingBorder.resolvedForCurrentAppearance(
            fallback: NSColor(red: 0.933, green: 0.933, blue: 0.933, alpha: 1.0)
        )
    }

    /// Stroke thickness in points. Default theme value = 0.5pt hairline
    /// (CSS `1px` on Retina) — matches pre-theme TK1 behaviour.
    public static var borderThickness: CGFloat {
        Theme.shared.chrome.headingBorderThickness
    }

    /// Gap between the last line of heading text and the hairline.
    /// Default theme value = 1.0pt, matching TK1's `+ 1` below
    /// `usedRect.maxY`.
    public static var borderOffsetBelowText: CGFloat {
        Theme.shared.chrome.headingBorderOffsetBelowText
    }

    // MARK: - Heading level lookup

    /// Read the heading level (1...6) from the element's backing
    /// attributed string. `DocumentRenderer` tags every character of a
    /// heading paragraph with `.headingLevel = <Int>`. Returns 0 for
    /// non-heading content or for levels outside 1...6.
    internal var headingLevel: Int {
        guard let paragraph = textElement as? NSTextParagraph else { return 0 }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else { return 0 }
        let raw = attributed.attribute(.headingLevel, at: 0, effectiveRange: nil)
        if let intVal = raw as? Int, intVal >= 1, intVal <= 6 {
            return intVal
        }
        return 0
    }

    // MARK: - Folded-state lookup

    /// True when the character IMMEDIATELY FOLLOWING this heading
    /// element carries `.foldedContent`. `TextStorageProcessor.toggleFold`
    /// writes the attribute over the range from the header-line end to
    /// the next same-level header, so peeking at `endOffset` is
    /// sufficient — that slot is always inside the fold range when the
    /// heading is collapsed, and never inside one otherwise.
    ///
    /// Returns `false` when the fragment has no content manager, no
    /// element range, or is at end-of-storage (no trailing content to
    /// fold).
    internal var isFolded: Bool {
        guard let contentStorage =
                textLayoutManager?.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage,
              let elementRange = textElement?.elementRange
        else { return false }
        let docStart = contentStorage.documentRange.location
        let endOffset = contentStorage.offset(
            from: docStart, to: elementRange.endLocation
        )
        guard endOffset >= 0, endOffset < storage.length else {
            return false
        }
        return storage.attribute(
            .foldedContent, at: endOffset, effectiveRange: nil
        ) != nil
    }

    // MARK: - Heading body font lookup

    /// Returns the body font of the heading's first glyph, used to
    /// scale the folded-indicator font. Falls back to the theme body
    /// font size at default weight.
    internal var headingBodyFont: NSFont {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           let font = paragraph.attributedString.attribute(
            .font, at: 0, effectiveRange: nil
           ) as? NSFont {
            return font
        }
        return NSFont.systemFont(
            ofSize: Theme.shared.typography.bodyFontSize
        )
    }

    // MARK: - Rendering surface

    /// The hairline must span the full text container width — edge to
    /// edge with no `lineFragmentPadding` inset, matching TK1. The
    /// default `renderingSurfaceBounds` is `layoutFragmentFrame`, which
    /// for an H1 usually starts at container x=0 and spans the full
    /// width, so the default would often work. We override to guarantee
    /// the surface reaches the container's left edge in every case
    /// (defensive for fragments with non-zero origin).
    public override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        let containerWidth =
            textLayoutManager?.textContainer?.size.width ?? frame.width
        let localLeft = -frame.origin.x
        return CGRect(
            x: localLeft,
            y: 0,
            width: containerWidth,
            height: frame.height
        )
    }

    // MARK: - Folded-indicator geometry (pure helper for tests)

    /// Pure helper that computes the folded-indicator chip rect given
    /// the heading's last-line typographic bounds + body font size.
    /// Isolated as a static so it can be unit-tested without any TK2
    /// delegate setup. Returns `nil` when `folded == false`.
    ///
    /// Coordinates are expressed in the fragment's local space (origin
    /// matches `layoutFragmentFrame.origin`). The caller adds the draw
    /// `point` when passing the rect to Core Graphics.
    ///
    /// - Parameters:
    ///   - folded: Whether the heading is in a folded state.
    ///   - lastLineTypographicBounds: `typographicBounds` of the
    ///     last `NSTextLineFragment` of the heading.
    ///   - bodyFontSize: Point size of the heading's body font.
    ///   - chrome: Active `ThemeChrome` — supplies padding, corner
    ///     radius, font multiplier, and trailing gap.
    /// - Returns: The chip rect in fragment-local coordinates, or
    ///   `nil` when the heading isn't folded.
    public static func indicatorRect(
        folded: Bool,
        lastLineTypographicBounds: CGRect,
        bodyFontSize: CGFloat,
        chrome: ThemeChrome
    ) -> CGRect? {
        guard folded else { return nil }
        let indicatorFontSize =
            bodyFontSize * chrome.foldedHeaderIndicatorFontSizeMultiplier
        // Measure "..." at indicator font size to size the chip.
        let font = NSFont.systemFont(ofSize: indicatorFontSize)
        let textSize = NSAttributedString(
            string: indicatorText,
            attributes: [.font: font]
        ).size()
        let padH = chrome.foldedHeaderIndicatorHorizontalPadding
        let padV = chrome.foldedHeaderIndicatorVerticalPadding
        let chipW = ceil(textSize.width) + 2 * padH
        let chipH = ceil(textSize.height) + 2 * padV
        let x = lastLineTypographicBounds.maxX
            + chrome.foldedHeaderIndicatorTrailingGap
        // Vertically center against the last line's box.
        let y = lastLineTypographicBounds.midY - chipH / 2
        return CGRect(x: x, y: y, width: chipW, height: chipH)
    }

    /// The literal characters drawn inside the chip. Three ASCII dots
    /// — consistent with the "folded" metaphor and free of Unicode
    /// ambiguity (a single `…` glyph rendered at a tiny size is often
    /// unreadable).
    public static let indicatorText: String = "..."

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        // Bug #51: paint inline-code chrome behind any `.inlineCodeRange`
        // runs in the heading text BEFORE super.draw paints the glyphs.
        InlineCodeChromeDrawer.paint(in: self, at: point, context: context)
        // Draw the heading text first — the hairline and the folded
        // indicator sit alongside / below the text, so paint order is:
        // text, then rule, then indicator.
        super.draw(at: point, in: context)

        guard let lastLine = textLineFragments.last else { return }
        let lineBottom = lastLine.typographicBounds.maxY
        let level = headingLevel

        // Hairline for H1 / H2.
        if level >= 1, level <= 2 {
            // Map to drawing-context space: the fragment origin lands at
            // `point`, so fragment-local y adds to `point.y`.
            let hairlineY = point.y + lineBottom + Self.borderOffsetBelowText

            // The hairline spans the full text container width, edge to
            // edge (no lineFragmentPadding inset). Container's left edge
            // in context space is at `point.x - layoutFragmentFrame.origin.x`.
            let container = textLayoutManager?.textContainer
            let containerWidth = container?.size.width ?? layoutFragmentFrame.width
            let containerOriginX = point.x - layoutFragmentFrame.origin.x

            context.saveGState()
            context.setStrokeColor(Self.borderColor.cgColor)
            context.setLineWidth(Self.borderThickness)
            context.move(to: CGPoint(x: containerOriginX, y: hairlineY))
            context.addLine(
                to: CGPoint(x: containerOriginX + containerWidth, y: hairlineY)
            )
            context.strokePath()
            context.restoreGState()
        }

        // Folded-state indicator (any heading level).
        if let local = Self.indicatorRect(
            folded: isFolded,
            lastLineTypographicBounds: lastLine.typographicBounds,
            bodyFontSize: headingBodyFont.pointSize,
            chrome: Theme.shared.chrome
        ) {
            drawFoldedIndicator(in: context, atDrawOrigin: point, localRect: local)
        }
    }

    // MARK: - Indicator draw

    /// Paint the chip + "..." text at `localRect + point`.
    private func drawFoldedIndicator(
        in context: CGContext,
        atDrawOrigin point: CGPoint,
        localRect: CGRect
    ) {
        let chrome = Theme.shared.chrome
        let fg = chrome.foldedHeaderIndicatorForeground
            .resolvedForCurrentAppearance(
                fallback: NSColor(
                    red: 0.533, green: 0.533, blue: 0.533, alpha: 1.0
                )
            )
        let bg = chrome.foldedHeaderIndicatorBackground
            .resolvedForCurrentAppearance(
                fallback: NSColor(
                    red: 0.898, green: 0.898, blue: 0.898, alpha: 0.5
                )
            )
        let rect = CGRect(
            x: point.x + localRect.origin.x,
            y: point.y + localRect.origin.y,
            width: localRect.width,
            height: localRect.height
        )

        // Fill the rounded chip.
        context.saveGState()
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: chrome.foldedHeaderIndicatorCornerRadius,
            cornerHeight: chrome.foldedHeaderIndicatorCornerRadius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(bg.cgColor)
        context.fillPath()
        context.restoreGState()

        // Draw the "..." text centered inside the chip.
        let indicatorFontSize =
            headingBodyFont.pointSize
            * chrome.foldedHeaderIndicatorFontSizeMultiplier
        let font = NSFont.systemFont(ofSize: indicatorFontSize)
        let attrString = NSAttributedString(
            string: Self.indicatorText,
            attributes: [
                .font: font,
                .foregroundColor: fg
            ]
        )
        let textSize = attrString.size()
        let textOrigin = CGPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )

        // `NSAttributedString.draw(at:)` respects the current graphics
        // context — wire up AppKit focus so the draw lands in `context`.
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = nsContext
        attrString.draw(at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()
    }
}
