//
//  InlineCodeChromeDrawer.swift
//  FSNotesCore
//
//  Bug #51 — shared painter for inline `` `code` `` chrome.
//
//  Inline code spans can appear inside ANY block kind: plain paragraphs,
//  list items, headings, blockquotes, kbd-paragraphs. So unlike the
//  per-block-element kbd box (which is paragraph-tagged and dispatched
//  to its own fragment subclass), inline-code chrome is a generic
//  post-text-draw step that every text-flow fragment subclass calls
//  before super.draw paints the glyphs on top.
//
//  Each call site:
//      InlineCodeChromeDrawer.paint(in: self, at: point, context: context)
//      super.draw(at: point, in: context)
//
//  The helper enumerates `.inlineCodeRange` runs, computes per-line
//  rectangles via `textLineFragments`, and fills a rounded rect for
//  each. Stroke is drawn iff `theme.chrome.inlineCodeBorderWidth > 0`.
//
//  Fragments that intentionally skip this step:
//      • CodeBlockLayoutFragment — text is already in a code block;
//        chrome would compound visually.
//      • MermaidLayoutFragment / MathLayoutFragment / DisplayMathLayoutFragment
//        — replace text with bitmaps, no inline code spans visible.
//      • Table cell subviews — cell-level inline code lives inside
//        cell text and the cell renderer owns that paint pass already
//        (out of scope for #51).
//      • HorizontalRuleLayoutFragment — no text content.
//      • FoldedLayoutFragment — zero-height no-op.
//      • SourceLayoutFragment — source mode shows raw `` ` `` markers,
//        chrome would conflict with the marker-painting pass.
//

import AppKit

public enum InlineCodeChromeDrawer {

    // MARK: - Theme accessors

    public static var fillColor: NSColor {
        Theme.shared.colors.inlineCodeBackground.resolvedForCurrentAppearance(
            fallback: NSColor(red: 0.94, green: 0.94, blue: 0.94, alpha: 1.0)
        )
    }

    public static var cornerRadius: CGFloat {
        Theme.shared.chrome.inlineCodeCornerRadius
    }

    public static var borderWidth: CGFloat {
        Theme.shared.chrome.inlineCodeBorderWidth
    }

    public static var horizontalPadding: CGFloat {
        Theme.shared.chrome.inlineCodeHorizontalPadding
    }

    public static var verticalPaddingTop: CGFloat {
        Theme.shared.chrome.inlineCodeVerticalPaddingTop
    }

    public static var verticalPaddingBottom: CGFloat {
        Theme.shared.chrome.inlineCodeVerticalPaddingBottom
    }

    // MARK: - Paint

    /// Paint inline-code chrome rectangles behind every `.inlineCodeRange`
    /// run in `fragment`'s backing attributed string. Call BEFORE
    /// `super.draw(at:in:)` so the text glyphs render on top of the fill.
    ///
    /// `point` is the fragment-origin location in drawing-context space,
    /// matching the parameter passed to `NSTextLayoutFragment.draw`.
    public static func paint(
        in fragment: NSTextLayoutFragment,
        at point: CGPoint,
        context: CGContext
    ) {
        guard let paragraph = fragment.textElement as? NSTextParagraph else { return }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributed.length)

        context.saveGState()
        defer { context.restoreGState() }

        attributed.enumerateAttribute(
            .inlineCodeRange,
            in: fullRange,
            options: []
        ) { value, runRange, _ in
            guard value != nil, runRange.length > 0 else { return }
            paintOneRun(
                fragment: fragment,
                range: runRange,
                at: point,
                context: context
            )
        }
    }

    /// Paint one contiguous `.inlineCodeRange` run. If the run wraps
    /// across a line break, one box per line slice (matches the
    /// `KbdBoxParagraphLayoutFragment` line-fragment loop).
    private static func paintOneRun(
        fragment: NSTextLayoutFragment,
        range: NSRange,
        at point: CGPoint,
        context: CGContext
    ) {
        let hPad = horizontalPadding
        let vTop = verticalPaddingTop
        let vBot = verticalPaddingBottom
        let radius = cornerRadius
        let border = borderWidth

        for line in fragment.textLineFragments {
            let lineRange = line.characterRange
            let slice = NSIntersectionRange(range, lineRange)
            if slice.length == 0 { continue }

            let startX = line.locationForCharacter(at: slice.location).x
            let endX = line.locationForCharacter(
                at: slice.location + slice.length
            ).x
            let lineBounds = line.typographicBounds

            let rect = CGRect(
                x: point.x + lineBounds.origin.x + startX - hPad,
                y: point.y + lineBounds.origin.y - vTop,
                width: (endX - startX) + 2 * hPad,
                height: lineBounds.height + vTop + vBot
            )
            guard rect.width > 0, rect.height > 0 else { continue }

            let path = CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.setFillColor(fillColor.cgColor)
            context.addPath(path)
            context.fillPath()

            if border > 0 {
                context.addPath(path)
                context.setStrokeColor(fillColor.cgColor)
                context.setLineWidth(border)
                context.strokePath()
            }
        }
    }
}
