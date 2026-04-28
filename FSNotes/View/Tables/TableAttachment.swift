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
    ///
    /// Mutable so cell-content edits can update the payload in place
    /// without remounting the view provider — see
    /// `applyInPlaceBlockUpdate(_:)`. Structural edits (insert/delete
    /// row/col) still go through the full splice path because the
    /// attachment's bounds and the cell-subview list both need to
    /// rebuild.
    private(set) var block: Block

    /// Live container view for this attachment. Weak so the view
    /// can be deallocated when TK2 dismounts the view-provider.
    /// (An earlier experiment held this strong to reduce the
    /// rebuild-flicker on body-paragraph typing, but that interfered
    /// with TK2's expected mount/dismount cycle and the
    /// `TableContainerView` ended up cached but not in the editor's
    /// view tree. The flicker is now tracked as a known bug; the
    /// proper fix is the Phase D `NSTextViewportLayoutControllerDelegate`
    /// path or moving the view outside the view-provider mechanism
    /// entirely.)
    weak var liveContainerView: TableContainerView?

    /// Cell to focus once the view-provider mounts. Set by
    /// `requestPostMountFocus(row:col:)`; consumed by the
    /// view-provider's `loadView` when it constructs the container.
    /// If the container is already live at request time, focus
    /// happens immediately and this stays nil.
    var pendingFocus: (row: Int, col: Int)?

    init(block: Block) {
        self.block = block
        super.init(data: nil, ofType: nil)
        // Initial `bounds` so TK2 doesn't fall back to its 32x32
        // default-attachment-cell size before our provider mounts.
        // The provider re-runs the same computation against the live
        // textContainer width in `loadView` and updates `bounds` if
        // the layout width differs from this default.
        self.bounds = TableAttachment.computeBounds(block: block, containerWidth: 600)
        // Transparent placeholder image so TK2 doesn't render its
        // default rotated-document-icon glyph during the brief
        // window between attachment registration and view-provider
        // mount. Same trick the existing image / PDF / QuickLook
        // attachments use (CLAUDE.md: commit c033b46).
        TableAttachment.assignTransparentPlaceholder(to: self, size: bounds.size)
    }

    /// Generate a transparent NSImage of the given size and assign it
    /// as `attachment.image`. The closure-init `NSImage(size:flipped:_:)`
    /// returns true without drawing anything, producing an invisible
    /// bitmap. Same pattern `TextStorageProcessor` uses on attachment
    /// bounds-change — see `feedback_block_fsm_architecture.md`.
    private static func assignTransparentPlaceholder(
        to attachment: NSTextAttachment,
        size: NSSize
    ) {
        guard size.width > 0, size.height > 0 else { return }
        attachment.image = NSImage(size: size, flipped: false) { _ in true }
    }

    /// Update the attachment's block payload in place. Recomputes
    /// `bounds` against the live container view's current width (or
    /// the default 600 if the container has not loaded), and asks
    /// the live container to re-layout. Does NOT touch storage —
    /// callers must update the parent's projection separately.
    ///
    /// This is the cell-content-only fast path: same storage shape
    /// (1 U+FFFC), same attachment object, just new block payload.
    /// Avoids the view-provider remount that a full splice would
    /// trigger and that would tear down the cell view the user is
    /// currently typing in.
    /// Request that the cell at `(row, col)` be made first responder
    /// once the view-provider mounts. Event-driven — no polling.
    /// If the container is already live, focus happens immediately.
    /// Otherwise the flag is consumed by `TableAttachmentViewProvider.loadView`
    /// when it builds the container.
    func requestPostMountFocus(row: Int, col: Int) {
        if let container = liveContainerView,
           let cell = container.cellViewAt(row: row, col: col),
           let window = cell.window {
            window.makeFirstResponder(cell)
            self.pendingFocus = nil
            return
        }
        self.pendingFocus = (row, col)
    }

    func applyInPlaceBlockUpdate(_ newBlock: Block) {
        self.block = newBlock
        let width = liveContainerView?.containerWidthForExternalSync ?? bounds.width
        let newBounds = TableAttachment.computeBounds(
            block: newBlock, containerWidth: width
        )
        let boundsChanged = !newBounds.equalTo(self.bounds)
        // Only touch `bounds` and `image` if the new value actually
        // differs. Setting either one even to an "equal" value can
        // trigger TK2 to invalidate the attachment's line fragment
        // and dismount the view-provider's view; the user perceives
        // that as the table briefly disappearing. Cell-content-only
        // edits don't change `bounds` (full-width attachment) so
        // this skip is the common case.
        if boundsChanged {
            self.bounds = newBounds
            TableAttachment.assignTransparentPlaceholder(
                to: self, size: newBounds.size
            )
        }
        liveContainerView?.refreshCellContents(newBlock: newBlock)
        // When bounds change (e.g. row inserted, table grows taller),
        // TK2 doesn't always re-layout the attachment's line fragment
        // automatically. Force a viewport layout so the line fragment
        // expands to the new bounds and the new content (e.g. an
        // appended row's cell views) becomes visible.
        if boundsChanged {
            liveContainerView?.requestHostViewportRelayout()
        }
    }

    /// Pure size computation — same `TableGeometry.compute` math the
    /// container view runs. Centralised here so attachment + provider
    /// + container view all reach identical numbers from the same
    /// (block, width) pair.
    ///
    /// Returns the FULL `containerWidth` for the attachment's bounds.
    /// Tight bounds (= visualWidth) was attempted and reverted — it
    /// caused (a) cell-row clipping when typing widened columns
    /// faster than TK2's reflow, and (b) the view-provider for the
    /// table was occasionally evicted from the view tree after a
    /// body-paragraph splice and not re-mounted, making the table
    /// appear "disappeared" until the user toggled markdown view.
    /// Click-outside-table is now solved at the parent's `mouseDown`
    /// instead, by detecting clicks past the visible grid extent and
    /// routing them to the storage offset right after the U+FFFC.
    /// Caret height + position fixed in `drawInsertionPoint`.
    static func computeBounds(block: Block, containerWidth: CGFloat) -> CGRect {
        guard case .table(let header, let alignments, let rows, let widths) = block,
              header.count > 0 else {
            return .zero
        }
        let font = UserDefaultsManagement.noteFont
        let geom = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: containerWidth,
            font: font,
            columnWidthsOverride: widths
        )
        let height = TableGeometry.handleBarHeight + geom.totalHeight
        return CGRect(x: 0, y: 0, width: containerWidth, height: height)
    }

    /// Width that the table actually occupies visually — sum of
    /// column widths plus handle bar + focus-ring padding. Used by
    /// the parent's mouseDown override to decide whether a click on
    /// the table's y-band landed past the visible right edge (in
    /// which case the cursor should go to the storage offset right
    /// after the table, not be mapped to the U+FFFC by TK2's natural
    /// character-index logic).
    func visibleGridWidth(containerWidth: CGFloat) -> CGFloat {
        guard case .table(let header, let alignments, let rows, let widths) = block,
              header.count > 0 else {
            return 0
        }
        let font = UserDefaultsManagement.noteFont
        let geom = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: containerWidth,
            font: font,
            columnWidthsOverride: widths
        )
        return geom.columnWidths.reduce(0, +)
            + TableGeometry.handleBarWidth
            + TableGeometry.focusRingPadding
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
