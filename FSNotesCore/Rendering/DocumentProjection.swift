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

        let spans = rendered.blockSpans
        guard !spans.isEmpty else { return nil }

        // Binary search: spans are sorted by `location` and are
        // non-overlapping (each block's span ends before the next block's
        // starts, modulo inter-block separators). Find the largest span
        // whose `location` is ≤ idx, then check that span's range. This
        // replaces the O(N) linear scan that ran on every keystroke via
        // `updateButtonStates`, `syncTypingAttributesToCursorBlock`, etc.
        // (Perf plan item #1.)
        var lo = 0
        var hi = spans.count - 1
        var candidate = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].location <= idx {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let span = spans[candidate]
        let upper = span.location + span.length
        if idx >= span.location && idx <= upper {
            return (candidate, idx - span.location)
        }

        // Cursor past all block spans but still within the rendered string
        // (e.g. on a trailing newline or at attributed.length). Map to the
        // last block so that operations like toggleTodoList work when the
        // cursor is at the document end.
        let lastSpan = spans[spans.count - 1]
        if idx > lastSpan.location + lastSpan.length,
           idx <= rendered.attributed.length {
            return (spans.count - 1, lastSpan.length)
        }
        return nil
    }

    /// Locate the block whose rendered span contains the given
    /// selection. Pure function on `blockSpans` + `document.blocks` —
    /// no view access, no AppKit.
    ///
    /// Semantics:
    /// - Zero-length selection (a cursor) → the block containing that
    ///   insertion point (`blockContaining(storageIndex:)`).
    /// - Non-empty selection → the block whose span STRICTLY contains
    ///   the entire selection range. If the selection straddles block
    ///   boundaries, there is no single containing block and we return
    ///   nil. This is deliberate: Slice 4's observer treats a multi-
    ///   block selection as "cursor is NOT inside any single editing
    ///   block", so every block currently in `editingCodeBlocks`
    ///   collapses.
    ///
    /// - Parameter selection: the selected `NSRange` in storage
    ///   coordinates.
    /// - Returns: `(index, ref)` of the containing block, or nil if no
    ///   single block contains the entire selection.
    public func blockContainingSelection(
        _ selection: NSRange
    ) -> (index: Int, ref: BlockRef)? {
        // Zero-length → delegate to blockContaining(storageIndex:).
        if selection.length == 0 {
            guard let (idx, _) = blockContaining(
                storageIndex: selection.location
            ) else { return nil }
            guard idx >= 0, idx < rendered.document.blocks.count else {
                return nil
            }
            return (idx, BlockRef(rendered.document.blocks[idx]))
        }

        // Non-empty selection: require strict containment in a single
        // block's span. Use the low-end via binary-search (blockContaining)
        // then verify the high end lies within the same span.
        guard let (idx, _) = blockContaining(
            storageIndex: selection.location
        ) else { return nil }
        guard idx >= 0, idx < rendered.blockSpans.count,
              idx < rendered.document.blocks.count else { return nil }
        let span = rendered.blockSpans[idx]
        let selEnd = selection.location + selection.length
        let spanEnd = span.location + span.length
        if selection.location >= span.location && selEnd <= spanEnd {
            return (idx, BlockRef(rendered.document.blocks[idx]))
        }
        return nil
    }

    /// Return the indices of all blocks that overlap the given storage
    /// range. Used by multi-block toolbar operations (e.g. select three
    /// paragraphs and toggle to list). Returns an empty array if no
    /// blocks overlap.
    public func blockIndices(overlapping range: NSRange) -> [Int] {
        let rangeEnd = range.location + range.length
        var indices: [Int] = []
        for (i, span) in rendered.blockSpans.enumerated() {
            let spanEnd = span.location + span.length
            // A block overlaps the range if they share any characters.
            // For zero-length selections (cursor), use blockContaining instead.
            if span.location < rangeEnd && spanEnd > range.location {
                indices.append(i)
            }
        }
        // Fallback: if zero-length range (cursor), use blockContaining.
        if indices.isEmpty, range.length == 0,
           let (idx, _) = blockContaining(storageIndex: range.location) {
            indices.append(idx)
        }
        return indices
    }
}
