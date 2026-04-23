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

    // MARK: - Drawing constants (match KbdBoxDrawer)

    public static let cornerRadius: CGFloat = 3.0
    public static let borderWidth: CGFloat = 1.0

    /// Fill color of the key face. Matches `KbdBoxDrawer`'s
    /// `0.988 / 0.988 / 0.988` white.
    public static let fillColor = NSColor(
        red: 0.988, green: 0.988, blue: 0.988, alpha: 1.0
    )
    /// 1pt stroke around the whole box.
    public static let strokeColor = NSColor(
        red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0
    )
    /// Bottom shadow line — drawn inside the box 1pt above maxY to
    /// simulate the key's bottom bevel.
    public static let shadowColor = NSColor(
        red: 0.733, green: 0.733, blue: 0.733, alpha: 1.0
    )

    /// Horizontal padding applied to each side of the glyph bounds.
    /// Matches `KbdBoxDrawer.draw`'s `rect.minX - 2` / `width + 4`.
    public static let horizontalPadding: CGFloat = 2.0

    /// Vertical padding applied to top (1pt) and bottom (1pt extra)
    /// of the glyph bounds, for a total vertical expansion of 2pt
    /// (`height + 2`). Matches `KbdBoxDrawer.draw`.
    public static let verticalPaddingTop: CGFloat = 1.0
    public static let verticalPaddingBottom: CGFloat = 1.0

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
