//
//  TableAttachmentViewProvider.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — C1.
//
//  TK2 `NSTextAttachmentViewProvider` for `TableAttachment`. Returns
//  a `TableContainerView` sized to the table's geometry, with
//  `attachment.bounds` and the view's frame kept in agreement so TK2
//  glyph layout, AppKit hit-testing, and the cell subviews all reach
//  identical numbers from the same `TableGeometry.compute` math.
//
//  Bounds-mismatch is the click-routing bug class: if `attachment.bounds`
//  is `.zero`, TK2 falls back to a 32×32 default cell size, the view's
//  frame gets clipped to that rect, and AppKit's hit-test refuses to
//  reach cell subviews that paint OUTSIDE the rect (`draw(_:)` doesn't
//  clip — only hit-testing does). The result was visually correct
//  tables that didn't accept clicks.
//

import AppKit

final class TableAttachmentViewProvider: NSTextAttachmentViewProvider {

    private weak var containerView: TableContainerView?

    override func loadView() {
        guard let attachment = self.textAttachment as? TableAttachment,
              case .table = attachment.block else {
            self.view = NSView(frame: .zero)
            return
        }
        let width = textLayoutManager?.textContainer?.size.width ?? 600
        // Reuse the existing TableContainerView if cached on the
        // attachment. TK2 dismounts and remounts the view-provider
        // on every textStorage edit (even edits in neighbouring
        // blocks), so building a fresh container each time produces
        // visible flicker. Re-using the same instance preserves
        // visual continuity.
        let container: TableContainerView
        if let existing = attachment.liveContainerView {
            container = existing
            container.setContainerWidth(width)
        } else {
            container = TableContainerView(
                block: attachment.block, containerWidth: width
            )
        }
        let bounds = TableAttachment.computeBounds(
            block: attachment.block, containerWidth: width
        )
        attachment.bounds = bounds
        // Refresh the transparent placeholder so it spans the now-
        // known textContainer width. Without the placeholder, TK2
        // briefly renders its default document-icon glyph during the
        // window between attachment registration and view-provider
        // mount.
        if bounds.width > 0, bounds.height > 0 {
            attachment.image = NSImage(size: bounds.size, flipped: false) { _ in true }
        }
        container.frame = NSRect(origin: .zero, size: bounds.size)
        self.containerView = container
        attachment.liveContainerView = container
        self.view = container

        // Wire the cell-edit callback to the host EditTextView. The
        // editor is located at edit time by walking up the container's
        // superview chain — by then TK2 has mounted the container as
        // a subview of `_NSTextViewportElementView` inside the editor.
        // (NSTextAttachmentViewProvider's `parentView` is not exposed
        // as a Swift property, so the explicit walk is the path.)
        container.onCellEdit = { [weak attachment, weak container] row, col, inline in
            guard let attachment = attachment,
                  let container = container,
                  let editor = TableAttachmentViewProvider
                    .findEditTextView(startingAt: container)
            else { return }
            editor.applyTableCellInPlaceEdit(
                attachment: attachment,
                cellRow: row,
                cellCol: col,
                inline: inline
            )
        }
        container.onAppendRowFromTab = { [weak attachment, weak container] in
            guard let attachment = attachment,
                  let container = container,
                  let editor = TableAttachmentViewProvider
                    .findEditTextView(startingAt: container)
            else { return }
            editor.applyTableAppendRowAndFocusFirstCell(of: attachment)
        }
        container.onClickOutsideCells = { [weak attachment, weak container] _, side in
            guard let attachment = attachment,
                  let container = container,
                  let editor = TableAttachmentViewProvider
                    .findEditTextView(startingAt: container)
            else { return }
            editor.placeCursorOutsideTable(attachment: attachment, side: side)
        }
        container.onExitTable = { [weak attachment, weak container] direction in
            guard let attachment = attachment,
                  let container = container,
                  let editor = TableAttachmentViewProvider
                    .findEditTextView(startingAt: container)
            else { return }
            // Up arrow at table top → land cursor before the table
            // (= attachment offset). Down arrow at table bottom →
            // land cursor after the table (= attachment offset + 1).
            // Same primitive `placeCursorOutsideTable` that handles
            // the click-outside path; ExitTableDirection maps directly
            // to ClickOutsideSide.
            let side: TableContainerView.ClickOutsideSide =
                (direction == .up) ? .before : .after
            editor.placeCursorOutsideTable(attachment: attachment, side: side)
        }

        // Consume any pending post-mount focus request (set by
        // `Insert Table` and `Tab-extends-row` to land the caret in
        // a specific cell once the view-provider mounts). Defer to
        // the next run-loop tick so the container has been added to
        // the editor's view hierarchy and the cell's `window` is
        // non-nil — without that, `makeFirstResponder` no-ops.
        if let pending = attachment.pendingFocus,
           let cell = container.cellViewAt(row: pending.row, col: pending.col) {
            attachment.pendingFocus = nil
            DispatchQueue.main.async { [weak cell] in
                guard let cell = cell, let window = cell.window else { return }
                window.makeFirstResponder(cell)
            }
        }
    }

    /// Walk up the view hierarchy from `view` to locate the host
    /// EditTextView.
    private static func findEditTextView(startingAt view: NSView?) -> EditTextView? {
        var cursor: NSView? = view
        while let v = cursor {
            if let editor = v as? EditTextView { return editor }
            cursor = v.superview
        }
        return nil
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key : Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let attachment = self.textAttachment as? TableAttachment,
              case .table = attachment.block
        else { return .zero }

        let width = textContainer?.size.width
            ?? proposedLineFragment.width
        if let view = containerView {
            view.setContainerWidth(width)
            return CGRect(x: 0, y: 0, width: width, height: view.totalHeight)
        }
        let probe = TableContainerView(
            block: attachment.block, containerWidth: width
        )
        return CGRect(x: 0, y: 0, width: width, height: probe.totalHeight)
    }
}
