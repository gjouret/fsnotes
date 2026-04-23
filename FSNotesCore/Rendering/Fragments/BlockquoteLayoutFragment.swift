//
//  BlockquoteLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2c — Custom NSTextLayoutFragment for blockquotes.
//
//  Pairs with `BlockquoteElement`. Draws the depth-stacked vertical gray
//  bars on the left edge of each blockquote paragraph (one bar per
//  nesting level), then delegates to `super.draw(at:in:)` to paint the
//  paragraph's text glyphs on top.
//
//  Under TK1, the bars were drawn by `BlockquoteBorderDrawer` via the
//  `AttributeDrawer` side-drawing path invoked from
//  `LayoutManager.drawBackground`. That path is never called under TK2 —
//  TK2 composes rendering through `NSTextLayoutFragment.draw(at:in:)`
//  only. This fragment is the TK2 equivalent so blockquote borders
//  survive the Phase 2 migration.
//
//  Depth encoding matches `BlockquoteRenderer`: the `.blockquote`
//  attribute is an `Int` nesting level on every character of the
//  paragraph's backing string. The rendered paragraph already has a
//  `headIndent` that clears the bars (set by `BlockquoteRenderer`), so
//  text and bars don't overlap.
//

import AppKit

public final class BlockquoteLayoutFragment: NSTextLayoutFragment {

    // MARK: - Drawing constants (phase 7.3 — read from Theme.shared)
    //
    // These are static computed properties so any remaining external
    // references keep working; the live drawing path uses the same
    // theme-backed values. Default-theme values in `ThemeSchema.swift`
    // match the pre-theme TK1 `BlockquoteBorderDrawer` constants
    // byte-for-byte (bar color 0.867×3 = `#DDDDDD`, width 4, spacing 10,
    // initial offset 2).

    /// Gray bar fill color. Default theme = `#DDDDDD` (RGB 0.867 × 3),
    /// identical to the TK1 `BlockquoteBorderDrawer`.
    public static var barColor: NSColor {
        Theme.shared.colors.blockquoteBar.resolvedForCurrentAppearance(
            fallback: NSColor(red: 0.867, green: 0.867, blue: 0.867, alpha: 1.0)
        )
    }

    /// Width of each individual bar in points. Default theme = 4pt.
    public static var barWidth: CGFloat {
        Theme.shared.chrome.blockquoteBarWidth
    }

    /// Horizontal distance between successive bars for nested quotes.
    /// Default theme = 10pt. Must match the spacing
    /// `BlockquoteRenderer` uses when computing `headIndent`.
    public static var barSpacing: CGFloat {
        Theme.shared.chrome.blockquoteBarSpacing
    }

    /// Offset from the container's padding edge to the first bar's left
    /// edge. Default theme = 2pt, matching TK1 (`+ 2` in
    /// `BlockquoteBorderDrawer`).
    public static var barInitialOffset: CGFloat {
        Theme.shared.chrome.blockquoteBarInitialOffset
    }

    // MARK: - Depth lookup

    /// Read the nesting depth from the element's backing attributed
    /// string. `BlockquoteRenderer` tags every character of a blockquote
    /// line with `.blockquote = <Int level>`. Returns 0 for non-blockquote
    /// content (which should not reach this fragment via the delegate
    /// dispatch, but we defend anyway).
    internal var blockquoteDepth: Int {
        guard let paragraph = textElement as? NSTextParagraph else { return 0 }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else { return 0 }
        let raw = attributed.attribute(.blockquote, at: 0, effectiveRange: nil)
        if let intVal = raw as? Int {
            return max(intVal, 0)
        }
        if raw is Bool {
            return 1
        }
        return 0
    }

    // MARK: - Rendering surface

    /// The default `renderingSurfaceBounds` equals `layoutFragmentFrame`.
    /// For a blockquote paragraph the frame typically starts at container
    /// x = 0 and the bars live at x = `padding + 2 + i * barSpacing`,
    /// which is already inside the frame — so the default would be fine.
    ///
    /// We nonetheless widen the surface to reach the container's left
    /// edge (using `layoutFragmentFrame.origin.x`) as a defensive measure
    /// for edge cases where TK2 gives us a frame whose origin is
    /// non-zero. Without this guard, a non-zero-origin fragment would
    /// clip the bars to negative-x space and they'd disappear. The TK2
    /// surface is expressed in fragment-local coordinates, so the
    /// container's left edge is at `-layoutFragmentFrame.origin.x`.
    public override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        let localLeft = min(0, -frame.origin.x)
        let rightEdge = max(frame.width, frame.width - frame.origin.x)
        return CGRect(
            x: localLeft,
            y: 0,
            width: rightEdge - localLeft,
            height: frame.height
        )
    }

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        let depth = blockquoteDepth
        // Draw bars first so text (drawn by super) paints on top.
        // Zero-depth == no bars; fall through to super-only.
        if depth > 0 {
            drawBars(depth: depth, at: point, in: context)
        }
        super.draw(at: point, in: context)
    }

    private func drawBars(depth: Int, at point: CGPoint, in context: CGContext) {
        let frame = layoutFragmentFrame
        guard frame.height > 0 else { return }

        // `point` is where the fragment origin lands in the drawing
        // context. The text container's left edge is at
        // `point.x - frame.origin.x` in that same space (frame.origin.x
        // is the fragment origin's distance from container origin).
        let container = textLayoutManager?.textContainer
        let padding = container?.lineFragmentPadding ?? 0
        let containerOriginX = point.x - frame.origin.x
        let baseX = containerOriginX + padding + Self.barInitialOffset

        context.saveGState()
        context.setFillColor(Self.barColor.cgColor)
        for i in 0..<depth {
            let barRect = CGRect(
                x: baseX + CGFloat(i) * Self.barSpacing,
                y: point.y,
                width: Self.barWidth,
                height: frame.height
            )
            context.fill(barRect)
        }
        context.restoreGState()
    }
}
