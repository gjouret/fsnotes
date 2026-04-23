//
//  SourceLayoutFragment.swift
//  FSNotesCore
//
//  Phase 4.1 (dormant additive slice) — custom NSTextLayoutFragment for
//  `SourceRenderer`-emitted paragraphs. Paints `.markerRange`-tagged
//  runs in `Theme.shared.chrome.sourceMarker` as an overlay after the
//  default text draw.
//
//  This fragment is DEAD CODE in Phase 4.1 — no layout-manager delegate
//  dispatches to it and no call site consults `FeatureFlag.useSourceRendererV2`
//  yet. Phase 4.4 will:
//    1. Flip `useSourceRendererV2` on by default.
//    2. Flip source-mode rendering onto `SourceRenderer.render`.
//    3. Wire the layout-manager delegate to return `SourceLayoutFragment`
//       for any paragraph whose `.blockModelKind == .sourceMarkdown`
//       (and for a source-mode editor, return it for every paragraph
//       regardless of tag).
//
//  Draw model:
//    1. Invoke `super.draw(at:in:)` to paint default text (body font,
//       default foreground). This paints BOTH marker and content runs
//       in the standard text color.
//    2. Enumerate `.markerRange`-tagged runs in the fragment's
//       attributed string. For each, compute the glyph bounding rect
//       via `CTLine` and fill-paint the same glyphs in the theme's
//       `sourceMarker` color on top.
//
//  Why overlay rather than mutating storage's `.foregroundColor`:
//  storage is the source of truth and must stay free of view-layer
//  color decisions. Keeping the marker paint in the fragment means a
//  theme change (light → dark) repaints automatically without
//  re-rendering the document. This also matches rule 2 ("views render
//  data; views never write to data") — we read the storage attribute
//  and paint; we never write back.
//

import AppKit

public final class SourceLayoutFragment: NSTextLayoutFragment {

    // MARK: - Theme-backed marker color

    /// Foreground color used for `.markerRange`-tagged runs. Resolves
    /// `Theme.shared.chrome.sourceMarker` against the current
    /// appearance on every draw so a mode switch (light → dark)
    /// repaints without re-rendering the storage.
    public static var markerColor: NSColor {
        Theme.shared.chrome.sourceMarker.resolvedForCurrentAppearance(
            fallback: NSColor(white: 0.6, alpha: 1.0)
        )
    }

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        // 1. Default text draw — body font + default foreground across
        //    the whole fragment. Marker runs currently paint in the
        //    default text color here; step 2 overpaints them.
        super.draw(at: point, in: context)

        // 2. Locate `.markerRange` runs inside the fragment's text and
        //    overpaint them in the theme's marker color.
        guard let paragraph = textElement as? NSTextParagraph else { return }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else { return }

        paintMarkerRuns(
            in: attributed,
            at: point,
            context: context
        )
    }

    // MARK: - Marker overpaint

    /// Enumerate `.markerRange`-tagged runs in `attributed` and
    /// overlay-paint them in the theme's marker color. The overpaint
    /// draws the same glyph geometry as the default text draw so
    /// selection, insertion point math, and layout remain untouched —
    /// this is purely a color swap.
    private func paintMarkerRuns(
        in attributed: NSAttributedString,
        at point: CGPoint,
        context: CGContext
    ) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(
            .markerRange, in: fullRange, options: []
        ) { value, range, _ in
            guard value != nil else { return }
            paintRun(
                attributed: attributed,
                subrange: range,
                at: point,
                context: context
            )
        }
    }

    /// Paint a single `.markerRange` run in the theme marker color.
    /// Draws the run's glyphs as a `CTLine` at the baseline TK2
    /// assigns via the fragment's text-line-fragments table.
    ///
    /// Phase 4.1 scope: the skeleton is additive and dormant. It
    /// supports single-line runs inside a single text-line fragment,
    /// which covers every marker shape this slice emits (fences, `>`,
    /// `#`, `**`, `---`, inline markers). Phase 4.4 extends this to
    /// multi-line runs when hard-break + soft-wrap scenarios land live.
    private func paintRun(
        attributed: NSAttributedString,
        subrange: NSRange,
        at point: CGPoint,
        context: CGContext
    ) {
        for textLineFragment in textLineFragments {
            let lineRange = textLineFragment.characterRange
            // Compute the intersection between this line's range and
            // the marker run. If the run doesn't touch this line,
            // skip it.
            let intersection = NSIntersectionRange(lineRange, subrange)
            guard intersection.length > 0 else { continue }

            // Extract the run's attributed substring and re-color it
            // to the theme marker color. Keep every other attribute
            // (including font + marker tag itself) so the glyph
            // geometry matches `super.draw`.
            let mutableRun = NSMutableAttributedString(
                attributedString: attributed.attributedSubstring(from: intersection)
            )
            mutableRun.addAttribute(
                .foregroundColor,
                value: Self.markerColor,
                range: NSRange(location: 0, length: mutableRun.length)
            )

            // Find where in the line this sub-run starts. The
            // `typographicBounds` of the line is in fragment-local
            // coordinates (origin at the fragment's top-left); the
            // glyph locations within the line advance left-to-right
            // from the line's baseline origin.
            let lineOrigin = textLineFragment.typographicBounds.origin
            let baselineY = lineOrigin.y + textLineFragment.glyphOrigin.y

            // Advance width of the characters BEFORE the marker run
            // inside this line — used to position the overpaint.
            let prefixRange = NSRange(
                location: lineRange.location,
                length: intersection.location - lineRange.location
            )
            let prefixAdvance: CGFloat
            if prefixRange.length > 0 {
                let prefix = attributed.attributedSubstring(from: prefixRange)
                let prefixLine = CTLineCreateWithAttributedString(prefix as CFAttributedString)
                prefixAdvance = CGFloat(
                    CTLineGetTypographicBounds(prefixLine, nil, nil, nil)
                )
            } else {
                prefixAdvance = 0
            }

            // Draw the marker run at baseline. Coordinate mapping:
            // fragment-local (lineOrigin.x + prefixAdvance, baselineY)
            // translated by `point` (the fragment's origin in the
            // drawing context).
            let runLine = CTLineCreateWithAttributedString(
                mutableRun as CFAttributedString
            )
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(
                x: point.x + lineOrigin.x + prefixAdvance,
                y: point.y + baselineY
            )
            // Flip vertical so CT draws glyphs upright; TK2 context
            // comes in flipped from AppKit's NSTextView coordinate
            // system.
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(runLine, context)
            context.restoreGState()
        }
    }
}
