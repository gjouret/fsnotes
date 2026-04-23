//
//  HorizontalRuleLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2c — Custom NSTextLayoutFragment for horizontal rules.
//
//  Pairs with `HorizontalRuleElement` (a `BlockModelElement` /
//  `NSTextParagraph` subclass wrapping a single space character — the
//  output of `HorizontalRuleRenderer.render`). The element's content is
//  a single space so the content storage has a selectable position for
//  the rule (RET / arrow-key navigation works without a zero-length
//  block); this fragment overrides `draw(at:in:)` to suppress the space
//  glyph draw and stroke a 4pt gray bar across the content rect in its
//  place. Color + thickness match the TK1 `HorizontalRuleDrawer`.
//
//  The fragment inherits its frame from `NSTextLayoutFragment`'s default
//  layout: the enclosing paragraph lays out the single space character
//  at the editor's body font, producing a one-line fragment whose height
//  is the body-font line height plus its paragraph spacing. The rule is
//  drawn at the vertical center of that frame.
//

import AppKit

public final class HorizontalRuleLayoutFragment: NSTextLayoutFragment {

    // MARK: - Drawing constants (phase 7.3 — read from Theme.shared)
    //
    // Static computed properties so external references keep working.
    // Default-theme values in `ThemeSchema.swift` match the pre-theme
    // TK1 `HorizontalRuleDrawer` byte-for-byte:
    // `hrLine` = `#E7E7E7` (RGB 0.906 × 3), `hrThickness` = 4.0pt.

    /// Rule fill color. Default theme = `#E7E7E7` (RGB 0.906 × 3) —
    /// identical to the TK1 `HorizontalRuleDrawer`.
    public static var ruleColor: NSColor {
        Theme.shared.colors.hrLine.resolvedForCurrentAppearance(
            fallback: NSColor(red: 0.906, green: 0.906, blue: 0.906, alpha: 1.0)
        )
    }

    /// Thickness of the drawn rule in points. Default theme = 4.0pt.
    public static var ruleThickness: CGFloat {
        Theme.shared.chrome.hrThickness
    }

    // MARK: - Rendering surface

    /// TK2 uses `renderingSurfaceBounds` to decide what area the fragment
    /// is allowed to paint. The default value is `layoutFragmentFrame`,
    /// which for our HR element is only as wide as the single space
    /// character that `HorizontalRuleRenderer` emits (~4pt). If we
    /// returned the default, TK2 would clip our 4pt gray bar to that
    /// tiny width and the rule would render as an invisible dot.
    ///
    /// We widen the surface to cover the full text container usable
    /// width so the bar actually shows. Coordinates are fragment-local
    /// (0,0 == `layoutFragmentFrame.origin`), so we shift the origin
    /// left by `layoutFragmentFrame.origin.x` to reach the container's
    /// left edge.
    public override var renderingSurfaceBounds: CGRect {
        let containerWidth =
            textLayoutManager?.textContainer?.size.width
                ?? layoutFragmentFrame.width
        let localLeft = -layoutFragmentFrame.origin.x
        return CGRect(
            x: localLeft,
            y: 0,
            width: containerWidth,
            height: layoutFragmentFrame.height
        )
    }

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        let frame = layoutFragmentFrame
        guard frame.height > 0 else {
            super.draw(at: point, in: context)
            return
        }

        // The rule mirrors the TK1 `HorizontalRuleDrawer`: spans the full
        // text container width minus `lineFragmentPadding` on both sides,
        // vertically centered in the fragment.
        //
        // Coordinate mapping: the drawing context is translated so that
        // drawing at `point` places content at the fragment's origin.
        // The text container's (0,0) in the drawing context is therefore
        // `point - layoutFragmentFrame.origin`. We draw the rule
        // spanning [padding, containerWidth − padding] in text-container
        // coords, which becomes [point.x − frame.origin.x + padding, …]
        // in the drawing context.
        let container = textLayoutManager?.textContainer
        let containerWidth = container?.size.width ?? frame.width
        let padding = container?.lineFragmentPadding ?? 0

        let containerOriginX = point.x - frame.origin.x
        let ruleStartX = containerOriginX + padding
        let ruleWidth = max(containerWidth - padding * 2, 0)

        let midY = point.y + frame.height / 2.0
        let ruleRect = CGRect(
            x: ruleStartX,
            y: midY - Self.ruleThickness / 2.0,
            width: ruleWidth,
            height: Self.ruleThickness
        )

        context.saveGState()
        context.setFillColor(Self.ruleColor.cgColor)
        context.fill(ruleRect)
        context.restoreGState()

        // Deliberately do NOT call `super.draw(at:in:)`. The element's
        // backing content is a single space character; drawing its line
        // fragments would paint an (invisible) space glyph, but more
        // importantly it would let NSTextLayoutManager composite text
        // insertion point rectangles on top of our rule. Suppressing
        // super keeps the rule as the only visible content of this
        // fragment.
    }
}
