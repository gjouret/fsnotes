//
//  TableCellTextView.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — C0.
//
//  `NSTextView` subclass that hosts one cell's content. In C0 the
//  cell is read-only — `isEditable = false`, `isSelectable = false`
//  — so it renders its `[Inline]` content via the standard TK2
//  pipeline (caret, IME, autocorrect, spell-check all inactive
//  while non-editable). Phase C1 turns editability on and routes
//  edits through `EditingOps.replaceTableCellInline`.
//
//  Construction takes a `TableCell` value plus drawing parameters
//  (font, alignment) and configures the underlying text storage
//  with the inline-rendered attributed string.
//

import AppKit

final class TableCellTextView: NSTextView {

    /// (row, col) coordinates within the parent table. Phase C2 reads
    /// these to compute the next/previous cell when Tab fires.
    var cellRow: Int = 0
    var cellCol: Int = 0

    convenience init(
        cell: TableCell,
        font: NSFont,
        alignment: NSTextAlignment,
        frame: NSRect
    ) {
        self.init(frame: frame)
        self.drawsBackground = false
        // Phase C0: read-only. Phase C1 flips these to true.
        self.isEditable = false
        self.isSelectable = false
        self.isRichText = true
        self.allowsUndo = false  // Phase C1 wires undo coordination.
        self.textContainerInset = .zero
        if let container = self.textContainer {
            container.lineFragmentPadding = 0
        }
        self.setContent(cell: cell, font: font, alignment: alignment)
    }

    /// Replace the cell's displayed content. Used by `TableContainerView`
    /// when the parent block's cells change (Phase B / Phase C splice
    /// pipeline).
    func setContent(
        cell: TableCell,
        font: NSFont,
        alignment: NSTextAlignment
    ) {
        // Reuse the same renderer the measurement + native-cell paint
        // paths use, so visual height matches geometry exactly.
        let rendered = TableGeometry.renderCellAttributedString(
            cell: cell, font: font, alignment: alignment
        )
        self.textStorage?.setAttributedString(rendered)
    }
}
