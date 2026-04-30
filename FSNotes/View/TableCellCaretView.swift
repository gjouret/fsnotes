//
//  TableCellCaretView.swift
//  FSNotes
//
//  Caret indicator for parent-editor cursors parked immediately before
//  or after a subview-backed table attachment. TK2 can otherwise paint
//  the parent caret as tall as the table's attachment line fragment.
//

import AppKit

/// Caret indicator subview repositioned on selection changes when the
/// parent cursor is adjacent to a table attachment. Wraps
/// `NSTextInsertionIndicator` so the platform handles blinking, color,
/// and accessibility; this class only owns the frame.
final class TableCellCaretView: NSView {

    private let indicator: NSTextInsertionIndicator

    override init(frame: NSRect) {
        self.indicator = NSTextInsertionIndicator(
            frame: NSRect(origin: .zero, size: frame.size)
        )
        super.init(frame: frame)
        addSubview(indicator)
        indicator.autoresizingMask = [.width, .height]
        // `.automatic` ties blink to the host text view's first-
        // responder state; the platform pauses blink when the window
        // isn't key. This matches the standard NSTextView behaviour.
        indicator.displayMode = .automatic
    }

    required init?(coder: NSCoder) {
        fatalError("TableCellCaretView does not support NSCoding")
    }

    /// Show the indicator and update its frame. The frame is in the
    /// host view's coordinate space.
    func show(at frame: NSRect) {
        self.frame = frame
        self.isHidden = false
        indicator.displayMode = .automatic
    }

    /// Hide the indicator. The view stays in the subview tree and is
    /// reused on the next selection change.
    func hide() {
        // `.hidden` on the indicator stops blink; setting `isHidden`
        // on the wrapper view also removes it from hit-test (which
        // it isn't anyway, see below).
        indicator.displayMode = .hidden
        self.isHidden = true
    }

    /// Pointer-transparent: clicks must pass through to the editor's
    /// `mouseDown(with:)`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

// MARK: - EditTextView wiring

/// Associated-object key for the lazily-installed caret view. Lives at
/// file scope because `EditTextView` is in another file and is a
/// closed class hierarchy under @testable; the associated-object
/// pattern is the lightest way to add per-instance state from this
/// file without modifying `EditTextView` itself.
private var tableCaretViewKey: UInt8 = 0

extension EditTextView {

    private var tableCellCaretView: TableCellCaretView? {
        get {
            objc_getAssociatedObject(self, &tableCaretViewKey)
                as? TableCellCaretView
        }
        set {
            objc_setAssociatedObject(
                self, &tableCaretViewKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Saved insertion-point color for restoration when the caret
    /// leaves a table boundary. We set `insertionPointColor = .clear`
    /// to suppress the platform `NSTextInsertionIndicator` while our
    /// own caret view is active.
    private var savedInsertionPointColor: NSColor? {
        get {
            objc_getAssociatedObject(self, &savedInsertionPointColorKey)
                as? NSColor
        }
        set {
            objc_setAssociatedObject(
                self, &savedInsertionPointColorKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Reposition (or hide) the table-boundary caret subview based on the
    /// current selection. Called from
    /// `setSelectedRanges(_:affinity:stillSelecting:)`.
    ///
    /// Behaviour:
    ///   * If the selection is a single zero-length caret AND the
    ///     cursor sits before or after a TableAttachment, install
    ///     (lazily) the caret subview, position it at the table
    ///     boundary rect, suppress the platform `NSTextInsertionIndicator`
    ///     by clearing `insertionPointColor`, and show our subview.
    ///   * Otherwise hide our caret subview and restore the saved
    ///     `insertionPointColor` so the platform indicator paints
    ///     normally outside the table.
    ///
    /// `caretRectAtSubviewTableBoundary()` returns a view-coordinate
    /// rect, so the result can be assigned directly to `frame`.
    func updateTableCellCaret() {
        let selection = selectedRange()
        // If a TableCellTextView (subview-tables cell) currently owns
        // first responder, the cell paints its OWN caret. Don't also
        // paint the parent's caret view — that'd be a phantom caret
        // visible alongside the cell's real one.
        if let fr = window?.firstResponder, fr is TableCellTextView {
            tableCellCaretView?.hide()
            if let saved = savedInsertionPointColor {
                insertionPointColor = saved
                savedInsertionPointColor = nil
            }
            return
        }
        // Parent-editor table carets only occur at the attachment
        // boundary. Active cells paint their own caret.
        let rect: NSRect? = {
            guard selection.length == 0 else { return nil }
            if let r = caretRectAtSubviewTableBoundary() { return r }
            return nil
        }()
        guard let rect = rect else {
            tableCellCaretView?.hide()
            // Restore the platform indicator color when we leave the
            // table. Save-then-restore handles the case where the user
            // had a custom cursor color (insertionPointColor is
            // settable via `Theme`).
            if let saved = savedInsertionPointColor {
                insertionPointColor = saved
                savedInsertionPointColor = nil
            }
            return
        }
        // Boundary caret rect already returns the desired table-height
        // rect. Set the width to the standard caret stripe.
        var caretRect = rect
        caretRect.size.width = max(2, caretWidth)

        let view: TableCellCaretView
        if let existing = tableCellCaretView {
            view = existing
        } else {
            let v = TableCellCaretView(frame: caretRect)
            v.autoresizingMask = []
            addSubview(v)
            tableCellCaretView = v
            view = v
        }
        view.show(at: caretRect)

        // Suppress the platform indicator. Save the original color
        // once so we can restore it when the caret leaves the table.
        if savedInsertionPointColor == nil {
            savedInsertionPointColor = insertionPointColor
        }
        insertionPointColor = .clear
    }
}

private var savedInsertionPointColorKey: UInt8 = 0
