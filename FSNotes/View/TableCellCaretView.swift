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

    /// Reposition (or hide) the table-cell caret subview based on the
    /// current selection. Called from
    /// `setSelectedRanges(_:affinity:stillSelecting:)`.
    ///
    /// Behaviour:
    ///   * If the selection is a single zero-length caret AND the
    ///     cursor is inside a `TableLayoutFragment`, install (lazily)
    ///     the caret subview, position it at the cell rect computed
    ///     by `caretRectIfInTableCell()`, and show it.
    ///   * Otherwise hide the caret subview.
    ///
    /// `caretRectIfInTableCell()` already returns view-coordinate
    /// rects (its math: `localRect + fragment.frame.origin
    /// + textContainerOrigin`), so the result can be assigned
    /// directly to `frame`.
    func updateTableCellCaret() {
        let selection = selectedRange()
        guard selection.length == 0,
              let rect = caretRectIfInTableCell()
        else {
            tableCellCaretView?.hide()
            return
        }
        // Caret rect from `caretRectIfInTableCell` is the cell's
        // content rect (full row height inside cell padding); narrow
        // to a 2-pt-wide caret stripe at the rect's left edge.
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
    }
}
