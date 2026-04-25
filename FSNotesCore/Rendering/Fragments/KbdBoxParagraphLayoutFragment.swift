//
//  KbdBoxParagraphLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2d — Custom NSTextLayoutFragment for paragraphs containing
//  one or more `<kbd>…</kbd>` runs.
//
//  Pairs with `ParagraphWithKbdElement`. Draws a rounded-rect
//  "keyboard key" decoration BEHIND each `.kbdTag` attribute run,
//  then calls `super.draw(at:in:)` so the text glyphs render on top.
//
//  Dispatched only for paragraphs that actually contain kbd tags —
//  `DocumentRenderer` upgrades the paragraph's `.blockModelKind` to
//  `.paragraphWithKbd` during the tagging pass when it detects at
//  least one `.kbdTag` run in the rendered attributed string. Every
//  other paragraph keeps the default `NSTextLayoutFragment` so we
//  don't pay fragment-dispatch overhead on 99%+ of paragraphs.
//
//  Visual parity with the TK1 `KbdBoxDrawer`:
//    - fill   : `#fcfcfc` (RGB 0.988 × 3)
//    - border : 1pt stroke in `#ccc` (RGB 0.8 × 3)
//    - shadow : 1pt line at rect.maxY inset 1pt, `#bbb` (RGB 0.733 × 3)
//    - radius : 3pt
//    - padding: 2pt horizontal, 1pt top, 2pt bottom (relative to the
//               kbd glyph bounds). Matches `KbdBoxDrawer.draw` exactly
//               so a note that flips between source-mode and block-
//               model shows no visual shift.
//
//  Geometry is computed per-line via `textLineFragments`. If a kbd
//  run wraps across a line break, each line slice gets its own box
//  (same behavior as TK1's `boundingRect(forGlyphRange:)`-driven
//  draw). In practice kbd tags rarely wrap; the degenerate case is
//  handled safely.
//

import AppKit

public final class KbdBoxParagraphLayoutFragment: NSTextLayoutFragment {

    // MARK: - Drawing constants (phase 7.3 — read from Theme.shared)
    //
    // Static computed properties so external references keep working;
    // the live drawing path uses the same theme-backed values. Default-
    // theme values in `ThemeSchema.swift` match the pre-theme TK1
    // `KbdBoxDrawer` byte-for-byte:
    //   fillColor   = `#FCFCFC` (0.988 × 3)
    //   strokeColor = `#CCCCCC` (0.8 × 3)
    //   shadowColor = `#BBBBBB` (0.733 × 3)
    //   cornerRadius = 3, borderWidth = 1
    //   horizontalPadding = 2, verticalPaddingTop/Bottom = 1
    //
    // `KbdBoxDrawer.draw` expands the glyph bounds by `height + 2`,
    // which is `verticalPaddingTop + verticalPaddingBottom = 1 + 1 = 2`.
    // Both paddings are intentionally 1.0; the 7.2 agent's note about
    // 0.0 vs 1.0 is resolved here — TK1 uses symmetric 1pt padding.

    public static var cornerRadius: CGFloat {
        Theme.shared.chrome.kbdCornerRadius
    }
    public static var borderWidth: CGFloat {
        Theme.shared.chrome.kbdBorderWidth
    }

    /// Fill color of the key face. Default theme = `#FCFCFC`
    /// (RGB 0.988 × 3), matching `KbdBoxDrawer`.
    public static var fillColor: NSColor {
        Theme.shared.colors.kbdFill.resolvedForCurrentAppearance(
            fallback: NSColor(red: 0.988, green: 0.988, blue: 0.988, alpha: 1.0)
        )
    }
    /// 1pt stroke around the whole box. Default theme = `#CCCCCC`
    /// (RGB 0.8 × 3).
    public static var strokeColor: NSColor {
        Theme.shared.colors.kbdStroke.resolvedForCurrentAppearance(
            fallback: NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0)
        )
    }
    /// Bottom shadow line — drawn inside the box 1pt above maxY to
    /// simulate the key's bottom bevel. Default theme = `#BBBBBB`
    /// (RGB 0.733 × 3).
    public static var shadowColor: NSColor {
        Theme.shared.colors.kbdShadow.resolvedForCurrentAppearance(
            fallback: NSColor(red: 0.733, green: 0.733, blue: 0.733, alpha: 1.0)
        )
    }

    /// Horizontal padding applied to each side of the glyph bounds.
    /// Default theme = 2.0pt, matching `KbdBoxDrawer.draw`'s
    /// `rect.minX - 2` / `width + 4`.
    public static var horizontalPadding: CGFloat {
        Theme.shared.chrome.kbdHorizontalPadding
    }

    /// Vertical padding applied to top (1pt) and bottom (1pt) of the
    /// glyph bounds, for a total vertical expansion of 2pt (`height + 2`
    /// in `KbdBoxDrawer.draw`).
    public static var verticalPaddingTop: CGFloat {
        Theme.shared.chrome.kbdVerticalPaddingTop
    }
    public static var verticalPaddingBottom: CGFloat {
        Theme.shared.chrome.kbdVerticalPaddingBottom
    }

    // MARK: - Rendering surface
    //
    // Kbd boxes bleed 2pt horizontally past the glyph edges. Widen
    // the rendering surface defensively so TK2 doesn't clip the
    // rounded corners or the border on the right side of a kbd run.
    public override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        let bleed = Self.horizontalPadding + Self.borderWidth
        // Default rendering surface is the frame; pad horizontally on
        // both sides so we have room for the kbd box at the very
        // start or end of a line.
        let localLeft = min(0, -frame.origin.x) - bleed
        let rightEdge = max(frame.width, frame.width - frame.origin.x) + bleed
        return CGRect(
            x: localLeft,
            y: 0,
            width: rightEdge - localLeft,
            height: frame.height
        )
    }

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        drawKbdBoxes(at: point, in: context)
        // Bug #51: paint inline-code chrome behind any `.inlineCodeRange`
        // runs in the same paragraph (kbd and inline-code can co-exist).
        // After kbd boxes so the relative paint order matches plain
        // paragraphs (chrome under text), before super.draw so text
        // renders on top.
        InlineCodeChromeDrawer.paint(in: self, at: point, context: context)
        // Text renders on top of the boxes so the kbd glyphs sit
        // legibly inside the key face.
        super.draw(at: point, in: context)
    }

    /// Enumerate every `.kbdTag` run in this fragment's backing
    /// attributed string, compute the glyph rect of each run via
    /// `textLineFragments`, and draw the kbd box behind it.
    private func drawKbdBoxes(at point: CGPoint, in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph else { return }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributed.length)

        context.saveGState()
        defer { context.restoreGState() }

        attributed.enumerateAttribute(
            .kbdTag,
            in: fullRange,
            options: []
        ) { value, runRange, _ in
            guard value != nil, runRange.length > 0 else { return }
            // The attribute's run range is in the element's local
            // character coordinates. Compute its geometry per line.
            drawOneRun(range: runRange, at: point, in: context)
        }
    }

    /// Draw kbd box(es) for one contiguous `.kbdTag` run. If the run
    /// wraps across a line break, one box per line slice.
    private func drawOneRun(
        range: NSRange,
        at point: CGPoint,
        in context: CGContext
    ) {
        for line in textLineFragments {
            let lineRange = line.characterRange
            let slice = NSIntersectionRange(range, lineRange)
            if slice.length == 0 { continue }

            // Convert slice bounds to x-positions on this line.
            let startX = line.locationForCharacter(at: slice.location).x
            let endX = line.locationForCharacter(
                at: slice.location + slice.length
            ).x
            let lineBounds = line.typographicBounds
            // textLineFragment typographicBounds are expressed
            // relative to the layout fragment's origin; `point.x` /
            // `point.y` translate into drawing-context space.
            let rect = CGRect(
                x: point.x + lineBounds.origin.x + startX
                    - Self.horizontalPadding,
                y: point.y + lineBounds.origin.y
                    - Self.verticalPaddingTop,
                width: (endX - startX) + 2 * Self.horizontalPadding,
                height: lineBounds.height
                    + Self.verticalPaddingTop
                    + Self.verticalPaddingBottom
            )
            guard rect.width > 0, rect.height > 0 else { continue }
            drawBox(rect: rect, in: context)
        }
    }

    private func drawBox(rect: CGRect, in context: CGContext) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )

        // Fill.
        context.setFillColor(Self.fillColor.cgColor)
        context.addPath(path)
        context.fillPath()

        // Border.
        context.addPath(path)
        context.setStrokeColor(Self.strokeColor.cgColor)
        context.setLineWidth(Self.borderWidth)
        context.strokePath()

        // Bottom shadow line — 1pt above maxY, inset 1pt on each side.
        // Gives the key a subtle 3D bevel without a full gradient.
        let shadowY = rect.maxY - 1.0
        context.setStrokeColor(Self.shadowColor.cgColor)
        context.setLineWidth(1.0)
        context.beginPath()
        context.move(to: CGPoint(x: rect.minX + 1, y: shadowY))
        context.addLine(to: CGPoint(x: rect.maxX - 1, y: shadowY))
        context.strokePath()
    }
}
