//
//  MermaidLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2c — Custom NSTextLayoutFragment for mermaid code blocks.
//
//  Pairs with `MermaidElement`. The element's backing attributed string
//  is the raw mermaid source (the content of a ```mermaid ... ``` fence
//  — fences are NOT present in rendered storage, because `CodeBlockRenderer`
//  strips them). DocumentRenderer tags the range with
//  `.blockModelKind = .mermaid`, and the content-storage delegate
//  produces a `MermaidElement` the layout-manager delegate hands to this
//  fragment.
//
//  Unlike the old "render source, wrap NSImage in NSTextAttachment,
//  replaceCharacters over the code block range" mechanism, the source
//  text STAYS in storage. This keeps `NSTextFinder` / "Find in note"
//  working — a user can search for identifiers that appear inside the
//  diagram source. The fragment hides the source visually by suppressing
//  `super.draw(at:in:)` (no glyph painting) and draws the rendered SVG
//  bitmap on top.
//
//  Image lifecycle:
//   - On first draw, the fragment asks `BlockRenderer.render(...)`. If
//     the in-memory or disk cache has the image, the completion fires
//     synchronously in-line (see `BlockRenderer.render` at lines 76–88 of
//     BlockRenderer.swift — cache-hit path calls `completion(cached)` on
//     the caller's thread without dispatching), so we capture it before
//     the first draw returns. Result: cached diagrams paint on the first
//     frame, no flash of placeholder.
//   - On cache miss, `BlockRenderer.render` spawns an offscreen WKWebView
//     and calls back on the main queue when the snapshot is ready. The
//     fragment stores the image and invalidates its own layout so the
//     layout manager re-runs layout + draw; the cache is now warm, so
//     the next draw paints the image.
//

import AppKit

public final class MermaidLayoutFragment: NSTextLayoutFragment {

    // MARK: - State

    /// Rendered bitmap. `nil` until the first `BlockRenderer.render`
    /// completion fires — which may be synchronous (cache hit) during
    /// the first `draw(at:in:)` or asynchronous (cache miss, WebView
    /// snapshot) on the main queue.
    private var renderedImage: NSImage?

    /// Guards against kicking off the same render more than once while a
    /// cache-miss is in flight. Reset on completion regardless of
    /// success, so a failed render retries on the next draw.
    private var renderInFlight: Bool = false

    /// Placeholder height for the pre-render frame. Gives the layout
    /// engine visible vertical space while the WebView snapshot is
    /// being produced, so the document doesn't jump when the image
    /// arrives.
    private static let placeholderHeight: CGFloat = 40.0

    /// Fallback container width when `textContainer?.size.width` is
    /// zero (pre-layout) or missing. Matches `BlockRenderer.render`'s
    /// default `maxWidth: 480`.
    private static let fallbackContainerWidth: CGFloat = 480.0

    // MARK: - Source extraction

    /// Raw mermaid source text. `CodeBlockRenderer.render` emits a
    /// single-`U+FFFC` `BlockSourceTextAttachment` for mermaid blocks
    /// rather than the source verbatim, and `DocumentRenderer` tags
    /// the attachment's one-character range with `.renderedBlockSource`
    /// carrying the full source. We read that attribute here.
    ///
    /// Why source isn't stored as text: under `NSTextContentStorage`
    /// each `\n` is a paragraph boundary. Storing multi-line mermaid
    /// source verbatim split the block into one paragraph per line —
    /// each producing its own `MermaidElement` / `MermaidLayoutFragment`
    /// that fed a single source line to `BlockRenderer`, which fails
    /// (one line isn't a valid mermaid diagram). The attachment
    /// placeholder keeps the block as one paragraph; the attribute
    /// carries the multi-line source intact.
    ///
    /// Fallback to the paragraph's string content preserves behaviour
    /// for any legacy-rendered storage (e.g. a snapshot that predates
    /// the attachment switch).
    private var sourceText: String {
        guard let paragraph = textElement as? NSTextParagraph else { return "" }
        let attributed = paragraph.attributedString
        if attributed.length > 0,
           let raw = attributed.attribute(
               .renderedBlockSource, at: 0, effectiveRange: nil
           ) as? String {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Target render width in points — the text container's usable
    /// width, which caps the rendered SVG's maximum size.
    private var containerWidth: CGFloat {
        let width = textLayoutManager?.textContainer?.size.width ?? 0
        return width > 0 ? width : Self.fallbackContainerWidth
    }

    // MARK: - Layout

    /// Override the layout frame's height so TK2 reserves enough
    /// vertical space for the rendered bitmap. The fragment's backing
    /// storage is a single `U+FFFC` attachment character — TK2's default
    /// `layoutFragmentFrame` would be a one-line-tall frame, but we
    /// paint a bitmap spanning the full image height. Without this
    /// override, the bitmap draws past the fragment's allocated space
    /// and overlaps the fragments below (confirmed bug 2026-04-23: the
    /// mermaid diagram painted over the following `MathJax example`
    /// heading and paragraphs).
    ///
    /// The width is inherited from `super.layoutFragmentFrame` — TK2
    /// manages horizontal positioning within the text container. Only
    /// the height needs extending.
    public override var layoutFragmentFrame: CGRect {
        let base = super.layoutFragmentFrame
        let target = bitmapHeightOrPlaceholder()
        return CGRect(
            x: base.origin.x,
            y: base.origin.y,
            width: base.width,
            height: max(base.height, target)
        )
    }

    /// The rendered bitmap's height if known, else the pre-render
    /// placeholder height. Used by both `layoutFragmentFrame` (to
    /// reserve vertical space) and `renderingSurfaceBounds` (to define
    /// the draw surface). Keeping them in lockstep prevents the draw
    /// from escaping the frame.
    private func bitmapHeightOrPlaceholder() -> CGFloat {
        if let image = renderedImage {
            let scale = min(containerWidth / image.size.width, 1.0)
            return image.size.height * scale
        }
        return Self.placeholderHeight
    }

    // MARK: - Rendering surface

    /// The rendered image is drawn starting at the text container's left
    /// edge and spanning the container's usable width, so the rendering
    /// surface must cover that full horizontal extent. Vertical extent
    /// is either the placeholder height (pre-render) or the scaled image
    /// height.
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
        // Ensure a render has been requested. On a cache hit the
        // completion fires synchronously inside this call and
        // populates `renderedImage` BEFORE we fall through to the
        // draw path below — see BlockRenderer.render() cache-hit path
        // at BlockRenderer.swift:76–88.
        ensureRenderRequested()

        // Do NOT call `super.draw(at:in:)`: the element's backing
        // attributed string is the mermaid source text, which we are
        // intentionally hiding. If we called super, TK2 would paint
        // the raw source glyphs on top of (or instead of) the image.
        //
        // Side effect: the source text IS in storage, so NSTextFinder
        // still finds identifiers inside the diagram. It just isn't
        // painted.

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
            type: .mermaid,
            maxWidth: maxWidth
        ) { [weak self] image in
            // Cache-hit path: BlockRenderer calls this synchronously on
            // the current thread BEFORE `render` returns. We're still
            // inside `ensureRenderRequested` -> `draw(at:in:)`, so the
            // first draw will see `renderedImage` set and paint the
            // image on this same frame.
            //
            // Cache-miss path: the completion fires asynchronously on
            // the main queue after the WKWebView snapshot completes.
            // We invalidate our layout so TK2 re-runs draw with the
            // image now cached.
            guard let self = self else { return }
            self.renderInFlight = false
            if let image = image {
                self.renderedImage = image
                // Only invalidate if we're in the async path. The sync
                // (cache-hit) path is still inside the current draw —
                // invalidating now would create a redundant layout
                // pass. The `Thread.isMainThread` check is not a
                // reliable sync/async discriminator (BlockRenderer's
                // cache-hit is always on the caller's thread, which is
                // main here too); instead we rely on the fact that
                // during a sync cache hit `renderedImage` was nil at
                // `draw` entry and will be non-nil by the time `draw`
                // uses it. For the async path, TK2 has already finished
                // the prior draw frame — we must request a new one.
                //
                // Distinguishing the two cases cheaply: the async path
                // always enters a new run-loop tick, so scheduling
                // `invalidateLayout` via `DispatchQueue.main.async`
                // makes the sync path a no-op (the draw completes, the
                // async block runs, sees `renderedImage` already set,
                // and the invalidate is harmless because layout hasn't
                // changed). Simpler and correct: just always invalidate
                // — at worst one extra layout pass per mermaid block
                // the first time it appears.
                self.invalidateOwnLayout()
            }
        }
    }

    /// Invalidate this fragment's layout so TK2 re-runs draw with the
    /// image now populated. `NSTextLayoutFragment` does not expose a
    /// direct `invalidateLayout()` — we go through the owning layout
    /// manager with `rangeInElement` mapped into the content storage's
    /// coordinate space.
    private func invalidateOwnLayout() {
        guard let tlm = textLayoutManager else { return }
        // Prefer the fragment's own `rangeInElement` (an NSTextRange
        // directly) when available.
        let range = self.rangeInElement
        tlm.invalidateLayout(for: range)
    }
}
