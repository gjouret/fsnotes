//
//  TableAttachmentViewProvider.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — A1.
//
//  TK2 `NSTextAttachmentViewProvider` for `TableAttachment`. Returns
//  a `TableContainerView` sized to the table's geometry. Lifecycles
//  the container view across edit cycles.
//
//  In A1 this is skeletal: it constructs a `TableContainerView` from
//  the attachment's `Block.table` and returns it. A3 fills in the
//  view's read-only render. Later phases (C, F) extend the provider
//  to coordinate cell-level editing and hover handles.
//

import AppKit

final class TableAttachmentViewProvider: NSTextAttachmentViewProvider {

    /// The container view that hosts this table's cell views. Created
    /// lazily on first `loadView()`. TK2 calls `loadView` after the
    /// provider is constructed.
    private weak var containerView: TableContainerView?

    override func loadView() {
        guard let attachment = self.textAttachment as? TableAttachment,
              case .table = attachment.block else {
            self.view = NSView(frame: .zero)
            return
        }

        let container = TableContainerView(block: attachment.block)
        self.containerView = container
        self.view = container
        // Tracks attachment size from the container's intrinsic
        // content size — A3 sets that based on geometry.
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
              case .table = attachment.block else {
            return .zero
        }
        // A1 returns a placeholder bound. A3 computes from
        // `TableGeometry.compute(...)` for the real height.
        let width = textContainer?.size.width ?? proposedLineFragment.width
        return CGRect(x: 0, y: 0, width: width, height: 60)
    }
}
