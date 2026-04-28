//
//  TableCellTextView.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — C1.
//
//  `NSTextView` subclass that hosts one cell's content. The cell IS a
//  real text editor — full TK2 caret, selection, IME, autocorrect,
//  spell-check, copy/paste — once it owns the responder chain. Per
//  the SUBVIEW_TABLES_PLAN, edits route through the cell's delegate
//  to `EditingOps.replaceTableCellInline` on the parent's `Document`
//  (Invariant A: single write path).
//
//  C1 makes the cell editable + first-responder-aware. `mouseDown`
//  explicitly claims first responder before deferring to super —
//  without that, NSTextView's own `mouseDown` does not promote a
//  hosted-attachment subview, and the parent EditTextView keeps the
//  focus while the user clicks "into" the cell, which paints the
//  caret in the parent's coordinate space (the bug class users saw).
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
        // C1: editable, selectable. Caret + selection paint via the
        // cell's own NSTextView, not the parent EditTextView.
        self.isEditable = true
        self.isSelectable = true
        self.isRichText = true
        self.allowsUndo = false  // Phase C-later wires undo coordination.
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
        // Set the cell's default font + typingAttributes so newly-typed
        // characters (which inherit from typingAttributes, not from
        // surrounding storage when the cursor is at start-of-cell or
        // the cell is empty) match the cell's role: bold for header,
        // regular for body. Without this, header cells display the
        // existing characters bold but newly-typed ones in regular
        // weight until the user moves focus away and `setContent` runs
        // again (which is what reapplied bold to them).
        self.font = font
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        self.typingAttributes = [
            .font: font,
            .paragraphStyle: para
        ]
    }

    override var acceptsFirstResponder: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Without this, a click that activates an inactive window
        // does not make us first responder on the same click.
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Claim first responder explicitly. NSTextView's own mouseDown
        // does not promote a hosted-attachment subview to first
        // responder, so without this the parent EditTextView keeps
        // focus and the caret never paints inside the cell.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // The parent EditTextView's caret view is only repositioned
        // on selection change. When this cell takes first responder
        // (e.g. via auto-focus after Insert Table), the parent's
        // selection isn't changing — so without an explicit nudge,
        // the parent's caret view stays visible alongside this cell's
        // own caret. Find the parent EditTextView and trigger an
        // update so it can hide its caret view.
        var v: NSView? = self.superview
        while let cur = v {
            if let editor = cur as? EditTextView {
                editor.updateTableCellCaret()
                break
            }
            v = cur.superview
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        // Symmetric: when this cell loses FR, the parent may have
        // gained FR. Re-evaluate caret visibility.
        var v: NSView? = self.superview
        while let cur = v {
            if let editor = cur as? EditTextView {
                editor.updateTableCellCaret()
                break
            }
            v = cur.superview
        }
        return result
    }
}
