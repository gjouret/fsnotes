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
        // TableAttachment, not some other attachment object that
        // happens to occupy a U+FFFC.
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

private var subviewTableFindClientKey: UInt8 = 0
private var subviewTableTextFinderKey: UInt8 = 0

extension EditTextView {

    /// Route Cmd-F/Cmd-G through a finder client that exposes table
    /// cell text for the subview-table path. NSTextView's default
    /// finder only sees the parent storage string, which contains a
    /// single U+FFFC attachment placeholder for each table.
    func performSubviewTableFindPanelAction(_ sender: Any?) -> Bool {
        guard documentProjection?.document.blocks.contains(where: {
                  if case .table = $0 { return true }
                  return false
              }) == true else {
            return false
        }

        let client = subviewTableFindClient()
        let finder = subviewTableTextFinder(client: client)
        finder.performAction(subviewTableFindAction(from: sender))
        return true
    }

    func debugSubviewTableFindString() -> String {
        return SubviewTableFindClient(editor: self).debugString()
    }

    private func subviewTableFindClient() -> SubviewTableFindClient {
        if let existing = objc_getAssociatedObject(
            self, &subviewTableFindClientKey
        ) as? SubviewTableFindClient {
            return existing
        }
        let client = SubviewTableFindClient(editor: self)
        objc_setAssociatedObject(
            self, &subviewTableFindClientKey, client,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return client
    }

    private func subviewTableTextFinder(
        client: SubviewTableFindClient
    ) -> NSTextFinder {
        if let existing = objc_getAssociatedObject(
            self, &subviewTableTextFinderKey
        ) as? NSTextFinder {
            existing.client = client
            if let scrollView = enclosingScrollView {
                existing.findBarContainer = scrollView
            }
            return existing
        }
        let finder = NSTextFinder()
        finder.client = client
        if let scrollView = enclosingScrollView {
            finder.findBarContainer = scrollView
        }
        objc_setAssociatedObject(
            self, &subviewTableTextFinderKey, finder,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return finder
    }

    private func subviewTableFindAction(from sender: Any?) -> NSTextFinder.Action {
        if let menu = sender as? NSMenuItem {
            return NSTextFinder.Action(rawValue: menu.tag) ?? .showFindInterface
        }
        if let control = sender as? NSControl {
            return NSTextFinder.Action(rawValue: control.tag) ?? .showFindInterface
        }
        return .showFindInterface
    }
}

private final class SubviewTableFindClient: NSObject, NSTextFinderClient {

    private enum SegmentKind {
        case storage(NSRange)
        case tableCell(
            attachment: TableAttachment?,
            attachmentRange: NSRange,
            row: Int,
            col: Int
        )
        case tableDelimiter(
            attachment: TableAttachment?,
            attachmentRange: NSRange
        )
    }

    private struct Segment {
        let virtualRange: NSRange
        let text: String
        let kind: SegmentKind
        let endsWithSearchBoundary: Bool
    }

    private struct Snapshot {
        let segments: [Segment]
        let stringLength: Int

        var fullString: String {
            segments.map(\.text).joined()
        }

        func segment(containing location: Int) -> Segment? {
            guard !segments.isEmpty else { return nil }
            let clamped = max(0, min(location, max(0, stringLength - 1)))
            return segments.first { NSLocationInRange(clamped, $0.virtualRange) }
        }

        func segmentForRangeStart(_ range: NSRange) -> Segment? {
            if let exact = segment(containing: range.location) {
                return exact
            }
            return segments.last { NSMaxRange($0.virtualRange) <= range.location }
                ?? segments.first
        }
    }

    private weak var editor: EditTextView?

    init(editor: EditTextView) {
        self.editor = editor
        super.init()
    }

    func debugString() -> String {
        buildSnapshot().fullString
    }

    override var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { true }
    var isEditable: Bool { false }

    var stringLength: Int {
        buildSnapshot().stringLength
    }

    func string(
        at characterIndex: Int,
        effectiveRange outRange: NSRangePointer,
        endsWithSearchBoundary outFlag: UnsafeMutablePointer<ObjCBool>
    ) -> String {
        let snapshot = buildSnapshot()
        guard let segment = snapshot.segment(containing: characterIndex) else {
            outRange.pointee = NSRange(location: 0, length: 0)
            outFlag.pointee = true
            return ""
        }
        outRange.pointee = segment.virtualRange
        outFlag.pointee = ObjCBool(segment.endsWithSearchBoundary)
        return segment.text
    }

    var firstSelectedRange: NSRange {
        let snapshot = buildSnapshot()
        if let cellRange = selectedTableCellRange(in: snapshot) {
            return cellRange
        }
        if let parentRange = selectedParentRange(in: snapshot) {
            return parentRange
        }
        return NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let range = newValue.first?.rangeValue else { return }
            applyVirtualSelection(range)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        let snapshot = buildSnapshot()
        guard let segment = snapshot.segmentForRangeStart(range),
              let editor = editor else { return }
        switch segment.kind {
        case .storage(let storageRange):
            let mapped = mapRange(
                range, from: segment.virtualRange, toStart: storageRange.location
            )
            editor.scrollRangeToVisible(mapped)
        case .tableCell(let attachment, let attachmentRange, let row, let col):
            editor.scrollRangeToVisible(attachmentRange)
            guard let cell = attachment?.liveContainerView?.cellViewAt(
                row: row, col: col
            ) else { return }
            let mapped = mapRange(range, from: segment.virtualRange, toStart: 0)
            cell.scrollRangeToVisible(mapped)
        case .tableDelimiter(_, let attachmentRange):
            editor.scrollRangeToVisible(attachmentRange)
        }
    }

    func contentView(
        at index: Int,
        effectiveCharacterRange outRange: NSRangePointer
    ) -> NSView {
        let snapshot = buildSnapshot()
        guard let segment = snapshot.segment(containing: index) else {
            outRange.pointee = NSRange(location: 0, length: 0)
            return editor ?? NSView()
        }
        outRange.pointee = segment.virtualRange
        if case .tableCell(let attachment, _, let row, let col) = segment.kind,
           let cell = attachment?.liveContainerView?.cellViewAt(row: row, col: col) {
            return cell
        }
        return editor ?? NSView()
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        let snapshot = buildSnapshot()
        guard let segment = snapshot.segmentForRangeStart(range),
              let editor = editor else { return [] }

        switch segment.kind {
        case .storage(let storageRange):
            let mapped = mapRange(
                range, from: segment.virtualRange, toStart: storageRange.location
            )
            let screenRect = editor.firstRect(
                forCharacterRange: mapped, actualRange: nil
            )
            return screenRect.isEmpty
                ? []
                : [NSValue(rect: localRect(fromScreenRect: screenRect, in: editor))]
        case .tableCell(let attachment, _, let row, let col):
            guard let cell = attachment?.liveContainerView?.cellViewAt(
                row: row, col: col
            ) else { return [] }
            let mapped = mapRange(range, from: segment.virtualRange, toStart: 0)
            let screenRect = cell.firstRect(
                forCharacterRange: mapped, actualRange: nil
            )
            return screenRect.isEmpty
                ? []
                : [NSValue(rect: localRect(fromScreenRect: screenRect, in: cell))]
        case .tableDelimiter:
            return []
        }
    }

    var visibleCharacterRanges: [NSValue] {
        let length = buildSnapshot().stringLength
        return [NSValue(range: NSRange(location: 0, length: length))]
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        _ = range
        _ = view
    }

    private func buildSnapshot() -> Snapshot {
        guard let editor = editor,
              let projection = editor.documentProjection,
              let storage = editor.textStorage else {
            return Snapshot(segments: [], stringLength: 0)
        }

        var segments: [Segment] = []
        var virtualLocation = 0
        var storageCursor = 0
        let storageString = storage.string as NSString

        func appendSegment(
            _ text: String,
            kind: SegmentKind,
            boundary: Bool = false
        ) {
            let length = (text as NSString).length
            guard length > 0 else { return }
            let range = NSRange(location: virtualLocation, length: length)
            segments.append(
                Segment(
                    virtualRange: range,
                    text: text,
                    kind: kind,
                    endsWithSearchBoundary: boundary
                )
            )
            virtualLocation += length
        }

        func appendStorageRange(_ range: NSRange) {
            guard range.length > 0 else { return }
            appendSegment(
                storageString.substring(with: range),
                kind: .storage(range)
            )
        }

        func appendTable(
            _ block: Block,
            attachment: TableAttachment?,
            attachmentRange: NSRange
        ) {
            guard case .table(let header, _, let rows, _) = block else { return }

            func appendCell(_ cell: TableCell, row: Int, col: Int) {
                appendSegment(
                    InlineRenderer.plainText(cell.inline),
                    kind: .tableCell(
                        attachment: attachment,
                        attachmentRange: attachmentRange,
                        row: row,
                        col: col
                    )
                )
            }

            for (col, cell) in header.enumerated() {
                appendCell(cell, row: 0, col: col)
                if col < header.count - 1 {
                    appendSegment(
                        "\t",
                        kind: .tableDelimiter(
                            attachment: attachment,
                            attachmentRange: attachmentRange
                        )
                    )
                }
            }

            if !header.isEmpty || !rows.isEmpty {
                appendSegment(
                    "\n",
                    kind: .tableDelimiter(
                        attachment: attachment,
                        attachmentRange: attachmentRange
                    ),
                    boundary: true
                )
            }

            for (rowIdx, row) in rows.enumerated() {
                for (col, cell) in row.enumerated() {
                    appendCell(cell, row: rowIdx + 1, col: col)
                    if col < row.count - 1 {
                        appendSegment(
                            "\t",
                            kind: .tableDelimiter(
                                attachment: attachment,
                                attachmentRange: attachmentRange
                            )
                        )
                    }
                }
                if rowIdx < rows.count - 1 {
                    appendSegment(
                        "\n",
                        kind: .tableDelimiter(
                            attachment: attachment,
                            attachmentRange: attachmentRange
                        ),
                        boundary: true
                    )
                }
            }
        }

        for (idx, block) in projection.document.blocks.enumerated() {
            guard idx < projection.blockSpans.count else { continue }
            let span = projection.blockSpans[idx]
            let prefixLength = max(0, span.location - storageCursor)
            appendStorageRange(
                NSRange(location: storageCursor, length: prefixLength)
            )

            if case .table = block {
                let attachment = tableAttachment(in: storage, span: span)
                appendTable(block, attachment: attachment, attachmentRange: span)
            } else {
                appendStorageRange(span)
            }
            storageCursor = max(storageCursor, NSMaxRange(span))
        }

        if storageCursor < storage.length {
            appendStorageRange(
                NSRange(location: storageCursor, length: storage.length - storageCursor)
            )
        }

        return Snapshot(segments: segments, stringLength: virtualLocation)
    }

    private func tableAttachment(
        in storage: NSTextStorage,
        span: NSRange
    ) -> TableAttachment? {
        guard span.length > 0,
              span.location >= 0,
              span.location < storage.length else { return nil }
        return storage.attribute(
            .attachment, at: span.location, effectiveRange: nil
        ) as? TableAttachment
    }

    private func selectedTableCellRange(in snapshot: Snapshot) -> NSRange? {
        guard let cell = editor?.window?.firstResponder as? TableCellTextView else {
            return nil
        }
        for segment in snapshot.segments {
            guard case .tableCell(let attachment, _, let row, let col) = segment.kind,
                  let candidate = attachment?.liveContainerView?.cellViewAt(
                      row: row, col: col
                  ),
                  candidate === cell else { continue }
            let local = cell.selectedRange()
            let location = segment.virtualRange.location
                + max(0, min(local.location, segment.virtualRange.length))
            let length = max(
                0,
                min(local.length, segment.virtualRange.length - (location - segment.virtualRange.location))
            )
            return NSRange(location: location, length: length)
        }
        return nil
    }

    private func selectedParentRange(in snapshot: Snapshot) -> NSRange? {
        guard let editor = editor else { return nil }
        let selected = editor.selectedRange()
        for segment in snapshot.segments {
            switch segment.kind {
            case .storage(let storageRange):
                if selected.location >= storageRange.location,
                   selected.location <= NSMaxRange(storageRange) {
                    let local = max(0, selected.location - storageRange.location)
                    let location = segment.virtualRange.location
                        + min(local, segment.virtualRange.length)
                    let length = max(
                        0,
                        min(selected.length, segment.virtualRange.length - (location - segment.virtualRange.location))
                    )
                    return NSRange(location: location, length: length)
                }
            case .tableCell(_, let attachmentRange, _, _),
                 .tableDelimiter(_, let attachmentRange):
                if selected.location >= attachmentRange.location,
                   selected.location <= NSMaxRange(attachmentRange) {
                    return NSRange(location: segment.virtualRange.location, length: 0)
                }
            }
        }
        return nil
    }

    private func applyVirtualSelection(_ range: NSRange) {
        let snapshot = buildSnapshot()
        guard let segment = snapshot.segmentForRangeStart(range),
              let editor = editor else { return }

        switch segment.kind {
        case .storage(let storageRange):
            let mapped = mapRange(
                range, from: segment.virtualRange, toStart: storageRange.location
            )
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(mapped)
            editor.scrollRangeToVisible(mapped)
        case .tableCell(let attachment, let attachmentRange, let row, let col):
            guard let cell = attachment?.liveContainerView?.cellViewAt(
                row: row, col: col
            ) else {
                editor.window?.makeFirstResponder(editor)
                editor.setSelectedRange(
                    NSRange(location: attachmentRange.location, length: 1)
                )
                editor.scrollRangeToVisible(attachmentRange)
                return
            }
            let mapped = mapRange(range, from: segment.virtualRange, toStart: 0)
            cell.window?.makeFirstResponder(cell)
            cell.setSelectedRange(mapped)
            cell.scrollRangeToVisible(mapped)
        case .tableDelimiter(_, let attachmentRange):
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(
                NSRange(location: attachmentRange.location, length: 1)
            )
            editor.scrollRangeToVisible(attachmentRange)
        }
    }

    private func mapRange(
        _ range: NSRange,
        from source: NSRange,
        toStart targetStart: Int
    ) -> NSRange {
        let localStart = max(0, min(range.location - source.location, source.length))
        let available = max(0, source.length - localStart)
        let length = max(0, min(range.length, available))
        return NSRange(location: targetStart + localStart, length: length)
    }

    private func localRect(fromScreenRect screenRect: NSRect, in view: NSView) -> NSRect {
        guard let window = view.window else { return screenRect }
        let windowRect = window.convertFromScreen(screenRect)
        return view.convert(windowRect, from: nil)
    }
}
