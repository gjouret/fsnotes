//
//  TableContainerView.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — A1 skeleton.
//
//  Replaces `TableLayoutFragment` for the subview-table path. Lays
//  out cell text views in a grid, paints the borders, hosts hover
//  handles. Owns no document state of its own — reads everything
//  from the `Block.table` payload it was constructed with.
//
//  A1: skeleton, accepts a `Block.table`, sizes itself to a
//  placeholder height. A3 implements the real read-only render
//  (borders, header fill, zebra rows, per-cell text) pixel-matching
//  the current `TableLayoutFragment.draw`. Phase C wires up cell
//  text views (`TableCellTextView`) for editing. Phase F restores
//  hover-handle / drag-resize / drag-reorder UX.
//

import AppKit

final class TableContainerView: NSView {

    /// The authoritative `Block.table` value this container renders.
    /// Re-set when the document changes (Phase B wires the splice
    /// pipeline; for A1 it's set once at construction).
    private(set) var block: Block

    init(block: Block) {
        self.block = block
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("TableContainerView does not support NSCoding")
    }

    /// Update the rendered table to match a new `Block.table` value.
    /// Skeleton — Phase B fills in the real diff/relayout logic.
    func update(block: Block) {
        guard case .table = block else { return }
        self.block = block
        needsDisplay = true
    }

    // A3 will replace this stub draw with the real grid render —
    // ported from `TableLayoutFragment.draw(at:in:)`.
    override func draw(_ dirtyRect: NSRect) {
        // Placeholder fill so the attachment is visible during A1
        // smoke-tests. A3 paints the real chrome.
        NSColor.separatorColor.withAlphaComponent(0.1).setFill()
        bounds.fill()
    }
}
