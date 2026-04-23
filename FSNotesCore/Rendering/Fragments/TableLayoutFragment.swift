//
//  TableLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2e-T2-a — Additive foundation for the TK2 native-cell table
//  path. Pairs with `TableElement`. This fragment is dead code on disk:
//  no layout-manager delegate dispatches to it, no content storage
//  vends a `TableElement` yet. The class exists so slice 2e-T2-c can
//  land grid rendering with no further plumbing churn.
//
//  Planned overrides (landing in 2e-T2-c):
//    * `layoutFragmentFrame` — return a rect whose height is the
//      table's total grid height as computed by `TableGeometry`. The
//      backing attributed string (with separator characters collapsed
//      to line breaks) would otherwise drive `super.layoutFragmentFrame`
//      and we'd get the wrong height.
//    * `renderingSurfaceBounds` — cover the full grid plus focus-ring
//      padding so invalidation is pixel-correct.
//    * `draw(at:in:)` — suppress `super.draw` (the raw separator
//      characters should not paint) and instead call into `TableGeometry`
//      for column widths / row heights, then draw grid lines and hand
//      each cell's attributed substring to `NSTextLineFragment`-style
//      line layout inside its cell rect.
//
//  For this slice, each override returns the superclass default. No
//  behaviour changes.
//

import AppKit

/// Custom `NSTextLayoutFragment` for the TK2 native-cell table path.
/// Stubbed in 2e-T2-a — all overrides defer to `super`. Real rendering
/// lands in 2e-T2-c.
public final class TableLayoutFragment: NSTextLayoutFragment {

    // MARK: - Geometry overrides

    /// Defer to `super` for the stub. 2e-T2-c will compute the grid
    /// height via `TableGeometry.compute(...)` and return a rect whose
    /// height matches `totalHeight`.
    public override var layoutFragmentFrame: CGRect {
        return super.layoutFragmentFrame
    }

    /// Defer to `super` for the stub. 2e-T2-c will expand the
    /// rendering surface to cover the full grid bounds plus the
    /// focus-ring padding (matching the current `InlineTableView`
    /// visual).
    public override var renderingSurfaceBounds: CGRect {
        return super.renderingSurfaceBounds
    }

    // MARK: - Drawing

    /// Empty in this slice. 2e-T2-c will:
    ///   1. Skip `super.draw(at:in:)` so the raw separator characters
    ///      from `TableElement`'s attributed string do not paint.
    ///   2. Read the `TableElement`'s `block` to get `header` /
    ///      `alignments` / `rows`.
    ///   3. Call `TableGeometry.compute(...)` for column widths and
    ///      row heights against the current container width.
    ///   4. Draw grid lines and lay each cell's rendered attributed
    ///      substring into its cell rect via line-fragment layout.
    public override func draw(at point: CGPoint, in context: CGContext) {
        // Intentionally empty — stubbed for 2e-T2-a. No grid rendering
        // wired in this slice, and no dispatch path reaches this draw
        // call yet.
    }
}
