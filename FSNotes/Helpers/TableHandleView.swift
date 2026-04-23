//
//  TableHandleView.swift
//  FSNotes
//
//  Phase 2e-T2-g — transparent overlay subview that spans a
//  `TableLayoutFragment`'s rendering surface inside the text view.
//
//  Responsibilities:
//    * Track `mouseMoved` to decide which row/column the pointer is
//      hovering, translate the hit into the fragment's handle-strip
//      coordinate space, and update `fragment.setHoverState(...)` via
//      `overlay.updateHover(...)`.
//    * Swallow right-click (or ctrl-click) on a handle strip and show
//      the column or row context menu vended by the overlay.
//
//  What this view deliberately does NOT do:
//    * Write to `Block.table` — all structural edits go through the
//      overlay → EditingOps primitive path (CLAUDE.md rule 2).
//    * Block pointer events inside the grid body. `hitTest(_:)` returns
//      nil for points outside the handle strips so the text view's
//      own caret / selection handling is untouched in normal typing.
//
//  Rule 7 grep-conscience: no marker-hiding, no bidirectional data
//  flow, no re-implementation of InlineRenderer. The view mutates the
//  fragment's hover-state enum only — not its data.
//

import AppKit

final class TableHandleView: NSView {

    // MARK: - Wiring (set by TableHandleOverlay.reposition())

    weak var fragment: TableLayoutFragment?
    weak var overlay: TableHandleOverlay?
    var elementStorageStart: Int = 0
    var blockIndex: Int = -1

    // MARK: - Tracking

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Stay transparent — we only paint via the owning fragment's
        // draw(at:in:). The view's job is hit-testing, not rendering.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea {
            removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Hit-testing
    //
    // Return self ONLY for points that hit a handle strip. Everywhere
    // else (cell body), return nil so clicks pass through to the text
    // view's default hit test (caret placement, selection, etc.).

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let fragment = fragment else { return nil }
        // `point` is in the parent view's coordinate system. Convert
        // to our local coords.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Translate to the fragment's rendering surface: the fragment's
        // frame origin matches our `frame.origin` (minus
        // `textContainerOrigin`, which is already baked into the tvFrame
        // the overlay assigns). Our local coords ARE the fragment's
        // local coords.
        if fragment.isInTopHandleStrip(localY: local.y) ||
            fragment.isInLeftHandleStrip(localX: local.x) {
            return self
        }
        return nil
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(from: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func updateHover(from event: NSEvent) {
        guard let fragment = fragment, let overlay = overlay else { return }
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else {
            clearHover()
            return
        }
        if fragment.isInTopHandleStrip(localY: pt.y),
           let col = fragment.columnAt(localX: pt.x) {
            overlay.updateHover(on: fragment, to: .column(col))
            return
        }
        if fragment.isInLeftHandleStrip(localX: pt.x),
           let row = fragment.rowAt(localY: pt.y) {
            overlay.updateHover(on: fragment, to: .row(row))
            return
        }
        clearHover()
    }

    private func clearHover() {
        guard let fragment = fragment, let overlay = overlay else { return }
        overlay.updateHover(on: fragment, to: .none)
    }

    // MARK: - Context menu (T2-g.2)

    override func menu(for event: NSEvent) -> NSMenu? {
        // Only intercept clicks on the handle strips.
        guard let fragment = fragment, let overlay = overlay,
              blockIndex >= 0 else {
            return super.menu(for: event)
        }
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else {
            return super.menu(for: event)
        }
        if fragment.isInTopHandleStrip(localY: pt.y),
           let col = fragment.columnAt(localX: pt.x) {
            return overlay.makeColumnMenu(blockIndex: blockIndex, col: col)
        }
        if fragment.isInLeftHandleStrip(localX: pt.x),
           let row = fragment.rowAt(localY: pt.y) {
            return overlay.makeRowMenu(blockIndex: blockIndex, row: row)
        }
        return super.menu(for: event)
    }

    // MARK: - T2-g.3 drag-resize entry point (deferred)

    /// Left-mouse-down on a column-boundary handle would initiate a
    /// drag-resize interaction. The live preview + persistence of
    /// resized column widths is held for the T2-g.4 follow-up review:
    /// width overrides need a backing field on `Block.table` (or a
    /// side table on `TableElement`) before the drag can commit
    /// anywhere durable. The entry point is wired so the mouse event
    /// is owned by this view (rather than the text view); the loop
    /// itself is stubbed.
    ///
    /// See the T2-g report: "T2-g.3 deferred — drag-resize live
    /// preview + persistence held for review."
    override func mouseDown(with event: NSEvent) {
        // For now, let mouseDown fall through to super so selection
        // extension / start-click behaviour stays intact on the edges
        // of the handle strip. The live drag is a follow-up.
        super.mouseDown(with: event)
    }
}
