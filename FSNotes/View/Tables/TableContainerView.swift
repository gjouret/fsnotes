//
//  TableContainerView.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — A3.
//
//  `NSView` that renders a `Block.table` as a grid of cells with the
//  same visual chrome as the table renderer — header
//  fill, zebra body rows, grid lines, and a top/left handle-strip
//  reservation so handles can later sit there.
//
//  Read-only in A3: cell content is painted via
//  `TableGeometry.renderCellAttributedString` (the same helper the
//  measurement path uses, so painted heights match measured heights).
//  Phase C replaces the cell-content paint with per-cell
//  `TableCellTextView` subviews.
//
//  Coordinate system: `isFlipped = true` so y increases downward,
//  matching TK2's drawing convention. The view's own bounds are
//  (0, 0, containerWidth, handleBarHeight + totalCellHeight). Grid
//  origin is (handleBarWidth, handleBarHeight) relative to view-
//  local (0, 0).
//

import AppKit

final class TableContainerView: NSView, NSTextViewDelegate {

    /// The authoritative `Block.table` value this container renders.
    private(set) var block: Block

    /// Closure fired when a cell's content changed via user typing.
    /// Set by `TableAttachmentViewProvider`; routes the new
    /// `(cellRow, cellCol, [Inline])` into the parent EditTextView's
    /// edit pipeline. The container itself stays out of the
    /// `EditingOps` / `applyDocumentEdit` machinery so it's testable
    /// without an `EditTextView` host.
    var onCellEdit: ((_ cellRow: Int, _ cellCol: Int, _ inline: [Inline]) -> Void)?

    /// Closure fired when Tab is pressed on the last (bottom-right)
    /// cell. Implementer is expected to append a new body row and
    /// focus its first cell. Matches Excel / Numbers / Word
    /// convention.
    var onAppendRowFromTab: (() -> Void)?

    /// Closure fired when an arrow key tries to leave the table at a
    /// boundary — Up arrow at the top line of the header row, Down
    /// arrow at the bottom line of the last row. Implementer parks
    /// the parent EditTextView's cursor before/after the table's
    /// U+FFFC and makes the parent first responder.
    var onExitTable: ((_ direction: ExitTableDirection) -> Void)?

    enum ExitTableDirection { case up, down }

    /// Container width — set by the view provider's
    /// `attachmentBounds(...)` so the grid spans the available text-
    /// container width. Defaults to a reasonable size at construction
    /// and is updated when the view's frame changes.
    private var containerWidth: CGFloat

    /// Read-only accessor for `TableAttachment.applyInPlaceBlockUpdate`,
    /// which re-runs `computeBounds` against the live width when the
    /// block's payload changes.
    var containerWidthForExternalSync: CGFloat { containerWidth }

    /// First header cell of the rendered grid — used by the auto-
    /// focus path after `Insert Table` so the user lands inside the
    /// table without a separate click. Returns nil if the grid has
    /// not yet been built (no header cells in the model).
    func firstHeaderCell() -> TableCellTextView? {
        return cellSubviews.first?.first
    }

    /// Lookup a cell view by its (row, col) coordinate. Row 0 is the
    /// header; rows 1..N are body rows. Used by the post-splice
    /// auto-focus path on `Tab from last cell`.
    func cellViewAt(row: Int, col: Int) -> TableCellTextView? {
        guard row >= 0, row < cellSubviews.count else { return nil }
        let rowCells = cellSubviews[row]
        guard col >= 0, col < rowCells.count else { return nil }
        return rowCells[col]
    }

    /// Cells indexed [row][col] — header row at index 0, body rows
    /// after. Subviews of self; created in `rebuildCellSubviews()`
    /// and repositioned in `layout()`.
    private var cellSubviews: [[TableCellTextView]] = []

    init(block: Block, containerWidth: CGFloat = 600) {
        self.block = block
        self.containerWidth = containerWidth
        super.init(frame: .zero)
        self.wantsLayer = true
        rebuildCellSubviews()
        syncFrameSizeToContent()
    }

    required init?(coder: NSCoder) {
        fatalError("TableContainerView does not support NSCoding")
    }

    /// Update the rendered table to match a new `Block.table` value.
    /// Used for structural changes (insert/delete row/col, alignment
    /// change). For cell-content-only edits prefer
    /// `refreshCellContents(newBlock:)`, which preserves the live
    /// cells' first-responder + selection state.
    func update(block: Block) {
        guard case .table = block else { return }
        self.block = block
        invalidateIntrinsicContentSize()
        rebuildCellSubviews()
        syncFrameSizeToContent()
        needsDisplay = true
        needsLayout = true
        // Run layout NOW so the new cell views (e.g. an inserted row)
        // have their frames before the next paint. Without this, the
        // user pressed Tab from the last cell, the model added a new
        // row, but the cell views hadn't laid out yet so the visible
        // table stayed at the old row count.
        layoutSubtreeIfNeeded()
    }

    /// In-place refresh: replace cell contents (and re-run geometry)
    /// without tearing down + re-creating the cell text views. Called
    /// from `TableAttachment.applyInPlaceBlockUpdate` on the
    /// `.replaceTableCell` fast path so the cell the user is typing
    /// in keeps its first-responder state and cursor position.
    ///
    /// Falls back to full `update(block:)` if the new block has a
    /// different row/col count (a structural change masquerading as
    /// a content change — should not happen for `.replaceTableCell`
    /// but the guard keeps the contract honest).
    func refreshCellContents(newBlock: Block) {
        guard case .table(let newHeader, let newAlignments, let newRows, _) = newBlock,
              case .table(let oldHeader, _, let oldRows, _) = self.block,
              newHeader.count == oldHeader.count,
              newRows.count == oldRows.count else {
            update(block: newBlock)
            return
        }
        self.block = newBlock
        let baseFont = bodyFont
        let boldFont = NSFontManager.shared.convert(
            baseFont, toHaveTrait: .boldFontMask
        )
        let nsAlignments = newAlignments.map { TableGeometry.nsAlignment(for: $0) }

        for (rowIdx, cellsInRow) in cellSubviews.enumerated() {
            for (colIdx, cellView) in cellsInRow.enumerated() {
                // Skip the cell currently being edited — its local
                // textStorage is already authoritative for what the
                // user just typed; calling setContent would reset
                // the selection / cursor to .zero.
                if window?.firstResponder === cellView { continue }
                let alignment = colIdx < nsAlignments.count ? nsAlignments[colIdx] : .left
                let isHeader = (rowIdx == 0)
                let modelCell: TableCell?
                if isHeader {
                    modelCell = colIdx < newHeader.count ? newHeader[colIdx] : nil
                } else {
                    let bodyRow = rowIdx - 1
                    modelCell = (bodyRow < newRows.count && colIdx < newRows[bodyRow].count)
                        ? newRows[bodyRow][colIdx] : nil
                }
                guard let modelCell = modelCell else { continue }
                cellView.setContent(
                    cell: modelCell,
                    font: isHeader ? boldFont : baseFont,
                    alignment: alignment
                )
            }
        }
        invalidateIntrinsicContentSize()
        syncFrameSizeToContent()
        needsDisplay = true
        needsLayout = true
        // Force layout to run NOW. Without this, the cell text view's
        // next paint races with our frame-update — when typing widens
        // a column past its old frame, the cell paints with the OLD
        // (narrower) frame and clips the wrapped text. Synchronous
        // layout makes the cell's frame catch up before the next
        // paint cycle, so wrapping (and the row's height growth)
        // appear smoothly.
        layoutSubtreeIfNeeded()
    }

    /// Set the available container width. Called by the provider when
    /// the host text container resizes (window/split-view drag).
    func setContainerWidth(_ width: CGFloat) {
        if abs(width - containerWidth) < 0.5 { return }
        self.containerWidth = width
        invalidateIntrinsicContentSize()
        syncFrameSizeToContent()
        needsDisplay = true
        needsLayout = true
    }

    /// Resize `frame` to the layout-input `containerWidth` to match
    /// `attachment.bounds.width`. The container is wider than the
    /// visible grid extent — clicks past the visible right edge land
    /// on the container, where `mouseDown` (below) routes them to
    /// the parent's after-attachment offset.
    private func syncFrameSizeToContent() {
        let target = NSSize(width: containerWidth, height: totalHeight)
        if frame.size != target {
            setFrameSize(target)
        }
    }

    /// Width the visible grid occupies (sum of column widths + handle
    /// bar + focus-ring padding). Used by `mouseDown` and the parent
    /// EditTextView to decide whether a click landed past the visible
    /// table.
    var visibleGridWidth: CGFloat {
        guard let g = geometry() else { return 0 }
        return g.columnWidths.reduce(0, +)
            + TableGeometry.handleBarWidth
            + TableGeometry.focusRingPadding
    }

    /// Walk up to the host EditTextView, find this attachment's
    /// storage range, invalidate its TK2 layout, and force a viewport
    /// layout pass. Called by `TableAttachment.applyInPlaceBlockUpdate`
    /// when the attachment's bounds change (e.g. row inserted) so the
    /// line fragment expands to the new height. Same pattern
    /// `InlineImageView` uses on resize.
    func requestHostViewportRelayout() {
        var v: NSView? = self.superview
        var editor: EditTextView? = nil
        while let cur = v {
            if let e = cur as? EditTextView {
                editor = e
                break
            }
            v = cur.superview
        }
        guard let editor = editor,
              let tlm = editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage,
              let storage = editor.textStorage else { return }
        // Find the attachment's offset by attribute search.
        var attachmentOffset: Int? = nil
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(
            .attachment, in: fullRange, options: []
        ) { value, range, stop in
            if let candidate = value as? TableAttachment,
               candidate === attachmentForExternalSync {
                attachmentOffset = range.location
                stop.pointee = true
            }
        }
        guard let offset = attachmentOffset,
              let startLoc = cs.location(cs.documentRange.location, offsetBy: offset),
              let endLoc = cs.location(startLoc, offsetBy: 1),
              let range = NSTextRange(location: startLoc, end: endLoc)
        else { return }
        tlm.invalidateLayout(for: range)
        tlm.textViewportLayoutController.layoutViewport()
    }

    /// Reverse-lookup helper: find the TableAttachment whose
    /// `liveContainerView` is `self`. Used by
    /// `requestHostViewportRelayout` to identify which attachment to
    /// invalidate.
    private var attachmentForExternalSync: TableAttachment? {
        // Walk up the editor's storage to find the attachment whose
        // liveContainerView matches self. We don't keep a back-reference
        // (would create a retain cycle since liveContainerView is weak),
        // so we look it up here.
        var v: NSView? = self.superview
        while let cur = v {
            if let editor = cur as? EditTextView,
               let storage = editor.textStorage {
                let fullRange = NSRange(location: 0, length: storage.length)
                var found: TableAttachment? = nil
                storage.enumerateAttribute(
                    .attachment, in: fullRange, options: []
                ) { value, _, stop in
                    if let a = value as? TableAttachment,
                       a.liveContainerView === self {
                        found = a
                        stop.pointee = true
                    }
                }
                return found
            }
            v = cur.superview
        }
        return nil
    }

    // MARK: - Cell subview lifecycle

    /// Rebuild the cell subviews from the current `Block.table`. C0
    /// uses a simple build-from-scratch approach; Phase B's splice
    /// integration may switch to a diff-based update for performance.
    private func rebuildCellSubviews() {
        // Tear down existing.
        for row in cellSubviews { for v in row { v.removeFromSuperview() } }
        cellSubviews.removeAll()

        guard case .table(let header, let alignments, let rows, _) = block,
              header.count > 0 else { return }

        let baseFont = bodyFont
        let boldFont = NSFontManager.shared.convert(
            baseFont, toHaveTrait: .boldFontMask
        )
        let nsAlignments = alignments.map { TableGeometry.nsAlignment(for: $0) }

        // Header row.
        var headerCells: [TableCellTextView] = []
        for (col, cell) in header.enumerated() {
            let alignment = col < nsAlignments.count ? nsAlignments[col] : .left
            let v = TableCellTextView(
                cell: cell,
                font: boldFont,
                alignment: alignment,
                frame: .zero
            )
            v.cellRow = 0
            v.cellCol = col
            v.delegate = self
            addSubview(v)
            headerCells.append(v)
        }
        cellSubviews.append(headerCells)

        // Body rows.
        for (rowIdx, row) in rows.enumerated() {
            var rowCells: [TableCellTextView] = []
            for (col, cell) in row.enumerated() {
                let alignment = col < nsAlignments.count ? nsAlignments[col] : .left
                let v = TableCellTextView(
                    cell: cell,
                    font: baseFont,
                    alignment: alignment,
                    frame: .zero
                )
                v.cellRow = rowIdx + 1
                v.cellCol = col
                v.delegate = self
                addSubview(v)
                rowCells.append(v)
            }
            cellSubviews.append(rowCells)
        }
    }

    // MARK: - NSTextViewDelegate
    //
    // We only adopt `textDidChange(_:)` here. Other delegate hooks
    // (Tab, arrows, completion) are Phase C2/C3 work.

    func textDidChange(_ notification: Notification) {
        guard let cell = notification.object as? TableCellTextView else { return }
        // Sentinel guard: if we ourselves just set the cell's content
        // (via setContent during a refresh), the textStorage edit can
        // re-fire textDidChange. The InlineRenderer.inlineTreeFromAttributedString
        // round-trip is ~idempotent, but we still want to avoid a
        // redundant re-edit cycle. The cleanest gate is to only act
        // when the cell is first responder — content refreshes from
        // refreshCellContents skip the focused cell, and external
        // setContent calls happen before the cell can be first
        // responder.
        guard window?.firstResponder === cell else { return }
        let attr = cell.attributedString()
        let inline = InlineRenderer.inlineTreeFromAttributedString(attr)
        onCellEdit?(cell.cellRow, cell.cellCol, inline)
    }

    /// Phase C2: Tab / Shift-Tab navigate cell-to-cell. Phase C4:
    /// Up / Down arrows navigate row-to-row, exiting the table at
    /// header-top / last-row-bottom. Intercepted at the delegate
    /// level so the cell's own NSTextView never sees the command
    /// (otherwise Tab would insert a literal tab character; arrows
    /// would navigate within the cell only).
    func textView(
        _ textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let cell = textView as? TableCellTextView else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            return focusAdjacentCell(from: cell, reverse: false)
        case #selector(NSResponder.insertBacktab(_:)):
            return focusAdjacentCell(from: cell, reverse: true)
        case #selector(NSResponder.moveUp(_:)):
            return handleArrowAtBoundary(from: cell, direction: .up)
        case #selector(NSResponder.moveDown(_:)):
            return handleArrowAtBoundary(from: cell, direction: .down)
        case #selector(NSResponder.deleteBackward(_:)):
            // Phase C6: Backspace at offset 0 of a cell is a no-op
            // (matches the architecture's "cell-start backspace no-op"
            // rule — prevents merging cell content with the previous
            // cell or with the table's own structure).
            let sel = cell.selectedRange()
            if sel.location == 0 && sel.length == 0 { return true }
            return false
        default:
            return false
        }
    }

    /// Up / Down arrow handler. If the cursor is on the FIRST line of
    /// the cell's text and Up is pressed, navigate to the cell ABOVE
    /// at the same column (or exit the table if no row above). If
    /// the cursor is on the LAST line of the cell's text and Down is
    /// pressed, navigate to the cell BELOW (or exit if no row below).
    /// Otherwise return false so NSTextView handles the arrow within
    /// the cell normally.
    private func handleArrowAtBoundary(
        from cell: TableCellTextView,
        direction: ExitTableDirection
    ) -> Bool {
        guard let storage = cell.textStorage else { return false }
        let cellString = storage.string as NSString
        let cursor = cell.selectedRange().location
        // Find the line range covering the cursor.
        let lineRange = cellString.lineRange(
            for: NSRange(location: cursor, length: 0)
        )
        let isAtTopLine = (lineRange.location == 0)
        let isAtBottomLine: Bool = {
            // Last line: lineRange covers the final segment OR there's
            // no trailing newline AND lineRange.upperBound == length.
            let upper = lineRange.location + lineRange.length
            if upper >= cellString.length { return true }
            // Multi-line cell: bottom line if no further \n exists.
            let rest = cellString.substring(from: upper)
            return !rest.contains("\n")
        }()

        switch direction {
        case .up:
            guard isAtTopLine else { return false }
            // Move to cell above at same column, or exit.
            let aboveRow = cell.cellRow - 1
            if aboveRow >= 0,
               aboveRow < cellSubviews.count,
               cell.cellCol < cellSubviews[aboveRow].count {
                let target = cellSubviews[aboveRow][cell.cellCol]
                window?.makeFirstResponder(target)
                // Park cursor at end of target cell — natural for "moving up".
                let len = target.textStorage?.length ?? 0
                target.setSelectedRange(NSRange(location: len, length: 0))
                return true
            }
            onExitTable?(.up)
            return true
        case .down:
            guard isAtBottomLine else { return false }
            let belowRow = cell.cellRow + 1
            if belowRow < cellSubviews.count,
               cell.cellCol < cellSubviews[belowRow].count {
                let target = cellSubviews[belowRow][cell.cellCol]
                window?.makeFirstResponder(target)
                target.setSelectedRange(NSRange(location: 0, length: 0))
                return true
            }
            onExitTable?(.down)
            return true
        }
    }

    /// Move first responder to the cell after (or before) `cell` in
    /// row-major order. Tab from the last cell calls
    /// `onAppendRowFromTab` (host extends the table); Shift-Tab from
    /// the first cell stays put. Returns `true` to signal the command
    /// was handled.
    private func focusAdjacentCell(from cell: TableCellTextView, reverse: Bool) -> Bool {
        guard cell.cellRow < cellSubviews.count else { return true }
        let row = cell.cellRow
        let col = cell.cellCol
        var nextRow = row
        var nextCol = col
        if reverse {
            nextCol -= 1
            if nextCol < 0 {
                nextRow -= 1
                if nextRow < 0 { return true }
                nextCol = cellSubviews[nextRow].count - 1
            }
        } else {
            nextCol += 1
            if nextCol >= cellSubviews[row].count {
                nextRow += 1
                if nextRow >= cellSubviews.count {
                    // Last cell + forward Tab → append row, focus its
                    // first cell. The host EditTextView handles the
                    // splice + post-mount focus on the new container.
                    onAppendRowFromTab?()
                    return true
                }
                nextCol = 0
            }
        }
        guard nextRow < cellSubviews.count,
              nextCol < cellSubviews[nextRow].count else { return true }
        let nextCell = cellSubviews[nextRow][nextCol]
        window?.makeFirstResponder(nextCell)
        // Select all text in the next cell — standard table-nav
        // convention so the user can immediately type-replace.
        let len = nextCell.textStorage?.length ?? 0
        nextCell.setSelectedRange(NSRange(location: 0, length: len))
        return true
    }

    /// Position each cell subview at its painted rect. Called by
    /// AppKit on layout passes (responds to `needsLayout = true`).
    override func layout() {
        super.layout()
        guard let g = geometry(),
              case .table = block,
              !cellSubviews.isEmpty,
              g.columnWidths.count > 0,
              g.rowHeights.count == cellSubviews.count
        else { return }

        let padH = TableGeometry.cellPaddingH()
        let padTop = TableGeometry.cellPaddingTop()
        let padBot = TableGeometry.cellPaddingBot()
        let gridLeft = TableGeometry.handleBarWidth
        let gridTop = TableGeometry.handleBarHeight

        for (rowIdx, row) in cellSubviews.enumerated() {
            var rowY = gridTop
            for i in 0..<rowIdx { rowY += g.rowHeights[i] }
            let rowHeight = g.rowHeights[rowIdx]
            var colX = gridLeft
            for (colIdx, cellView) in row.enumerated() {
                guard colIdx < g.columnWidths.count else { break }
                let w = g.columnWidths[colIdx]
                let cellRect = CGRect(
                    x: colX + padH,
                    y: rowY + padTop,
                    width: max(0, w - padH * 2),
                    height: max(0, rowHeight - padTop - padBot)
                )
                cellView.frame = cellRect
                colX += w
            }
        }
    }

    override var isFlipped: Bool { true }

    /// Closure fired when the user clicks INSIDE the container's
    /// frame but OUTSIDE any cell subview (the right margin past
    /// the rightmost column, the handle bar, the area between cells
    /// on a grid line). The implementer decides which side of the
    /// attachment to place the parent's cursor on. Set by
    /// `TableAttachmentViewProvider` to forward to the host
    /// `EditTextView`.
    var onClickOutsideCells: ((_ point: NSPoint, _ side: ClickOutsideSide) -> Void)?

    /// Which side of the table the click landed on, relative to the
    /// visible grid extent.
    enum ClickOutsideSide {
        /// Click is left of the leftmost cell (handle bar area).
        case before
        /// Click is right of the rightmost cell, or below all rows
        /// (most common: clicking in the right margin to escape the
        /// table for a new paragraph).
        case after
    }

    /// Override mouseDown to handle clicks that fall on the
    /// container's own area. Clicks on cell subviews never reach
    /// this method — AppKit's hit-test routes those directly to the
    /// cell. Clicks here are on chrome (right margin, handle bar,
    /// grid-line area) and need to land the parent's cursor on a
    /// sensible side of the attachment.
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let side = clickOutsideSide(forContainerLocalPoint: pt)
        onClickOutsideCells?(pt, side)
    }

    /// Decide whether a click in the container's own area is to the
    /// LEFT of the visible cells (handle bar / before the table) or
    /// RIGHT (after the table — the most common case the user wants
    /// to reach to start a new paragraph below).
    private func clickOutsideSide(
        forContainerLocalPoint pt: NSPoint
    ) -> ClickOutsideSide {
        guard let g = geometry() else { return .after }
        let visibleRight = TableGeometry.handleBarWidth + g.columnWidths.reduce(0, +)
        return pt.x < TableGeometry.handleBarWidth ? .before
             : pt.x > visibleRight                  ? .after
             : .after  // grid-line / between-cell area: prefer .after
    }

    private var bodyFont: NSFont {
        UserDefaultsManagement.noteFont
    }

    /// Cached geometry — recomputed when block / containerWidth /
    /// font changes. The cache key is the cell-shape hash (via
    /// `TableGeometry`'s shape hashing inside `compute`) plus the
    /// container width and font point size.
    private var cachedGeometry: TableGeometry.Result?
    private var cachedGeometryKey: String?

    private func geometry() -> TableGeometry.Result? {
        guard case .table(let header, let alignments, let rows, let widths) = block,
              header.count > 0
        else { return nil }
        let font = bodyFont
        let key = "\(containerWidth)|\(font.pointSize)|\(widths?.description ?? "nil")|\(header.map { $0.rawText }.joined(separator: "\u{1f}"))|\(rows.flatMap { $0.map { $0.rawText } }.joined(separator: "\u{1f}"))"
        if let cached = cachedGeometry, cachedGeometryKey == key {
            return cached
        }
        let result = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: containerWidth,
            font: font,
            columnWidthsOverride: widths
        )
        cachedGeometry = result
        cachedGeometryKey = key
        return result
    }

    /// Total height occupied by the table including the top handle
    /// strip. The view provider reads this to size the attachment
    /// bounds in the document.
    var totalHeight: CGFloat {
        guard let g = geometry() else { return 0 }
        return TableGeometry.handleBarHeight + g.totalHeight
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: containerWidth, height: totalHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard case .table(let header, _, _, _) = block,
              header.count > 0,
              let g = geometry(),
              g.columnWidths.count == header.count,
              g.rowHeights.count >= 1,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        // Grid origin: skip the top + left handle strips so handles
        // (Phase F) have reserved space without overlapping cells.
        let gridLeft = TableGeometry.handleBarWidth
        let gridTop = TableGeometry.handleBarHeight
        let gridWidth = g.columnWidths.reduce(0, +)
        let gridHeight = g.totalHeight

        context.saveGState()
        defer { context.restoreGState() }

        // Row fills (header + zebra) are background paint. Cell text
        // content is now rendered by `TableCellTextView` subviews in
        // `layout()`, not by this draw pass — `drawCellContent` is no
        // longer called here. Grid lines paint OVER row fills and
        // UNDER subviews (subviews stack on top of view-layer paint).
        drawRowFills(
            context: context,
            rowHeights: g.rowHeights,
            gridLeft: gridLeft,
            gridTop: gridTop,
            gridWidth: gridWidth
        )
        drawGridLines(
            context: context,
            columnWidths: g.columnWidths,
            rowHeights: g.rowHeights,
            gridLeft: gridLeft,
            gridTop: gridTop,
            gridWidth: gridWidth,
            gridHeight: gridHeight
        )
    }

    // MARK: - Row fills (header + zebra body shading)
    //
    // Uses the shared table chrome colors from TableGeometry.
    private func drawRowFills(
        context: CGContext,
        rowHeights: [CGFloat],
        gridLeft: CGFloat,
        gridTop: CGFloat,
        gridWidth: CGFloat
    ) {
        guard !rowHeights.isEmpty else { return }

        let headerRect = CGRect(
            x: gridLeft,
            y: gridTop,
            width: gridWidth,
            height: rowHeights[0]
        )
        context.saveGState()
        context.setFillColor(TableGeometry.headerFillColor.cgColor)
        context.fill(headerRect)
        context.restoreGState()

        var rowY = gridTop + rowHeights[0]
        for bodyIdx in 0..<(rowHeights.count - 1) {
            let h = rowHeights[bodyIdx + 1]
            if bodyIdx % 2 == 0 {
                let rect = CGRect(
                    x: gridLeft, y: rowY, width: gridWidth, height: h
                )
                context.saveGState()
                context.setFillColor(TableGeometry.zebraFillColor.cgColor)
                context.fill(rect)
                context.restoreGState()
            }
            rowY += h
        }
    }

    // MARK: - Grid lines
    //
    // Draw the table grid using the shared table chrome constants.
    private func drawGridLines(
        context: CGContext,
        columnWidths: [CGFloat],
        rowHeights: [CGFloat],
        gridLeft: CGFloat,
        gridTop: CGFloat,
        gridWidth: CGFloat,
        gridHeight: CGFloat
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(TableGeometry.gridLineColor.cgColor)
        context.setLineWidth(TableGeometry.gridLineWidth)

        let half = TableGeometry.gridLineWidth / 2

        // Horizontal lines.
        var y = gridTop
        context.move(to: CGPoint(x: gridLeft, y: y + half))
        context.addLine(to: CGPoint(x: gridLeft + gridWidth, y: y + half))
        for rh in rowHeights {
            y += rh
            let lineY: CGFloat
            if y >= gridTop + gridHeight - 0.001 {
                lineY = y - half
            } else {
                lineY = y
            }
            context.move(to: CGPoint(x: gridLeft, y: lineY))
            context.addLine(to: CGPoint(x: gridLeft + gridWidth, y: lineY))
        }

        // Vertical lines.
        var x = gridLeft
        context.move(to: CGPoint(x: x + half, y: gridTop))
        context.addLine(to: CGPoint(x: x + half, y: gridTop + gridHeight))
        for (idx, cw) in columnWidths.enumerated() {
            x += cw
            let lineX: CGFloat
            if idx == columnWidths.count - 1 {
                lineX = x - half
            } else {
                lineX = x
            }
            context.move(to: CGPoint(x: lineX, y: gridTop))
            context.addLine(to: CGPoint(x: lineX, y: gridTop + gridHeight))
        }
        context.strokePath()
    }
}
