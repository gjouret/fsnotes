//
//  BlockSourceTextAttachment.swift
//  FSNotesCore
//
//  Minimal `NSTextAttachment` subclass used as a single-character stand-in
//  for block-level content whose source is carried on an attribute rather
//  than stored verbatim in the `NSTextContentStorage` paragraph text.
//
//  Why this exists
//  ---------------
//  `NSTextContentStorage` uses Unicode rules to split its backing store
//  into paragraphs — `\n`, `\r\n`, U+2029 are paragraph boundaries. For
//  block types that render as a single bitmap spanning multiple source
//  lines (mermaid diagrams, multi-line LaTeX), storing the source text
//  verbatim would cause the block to fragment across multiple paragraphs,
//  each producing its own `NSTextElement`. Each element would submit ONE
//  line to the renderer — and MermaidJS / MathJax reject single-line
//  inputs because one line isn't a valid diagram.
//
//  The fix: emit ONE `U+FFFC` (the Unicode attachment character) into
//  storage for the whole block, plus a `.renderedBlockSource` attribute
//  carrying the full source. The block's paragraph is then always one
//  character long, one `NSTextElement`, one `NSTextLayoutFragment`, one
//  render call. The fragment (`MermaidLayoutFragment` /
//  `MathLayoutFragment`) reads `.renderedBlockSource` to recover the
//  source and draws the rendered bitmap over the attachment's location.
//
//  Why suppress the default view provider
//  --------------------------------------
//  Under TK2, `NSTextAttachment` with no `.image`, no `attachmentCell`,
//  and no custom `viewProvider(...)` would still vend a default placeholder
//  (the generic "attachment" box icon). We do NOT want that box under our
//  rendered bitmap, so this subclass overrides `viewProvider(...)` to
//  return `nil`. The fragment owns all drawing.
//
//  This is deliberately different from the Phase 2d view-provider pattern
//  used for PDFs, QuickLook previews, and inline images. Those attachments
//  host a live `NSView` (a PDFView, an NSImageView, etc.) because the
//  content is interactive and/or dynamic. Mermaid/math diagrams render to
//  a static bitmap and the existing `MermaidLayoutFragment` /
//  `MathLayoutFragment` already own the draw — wrapping the bitmap in a
//  view provider would add one level of indirection without any benefit.
//
//  Trade-offs
//  ----------
//  - Find-in-note cannot match text inside mermaid / math source — the
//    source lives on an attribute, not in the paragraph string. This is
//    an accepted trade per the Phase 2d follow-up review.
//  - The old "emit source verbatim + U+2028 as soft line break" hack is
//    reverted. No cross-reader converter contract to maintain.
//

import AppKit

public final class BlockSourceTextAttachment: NSTextAttachment {

    /// The fragment (`MermaidLayoutFragment` / `MathLayoutFragment`) is
    /// responsible for drawing this block's rendered content. Returning
    /// `nil` suppresses TK2's default placeholder view so the fragment's
    /// drawn bitmap isn't layered on top of an "attachment" icon.
    public override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        return nil
    }
}
