//
//  DocumentProjection.swift
//  FSNotesCore
//
//  The bidirectional link between block-model coordinates and
//  textStorage coordinates. Holds a rendered Document + the index
//  maps that let editing operations translate between the two worlds.
//
//  ARCHITECTURAL CONTRACT:
//  - A DocumentProjection is immutable. Every edit produces a NEW
//    projection (via EditingOperations).
//  - `blockContaining(storageIndex:)` is the ONLY way to translate a
//    textStorage index into a block-model coordinate.
//  - The projection owns the invariant that every storage position
//    inside a block's rendered content maps to exactly one block.
//  - The projection maps storage index → (blockIndex, offsetInBlock).
//    Mapping WITHIN a block (e.g. into the inline tree) is owned by
//    EditingOperations per-block type.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// A value type holding a rendered Document plus the API for
/// translating between textStorage coordinates and block-model
/// coordinates.
public struct DocumentProjection {

    /// The rendered document — single source of truth for the
    /// projection's block spans and attributed output.
    public let rendered: RenderedDocument

    /// The fonts used to produce `rendered`. Carried so that editing
    /// operations can re-render with identical typography.
    public let bodyFont: PlatformFont
    public let codeFont: PlatformFont

    /// Optional note context threaded through to InlineRenderer so that
    /// inline images / PDFs can resolve their relative paths. Carried
    /// on the projection so EditingOperations can preserve it across
    /// re-renders.
    public let note: Note?

    /// Build a projection by rendering the supplied document.
    public init(
        document: Document,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        note: Note? = nil
    ) {
        self.rendered = DocumentRenderer.render(
            document, bodyFont: bodyFont, codeFont: codeFont, note: note
        )
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.note = note
    }

    /// Build a projection from a pre-computed RenderedDocument. Used
    /// by EditingOperations when it already has the rendered output
    /// from a block-granular re-render.
    public init(
        rendered: RenderedDocument,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        note: Note? = nil
    ) {
        self.rendered = rendered
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.note = note
    }

    /// The document underlying this projection.
    public var document: Document { rendered.document }

    /// The rendered attributed string.
    public var attributed: NSAttributedString { rendered.attributed }

    /// The per-block storage spans.
    public var blockSpans: [NSRange] { rendered.blockSpans }

    /// Locate the block containing a given textStorage insertion
    /// point. Returns `(blockIndex, offsetInBlock)` where
    /// `offsetInBlock` is the character offset from the block's
    /// start in the RENDERED output.
    ///
    /// - Parameter storageIndex: an NSString-index insertion point
    ///   (0 ≤ idx ≤ attributed.length).
    /// - Returns: the containing block and the offset within its
    ///   rendered span, or nil if `storageIndex` falls on an
    ///   inter-block separator (a `\n` between two blocks) or on
    ///   the document's trailing newline.
    ///
    /// Tie-break: when an insertion point is exactly at a boundary
    /// (end of block i == start of block i+1's separator), the
    /// earlier block wins. This matches intuition: typing at the
    /// end of a paragraph appends to that paragraph.
    public func blockContaining(storageIndex idx: Int) -> (blockIndex: Int, offsetInBlock: Int)? {
        guard idx >= 0 else { return nil }
        for (i, span) in rendered.blockSpans.enumerated() {
            let lower = span.location
            let upper = span.location + span.length
            if idx >= lower && idx <= upper {
                return (i, idx - lower)
            }
        }
        // Cursor past all block spans but still within the rendered string
        // (e.g. on a trailing newline or at attributed.length). Map to the
        // last block so that operations like toggleTodoList work when the
        // cursor is at the document end.
        if let lastSpan = rendered.blockSpans.last,
           idx > lastSpan.location + lastSpan.length,
           idx <= rendered.attributed.length {
            let lastIndex = rendered.blockSpans.count - 1
            return (lastIndex, lastSpan.length)
        }
        return nil
    }
}
