//
//  TableCellCaretView.swift
//  FSNotes
//
//  Caret indicator for cursors parked inside a `TableLayoutFragment`.
//  Bug #29 visual half: under TK2 / macOS 26, `NSTextView` paints the
//  caret via an `NSTextInsertionIndicator` subview whose frame comes
//  from `NSTextLayoutManager.enumerateTextSegments`. For our table
//  fragment, the natural typesetter lays out the separator-encoded
//  storage (U+001F / U+001E / U+2028) as one flat run, so the
//  enumerated segment frame is at the natural-flow position — visually
//  outside the painted cell grid. Empirically (`textLineFragments`
//  override / `textLineFragment(for:)` override probed on
//  2026-04-26) the platform indicator's positioning cannot be
//  redirected via fragment-level overrides; the override side-effects
//  break segment enumeration entirely.
//
//  Architecture used here matches `STTextView`'s `STInsertionPointView`
//  (the most-used third-party TK2 text view, whose author filed the
//  Apple bug "drawInsertionPoint(in:color:turnedOn) is never called"):
//  install a separately-positioned `NSTextInsertionIndicator` as a
//  subview of the text view and reposition it manually on selection
//  change. The indicator's automatic-blinking behaviour, color, and
//  appearance handling come from the platform; only the frame is
//  manually computed.
//
//  Positioning math: the cell's rect in fragment-local coordinates
//  comes from `TableLayoutFragment.caretRectInCell(row:col:cellLocalOffset:)`.
//  Converting to view coordinates is `+ fragment.frame.origin + textContainerOrigin`,
//  the same conversion `EditTextView.caretRectIfInTableCell()` already
//  performs.
//

import AppKit

/// Caret indicator subview repositioned on selection changes when the
/// cursor is inside a `TableLayoutFragment`. Wraps
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
    /// `mouseDown(with:)` so they can route to `handleTableCellClick`
    /// and place the caret elsewhere.
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
    /// leaves a table cell. We set `insertionPointColor = .clear` to
    /// suppress the platform `NSTextInsertionIndicator` while our
    /// own caret view is active (otherwise both render — the platform
    /// one at the natural-flow position outside the table grid, the
    /// custom one inside the cell). When the cursor leaves the table,
    /// we restore the saved color.
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

    /// Reposition (or hide) the table-cell caret subview based on the
    /// current selection. Called from
    /// `setSelectedRanges(_:affinity:stillSelecting:)`.
    ///
    /// Behaviour:
    ///   * If the selection is a single zero-length caret AND the
    ///     cursor is inside a `TableLayoutFragment`, install (lazily)
    ///     the caret subview, position it at the cell rect computed
    ///     by `caretRectIfInTableCell()`, suppress the platform
    ///     `NSTextInsertionIndicator` by clearing
    ///     `insertionPointColor`, and show our subview.
    ///   * Otherwise hide our caret subview and restore the saved
    ///     `insertionPointColor` so the platform indicator paints
    ///     normally outside the table.
    ///
    /// `caretRectIfInTableCell()` already returns view-coordinate
    /// rects (its math: `localRect + fragment.frame.origin
    /// + textContainerOrigin`), so the result can be assigned
    /// directly to `frame`.
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
        // Check both: (a) cursor inside a native TableLayoutFragment
        // cell (TK1-style native-tables path), and (b) cursor at a
        // subview-tables `TableAttachment`'s U+FFFC offset (start or
        // end). Either way TK2 doesn't call `drawInsertionPoint` so
        // we manually position the caret subview.
        let rect: NSRect? = {
            guard selection.length == 0 else { return nil }
            if let r = caretRectIfInTableCell() { return r }
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
        // Caret rect from `caretRectIfInTableCell` already returns a
        // single-line-height rect (since the recent
        // `TableLayoutFragment.caretRectInCell` change capped the
        // height to the cell's text line height). Set the width to
        // the standard caret stripe.
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
