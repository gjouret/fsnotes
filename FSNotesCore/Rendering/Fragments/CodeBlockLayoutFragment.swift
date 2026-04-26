//
//  CodeBlockLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2c — Custom NSTextLayoutFragment for fenced code blocks.
//
//  Pairs with `CodeBlockElement`. Draws the gray rounded-rectangle
//  background (with a 1pt lightGray border) behind the code text, then
//  delegates to `super.draw(at:in:)` to render syntax-highlighted text
//  on top.
//
//  Under TK1 this background was painted by
//  `LayoutManager.drawCodeBlockBackground`, which reads visible code
//  block ranges from `NotesTextProcessor.codeBlockRanges` and paints
//  one rounded rect per block via `NSLayoutManager.drawBackground`.
//  TK2 never calls that path — composition flows exclusively through
//  `NSTextLayoutFragment.draw(at:in:)` — so without this fragment a
//  block-model editor shows code blocks with ZERO background, losing
//  the visual "code container" cue.
//
//  MULTI-LINE HANDLING. `MarkdownBlockParser` emits a single
//  `Block.codeBlock(language:content:raw:)` spanning every line between
//  fences, but `CodeBlockRenderer` renders that content with embedded
//  `\n` characters. TK2's `NSTextContentStorage` splits on `\n` into
//  separate paragraphs, so a multi-line code block arrives at the
//  delegate as MULTIPLE adjacent `CodeBlockElement`s → MULTIPLE
//  fragments. This fragment handles that by:
//    1. Drawing the background at CONTAINER width (not text width), so
//       short code lines still get a full-width box.
//    2. Detecting whether the fragment is at the START, MIDDLE, or END
//       of a run of adjacent code-block fragments — by peeking at the
//       `.blockModelKind` attribute on the character immediately
//       before / after its range. Corners round only on block
//       boundaries; the 1pt border is drawn only on the sides that
//       face non-code content. Interior fragments fill flat and
//       share edges with their neighbors, producing a single visually
//       continuous rounded-rect container.
//
//  Mermaid and math code blocks are dispatched elsewhere
//  (`MermaidLayoutFragment` / `MathLayoutFragment`), so this fragment
//  only ever sees a `CodeBlockElement` — the generic/plain-code case.
//
//  Visual parity with the TK1 drawer: same background color (pulled
//  from the active syntax-highlight theme so dark/light modes agree),
//  same 1pt lightGray border, same 5pt corner radius, same 5pt
//  horizontal bleed so the rect is slightly wider than the text's
//  natural bounds.
//

import AppKit
import STTextKitPlus

public final class CodeBlockLayoutFragment: NSTextLayoutFragment {

    // MARK: - Drawing constants (phase 7.3 — read from Theme.shared)
    //
    // Static computed properties so external references (including
    // `Tests/TextKit2FragmentDispatchTests.swift` which asserts on
    // `horizontalBleed`) keep working. Default-theme values in
    // `ThemeSchema.swift` match the pre-theme TK1
    // `LayoutManager.drawCodeBlockBackground` constants byte-for-byte:
    // cornerRadius = 5, horizontalBleed = 5, borderWidth = 1.
    //
    // Border COLOR remains `NSColor.lightGray` (a dynamic system color
    // that adapts to dark mode). The theme schema has `codeBlockBorder`
    // but its current default (`#D3D3D3`) doesn't match `NSColor.lightGray`
    // byte-for-byte, so routing the border color through the theme in
    // slice 7.3 would be a visual change — deferred to a later slice
    // that explicitly reconciles the default.

    /// Corner radius of the rounded rectangle. Default theme = 5.0pt.
    public static var cornerRadius: CGFloat {
        Theme.shared.chrome.codeBlockCornerRadius
    }

    /// Horizontal bleed on either side of the text container's
    /// content edge so the background reaches slightly beyond the
    /// normal text inset. Default theme = 5.0pt, matching TK1's
    /// `horizontalPadding`.
    public static var horizontalBleed: CGFloat {
        Theme.shared.chrome.codeBlockHorizontalBleed
    }

    /// Border width of the 1pt stroke around the rect. Default
    /// theme = 1.0pt.
    public static var borderWidth: CGFloat {
        Theme.shared.chrome.codeBlockBorderWidth
    }

    // MARK: - Block-run position
    //
    // A multi-line code block arrives as multiple adjacent fragments
    // (TK2 paragraph-splits on `\n` inside the rendered code content).
    // We want visual continuity across those fragments: one continuous
    // rounded rect, not N stacked rects. Derive the position by
    // peeking at `.blockModelKind` on the neighbor character to the
    // left/right of this fragment's range.

    /// Position of this fragment within an adjacent run of code-block
    /// fragments.
    ///   - `.single`: neither side is code — one-line block, full round.
    ///   - `.first` : next side is code, prev side is not.
    ///   - `.middle`: both sides are code — flat rect in the middle.
    ///   - `.last`  : prev side is code, next side is not.
    internal enum BlockRunPosition {
        case single, first, middle, last

        var roundsTop: Bool { self == .single || self == .first }
        var roundsBottom: Bool { self == .single || self == .last }
        var drawsTopBorder: Bool { roundsTop }
        var drawsBottomBorder: Bool { roundsBottom }
    }

    internal var blockRunPosition: BlockRunPosition {
        guard let contentStorage =
                textLayoutManager?.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage,
              let elementRange = textElement?.elementRange
        else {
            return .single
        }
        // Convert the fragment's NSTextRange to character offsets in
        // the underlying NSTextStorage so we can read attributes at
        // neighbor positions.
        let startOffset = NSRange(elementRange.location, in: contentStorage).location
        let endOffset = NSRange(elementRange.endLocation, in: contentStorage).location
        guard startOffset >= 0, endOffset >= startOffset,
              endOffset <= storage.length else { return .single }

        let prevIsCode: Bool = {
            let prev = startOffset - 1
            guard prev >= 0 else { return false }
            let kind = storage.attribute(
                .blockModelKind, at: prev, effectiveRange: nil
            ) as? String
            return kind == BlockModelKind.codeBlock.rawValue
        }()
        let nextIsCode: Bool = {
            // endOffset is one-past the last char in the fragment.
            // The separator between blocks is typically a `\n` that
            // sits at `endOffset`; the NEXT paragraph's first char is
            // `endOffset + 1` — but for adjacent paragraphs of the
            // same kind, `endOffset` itself belongs to the separator
            // whose attributes carry over from the previous paragraph.
            // Peek at `endOffset` first; if that slot is outside the
            // storage or has a different kind, we are the last.
            guard endOffset < storage.length else { return false }
            let kindAtBoundary = storage.attribute(
                .blockModelKind, at: endOffset, effectiveRange: nil
            ) as? String
            if kindAtBoundary == BlockModelKind.codeBlock.rawValue {
                return true
            }
            // Also peek one char further — some storage layouts put
            // the kind only on non-separator chars, so the next
            // paragraph starts at `endOffset + 1`.
            let probe = endOffset + 1
            guard probe < storage.length else { return false }
            let kindAtProbe = storage.attribute(
                .blockModelKind, at: probe, effectiveRange: nil
            ) as? String
            return kindAtProbe == BlockModelKind.codeBlock.rawValue
        }()

        switch (prevIsCode, nextIsCode) {
        case (false, false): return .single
        case (false, true):  return .first
        case (true,  true):  return .middle
        case (true,  false): return .last
        }
    }

    // MARK: - Rendering surface
    //
    // The background rect spans the full text container width, bleeding
    // `horizontalBleed` points beyond the padding inset on each side.
    // Widen the rendering surface to match so TK2 doesn't clip the paint
    // to the fragment's text-natural frame width.
    public override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        let containerWidth = textLayoutManager?
            .textContainer?
            .size
            .width ?? frame.width
        let bleed = Self.horizontalBleed + Self.borderWidth

        // Left edge in fragment-local coordinates. The fragment's
        // origin lands at x=0 in its own surface; the container's left
        // edge is at `-frame.origin.x`.
        let localLeft = -frame.origin.x - bleed
        let localRight = -frame.origin.x + containerWidth + bleed
        return CGRect(
            x: localLeft,
            y: 0,
            width: localRight - localLeft,
            height: frame.height
        )
    }

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        drawBackground(at: point, in: context)
        // Text and syntax-highlight attributes paint on top of the
        // background. The fragment's intrinsic line layout does the
        // right thing — code-font + foreground-color runs are already
        // on the attributed string.
        super.draw(at: point, in: context)
    }

    private func drawBackground(at point: CGPoint, in context: CGContext) {
        let frame = layoutFragmentFrame
        // Bug #31: do NOT gate on `frame.width > 0`. A code block whose
        // body contains a blank line produces an EMPTY paragraph between
        // the two non-empty lines; that paragraph's glyph-natural width
        // is zero, so its `layoutFragmentFrame.width` is also zero. The
        // background rect, however, is sized off the text CONTAINER's
        // width (so every line in the block paints a uniform full-width
        // rect, see comment below), not the fragment frame's natural
        // width. Gating on `frame.width > 0` would skip the bg paint on
        // every blank line and leave a visible white strip in the middle
        // of the block — the visible "shading interrupted" bug. The
        // container-derived `width > 0` guard further down is the
        // correct degenerate-case backstop. `frame.height > 0` stays:
        // a zero-height fragment has nothing to paint regardless.
        guard frame.height > 0 else { return }

        // Container-width rect: x = containerLeft + padding - bleed,
        // width = containerContentWidth + 2 * bleed. This makes every
        // code-block fragment paint a uniform full-width rect, so short
        // and long code lines share the same visual container.
        let container = textLayoutManager?.textContainer
        let containerWidth = container?.size.width ?? frame.width
        let padding = container?.lineFragmentPadding ?? 0
        let containerOriginX = point.x - frame.origin.x

        let left = containerOriginX + padding - Self.horizontalBleed
        let width = containerWidth - 2 * padding + 2 * Self.horizontalBleed
        guard width > 0 else { return }

        // Position-aware vertical clipping:
        //
        // TK2 includes paragraph-spacing (above/below glyphs) in the
        // fragment frame. Filling the full frame paints into that
        // whitespace, which shows up as uneven padding at the block
        // boundaries — typically larger below the last line because
        // `paragraphSpacing` adds trailing space. But if we ALSO clip
        // interior fragments, we reintroduce the "stack of separate
        // boxes" bug because neighbors stop touching.
        //
        // The rule: clip only the OUTER boundary of the block run. An
        // interior fragment (or the interior side of a first/last)
        // fills its whole frame so it merges seamlessly with its
        // neighbor; the outer boundary hugs the true glyph bounds so
        // the block looks symmetric.
        let position = blockRunPosition
        let lines = textLineFragments
        let firstLineTop = lines.first?.typographicBounds.minY ?? 0
        let lastLineBottom = lines.last?.typographicBounds.maxY ?? frame.height

        let topYLocal: CGFloat = position.roundsTop ? firstLineTop : 0
        let bottomYLocal: CGFloat = position.roundsBottom ? lastLineBottom : frame.height
        let height = bottomYLocal - topYLocal
        guard height > 0 else { return }

        let topRadius = position.roundsTop ? Self.cornerRadius : 0
        let bottomRadius = position.roundsBottom ? Self.cornerRadius : 0

        let rect = CGRect(
            x: left,
            y: point.y + topYLocal,
            width: width,
            height: height
        )

        context.saveGState()
        defer { context.restoreGState() }

        // Fill: a closed path with conditional corner rounding.
        let fillPath = makeFillPath(
            rect: rect,
            topRadius: topRadius,
            bottomRadius: bottomRadius
        )
        context.setFillColor(Self.backgroundFillColor().cgColor)
        context.addPath(fillPath)
        context.fillPath()

        // Border: stroke only the sides that face non-code content.
        // Left and right always draw (they're always outer edges in a
        // vertical stack). Top draws only on a `.first`/`.single`,
        // bottom only on a `.last`/`.single`. Interior fragments share
        // their top/bottom edge with a neighbor and must NOT stroke it
        // — otherwise we'd paint hairlines every line boundary.
        context.setStrokeColor(NSColor.lightGray.cgColor)
        context.setLineWidth(Self.borderWidth)
        drawBorder(
            context: context,
            rect: rect,
            topRadius: topRadius,
            bottomRadius: bottomRadius,
            drawTop: position.drawsTopBorder,
            drawBottom: position.drawsBottomBorder
        )
    }

    // MARK: - Path construction

    /// Build a closed path for the fragment's background fill. Rounds
    /// only the corners indicated by non-zero radii; flat-top / flat-
    /// bottom variants are used for interior and boundary fragments
    /// of multi-line blocks.
    private func makeFillPath(
        rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()

        // Start at (minX + topRadius, minY) — the top edge's left end.
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        // Top edge → top-right corner start.
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        // Top-right corner. If radius is 0, addArc degenerates to a
        // line to the corner, preserving the closed shape.
        if topRadius > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
                radius: topRadius
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        // Right edge → bottom-right corner start.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        // Bottom-right corner.
        if bottomRadius > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
                radius: bottomRadius
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        // Bottom edge → bottom-left corner start.
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        // Bottom-left corner.
        if bottomRadius > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
                radius: bottomRadius
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        // Left edge → top-left corner start.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        // Top-left corner.
        if topRadius > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + topRadius, y: rect.minY),
                radius: topRadius
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }

    /// Stroke each visible edge of the border as a separate sub-path.
    /// Left and right always stroke; top strokes only when `drawTop`
    /// (first/single), bottom only when `drawBottom` (last/single).
    /// Rounded corners are walked as arcs; non-rounded sides as
    /// straight lines.
    private func drawBorder(
        context: CGContext,
        rect: CGRect,
        topRadius: CGFloat,
        bottomRadius: CGFloat,
        drawTop: Bool,
        drawBottom: Bool
    ) {
        // Left edge: always.
        context.beginPath()
        context.move(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius))
        context.strokePath()

        // Right edge: always.
        context.beginPath()
        context.move(to: CGPoint(x: rect.maxX, y: rect.minY + topRadius))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        context.strokePath()

        if drawTop {
            context.beginPath()
            // Top-left corner (arc) into top edge.
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
            if topRadius > 0 {
                context.addArc(
                    tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + topRadius, y: rect.minY),
                    radius: topRadius
                )
            }
            context.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
            if topRadius > 0 {
                context.addArc(
                    tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
                    radius: topRadius
                )
            }
            context.strokePath()
        }

        if drawBottom {
            context.beginPath()
            // Bottom-left corner (arc) into bottom edge.
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius))
            if bottomRadius > 0 {
                context.addArc(
                    tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY),
                    radius: bottomRadius
                )
            }
            context.addLine(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY))
            if bottomRadius > 0 {
                context.addArc(
                    tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius),
                    radius: bottomRadius
                )
            }
            context.strokePath()
        }
    }

    /// Phase 7.3: honor the active theme's `codeBlockBackground` override
    /// if set; otherwise fall back to the syntax-highlight theme's own
    /// background color (matching `LayoutManager.drawCodeBlockBackground`
    /// so TK1 source mode and TK2 block-model mode paint an identical
    /// rect). `NotesTextProcessor.getHighlighter()` reads the current
    /// theme (honoring dark/light appearance), so the fallback is
    /// appearance-aware without any explicit mode check here. The theme
    /// override is appearance-aware via `resolvedForCurrentAppearance`.
    private static func backgroundFillColor() -> NSColor {
        if let override = Theme.shared.colors.codeBlockBackground {
            let syntax = NotesTextProcessor.getHighlighter().options.style.backgroundColor
            return override.resolvedForCurrentAppearance(fallback: syntax)
        }
        return NotesTextProcessor.getHighlighter().options.style.backgroundColor
    }
}
