//
//  TableAttachmentViewProvider.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — A3.
//
//  TK2 `NSTextAttachmentViewProvider` for `TableAttachment`. Returns
//  a `TableContainerView` sized to the table's geometry. Lifecycles
//  the container view across edit cycles.
//
//  In A3 this is read-only: `attachmentBounds(...)` returns
//  `(containerWidth, container.totalHeight)`. The container itself
//  paints the grid + cell content via the same `TableGeometry`
//  helpers `TableLayoutFragment.draw` uses, so visual fidelity is
//  pixel-equivalent to the native-cell path.
//
//  Phase B will gate this behind `useSubviewTables` from the
//  rendering pipeline. Phase C extends the provider to drive
//  per-cell `TableCellTextView` subviews for editing.
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
        let container = TableContainerView(
            block: attachment.block, containerWidth: width
        )
        self.containerView = container
        self.view = container
        self.tracksTextAttachmentViewBounds = true
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
        // Use the container view's geometry to size the attachment.
        // If the view hasn't loaded yet, build a throwaway container
        // for measurement — same `TableGeometry.compute` math.
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
