//
//  FoldedLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2f.1 — Custom NSTextLayoutFragment for header-folded ranges.
//
//  Pairs with `FoldedElement`. When the user folds a heading, the
//  storage-level `TextStorageProcessor.toggleFold` adds a `.foldedContent`
//  attribute over the range from the header-line end to the next
//  same-level header. Under TK1, `LayoutManager.drawGlyphs` and
//  `LayoutManager.drawBackground` consult `unfoldedRanges(in:)` and skip
//  drawing folded glyphs — fold works visually.
//
//  Under TK2, those LayoutManager methods never fire. Fragments paint
//  via `NSTextLayoutFragment.draw(at:in:)` only. So the TK2 analogue
//  must live at the fragment level.
//
//  This fragment is the TK2 analogue:
//    * `layoutFragmentFrame` returns a zero-height rect so TK2 stacks the
//      next fragment flush against the folded fragment's origin.
//    * `renderingSurfaceBounds` is empty — nothing to paint.
//    * `draw(at:in:)` is a no-op — explicitly suppresses `super.draw`
//      so no text glyphs render.
//    * `textLineFragments` is empty so TK2 doesn't try to lay out lines
//      over zero space (which would re-inflate height).
//
//  The characters stay in storage. Selection, find-in-note, and
//  serialization see the real text. Only the visual rendering is
//  collapsed.
//
//  Fold toggle invalidation: `TextStorageProcessor.toggleFold` adds /
//  removes the `.foldedContent` attribute inside a `beginEditing` /
//  `endEditing` pair. NSTextContentStorage observes the `.editedAttributes`
//  mask and invalidates the affected fragments so TK2 re-asks the layout
//  manager delegate for new fragments — which then dispatch to this
//  class (folded) or the normal block-model fragments (unfolded).
//

import AppKit

public final class FoldedLayoutFragment: NSTextLayoutFragment {

    // MARK: - Geometry overrides

    /// Zero-height frame: the fragment occupies no vertical space, so
    /// the next fragment stacks flush against this one's origin. This
    /// is the TK2 analogue of TK1's `drawGlyphs` skipping the folded
    /// glyph range — visually the content is gone.
    public override var layoutFragmentFrame: CGRect {
        let base = super.layoutFragmentFrame
        return CGRect(
            x: base.origin.x,
            y: base.origin.y,
            width: 0,
            height: 0
        )
    }

    /// Empty rendering surface: nothing to paint. Returning `.zero`
    /// also tells TK2 there are no pixels to invalidate for this
    /// fragment on redraw.
    public override var renderingSurfaceBounds: CGRect {
        .zero
    }

    // MARK: - Drawing

    /// No-op. Explicitly do NOT call `super.draw(at:in:)`, which would
    /// paint the backing text glyphs. Folded content is visually gone.
    public override func draw(at point: CGPoint, in context: CGContext) {
        // Intentionally empty.
    }
}
