//
//  DisplayMathLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2d — Custom NSTextLayoutFragment for inline display math
//  (`$$…$$`) that appears as a paragraph's sole content.
//
//  Pairs with `DisplayMathElement`. The element backs a paragraph whose
//  sole inline is `Inline.displayMath(String)`; `DocumentRenderer`
//  detects that shape in `blockModelKind(for:)` and tags the paragraph
//  with `.blockModelKind = .displayMath` plus `.renderedBlockSource`
//  carrying the raw LaTeX source. The content-storage delegate routes
//  the paragraph to a `DisplayMathElement`; the layout-manager delegate
//  routes that element to this fragment.
//
//  Sibling of `MathLayoutFragment`. Both fragments render through
//  `BlockRenderer.render(source:type:.math)` — the only reason this is a
//  separate file (rather than a shared base class with `MathLayoutFragment`)
//  is that each block-kind owns its own fragment subclass, leaving room
//  for future divergence (e.g. display-math baseline alignment that
//  fenced math doesn't need) without touching the other.
//
//  Source-text handling is identical to `MathLayoutFragment`: the raw
//  LaTeX source stays in storage so `NSTextFinder` keeps working; the
//  fragment suppresses `super.draw(at:in:)` so no glyphs are painted,
//  then renders the MathJax bitmap centered in the text container.
//

import AppKit

public final class DisplayMathLayoutFragment: NSTextLayoutFragment {

    // MARK: - State

    /// Rendered bitmap. `nil` until the first `BlockRenderer.render`
    /// completion fires — synchronous on cache hit, async on cache miss.
    private var renderedImage: NSImage?

    /// Guards against kicking off the same render more than once while
    /// a cache-miss is in flight. Reset on completion.
    private var renderInFlight: Bool = false

    /// Placeholder height used before the render completes. Matches
    /// `MathLayoutFragment` so the layout feel is identical.
    private static let placeholderHeight: CGFloat = 40.0

    /// Fallback container width when `textContainer?.size.width` is
    /// zero (pre-layout) or missing. Matches `BlockRenderer.render`'s
    /// default `maxWidth: 480`.
    private static let fallbackContainerWidth: CGFloat = 480.0

    // MARK: - Source extraction

    /// Raw LaTeX source — extracted from `.renderedBlockSource` on the
    /// paragraph range. `DocumentRenderer` writes this attribute when
    /// it tags the paragraph `.blockModelKind = .displayMath`; the
    /// fragment reads it here without reaching back into the Document.
    /// Whitespace-trimmed to match `BlockRenderer.render` expectations
    /// (consistent with `MathLayoutFragment`).
    private var sourceText: String {
        guard let paragraph = textElement as? NSTextParagraph else { return "" }
        let attributed = paragraph.attributedString
        guard attributed.length > 0 else { return "" }
        // Prefer the `.renderedBlockSource` attribute — DocumentRenderer
        // writes the LaTeX source verbatim, untouched by whatever
        // placeholder text `InlineRenderer` emitted into storage.
        if let raw = attributed.attribute(
            .renderedBlockSource,
            at: 0,
            effectiveRange: nil
        ) as? String {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: use the placeholder string. `InlineRenderer`
        // currently emits the LaTeX source as the placeholder text
        // (see `.displayMath` branch), so this preserves behaviour if
        // the attribute ever fails to land.
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Target render width in points — the text container's usable
    /// width, which caps the rendered formula's maximum size.
    private var containerWidth: CGFloat {
        let width = textLayoutManager?.textContainer?.size.width ?? 0
        return width > 0 ? width : Self.fallbackContainerWidth
    }

    // MARK: - Layout

    /// Reserve enough vertical space for the rendered bitmap — TK2's
    /// default `layoutFragmentFrame` uses the backing text's natural
    /// height (one line for a single-line LaTeX source paragraph), but
    /// the rendered bitmap often spans multiple lines (e.g. the
    /// quadratic formula with a `\over` stacked fraction is 2–3 lines
    /// tall). Without this override, the bitmap escapes the fragment's
    /// allocated space and overlaps the fragments below.
    /// See `MermaidLayoutFragment.layoutFragmentFrame` for the full
    /// rationale (same bug class, same fix).
    public override var layoutFragmentFrame: CGRect {
        let base = super.layoutFragmentFrame
        let target: CGFloat
        if let image = renderedImage {
            let scale = min(containerWidth / image.size.width, 1.0)
            target = image.size.height * scale
        } else {
            target = Self.placeholderHeight
        }
        return CGRect(
            x: base.origin.x,
            y: base.origin.y,
            width: base.width,
            height: max(base.height, target)
        )
    }

    // MARK: - Rendering surface

    /// The rendered image is drawn starting at the text container's
    /// left edge and spanning the container's usable width, so the
    /// rendering surface must cover that full horizontal extent.
    /// Vertical extent is either the placeholder height (pre-render)
    /// or the scaled image height.
    public override var renderingSurfaceBounds: CGRect {
        let maxWidth = containerWidth
        let localLeft = -layoutFragmentFrame.origin.x

        if let image = renderedImage {
            let scale = min(maxWidth / image.size.width, 1.0)
            return CGRect(
                x: localLeft,
                y: 0,
                width: maxWidth,
                height: image.size.height * scale
            )
        }

        return CGRect(
            x: localLeft,
            y: 0,
            width: maxWidth,
            height: Self.placeholderHeight
        )
    }

    // MARK: - Drawing

    public override func draw(at point: CGPoint, in context: CGContext) {
        // Cache-hit path: completion fires synchronously inside this
        // call and populates `renderedImage` BEFORE we fall through to
        // the draw path below. See BlockRenderer cache-hit semantics.
        ensureRenderRequested()

        // Do NOT call `super.draw(at:in:)`: the paragraph's backing
        // attributed string is the LaTeX source (placeholder), which
        // we intentionally hide. If we called super, TK2 would paint
        // the raw source on top of (or instead of) the rendered image.
        //
        // Side effect: the source text IS in storage, so NSTextFinder
        // still finds symbols inside the formula. It just isn't painted.

        guard let image = renderedImage else {
            // Pre-render: leave the surface blank. A placeholder glyph
            // would flash out of existence once the WebView completes,
            // which is more visually noisy than a brief empty space.
            return
        }

        drawImage(image, at: point, in: context)
    }

    /// Draw the rendered bitmap centered horizontally in the text
    /// container, top-aligned to the fragment origin.
    private func drawImage(_ image: NSImage, at point: CGPoint, in context: CGContext) {
        let maxWidth = containerWidth
        let scale = min(maxWidth / image.size.width, 1.0)
        let scaledSize = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        // The text container's left edge sits at
        // `point.x - layoutFragmentFrame.origin.x` in drawing-context
        // coordinates. Center horizontally within the container width.
        let containerOriginX = point.x - layoutFragmentFrame.origin.x
        let leftX = containerOriginX + (maxWidth - scaledSize.width) / 2.0
        let targetRect = CGRect(
            x: leftX,
            y: point.y,
            width: scaledSize.width,
            height: scaledSize.height
        )

        context.saveGState()
        image.draw(in: targetRect)
        context.restoreGState()
    }

    // MARK: - Render kickoff

    /// Request a render from `BlockRenderer` if one hasn't been started
    /// yet and no image is cached locally. Idempotent: safe to call on
    /// every draw. Cache hits populate `renderedImage` synchronously
    /// inside this call; cache misses return immediately and schedule
    /// the main-queue completion that will re-invalidate us.
    private func ensureRenderRequested() {
        if renderedImage != nil { return }
        if renderInFlight { return }

        let source = sourceText
        guard !source.isEmpty else { return }

        renderInFlight = true
        let maxWidth = containerWidth

        BlockRenderer.render(
            source: source,
            type: .math,
            maxWidth: maxWidth
        ) { [weak self] image in
            guard let self = self else { return }
            self.renderInFlight = false
            if let image = image {
                self.renderedImage = image
                self.invalidateOwnLayout()
            }
        }
    }

    /// Invalidate this fragment's layout so TK2 re-runs draw with the
    /// image now populated. `NSTextLayoutFragment` does not expose a
    /// direct `invalidateLayout()` — we go through the owning layout
    /// manager with `rangeInElement` (an `NSTextRange`).
    private func invalidateOwnLayout() {
        guard let tlm = textLayoutManager else { return }
        let range = self.rangeInElement
        tlm.invalidateLayout(for: range)
    }
}
