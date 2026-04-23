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

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        // Draw the heading text first — the hairline sits BELOW the text
        // so paint order is: text, then rule.
        super.draw(at: point, in: context)

        let level = headingLevel
        guard level >= 1, level <= 2 else { return }

        // We need the bottom of the LAST rendered line (to handle
        // wrapped headings). `textLineFragments` is fragment-local:
        // each `.typographicBounds` is expressed in the fragment's
        // coordinate space (origin at `layoutFragmentFrame.origin`).
        guard let lastLine = textLineFragments.last else { return }
        let lineBottom = lastLine.typographicBounds.maxY

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
}
