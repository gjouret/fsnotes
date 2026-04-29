//
//  EditTextView+SubviewTables.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — C1.5 (cell-edit integration).
//
//  Bridges `TableContainerView.onCellEdit` (a per-cell typing event)
//  into the parent EditTextView's edit pipeline:
//
//    cell types char
//      → `TableContainerView.textDidChange(_:)`
//      → `onCellEdit(row, col, [Inline])` closure invokes
//        `applyTableCellInPlaceEdit` here
//      → resolves the table's block index by searching storage for
//        the attachment object
//      → runs `EditingOps.replaceTableCellInline` (pure primitive)
//      → routes the resulting `EditResult` through
//        `applyEditResultWithUndo`
//
//  ──────────────────────────────────────────────────────────────────
//  Invariant-A status of the in-place fast path (`tryApplyTableCellInPlace`)
//  ──────────────────────────────────────────────────────────────────
//
//  CLAUDE.md Invariant A: "single write path into NSTextContentStorage —
//  `DocumentEditApplier.applyDocumentEdit` is the one function that
//  mutates TK2 content storage for WYSIWYG edits."
//
//  The fast path is **not** a violation. The reasoning:
//
//  1. Storage CHARACTER representation is invariant for the cases the
//     fast path matches. A `Block.table` renders to exactly one
//     `U+FFFC` character carrying a `TableAttachment`; both
//     `.replaceTableCell` (cell content) and `.replaceBlock` on a
//     table block (insert/delete row/col, alignment change, width
//     change) produce a NEW table whose rendered storage is also
//     exactly one `U+FFFC` carrying a TableAttachment. The character-
//     level diff between old and new storage is empty.
//
//  2. The standard `DocumentEditApplier.applyDocumentEdit` would
//     therefore emit a 1-char→1-char splice that replaces the OLD
//     attachment object with a NEW one. Character-wise that's a
//     no-op; object-wise it triggers TK2 to dismount the OLD
//     view-provider and mount the NEW one. The dismount tears down
//     the cell views the user is typing in. So the user-visible
//     "cell typing" feature is broken if every keystroke goes
//     through the standard splice.
//
//  3. The fast path mutates `attachment.block` in place (the
//     attachment OBJECT stays in storage; only its model payload
//     updates). It also advances `documentProjection`, `note.cachedDocument`,
//     and `hasUserEdits` — model-of-render state, not storage state.
//     It does NOT call `textStorage.replaceCharacters`. Therefore
//     `NSTextContentStorage` is untouched.
//
//  4. The DEBUG post-condition at the bottom of `tryApplyTableCellInPlace`
//     enforces the invariant: it re-renders `result.newProjection` and
//     asserts the substring at the splice range is byte-equal to what
//     the standard splice would have written. If a future primitive
//     ever produces a `.replaceTableCell`-tagged result whose new
//     storage representation isn't 1 U+FFFC, that assertion catches
//     the drift before it becomes silent corruption.
//
//  This is the same exemption pattern the fill paths use (legitimate
//  parallel write paths via `StorageWriteGuard.fillInFlight`); the
//  fast path's exemption is implicit because it doesn't write storage
//  at all.
//

import AppKit

private var pendingTableRefreshKey: UInt8 = 0
private var pendingListGlyphRefreshKey: UInt8 = 0

extension EditTextView {

    /// Entry point invoked from `TableContainerView.onCellEdit`.
    /// Resolves the table's block index, runs the pure cell-replace
    /// primitive, and dispatches the result through the standard
    /// edit pipeline.
    func applyTableCellInPlaceEdit(
        attachment: TableAttachment,
        cellRow: Int,
        cellCol: Int,
        inline: [Inline]
    ) {
        guard let projection = documentProjection else {
            bmLog("⛔ applyTableCellInPlaceEdit: no documentProjection")
            return
        }
        guard let storage = textStorage else {
            bmLog("⛔ applyTableCellInPlaceEdit: no textStorage")
            return
        }

        // Locate the table block by finding the attachment object in
        // storage and matching the offset against `blockSpans`. Object
        // identity is the right key here — the attachment is the live
        // payload of one specific block, and an EditingOps run that
        // re-renders the block produces a NEW attachment object that
        // we'll swap in via the fast path below.
        var blockIdx: Int? = nil
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(
            .attachment, in: fullRange, options: []
        ) { value, range, stop in
            guard let candidate = value as? TableAttachment,
                  candidate === attachment else { return }
            for (idx, span) in projection.blockSpans.enumerated() {
                if NSLocationInRange(range.location, span) {
                    blockIdx = idx
                    stop.pointee = true
                    return
                }
            }
        }
        guard let blockIdx = blockIdx else {
            bmLog("⛔ applyTableCellInPlaceEdit: attachment not found in storage")
            return
        }

        // Translate (cellRow, cellCol) — the view's row coordinate
        // includes the header at index 0 — to the primitive's
        // `TableCellLocation` discriminator.
        let cellLocation: EditingOps.TableCellLocation
        if cellRow == 0 {
            cellLocation = .header(col: cellCol)
        } else {
            cellLocation = .body(row: cellRow - 1, col: cellCol)
        }

        let result: EditResult
        do {
            result = try EditingOps.replaceTableCellInline(
                blockIndex: blockIdx,
                at: cellLocation,
                inline: inline,
                in: projection
            )
        } catch {
            bmLog("⚠️ applyTableCellInPlaceEdit: replaceTableCellInline threw \(error)")
            return
        }

        applyEditResultWithUndo(result, actionName: "Cell Edit")
    }

    /// Append a new body row to the table represented by `attachment`,
    /// then focus the first cell of that new row. Called from
    /// `TableContainerView.onAppendRowFromTab` when the user presses
    /// Tab on the last (bottom-right) cell.
    ///
    /// `insertTableRow` is a `.replaceBlock` change — it goes through
    /// the full splice path (no `.replaceTableCell` fast path), so
    /// the view-provider remounts a new TableContainerView. The new
    /// container mounts asynchronously on the next viewport-layout
    /// pass, so the cell-focus is dispatched via `DispatchQueue.main`
    /// to give TK2 time to call `loadView`.
    func applyTableAppendRowAndFocusFirstCell(of attachment: TableAttachment) {
        guard let projection = documentProjection else { return }
        guard let storage = textStorage else { return }

        // Locate the block index by attachment identity (same as the
        // cell-edit path). Capture it BEFORE the splice — after the
        // splice the old attachment is no longer in storage.
        var blockIdx: Int? = nil
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(
            .attachment, in: fullRange, options: []
        ) { value, range, stop in
            guard let candidate = value as? TableAttachment,
                  candidate === attachment else { return }
            for (idx, span) in projection.blockSpans.enumerated() {
                if NSLocationInRange(range.location, span) {
                    blockIdx = idx
                    stop.pointee = true
                    return
                }
            }
        }
        guard let blockIdx = blockIdx else { return }
        guard case .table(_, _, let rows, _) =
                projection.document.blocks[blockIdx] else { return }

        // Append at position == rows.count (i.e. after the last row).
        let appendPos = rows.count
        let result: EditResult
        do {
            result = try EditingOps.insertTableRow(
                blockIndex: blockIdx, at: appendPos, in: projection
            )
        } catch {
            bmLog("⚠️ applyTableAppendRowAndFocusFirstCell: insertTableRow threw \(error)")
            return
        }
        applyEditResultWithUndo(result, actionName: "Add Table Row")

        // Tag the (post-splice) attachment with a pending focus
        // request. The view-provider's `loadView` consumes it when
        // it mounts the new container — no polling, no retries.
        // `cellRow` for the new row in the container's row-indexed
        // layout is `header (row 0)` + `appendPos` = `appendPos + 1`.
        let newCellRow = appendPos + 1
        requestSubviewTableCellFocus(
            blockIndex: blockIdx, row: newCellRow, col: 0
        )
    }

    /// Place the parent's cursor on the requested side of the given
    /// table attachment. Called from `TableContainerView.mouseDown`
    /// when the user clicks on the container's own chrome (right
    /// margin past the rightmost column, handle bar, grid-line area).
    /// Without this, clicks on the container's empty right margin
    /// land on the parent's full-width line fragment but get mapped
    /// to the U+FFFC's start offset (the LEFT half of the fragment),
    /// not the END — so the user can't reach the storage offset
    /// "after the table" without clicking at the far right margin.
    func placeCursorOutsideTable(
        attachment: TableAttachment,
        side: TableContainerView.ClickOutsideSide
    ) {
        guard let storage = textStorage else { return }
        var attachmentOffset: Int? = nil
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(
            .attachment, in: fullRange, options: []
        ) { value, range, stop in
            if let candidate = value as? TableAttachment, candidate === attachment {
                attachmentOffset = range.location
                stop.pointee = true
            }
        }
        guard let offset = attachmentOffset else { return }
        let cursorOffset: Int
        switch side {
        case .before: cursorOffset = offset
        case .after:  cursorOffset = min(offset + 1, storage.length)
        }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: cursorOffset, length: 0))
    }

    /// Coalescing flag for `applyEditResultWithUndo`'s deferred
    /// table-container refresh. Set when a refresh is scheduled,
    /// cleared when it runs. Multiple keystrokes within the same
    /// run-loop tick share the single scheduled refresh.
    var pendingTableRefreshScheduled: Bool {
        get {
            objc_getAssociatedObject(self, &pendingTableRefreshKey) as? Bool ?? false
        }
        set {
            objc_setAssociatedObject(
                self, &pendingTableRefreshKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Coalescing flag for `applyEditResultWithUndo`'s deferred
    /// bullet/checkbox view-provider refresh (bd-fsnotes-ibj). Same
    /// pattern as `pendingTableRefreshScheduled` — one refresh per
    /// run-loop tick regardless of keystroke rate.
    var pendingListGlyphRefreshScheduled: Bool {
        get {
            objc_getAssociatedObject(self, &pendingListGlyphRefreshKey) as? Bool ?? false
        }
        set {
            objc_setAssociatedObject(
                self, &pendingListGlyphRefreshKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Walk a view tree and mark every TableContainerView as needing
    /// display. The system's paint cycle picks them up. We deliberately
    /// don't call `displayIfNeeded` — that forces an extra synchronous
    /// paint pass which compounds with the splice's natural paint and
    /// makes the table visibly flicker.
    func refreshAllTableContainerViews(in root: NSView) {
        for sub in root.subviews {
            if let container = sub as? TableContainerView {
                container.needsDisplay = true
                for cell in container.subviews {
                    cell.needsDisplay = true
                }
            } else {
                refreshAllTableContainerViews(in: sub)
            }
        }
    }

    /// Count how many TableAttachment objects are currently in
    /// storage. Used by the targeted diagnostic in
    /// `applyEditResultWithUndo` to detect when an edit unexpectedly
    /// removes the table attachment.
    func countTableAttachments(in storage: NSTextStorage) -> Int {
        var count = 0
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, _ in
            if value is TableAttachment { count += 1 }
        }
        return count
    }

    /// Subview-tables fast path used by `applyEditResultWithUndo`.
    /// Returns `true` if it handled the edit in place — caller skips
    /// the regular splice. Returns `false` otherwise.
    ///
    /// Detects a `.replaceTableCell` change whose splice range covers
    /// exactly the U+FFFC of the table attachment, and whose existing
    /// storage attachment is a `TableAttachment`. In that case the
    /// storage splice is semantically a no-op (both before and after
    /// is one U+FFFC), but constructing a new attachment object
    /// causes TK2 to remount the view provider and tear down the
    /// live cell view. The fast path updates the existing
    /// attachment's `block` payload via `applyInPlaceBlockUpdate(_:)`
    /// instead, then advances the projection without touching
    /// storage.
    func tryApplyTableCellInPlace(_ result: EditResult) -> Bool {
        guard UserDefaultsManagement.useSubviewTables else { return false }
        guard let storage = textStorage else { return false }
        guard let actions = result.contract?.declaredActions,
              !actions.isEmpty else { return false }

        // Every declared action must operate on the SAME block, and
        // that block must remain a table (i.e. the storage shape stays
        // 1 U+FFFC). Cell-content edits (`.replaceTableCell`) and
        // structural-within-table edits (`.replaceBlock` on a table
        // index — insertTableRow, insertTableColumn, etc.) both qualify.
        // Skipping the standard splice for these preserves the
        // attachment object identity, which keeps the view-provider
        // mounted — without this, the table briefly disappears after
        // each structural edit because TK2 dismounts the old provider
        // and doesn't remount the new attachment's view reliably.
        var blockIdx: Int? = nil
        for action in actions {
            let bi: Int
            switch action {
            case .replaceTableCell(let i, _, _): bi = i
            case .replaceBlock(let i): bi = i
            default: return false
            }
            if let existing = blockIdx, existing != bi { return false }
            blockIdx = bi
        }
        guard let blockIdx = blockIdx else { return false }

        // Splice must be 1 char in, 1 char out (the attachment glyph).
        guard result.spliceRange.length == 1,
              result.spliceReplacement.length == 1 else {
            return false
        }
        // Existing storage attachment at splice position must be a
        // TableAttachment (not e.g. a native-cell U+FFFC + a different
        // attachment kind).
        guard result.spliceRange.location < storage.length,
              let existingAttachment = storage.attribute(
                .attachment, at: result.spliceRange.location, effectiveRange: nil
              ) as? TableAttachment else {
            return false
        }
        // New block from the result's projection.
        guard blockIdx < result.newProjection.document.blocks.count else {
            return false
        }
        let newBlock = result.newProjection.document.blocks[blockIdx]
        guard case .table = newBlock else { return false }

        // DEBUG post-condition: enforce the storage-shape invariant
        // that justifies skipping the splice. The standard splice
        // would write `result.spliceReplacement` (1 char) into
        // `result.spliceRange`. Storage's character at that range
        // (the U+FFFC) is unchanged by our fast path; the attachment
        // object is unchanged; only the attachment's `block` payload
        // mutates. The post-condition checks: (a) storage's character
        // at the splice range is still the U+FFFC the splice
        // replacement carries (i.e. the splice would have been a
        // character-level no-op), and (b) the attachment object
        // identity is preserved. If either fails, a future primitive
        // has produced a contract-tagged result whose storage shape
        // diverges from the U+FFFC invariant — catch it here before
        // it silently corrupts.
        #if DEBUG
        let assertCharsEqual: () -> Void = {
            let storedChar = (storage.string as NSString)
                .character(at: result.spliceRange.location)
            let replacementChar = (result.spliceReplacement.string as NSString)
                .character(at: 0)
            assert(
                storedChar == replacementChar,
                "tryApplyTableCellInPlace: storage char at splice range \(storedChar) " +
                "≠ replacement char \(replacementChar). The fast path's " +
                "storage-shape-invariant assumption is broken."
            )
        }
        assertCharsEqual()
        #endif

        // All gates passed. Update the attachment in place and
        // advance the projection without touching storage.
        existingAttachment.applyInPlaceBlockUpdate(newBlock)
        documentProjection = result.newProjection
        note?.cachedDocument = result.newProjection.document
        hasUserEdits = true

        #if DEBUG
        // Attachment object identity preserved — that's the second
        // half of the invariant. Re-read storage and confirm the
        // attachment at the splice range is the SAME object.
        let postAttachment = storage.attribute(
            .attachment, at: result.spliceRange.location, effectiveRange: nil
        ) as? TableAttachment
        assert(
            postAttachment === existingAttachment,
            "tryApplyTableCellInPlace: attachment object identity broken. " +
            "Pre: \(ObjectIdentifier(existingAttachment)), " +
            "post: \(postAttachment.map { ObjectIdentifier($0) }.map(String.init(describing:)) ?? "nil")"
        )
        #endif

        return true
    }
}
