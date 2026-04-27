//
//  TableAttachment.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — A1.
//
//  `NSTextAttachment` subclass that carries a `Block.table` value and
//  serves a `TableAttachmentViewProvider` for TK2 view-hosted
//  rendering. One `U+FFFC` character in storage stands in for the
//  whole table; the attachment's view provider returns a
//  `TableContainerView` that lays out the cells.
//
//  This file is intentionally minimal in A1. Phase B wires up
//  `TableTextRenderer.renderAsAttachment` to actually emit these,
//  gated by `UserDefaultsManagement.useSubviewTables`.
//

import AppKit

/// `NSTextAttachment` subclass that carries the authoritative
/// `Block.table` payload for a table block. Hosts a
/// `TableAttachmentViewProvider` that constructs a `TableContainerView`
/// from the payload at view-mount time.
final class TableAttachment: NSTextAttachment {

    /// The authoritative block this attachment represents. The view
    /// provider reads this to construct the container view; the save
    /// path reads this when copying the table as TSV/HTML (replacing
    /// the prior `tableAuthoritativeBlock` storage attribute).
    let block: Block

    init(block: Block) {
        self.block = block
        super.init(data: nil, ofType: nil)
        // No `image` here — the view provider supplies the visual.
        // No `bounds` either — TK2 sizes the attachment from the
        // provider's view's intrinsic content size.
    }

    required init?(coder: NSCoder) {
        fatalError("TableAttachment does not support NSCoding")
    }

    /// TK2 attachment view-provider hook. Returns a provider that
    /// hosts a `TableContainerView` for this attachment's block.
    override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        return TableAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
}
