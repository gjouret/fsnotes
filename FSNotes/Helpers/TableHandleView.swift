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

    /// Match the enclosing `EditTextView`'s coordinate system. Without
    /// this, `localY = 0` maps to the BOTTOM of the view, and
    /// `TableLayoutFragment.isInTopHandleStrip(localY:)` (which
    /// matches `0 <= localY < handleBarHeight`) evaluates true on the
    /// BOTTOM strip instead of the TOP. Result: hovering the top
    /// handle strip fires no hover event and no column-handle chrome
    /// ever appears. Flipping the view's coordinate system so y
    /// increases downward realigns hit-testing with the fragment's
    /// draw coords — top strip at localY=0..handleBarHeight, left
    /// strip at localX=0..handleBarWidth, both top-left origin.
    override var isFlipped: Bool { return true }

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
        // TK1 UX: hovering anywhere inside the table shows handles
        // for the column + row the cursor is currently over. Don't
        // require the user to find the narrow 11pt strip — the old
        // `InlineTableView` widget showed both handles whenever the
        // mouse was anywhere in the grid, and that's how users
        // discovered them.
        let col = fragment.columnAt(localX: pt.x)
        let row = fragment.rowAt(localY: pt.y)
        if let col = col, let row = row {
            overlay.updateHover(
                on: fragment, to: .cell(column: col, row: row)
            )
            return
        }
        // Edge case: mouse is inside bounds but outside the grid
        // (e.g. over the left or top strip itself before the first
        // cell). Fall back to column- or row-only hover.
        if fragment.isInTopHandleStrip(localY: pt.y),
           let col = col {
            overlay.updateHover(on: fragment, to: .column(col))
            return
        }
        if fragment.isInLeftHandleStrip(localX: pt.x),
           let row = row {
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

    // MARK: - T2-g.4 drag-resize

    /// Drag-in-progress state. Captured on mouseDown hitting a column
    /// boundary, updated in-place during mouseDragged events, flushed
    /// on mouseUp via `EditingOps.setTableColumnWidths`.
    private struct DragState {
        let col: Int            // boundary col (left of the boundary)
        let startMouseX: CGFloat
        /// Column widths at drag start. `col` and `col + 1` are the
        /// two adjacent columns the delta is split between.
        let startWidths: [CGFloat]
    }
    private var dragState: DragState?

    /// Minimum column width while dragging. Slightly more conservative
    /// than `TableGeometry.minColumnWidth` (80) to leave headroom.
    private static let minDragColumnWidth: CGFloat = 40

    override func mouseDown(with event: NSEvent) {
        guard let fragment = fragment else {
            super.mouseDown(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        // Only initiate drag-resize if the click is on a column
        // boundary in the top-handle strip.
        guard fragment.isInTopHandleStrip(localY: pt.y),
              let col = fragment.columnBoundaryAt(localX: pt.x) else {
            super.mouseDown(with: event)
            return
        }
        // Capture baseline widths for the drag math.
        let widths = fragment.currentColumnWidths()
        guard col >= 0, col + 1 < widths.count else {
            super.mouseDown(with: event)
            return
        }
        dragState = DragState(
            col: col,
            startMouseX: pt.x,
            startWidths: widths
        )
        // Initial preview line at current boundary.
        if let edgeLeft = fragment.columnLeftEdge(col + 1) {
            _ = fragment.setResizePreview(localX: edgeLeft)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fragment = fragment, let state = dragState else {
            super.mouseDragged(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        let delta = pt.x - state.startMouseX
        let newWidths = applyDragDelta(
            to: state.startWidths, col: state.col, delta: delta
        )
        // Preview line sits at the new boundary between col and col+1.
        let sumUpToBoundary = TableGeometry.handleBarWidth
            + newWidths.prefix(state.col + 1).reduce(0, +)
        _ = fragment.setResizePreview(localX: sumUpToBoundary)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let fragment = fragment, let state = dragState else {
            super.mouseUp(with: event)
            return
        }
        dragState = nil
        _ = fragment.setResizePreview(localX: nil)
        needsDisplay = true

        let pt = convert(event.locationInWindow, from: nil)
        let delta = pt.x - state.startMouseX
        let newWidths = applyDragDelta(
            to: state.startWidths, col: state.col, delta: delta
        )
        // Persist via the pure primitive.
        overlay?.applySetColumnWidths(blockIndex: blockIndex, widths: newWidths)
    }

    /// Split `delta` between column `col` and column `col + 1`, clamped
    /// by `minDragColumnWidth` on both sides. `col + 1` shrinks by the
    /// same amount `col` grows — a traditional spreadsheet drag feel.
    private func applyDragDelta(
        to startWidths: [CGFloat], col: Int, delta: CGFloat
    ) -> [CGFloat] {
        var widths = startWidths
        guard col >= 0, col + 1 < widths.count else { return widths }
        let minW = Self.minDragColumnWidth
        var newLeft = widths[col] + delta
        var newRight = widths[col + 1] - delta
        // Clamp against minimum, trading from the other column.
        if newLeft < minW {
            newRight += (newLeft - minW)
            newLeft = minW
        }
        if newRight < minW {
            newLeft += (newRight - minW)
            newRight = minW
        }
        // Final floor — if both were already at min, both stay at min.
        widths[col] = max(minW, newLeft)
        widths[col + 1] = max(minW, newRight)
        return widths
    }
}
