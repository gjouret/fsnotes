//
//  InlineTableView.swift
//  FSNotes
//
//  Inline WYSIWYG table editor with Apple Notes / Obsidian-style controls.
//  Three states: unfocused (clean), hovered (glass handles visible), editing (full controls).
//  Supports: cell editing, column/row add/delete via context menu, drag-to-reorder,
//  column resize, and keyboard navigation (Tab, Shift+Tab, Return, Escape).
//

import Cocoa

// MARK: - Focus State

enum TableFocusState {
    case unfocused  // Clean table, no controls
    case hovered    // Glass handles + edge "+" buttons visible
    case editing    // Cells editable, full controls
}

// MARK: - InlineTableView

class InlineTableView: NSView, NSTextFieldDelegate {

    // MARK: - Data

    /// View-layer cache of `currentBlock`'s structural fields.
    /// Written only by `applyBlockUpdate` (from an editor-produced
    /// Document) and by structural-mutation methods that then call
    /// `notifyChanged()`. Never written from field-editor state —
    /// cell content edits route through `applyTableCellInlineEdit`.
    var headers: [TableCell] = [TableCell([]), TableCell([])]
    var rows: [[TableCell]] = [[TableCell([]), TableCell([])]]
    var alignments: [NSTextAlignment] = [.left, .left]

    /// The `Block.table` value this widget is currently rendering.
    /// `headers`/`rows`/`alignments` above are a cache computed from
    /// this on each `applyBlockUpdate`.
    private(set) var currentBlock: Block?

    /// Render a single table cell via the real block-model
    /// `InlineRenderer` — the same code path paragraph content uses.
    /// Output has zero markdown markers; `.font` carries bold/italic,
    /// `.strikethroughStyle`/`.underlineStyle` carry strike/underline,
    /// `.backgroundColor` carries highlight, `.link` carries links.
    private func renderedCellText(
        _ cell: TableCell,
        font: NSFont,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        attrs[.paragraphStyle] = para
        let rendered = InlineRenderer.render(cell.inline, baseAttributes: attrs, note: nil)
        // InlineRenderer preserves baseAttributes on its output, but
        // .paragraphStyle is a per-run attribute — re-apply to the
        // whole range so alignment takes effect uniformly even when
        // the renderer split runs for inline formatting.
        let mutable = NSMutableAttributedString(attributedString: rendered)
        if mutable.length > 0 {
            mutable.addAttribute(
                .paragraphStyle, value: para,
                range: NSRange(location: 0, length: mutable.length)
            )
        }
        // Cells store multi-line content as the HTML `<br>` tag for
        // round-trip fidelity with the legacy format. `InlineRenderer`
        // parses those as `.rawHTML` and emits them verbatim — we want
        // them displayed as actual newlines. Post-process the rendered
        // string to replace every `<br>` run with a newline character,
        // preserving the existing attributes on the replacement range.
        var searchStart = 0
        while searchStart < mutable.length {
            let searchRange = NSRange(
                location: searchStart, length: mutable.length - searchStart
            )
            let brRange = (mutable.string as NSString).range(
                of: "<br>", options: [.caseInsensitive], range: searchRange
            )
            if brRange.location == NSNotFound { break }
            mutable.replaceCharacters(in: brRange, with: "\n")
            searchStart = brRange.location + 1
        }
        return mutable
    }

    var focusState: TableFocusState = .unfocused {
        didSet {
            guard oldValue != focusState else { return }
            transitionFocusState(from: oldValue, to: focusState)
        }
    }

    var isFocused: Bool {
        get { focusState == .editing }
        set { focusState = newValue ? .editing : .unfocused }
    }

    var containerWidth: CGFloat = 400

    // MARK: - Cell Pool

    var cellPool: [NSTextField] = []
    private(set) var headerCells: [NSTextField] = []
    private(set) var dataCells: [[NSTextField]] = []

    // MARK: - Glass UI Handles (Obsidian-style: single handle per axis)

    private var activeColumnHandle: GlassHandleView?
    private var activeRowHandle: GlassHandleView?
    private var hoveredColumn: Int?      // Which column the mouse is over
    private var hoveredRow: Int?         // Which row the mouse is over (0=header, 1+=data)
    private var rowHighlightView: NSView?
    private var columnHighlightView: NSView?
    private var trackingArea: NSTrackingArea?

    // MARK: - Drag State

    private var isDragging = false
    private var dragType: DragType = .none
    private var dragSourceIndex = 0
    private var dragImage: NSImageView?
    private var dragInsertionIndicator: NSView?
    private var holdTimer: Timer?

    private enum DragType {
        case none, column, row
    }

    private var copyButton: GlassButton?
    private var copiedFeedbackTimer: Timer?

    // MARK: - Resize State

    private var isResizing = false
    private var resizeColumnIndex = 0
    private var resizeStartX: CGFloat = 0
    private var columnWidthRatios: [CGFloat] = []

    // MARK: - Layout Constants

    /// Minimum cell height: font size + line spacing + vertical padding.
    private var minCellHeight: CGFloat {
        let fontSize = UserDefaultsManagement.noteFont.pointSize
        let spacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        return ceil(fontSize + spacing + cellPaddingTop + cellPaddingBot + fontSize * 0.4)
    }
    /// Line height derived from the note font + line spacing setting.
    private var lineHeight: CGFloat {
        let fontSize = UserDefaultsManagement.noteFont.pointSize
        let spacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        return ceil(fontSize + spacing)
    }
    private let handleSize: CGFloat = 20
    private let edgeButtonSize: CGFloat = 16
    private let minColumnWidth: CGFloat = 80
    private let gridLineWidth: CGFloat = 0.5
    private let handleBarHeight: CGFloat = 11
    private let handleBarWidth: CGFloat = 11
    /// Horizontal cell padding, derived from margin size setting.
    private var cellPaddingH: CGFloat {
        return max(3, ceil(CGFloat(UserDefaultsManagement.marginSize) * 0.2))
    }
    /// Vertical cell padding, derived from line spacing setting.
    private var cellPaddingTop: CGFloat {
        return max(2, ceil(CGFloat(UserDefaultsManagement.editorLineSpacing) * 0.75))
    }
    private var cellPaddingBot: CGFloat {
        return max(2, ceil(CGFloat(UserDefaultsManagement.editorLineSpacing) * 0.75))
    }
    private let focusRingPadding: CGFloat = 8
    /// Extra width per column for text measurement, scales with margin.
    private var columnTextPadding: CGFloat {
        return max(16, ceil(CGFloat(UserDefaultsManagement.marginSize)))
    }

    // MARK: - Computed Layout

    /// Margins are always reserved so handles don't cause layout shift on hover.
    private var currentLeftMargin: CGFloat { handleBarWidth }
    private var currentTopMargin: CGFloat { handleBarHeight }

    /// Inset a column/row rect to produce the cell frame.
    func cellFrame(from rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + cellPaddingH,
               y: rect.minY + cellPaddingBot,
               width: rect.width - cellPaddingH * 2,
               height: rect.height - cellPaddingTop - cellPaddingBot)
    }

    /// Compute all frame geometry from current data. Every layout path calls this.
    func computeLayout() -> TableLayout {
        let colWidths = contentBasedColumnWidths()
        let rHeights = rowHeights(colWidths: colWidths)
        let leftMargin = currentLeftMargin
        let topMargin = currentTopMargin
        let gridWidth = colWidths.reduce(0, +)
        let gridHeight = gridHeightFromRows(rHeights)
        let scrollWidth = min(gridWidth + leftMargin + focusRingPadding, containerWidth)
        let docWidth = gridWidth + leftMargin + focusRingPadding
        let totalHeight = gridHeight + topMargin
        return TableLayout(colWidths: colWidths, rHeights: rHeights,
                           leftMargin: leftMargin, topMargin: topMargin,
                           gridWidth: gridWidth, gridHeight: gridHeight,
                           scrollWidth: scrollWidth, docWidth: docWidth,
                           totalHeight: totalHeight)
    }

    /// All computed geometry values — eliminates ad-hoc recomputation.
    struct TableLayout {
        let colWidths: [CGFloat]
        let rHeights: [CGFloat]
        let leftMargin: CGFloat
        let topMargin: CGFloat
        let gridWidth: CGFloat
        let gridHeight: CGFloat
        let scrollWidth: CGFloat   // min(gridWidth + leftMargin + focusRingPadding, containerWidth)
        let docWidth: CGFloat      // gridWidth + leftMargin + focusRingPadding
        let totalHeight: CGFloat   // gridHeight + topMargin

        var colCount: Int { colWidths.count }
        var rowCount: Int { max(0, rHeights.count - 1) }  // Excludes header
        var totalRows: Int { rHeights.count }
        var headerHeight: CGFloat { rHeights.isEmpty ? 32 : rHeights[0] }

        func dataRowHeight(_ row: Int) -> CGFloat {
            if (row + 1) < rHeights.count { return rHeights[row + 1] }
            // Fallback: font-relative minimum
            let fontSize = UserDefaultsManagement.noteFont.pointSize
            let spacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
            return ceil(fontSize + spacing + fontSize * 0.4 + 4)
        }
    }

    // MARK: - Scroll View (for wide tables)

    private var scrollView: NSScrollView!
    private var gridDocumentView: GridDocumentView!

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true

        // Set up scroll view for horizontal scrolling on wide tables
        gridDocumentView = GridDocumentView()
        gridDocumentView.drawGrid = { [weak self] dirtyRect, context in
            self?.drawGridLines(in: context)
        }

        scrollView = HorizontalScrollView()
        scrollView.documentView = gridDocumentView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed
        addSubview(scrollView)

        // Sync column handle positions with horizontal scroll offset
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        updateTrackingAreas()
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        let scrollX = scrollView.contentView.bounds.origin.x
        updateColumnHandlePositions(scrollOffsetX: scrollX)
    }

    private func updateColumnHandlePositions(scrollOffsetX: CGFloat) {
        guard let col = hoveredColumn, let handle = activeColumnHandle, !handle.isHidden else { return }
        let L = computeLayout()
        var xOffset = L.leftMargin
        for i in 0..<col { if i < L.colWidths.count { xOffset += L.colWidths[i] } }
        handle.frame.origin.x = xOffset - scrollOffsetX
        // Also update column highlight
        if let highlight = columnHighlightView, !highlight.isHidden {
            highlight.frame.origin.x = xOffset - scrollOffsetX
        }
    }

    // MARK: - Configuration

    func configure(with data: TableUtility.TableData) {
        // Legacy paste path: `TableUtility.TableData` still carries
        // string cells. Parse each one through `TableCell.parsing` so
        // the widget stores inline trees like all other code paths.
        headers = data.headers.map { TableCell.parsing($0) }
        rows = data.rows.map { row in row.map { TableCell.parsing($0) } }
        alignments = data.alignments
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild()
    }

    /// Block-aware construction path. Takes a `Block.table` value as
    /// the single source of truth for the widget's content. The
    /// editor passes this in at attachment-construction time and then
    /// calls `applyBlockUpdate(...)` for every subsequent cell edit.
    ///
    /// This is the replacement for `configure(with:)` — the old
    /// `TableUtility.TableData` path remains for compatibility with
    /// clipboard paste (which hasn't been migrated yet) but new call
    /// sites should use this one.
    func configure(withBlock block: Block) {
        guard case .table(let header, let blockAlignments, let bodyRows, _) = block else {
            return
        }
        self.currentBlock = block
        self.headers = header
        self.rows = bodyRows
        self.alignments = blockAlignments.map { nsAlignment(for: $0) }
        let colCount = max(header.count, 1)
        self.columnWidthRatios = Array(
            repeating: 1.0 / CGFloat(colCount), count: colCount
        )
        rebuild()
    }

    /// Apply an updated `Block.table` to this widget in-place. Called
    /// by the editor after `EditingOps.replaceTableCell(...)` produces
    /// a new Document. The widget diffs the new block against its
    /// `currentBlock` and takes one of two paths:
    ///
    ///  - **Shape unchanged** (same row/column count): refresh the
    ///    cells whose content changed. The cell currently holding the
    ///    field editor is left alone — it's the user's source of
    ///    truth for that one cell during an in-flight edit, and
    ///    overwriting it would reset the caret. Other cells get their
    ///    `attributedStringValue` re-parsed from the new raw markdown.
    ///
    ///  - **Shape changed** (row or column added/removed): full grid
    ///    rebuild via `rebuild()`. Shape changes are rare, and any
    ///    in-flight selection or focus is intentionally lost — the
    ///    grid is different now.
    ///
    /// Either way, `currentBlock` is updated to the new value before
    /// returning. No AppKit mutation happens outside this method in
    /// response to a cell edit, and this method never writes back into
    /// the document — it is a one-way projection renderer.
    func applyBlockUpdate(_ newBlock: Block) {
        guard case .table(let newHeader, let newAlignments, let newRows, _) = newBlock else {
            return
        }

        // First-time update (or `currentBlock` was nil): treat as a
        // full configure.
        guard case .table(let oldHeader, _, let oldRows, _)? = currentBlock else {
            configure(withBlock: newBlock)
            return
        }

        // Update the cached arrays and the canonical block first, so
        // that any helper that reads `headers`/`rows`/`alignments`
        // during `recalculateAndResize()` or `rebuild()` sees the new
        // values.
        self.currentBlock = newBlock
        self.headers = newHeader
        self.rows = newRows
        self.alignments = newAlignments.map { nsAlignment(for: $0) }

        // Shape change → full rebuild. We also re-derive column width
        // ratios so a newly-added column has a proportional slice.
        let shapeChanged =
            (newHeader.count != oldHeader.count) ||
            (newRows.count != oldRows.count) ||
            !oldRows.enumerated().allSatisfy { (i, row) in
                i < newRows.count && row.count == newRows[i].count
            }
        if shapeChanged {
            let colCount = max(newHeader.count, 1)
            self.columnWidthRatios = Array(
                repeating: 1.0 / CGFloat(colCount), count: colCount
            )
            rebuild()
            return
        }

        // Shape unchanged → in-place cell refresh. Identify the cell
        // that currently owns the field editor (if any) so we don't
        // trample the user's in-flight edit.
        let activeCell: NSTextField? = {
            guard let fieldEditor = window?.fieldEditor(false, for: nil) else {
                return nil
            }
            return fieldEditor.delegate as? NSTextField
        }()

        let font = UserDefaultsManagement.noteFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

        // Refresh header row cells. Diff on inline-tree equality —
        // unchanged cells do zero work.
        for col in 0..<min(headerCells.count, newHeader.count) {
            let cell = headerCells[col]
            if cell === activeCell { continue }
            if col < oldHeader.count && oldHeader[col] == newHeader[col] { continue }
            let alignment = col < alignments.count ? alignments[col] : .left
            cell.attributedStringValue = renderedCellText(
                newHeader[col], font: boldFont, alignment: alignment
            )
        }

        // Refresh data row cells.
        for row in 0..<min(dataCells.count, newRows.count) {
            let rowCells = dataCells[row]
            let newRow = newRows[row]
            let oldRow = row < oldRows.count ? oldRows[row] : []
            for col in 0..<min(rowCells.count, newRow.count) {
                let cell = rowCells[col]
                if cell === activeCell { continue }
                if col < oldRow.count && oldRow[col] == newRow[col] { continue }
                let alignment = col < alignments.count ? alignments[col] : .left
                cell.attributedStringValue = renderedCellText(
                    newRow[col], font: font, alignment: alignment
                )
            }
        }

        // Column widths may have changed because a cell's content
        // grew or shrank. Recalculate the layout in-place, preserving
        // first responder.
        recalculateAndResize()
    }

    /// Map a block-model `TableAlignment` value to the widget's
    /// AppKit-flavoured `NSTextAlignment`. `.none` collapses to `.left`
    /// to match existing rendering behavior.
    private func nsAlignment(for alignment: TableAlignment) -> NSTextAlignment {
        switch alignment {
        case .left, .none: return .left
        case .center:      return .center
        case .right:       return .right
        }
    }

    /// Inverse of `nsAlignment(for:)` — map the widget's
    /// `NSTextAlignment` back to a block-model `TableAlignment`.
    /// Used when pushing the widget's structural state back into the
    /// Document via `notifyChanged()`. `.justified`/`.natural` collapse
    /// to `.none` because they have no markdown equivalent.
    private func blockAlignment(for alignment: NSTextAlignment) -> TableAlignment {
        switch alignment {
        case .left:   return .left
        case .center: return .center
        case .right:  return .right
        default:      return .none
        }
    }

    /// Build a `Block.table` value that represents the widget's
    /// current state (`headers`, `rows`, `alignments`), with `raw`
    /// recomputed canonically via `EditingOps.rebuildTableRaw`. This
    /// is the bridge from widget state back into the Document model:
    /// `notifyChanged()` uses it to push structural changes (add/
    /// remove row/column, move, alignment change) into the editor's
    /// `documentProjection` so the save path sees them.
    private func buildCurrentTableBlock() -> Block {
        let blockAlignments = alignments.map { blockAlignment(for: $0) }
        let raw = EditingOps.rebuildTableRaw(
            header: headers, alignments: blockAlignments, rows: rows
        )
        return .table(
            header: headers,
            alignments: blockAlignments,
            rows: rows,
            raw: raw
        )
    }

    func focusFirstCell() {
        focusState = .editing
        if let first = headerCells.first {
            window?.makeFirstResponder(first)
        }
    }

    // MARK: - Tracking Areas (Hover Detection)

    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        if focusState == .unfocused {
            focusState = .hovered
        }
        updateHoverPosition(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if focusState == .hovered {
            focusState = .unfocused
        }
        clearHoverHandles()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverPosition(with: event)
    }

    // MARK: - Per-Row/Column Hover Detection

    /// Detect which row and column the mouse is over, and show handles accordingly.
    private func updateHoverPosition(with event: NSEvent) {
        guard focusState == .hovered || focusState == .editing else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let L = computeLayout()

        // Detect hovered column
        var xOffset = L.leftMargin
        var newCol: Int? = nil
        let scrollOffset = scrollView.contentView.bounds.origin.x
        for col in 0..<L.colCount {
            let colX = xOffset - scrollOffset
            if loc.x >= colX && loc.x < colX + L.colWidths[col] {
                newCol = col
                break
            }
            xOffset += L.colWidths[col]
        }

        // Detect hovered row (0=header, 1+=data)
        var newRow: Int? = nil
        // Grid occupies y=0 to y=gridHeight in the scrollView coordinate space
        // But InlineTableView has topMargin above the grid
        let gridLocalY = loc.y  // scrollView is at y=0
        if gridLocalY >= 0 && gridLocalY <= L.gridHeight {
            var rowY = L.gridHeight
            for totalRow in 0..<L.totalRows {
                let rowH = L.rHeights[totalRow]
                if gridLocalY <= rowY && gridLocalY > rowY - rowH {
                    newRow = totalRow
                    break
                }
                rowY -= rowH
            }
        }

        if newCol != hoveredColumn || newRow != hoveredRow {
            hoveredColumn = newCol
            hoveredRow = newRow
            updateHoverHandles(layout: L)
        }
    }

    /// Position the single column and row handles at the hovered position.
    private func updateHoverHandles(layout L: TableLayout) {
        let showHandles = (focusState == .hovered || focusState == .editing)
        guard showHandles else {
            clearHoverHandles()
            return
        }

        let scrollOffset = scrollView.contentView.bounds.origin.x

        // -- Column handle --
        if let col = hoveredColumn {
            var xOffset = L.leftMargin
            for i in 0..<col { xOffset += L.colWidths[i] }
            let handleFrame = NSRect(
                x: xOffset - scrollOffset,
                y: L.gridHeight,
                width: L.colWidths[col],
                height: handleBarHeight
            )

            if activeColumnHandle == nil {
                let handle = GlassHandleView(frame: handleFrame, orientation: .horizontal, index: col)
                handle.onRightClick = { [weak self] index in
                    self?.showColumnContextMenu(column: index, at: handle.frame.origin)
                }
                handle.onDragStart = { [weak self] index in
                    self?.startColumnDrag(column: index)
                }
                addSubview(handle)
                activeColumnHandle = handle
            } else {
                activeColumnHandle?.frame = handleFrame
                activeColumnHandle?.index = col
                activeColumnHandle?.onRightClick = { [weak self] index in
                    self?.showColumnContextMenu(column: index, at: NSPoint(x: handleFrame.origin.x, y: handleFrame.origin.y))
                }
                activeColumnHandle?.onDragStart = { [weak self] index in
                    self?.startColumnDrag(column: index)
                }
            }
            activeColumnHandle?.isHidden = false
            activeColumnHandle?.alphaValue = 1.0

            // Column highlight
            updateColumnHighlight(col: col, layout: L, scrollOffset: scrollOffset)
        } else {
            activeColumnHandle?.isHidden = true
            columnHighlightView?.isHidden = true
        }

        // -- Row handle --
        if let row = hoveredRow {
            var rowY = L.gridHeight
            for i in 0..<row { rowY -= L.rHeights[i] }
            let rowH = L.rHeights[row]
            let handleFrame = NSRect(
                x: 0,
                y: rowY - rowH,
                width: handleBarWidth,
                height: rowH
            )

            if activeRowHandle == nil {
                let handle = GlassHandleView(frame: handleFrame, orientation: .vertical, index: row)
                handle.onRightClick = { [weak self] index in
                    self?.showRowContextMenu(row: index, at: handle.frame.origin)
                }
                handle.onDragStart = { [weak self] index in
                    self?.startRowDrag(row: index)
                }
                addSubview(handle)
                activeRowHandle = handle
            } else {
                activeRowHandle?.frame = handleFrame
                activeRowHandle?.index = row
                activeRowHandle?.onRightClick = { [weak self] index in
                    self?.showRowContextMenu(row: index, at: NSPoint(x: handleFrame.origin.x, y: handleFrame.origin.y))
                }
                activeRowHandle?.onDragStart = { [weak self] index in
                    self?.startRowDrag(row: index)
                }
            }
            activeRowHandle?.isHidden = false
            activeRowHandle?.alphaValue = 1.0

            // Row highlight
            updateRowHighlight(row: row, layout: L)
        } else {
            activeRowHandle?.isHidden = true
            rowHighlightView?.isHidden = true
        }
    }

    /// Draw a subtle highlight on the hovered column.
    private func updateColumnHighlight(col: Int, layout L: TableLayout, scrollOffset: CGFloat) {
        var xOffset = L.leftMargin
        for i in 0..<col { xOffset += L.colWidths[i] }

        let highlightFrame = NSRect(
            x: xOffset - scrollOffset,
            y: 0,
            width: L.colWidths[col],
            height: L.gridHeight + handleBarHeight
        )

        if columnHighlightView == nil {
            let v = NSView(frame: highlightFrame)
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
            v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            v.layer?.borderWidth = 1.0
            // Add above scrollView so the highlight isn't obscured by the clip view
            addSubview(v, positioned: .above, relativeTo: scrollView)
            columnHighlightView = v
        } else {
            columnHighlightView?.frame = highlightFrame
            columnHighlightView?.isHidden = false
        }
    }

    /// Draw a subtle highlight on the hovered row.
    private func updateRowHighlight(row: Int, layout L: TableLayout) {
        var rowY = L.gridHeight
        for i in 0..<row { rowY -= L.rHeights[i] }
        let rowH = L.rHeights[row]

        // RC6: Highlight should start at the grid edge (after the left
        // handle margin) and span only the grid width — not the handle
        // bar. Previously it started at x=0 and included leftMargin,
        // creating a 1-2px offset and bleeding into the handle area.
        // Cap width to remaining visible scrollView width so the
        // highlight doesn't extend past the table.
        let availableGridWidth = max(0, scrollView.frame.width - L.leftMargin)
        let highlightWidth = min(L.gridWidth, availableGridWidth)

        let highlightFrame = NSRect(
            x: L.leftMargin,
            y: rowY - rowH,
            width: highlightWidth,
            height: rowH
        )

        if rowHighlightView == nil {
            let v = NSView(frame: highlightFrame)
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
            v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            v.layer?.borderWidth = 1.0
            // Add above scrollView so the highlight isn't obscured by the clip view
            addSubview(v, positioned: .above, relativeTo: scrollView)
            rowHighlightView = v
        } else {
            rowHighlightView?.frame = highlightFrame
            rowHighlightView?.isHidden = false
        }
    }

    /// Remove all hover handles and highlights.
    private func clearHoverHandles() {
        hoveredColumn = nil
        hoveredRow = nil
        activeColumnHandle?.removeFromSuperview()
        activeColumnHandle = nil
        activeRowHandle?.removeFromSuperview()
        activeRowHandle = nil
        columnHighlightView?.removeFromSuperview()
        columnHighlightView = nil
        rowHighlightView?.removeFromSuperview()
        rowHighlightView = nil
    }

    // Override hitTest so clicks outside the cell grid pass through to EditTextView.
    // This lets users click after the table to place the cursor there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        // Check if any cell contains the point
        for cell in cellPool where !cell.isHidden {
            if cell.frame.contains(localPoint) {
                return super.hitTest(point)
            }
        }
        // Check handle areas
        if let h = activeColumnHandle, !h.isHidden, h.frame.contains(localPoint) {
            return super.hitTest(point)
        }
        if let h = activeRowHandle, !h.isHidden, h.frame.contains(localPoint) {
            return super.hitTest(point)
        }
        // Click is outside all cells/handles — let it pass through to text view
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let wasEditing = (focusState == .editing)
        if !wasEditing {
            focusState = .editing
        }

        // Defer cell focus — rebuild() repositions cells after focusState change
        let clickPoint = event.locationInWindow
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let deferredLoc = self.convert(clickPoint, from: nil)
            for cell in self.cellPool where !cell.isHidden {
                if cell.frame.contains(deferredLoc) {
                    self.window?.makeFirstResponder(cell)
                    return
                }
            }
            // Fallback: focus first header cell
            if let first = self.headerCells.first {
                self.window?.makeFirstResponder(first)
            }
        }
    }

    // MARK: - Column Width Calculation

    /// Compute the height for each row based on multi-line content.
    /// Row 0 = header, rows 1..N = data rows.
    func rowHeights(colWidths: [CGFloat]? = nil) -> [CGFloat] {
        let colCount = headers.count
        guard colCount > 0 else { return [] }

        let font = UserDefaultsManagement.noteFont
        let boldFont = NSFontManager.shared.convert(UserDefaultsManagement.noteFont, toHaveTrait: .boldFontMask)

        var heights: [CGFloat] = []

        // Header row. Measure visible rendered height via InlineRenderer.
        var maxH: CGFloat = minCellHeight
        for col in 0..<colCount {
            let alignment = col < alignments.count ? alignments[col] : .left
            let cw = (colWidths != nil && col < colWidths!.count) ? colWidths![col] : nil
            let h = wrappedCellHeight(headers[col], font: boldFont, alignment: alignment, colWidth: cw)
            maxH = max(maxH, h)
        }
        heights.append(maxH)

        // Data rows.
        for row in rows {
            maxH = minCellHeight
            for col in 0..<min(colCount, row.count) {
                let alignment = col < alignments.count ? alignments[col] : .left
                let cw = (colWidths != nil && col < colWidths!.count) ? colWidths![col] : nil
                let h = wrappedCellHeight(row[col], font: font, alignment: alignment, colWidth: cw)
                maxH = max(maxH, h)
            }
            heights.append(maxH)
        }
        return heights
    }

    /// Calculate the height needed for a cell in a constrained column
    /// width. The cell renders via `InlineRenderer` and the resulting
    /// attributed string's `boundingRect` gives the true rendered
    /// height — no markdown markers contribute to the measurement.
    private func wrappedCellHeight(
        _ cell: TableCell,
        font: NSFont,
        alignment: NSTextAlignment,
        colWidth: CGFloat?
    ) -> CGFloat {
        let cellPad = cellPaddingH * 2
        let rendered = renderedCellText(cell, font: font, alignment: alignment)
        guard let colWidth = colWidth else {
            // Fallback: count visible lines from the rendered string.
            let displayText = rendered.string
            let lineCount = max(1, displayText.components(separatedBy: "\n").count)
            return max(minCellHeight, CGFloat(lineCount) * lineHeight + cellPaddingTop + cellPaddingBot)
        }

        let availableWidth = max(1, colWidth - cellPad)
        let boundingRect = rendered.boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(minCellHeight, ceil(boundingRect.height) + cellPaddingTop + cellPaddingBot + CGFloat(UserDefaultsManagement.editorLineSpacing))
    }

    /// Total grid height from row heights.
    func gridHeightFromRows(_ heights: [CGFloat]) -> CGFloat {
        return heights.reduce(0, +)
    }

    /// Single source of truth for column widths based on actual cell content.
    /// Used by rebuild(), layoutCells(), recalculateAndResize(), and intrinsicContentSize.
    func contentBasedColumnWidths() -> [CGFloat] {
        let colCount = headers.count
        guard colCount > 0 else { return [] }

        let font = UserDefaultsManagement.noteFont
        let boldFont = NSFontManager.shared.convert(UserDefaultsManagement.noteFont, toHaveTrait: .boldFontMask)
        let padding: CGFloat = columnTextPadding

        // Measure the VISIBLE rendered width of each cell via the
        // real InlineRenderer — not the raw markdown length. The
        // renderer produces an attributed string with zero markers
        // in it (bold is a font attribute, italic is a font attribute,
        // etc.) so .size().width is the true rendered width.
        func renderedMaxLineWidth(_ cell: TableCell, alignment: NSTextAlignment, font: NSFont) -> CGFloat {
            let attributed = renderedCellText(cell, font: font, alignment: alignment)
            let displayText = attributed.string
            let lines = displayText.components(separatedBy: "\n")
            if lines.count <= 1 {
                return attributed.size().width
            }
            // Multi-line cell: build per-line attributed substrings
            // and take the widest.
            var maxWidth: CGFloat = 0
            var offset = 0
            for line in lines {
                let lineLen = (line as NSString).length
                if lineLen == 0 {
                    offset += 1 // newline
                    continue
                }
                let range = NSRange(location: offset, length: lineLen)
                let substring = attributed.attributedSubstring(from: range)
                maxWidth = max(maxWidth, substring.size().width)
                offset += lineLen + 1
            }
            return maxWidth
        }

        var widths = Array(repeating: minColumnWidth, count: colCount)
        for col in 0..<colCount {
            let alignment = col < alignments.count ? alignments[col] : .left
            let hw = renderedMaxLineWidth(headers[col], alignment: alignment, font: boldFont) + padding
            widths[col] = max(widths[col], hw)
            for row in rows {
                if col < row.count {
                    let cw = renderedMaxLineWidth(row[col], alignment: alignment, font: font) + padding
                    widths[col] = max(widths[col], cw)
                }
            }
        }

        // Auto-wrap: if total width exceeds available space, shrink wide columns
        let availableWidth = containerWidth - currentLeftMargin - focusRingPadding
        let totalWidth = widths.reduce(0, +)
        if totalWidth > availableWidth && availableWidth > 0 {
            let fairShare = availableWidth / CGFloat(colCount)
            // Identify which columns are "wide" (above fair share)
            var fixedWidth: CGFloat = 0
            var flexCount: CGFloat = 0
            for w in widths {
                if w <= fairShare {
                    fixedWidth += w
                } else {
                    flexCount += 1
                }
            }
            let flexBudget = max(minColumnWidth * flexCount, availableWidth - fixedWidth)
            let perFlex = flexBudget / max(1, flexCount)
            for i in 0..<colCount {
                if widths[i] > fairShare {
                    widths[i] = max(minColumnWidth, perFlex)
                }
            }
        }

        return widths
    }

    /// Measure the width of the longest line in multi-line text (with <br> separators).
    private func maxLineWidth(_ text: String, font: NSFont) -> CGFloat {
        let displayText = text.replacingOccurrences(of: "<br>", with: "\n")
        let lines = displayText.components(separatedBy: "\n")
        var maxWidth: CGFloat = 0
        for line in lines {
            let w = (line as NSString).size(withAttributes: [.font: font]).width
            maxWidth = max(maxWidth, w)
        }
        return maxWidth
    }

    // MARK: - Build (Stable Cell Pool)

    func rebuild() {
        // No pre-rebuild view-to-data sync any more. Under Stage 3
        // of the table cell editing refactor (see CLAUDE.md
        // "Rules That Exist Because I Broke Them"), every cell
        // edit flushes through `EditingOps.replaceTableCellInline`
        // on each keystroke, so the widget's `headers` / `rows`
        // arrays are always in sync with the Document — reading
        // back from `fieldEditor.string` here would strip
        // formatting (plain-string read of an attributed-string
        // field editor) and silently corrupt the active cell.
        let L = computeLayout()

        if columnWidthRatios.count != L.colCount {
            columnWidthRatios = Array(repeating: 1.0 / CGFloat(L.colCount), count: L.colCount)
        }

        // Apply frames from single layout computation
        applyFrames(L)

        // Clear hover handles — they'll be recreated on next mouseMoved
        clearHoverHandles()

        // Build cells using pool
        let neededCells = L.totalRows * L.colCount
        ensureCellPool(count: neededCells)
        headerCells = []
        dataCells = Array(repeating: [], count: L.rowCount)

        var cellIndex = 0
        let isEditing = (focusState == .editing)

        // Header row
        var xOffset = L.leftMargin
        for col in 0..<L.colCount {
            let cell = cellPool[cellIndex]; cellIndex += 1
            let colRect = NSRect(x: xOffset, y: L.gridHeight - L.headerHeight, width: L.colWidths[col], height: L.headerHeight)
            let tableCell = col < headers.count ? headers[col] : TableCell([])
            configureCell(cell, cellData: tableCell, frame: colRect, isHeader: true, isEditing: isEditing, row: 0, col: col)
            headerCells.append(cell)
            xOffset += L.colWidths[col]
        }

        // Data rows
        var yBottom = L.gridHeight - L.headerHeight
        for row in 0..<L.rowCount {
            let rowH = L.dataRowHeight(row)
            yBottom -= rowH
            xOffset = L.leftMargin
            var rowCellArray: [NSTextField] = []
            for col in 0..<L.colCount {
                let cell = cellPool[cellIndex]; cellIndex += 1
                let tableCell = col < rows[row].count ? rows[row][col] : TableCell([])
                let colRect = NSRect(x: xOffset, y: yBottom, width: L.colWidths[col], height: rowH)
                configureCell(cell, cellData: tableCell, frame: colRect, isHeader: false, isEditing: isEditing, row: row + 1, col: col)
                rowCellArray.append(cell)
                xOffset += L.colWidths[col]
            }
            dataCells[row] = rowCellArray
        }

        // Hide unused pool cells
        for i in cellIndex..<cellPool.count {
            cellPool[i].isHidden = true
        }

        // Set up nextKeyView chain: header cells → data cells, left-to-right, top-to-bottom
        // This ensures Tab never lands on handles
        var allCells: [NSTextField] = headerCells
        for rowCellArray in dataCells {
            allCells.append(contentsOf: rowCellArray)
        }
        for i in 0..<allCells.count {
            allCells[i].nextKeyView = allCells[(i + 1) % allCells.count]
        }

        // Copy button moved to gutter — see GutterController.drawIcons().
        copyButton?.removeFromSuperview()
        copyButton = nil

        gridDocumentView.needsDisplay = true
        invalidateIntrinsicContentSize()
        // Structural rebuilds (add/remove row/column) change the
        // widget's intrinsic size. Without telling the hosting text
        // attachment cell, NSLayoutManager keeps using the old bounds
        // and the table ends up drawn at the wrong position (commonly
        // overlapping the heading above it) on the next click-away.
        invalidateAttachmentLayout()
    }

    /// Apply outer frame, scroll view, and document view frames from a layout computation.
    private func applyFrames(_ L: TableLayout) {
        self.frame.size = NSSize(width: L.scrollWidth, height: L.totalHeight)
        scrollView.frame = NSRect(x: 0, y: 0, width: L.scrollWidth, height: L.gridHeight)
        gridDocumentView.frame = NSRect(x: 0, y: 0, width: L.docWidth, height: L.gridHeight)
    }

    // MARK: - Cell Pool Management

    private func ensureCellPool(count: Int) {
        while cellPool.count < count {
            let cell = NSTextField()
            cell.delegate = self
            cell.cell?.truncatesLastVisibleLine = false
            cell.cell?.lineBreakMode = .byClipping
            gridDocumentView.addSubview(cell)
            cellPool.append(cell)
        }
    }

    private func configureCell(_ cell: NSTextField, cellData: TableCell, frame: NSRect, isHeader: Bool, isEditing: Bool, row: Int, col: Int) {
        cell.frame = cellFrame(from: frame)

        let cellFont = isHeader ? NSFontManager.shared.convert(UserDefaultsManagement.noteFont, toHaveTrait: .boldFontMask) : UserDefaultsManagement.noteFont
        let cellAlignment = col < alignments.count ? alignments[col] : NSTextAlignment.left

        // Rich-text mode is REQUIRED so that the field editor, when
        // it attaches to this cell, preserves the attributed
        // string's per-character attributes instead of downgrading
        // to plain text + the cell's default font. Without this
        // flag, `attributedStringValue` still displays correctly
        // in the non-editing state, but the moment the user clicks
        // into a cell the field editor reverts to the cell's plain
        // `font` property at the system default size — which looks
        // slightly smaller than the `renderedCellText` output.
        cell.allowsEditingTextAttributes = true

        // Also set the cell's font property as the fallback used by
        // the field editor's `typingAttributes` when the user types
        // new characters. Without this, newly typed characters can
        // inherit system defaults rather than the note body font.
        cell.font = cellFont
        cell.alignment = cellAlignment

        // Render via the real block-model `InlineRenderer` — the
        // same path paragraph content uses. Applies to BOTH
        // editing and non-editing modes (Stage 3): when the field
        // editor attaches to this cell, it inherits the rendered
        // attributed string (no markers), so the user sees and
        // edits the rendered form. Every keystroke flows back
        // through `inlineTreeFromAttributedString` → primitive,
        // with zero raw-markdown round-trips.
        cell.attributedStringValue = renderedCellText(
            cellData, font: cellFont, alignment: cellAlignment
        )

        cell.isHidden = false
        cell.isEditable = isEditing
        // Never draw an inner border or background — the grid itself provides
        // the visual frame. Flipping these on for edit mode used to wrap the
        // field editor in a second, smaller NSTextField rectangle inset from
        // the grid cell, shifting the text down and right.
        cell.isBordered = false
        cell.bezelStyle = .squareBezel
        cell.drawsBackground = false
        cell.backgroundColor = isHeader ? NSColor.controlBackgroundColor : NSColor.textBackgroundColor
        cell.tag = row * 1000 + col
        // Support multi-line cells (Return inserts newline, stored as <br> in markdown)
        cell.maximumNumberOfLines = 0
        cell.lineBreakMode = .byWordWrapping
        cell.cell?.wraps = true
        cell.cell?.isScrollable = false
    }

    // Glass handle building is now done lazily via updateHoverHandles()
    // — only the hovered row/column gets a handle.

    // MARK: - Context Menus

    private func showColumnContextMenu(column: Int, at point: NSPoint) {
        let menu = NSMenu()
        let insertLeft = menu.addItem(withTitle: "Insert Column Left", action: #selector(contextInsertColumnLeft(_:)), keyEquivalent: "[")
        insertLeft.keyEquivalentModifierMask = [.command, .option]
        insertLeft.tag = column
        let insertRight = menu.addItem(withTitle: "Insert Column Right", action: #selector(contextInsertColumnRight(_:)), keyEquivalent: "]")
        insertRight.keyEquivalentModifierMask = [.command, .option]
        insertRight.tag = column
        if headers.count > 1 {
            menu.addItem(.separator())
            let deleteItem = menu.addItem(withTitle: "Delete Column", action: #selector(contextDeleteColumn(_:)), keyEquivalent: "\u{8}")  // ⌫
            deleteItem.tag = column
        }
        menu.addItem(.separator())

        let alignLeftItem = menu.addItem(withTitle: "Align Left", action: #selector(contextAlignLeft(_:)), keyEquivalent: "l")
        alignLeftItem.tag = column
        alignLeftItem.keyEquivalentModifierMask = .command
        if column < alignments.count && alignments[column] == .left { alignLeftItem.state = .on }

        let centerItem = menu.addItem(withTitle: "Align Center", action: #selector(contextAlignCenter(_:)), keyEquivalent: "e")
        centerItem.tag = column
        centerItem.keyEquivalentModifierMask = .command
        if column < alignments.count && alignments[column] == .center { centerItem.state = .on }

        let alignRightItem = menu.addItem(withTitle: "Align Right", action: #selector(contextAlignRight(_:)), keyEquivalent: "r")
        alignRightItem.tag = column
        alignRightItem.keyEquivalentModifierMask = .command
        if column < alignments.count && alignments[column] == .right { alignRightItem.state = .on }

        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: self)
    }

    private func showRowContextMenu(row: Int, at point: NSPoint) {
        let menu = NSMenu()
        let aboveItem = menu.addItem(withTitle: "Insert Row Above", action: #selector(contextInsertRowAbove(_:)), keyEquivalent: "{")
        aboveItem.keyEquivalentModifierMask = [.command, .option]
        aboveItem.tag = row
        let belowItem = menu.addItem(withTitle: "Insert Row Below", action: #selector(contextInsertRowBelow(_:)), keyEquivalent: "}")
        belowItem.keyEquivalentModifierMask = [.command, .option]
        belowItem.tag = row
        if row > 0 && rows.count > 1 {
            menu.addItem(.separator())
            let deleteItem = menu.addItem(withTitle: "Delete Row", action: #selector(contextDeleteRow(_:)), keyEquivalent: "\u{8}")  // ⌫
            deleteItem.tag = row
        }
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: self)
    }

    // MARK: - Context Menu Actions

    @objc private func contextInsertColumnLeft(_ sender: NSMenuItem) {
        let col = sender.tag
        headers.insert(TableCell([]), at: col)
        alignments.insert(.left, at: col)
        for i in 0..<rows.count { rows[i].insert(TableCell([]), at: min(col, rows[i].count)) }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild()
        notifyChanged()
    }

    @objc private func contextInsertColumnRight(_ sender: NSMenuItem) {
        let col = min(sender.tag + 1, headers.count)
        headers.insert(TableCell([]), at: col)
        alignments.insert(.left, at: col)
        for i in 0..<rows.count { rows[i].insert(TableCell([]), at: min(col, rows[i].count)) }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild()
        notifyChanged()
    }

    @objc private func contextDeleteColumn(_ sender: NSMenuItem) {
        let col = sender.tag
        guard headers.count > 1, col < headers.count else { return }
        headers.remove(at: col)
        if col < alignments.count { alignments.remove(at: col) }
        for i in 0..<rows.count {
            if col < rows[i].count { rows[i].remove(at: col) }
        }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild()
        notifyChanged()
    }

    @objc private func contextAlignLeft(_ sender: NSMenuItem) { setAlignment(.left, column: sender.tag) }
    @objc private func contextAlignCenter(_ sender: NSMenuItem) { setAlignment(.center, column: sender.tag) }
    @objc private func contextAlignRight(_ sender: NSMenuItem) { setAlignment(.right, column: sender.tag) }

    private func setAlignment(_ alignment: NSTextAlignment, column: Int) {
        guard column < alignments.count else { return }
        alignments[column] = alignment
        rebuild()
        notifyChanged()
    }

    @objc private func contextInsertRowAbove(_ sender: NSMenuItem) {
        let dataRow = sender.tag - 1  // tag 0 = header, data starts at 1
        let newRow = Array(repeating: TableCell([]), count: headers.count)
        if dataRow < 0 {
            rows.insert(newRow, at: 0)
        } else {
            rows.insert(newRow, at: min(dataRow, rows.count))
        }
        rebuild()
        notifyChanged()
    }

    @objc private func contextInsertRowBelow(_ sender: NSMenuItem) {
        let dataRow = sender.tag  // insert after this row (tag includes header offset)
        let newRow = Array(repeating: TableCell([]), count: headers.count)
        rows.insert(newRow, at: min(dataRow, rows.count))
        rebuild()
        notifyChanged()
    }

    @objc private func contextDeleteRow(_ sender: NSMenuItem) {
        let dataRow = sender.tag - 1
        guard dataRow >= 0, dataRow < rows.count, rows.count > 1 else { return }
        rows.remove(at: dataRow)
        rebuild()
        notifyChanged()
    }

    // MARK: - Edge Button Actions

    private func addColumnAtEnd() {
        headers.append(TableCell([]))
        alignments.append(.left)
        for i in 0..<rows.count { rows[i].append(TableCell([])) }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild()
        notifyChanged()
    }

    private func addRowAtEnd() {
        rows.append(Array(repeating: TableCell([]), count: headers.count))
        rebuild()
        notifyChanged()
    }

    // MARK: - Drag-to-Reorder

    private func startColumnDrag(column: Int) {
        let colCount = headers.count
        guard column >= 0, column < colCount else { return }

        let colWidths = contentBasedColumnWidths()
        let rHeights = rowHeights()
        let gridHeight = gridHeightFromRows(rHeights)
        let leftMargin: CGFloat = handleBarWidth

        let gridWidth = colWidths.reduce(0, +) + leftMargin

        guard let window = self.window else { return }
        var targetIndex = column

        // Change handle color to accent (toolbar "on" state)
        activeColumnHandle?.setDragActive(true)

        // Create indicator and highlight in the grid document view (scrollable)
        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(indicator)  // Parent view — draws on top of handles

        let sourceHighlight = NSView()
        sourceHighlight.wantsLayer = true
        sourceHighlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        sourceHighlight.layer?.borderWidth = 2
        sourceHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        var srcX = leftMargin
        for i in 0..<column { srcX += colWidths[i] }
        sourceHighlight.frame = NSRect(x: srcX, y: 0, width: colWidths[column], height: gridHeight)
        gridDocumentView.addSubview(sourceHighlight)

        let autoScrollMargin: CGFloat = 30
        let autoScrollStep: CGFloat = 20

        var keepTracking = true
        while keepTracking {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            let loc = convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseUp {
                keepTracking = false
            } else {
                // Auto-scroll when dragging near edges of the scroll view
                let visibleRect = scrollView.contentView.bounds
                if loc.x < autoScrollMargin {
                    let newX = max(0, visibleRect.origin.x - autoScrollStep)
                    scrollView.contentView.scroll(to: NSPoint(x: newX, y: visibleRect.origin.y))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                } else if loc.x > scrollView.frame.width - autoScrollMargin {
                    let maxX = max(0, gridWidth - scrollView.frame.width)
                    let newX = min(maxX, visibleRect.origin.x + autoScrollStep)
                    scrollView.contentView.scroll(to: NSPoint(x: newX, y: visibleRect.origin.y))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }

                // Use document view coordinates for column gap detection
                let docLoc = gridDocumentView.convert(event.locationInWindow, from: nil)

                var x = leftMargin
                var bestGap = 0
                var bestDist: CGFloat = .greatestFiniteMagnitude
                for i in 0...colCount {
                    let dist = abs(docLoc.x - x)
                    if dist < bestDist {
                        bestDist = dist
                        bestGap = i
                    }
                    if i < colCount { x += colWidths[i] }
                }
                targetIndex = bestGap

                // Compute indicator x in document view coords, then convert to parent
                var indX = leftMargin
                for i in 0..<targetIndex {
                    if i < colWidths.count { indX += colWidths[i] }
                }
                let scrollOffset = scrollView.contentView.bounds.origin.x
                let parentX = indX - scrollOffset - 1
                indicator.frame = NSRect(x: parentX, y: 0, width: 2, height: gridHeight)

                // Animate handle sliding along the top edge to follow the mouse
                if let handle = activeColumnHandle {
                    let clampedX = max(leftMargin - scrollOffset, min(loc.x - handle.frame.width / 2, leftMargin + gridWidth - scrollOffset - handle.frame.width))
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.08
                        handle.animator().frame.origin.x = clampedX
                    }
                }
            }
        }

        // Reset handle color
        activeColumnHandle?.setDragActive(false)
        indicator.removeFromSuperview()
        sourceHighlight.removeFromSuperview()

        // Calculate destination: after removing source, where should we insert?
        let dst = targetIndex > column ? targetIndex - 1 : targetIndex

        if dst != column {
            moveColumn(from: column, to: dst)
        }
    }

    private func startRowDrag(row: Int) {
        // Row handle indices: 0 = header, 1+ = data rows.
        // Header row CAN be dragged — special handling below.
        let rHeights = rowHeights()
        let gridHeight = rHeights.reduce(0, +)
        let leftMargin: CGFloat = handleBarWidth
        let totalRowCount = rHeights.count  // header + data rows

        guard row >= 0, row < totalRowCount else { return }
        guard let window = self.window else { return }

        // Change handle color to accent (toolbar "on" state)
        activeRowHandle?.setDragActive(true)

        var targetRow = row  // target in total-row space (0=header position)

        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(indicator)

        // Create source row highlight (blue border)
        let sourceHighlight = NSView()
        sourceHighlight.wantsLayer = true
        sourceHighlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        sourceHighlight.layer?.borderWidth = 2
        sourceHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        var srcY = gridHeight
        for i in 0..<row { srcY -= rHeights[i] }
        let srcRowH = rHeights[row]
        sourceHighlight.frame = NSRect(x: 0, y: srcY - srcRowH, width: bounds.width, height: srcRowH)
        addSubview(sourceHighlight)

        var keepTracking = true
        while keepTracking {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            let loc = convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseUp {
                keepTracking = false
            } else {
                // Find which row gap the cursor is nearest (in total-row space)
                var y = gridHeight
                var bestGap = 0
                var bestDist: CGFloat = .greatestFiniteMagnitude

                for i in 0...totalRowCount {
                    let dist = abs(loc.y - y)
                    if dist < bestDist {
                        bestDist = dist
                        bestGap = i
                    }
                    if i < totalRowCount {
                        y -= rHeights[i]
                    }
                }
                targetRow = bestGap

                // Position indicator at the target gap
                var indY = gridHeight
                for i in 0..<targetRow { indY -= rHeights[i] }
                indicator.frame = NSRect(x: leftMargin, y: indY - 1, width: bounds.width - leftMargin, height: 2)

                // Animate handle sliding along the left edge to follow the mouse
                if let handle = activeRowHandle {
                    let clampedY = max(0, min(loc.y - handle.frame.height / 2, gridHeight - handle.frame.height))
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.08
                        handle.animator().frame.origin.y = clampedY
                    }
                }
            }
        }

        // Reset handle color
        activeRowHandle?.setDragActive(false)
        indicator.removeFromSuperview()
        sourceHighlight.removeFromSuperview()

        let dst = targetRow > row ? targetRow - 1 : targetRow
        if dst != row {
            moveRowTotal(from: row, to: dst)
        }
    }

    /// Move a row in total-row space (0=header, 1+=data).
    /// If the header (row 0) is moved down, the first data row becomes the new header.
    private func moveRowTotal(from src: Int, to dst: Int) {
        guard src != dst, src >= 0, dst >= 0 else { return }
        let totalRows = 1 + rows.count  // header + data

        guard src < totalRows, dst < totalRows else { return }

        // Build a unified row array: [headers] + rows
        var allRows: [[TableCell]] = [headers] + rows

        let moved = allRows.remove(at: src)
        allRows.insert(moved, at: dst)

        // Row 0 of allRows becomes the new header
        headers = allRows[0]
        rows = Array(allRows.dropFirst())

        rebuild()
        notifyChanged()
    }

    private func moveColumn(from src: Int, to dst: Int) {
        guard src >= 0, src < headers.count, dst >= 0, dst < headers.count, src != dst else { return }
        let h = headers.remove(at: src)
        headers.insert(h, at: dst)
        let a = alignments.remove(at: src)
        alignments.insert(a, at: dst)
        for r in 0..<rows.count {
            if src < rows[r].count && dst <= rows[r].count {
                let v = rows[r].remove(at: src)
                rows[r].insert(v, at: dst)
            }
        }

        rebuild()
        notifyChanged()
    }

    private func moveRow(from src: Int, to dst: Int) {
        guard src >= 0, src < rows.count, dst >= 0, dst < rows.count, src != dst else { return }
        let r = rows.remove(at: src)
        rows.insert(r, at: dst)
        rebuild()
        notifyChanged()
    }

    // NOTE: the former `collectCellData()` helper — which walked
    // the active field editor and wrote its `.string` back into
    // `rows[r][c]` — has been deleted. Under Stage 3 it became a
    // silent corruption vector: cells render via `InlineRenderer`
    // with attributes (not markers), so `fieldEditor.string`
    // returns the VISIBLE text with no formatting. Writing that
    // back into the cell stripped every bold/italic/highlight/
    // strike/underline from the active cell. The correct path is
    // `controlTextDidChange` → `inlineTreeFromAttributedString` →
    // `EditingOps.replaceTableCellInline`, which is called on
    // every keystroke and preserves all attribute runs.

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // AppKit's field-editor commit copies the field editor's
        // plain string back into the NSTextField's attributedStringValue,
        // erasing the rendered form — re-render via InlineRenderer
        // so the marker-free display comes back on detach. The
        // Document is already in sync from per-keystroke
        // `controlTextDidChange` → `applyTableCellInlineEdit`.
        guard let cell = obj.object as? NSTextField,
              let location = cellLocation(for: cell) else { return }
        let font = UserDefaultsManagement.noteFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let tableCell: TableCell
        let isHeader: Bool
        let col: Int
        switch location {
        case .header(let c):
            col = c
            isHeader = true
            guard col < headers.count else { return }
            tableCell = headers[col]
        case .body(let r, let c):
            col = c
            isHeader = false
            guard r < rows.count, col < rows[r].count else { return }
            tableCell = rows[r][col]
        }
        let alignment = col < alignments.count ? alignments[col] : .left
        let cellFont = isHeader
            ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            : font
        cell.attributedStringValue = renderedCellText(
            tableCell, font: cellFont, alignment: alignment
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        clearHoverHandles()

        // `NSControl.textDidChangeNotification` delivers the
        // NSTextField (the NSControl) as `obj.object`, NOT the field
        // editor NSTextView. Query the window for the field editor.
        guard
            let fieldEditor = window?.fieldEditor(false, for: nil),
            let activeCell = fieldEditor.delegate as? NSTextField,
            let editor = findParentEditTextView(),
            let location = cellLocation(for: activeCell)
        else {
            return
        }

        // Pass the field editor's storage directly — `NSTextStorage`
        // IS an `NSAttributedString` and the converter only reads.
        // Skipping the copy saves an allocation per keystroke.
        let attr: NSAttributedString
        if let tv = fieldEditor as? NSTextView, let storage = tv.textStorage {
            attr = storage
        } else {
            attr = NSAttributedString(string: fieldEditor.string)
        }
        let inline = InlineRenderer.inlineTreeFromAttributedString(attr)
        _ = editor.applyTableCellInlineEdit(
            from: self, at: location, inline: inline
        )
    }

    /// Find which cell in the grid is the given `NSTextField`, and
    /// return the corresponding `TableCellLocation`. Returns nil if
    /// the cell is not part of this widget.
    func cellLocation(for cell: NSTextField) -> EditingOps.TableCellLocation? {
        for (col, headerCell) in headerCells.enumerated() {
            if headerCell === cell { return .header(col: col) }
        }
        for (row, rowCells) in dataCells.enumerated() {
            for (col, dataCell) in rowCells.enumerated() {
                if dataCell === cell { return .body(row: row, col: col) }
            }
        }
        return nil
    }

    /// Recalculate column widths from content and resize the table frame.
    /// Columns expand to fit content; the table grows (up to containerWidth).
    private func recalculateAndResize() {
        let L = computeLayout()
        guard L.colCount > 0 else { return }
        applyFrames(L)
        layoutCells(L)
        gridDocumentView.needsDisplay = true
        invalidateIntrinsicContentSize()
        // The attachment cell's bounds must be updated whenever the
        // widget's intrinsic size changes, or the NSTextView layout
        // manager keeps using the stale size and the table ends up
        // mispositioned (e.g. overlapping the H1 title) on the next
        // layout pass triggered by a click outside the widget.
        invalidateAttachmentLayout()
    }

    /// Update cell AND handle frames in-place from a TableLayout (preserves first responder).
    private func layoutCells(_ L: TableLayout) {
        guard L.colCount > 0 else { return }

        // Header row
        var x = L.leftMargin
        for col in 0..<min(L.colCount, headerCells.count) {
            let colRect = NSRect(x: x, y: L.gridHeight - L.headerHeight, width: L.colWidths[col], height: L.headerHeight)
            headerCells[col].frame = cellFrame(from: colRect)
            x += L.colWidths[col]
        }

        // Data rows
        var yBottom = L.gridHeight - L.headerHeight
        for (rowIdx, rowCellArray) in dataCells.enumerated() {
            let rowH = L.dataRowHeight(rowIdx)
            yBottom -= rowH
            x = L.leftMargin
            for col in 0..<min(L.colCount, rowCellArray.count) {
                let colRect = NSRect(x: x, y: yBottom, width: L.colWidths[col], height: rowH)
                rowCellArray[col].frame = cellFrame(from: colRect)
                x += L.colWidths[col]
            }
        }

        // Hover handles are positioned by updateHoverHandles(), not here.
    }

    // Handle Tab / Return for keyboard navigation
    func control(_ control: NSControl, textView tv: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertTab(_:)) {
            // Tab in last cell (bottom-right) → add new row
            if let cell = control as? NSTextField {
                let (row, col) = decodeTag(cell.tag)
                let isLastRow = (row == rows.count)  // row 0 = header, rows.count = last data row
                let isLastCol = (col == headers.count - 1)
                if isLastRow && isLastCol {
                    rows.append(Array(repeating: TableCell([]), count: headers.count))
                    rebuild()
                    notifyChanged()
                    // Focus first cell of new row
                    if let newCell = cellAt(row: rows.count, col: 0) {
                        window?.makeFirstResponder(newCell)
                    }
                    return true
                }
            }
            navigateToNextCell(from: control as? NSTextField)
            return true
        }
        if commandSelector == #selector(insertBacktab(_:)) {
            navigateToPreviousCell(from: control as? NSTextField)
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            // Return = insert newline within the cell (displayed as multi-line,
            // stored as <br> in markdown). Like Bear's table behavior.
            tv.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            // Escape: unfocus table
            focusState = .unfocused
            if let textView = superview as? NSTextView {
                window?.makeFirstResponder(textView)
            }
            return true
        }
        return false
    }

    // MARK: - Keyboard Navigation

    private func navigateToNextCell(from cell: NSTextField?) {
        guard let cell = cell else { return }
        let (row, col) = decodeTag(cell.tag)
        if let next = cellAt(row: row, col: col + 1) ?? cellAt(row: row + 1, col: 0) {
            window?.makeFirstResponder(next)
        }
    }

    private func navigateToPreviousCell(from cell: NSTextField?) {
        guard let cell = cell else { return }
        let (row, col) = decodeTag(cell.tag)
        if let prev = cellAt(row: row, col: col - 1) ?? cellAt(row: row - 1, col: headers.count - 1) {
            window?.makeFirstResponder(prev)
        }
    }

    private func navigateToCellBelow(from cell: NSTextField?) {
        guard let cell = cell else { return }
        let (row, col) = decodeTag(cell.tag)
        if let below = cellAt(row: row + 1, col: col) {
            window?.makeFirstResponder(below)
        } else {
            // At bottom — add new row
            rows.append(Array(repeating: TableCell([]), count: headers.count))
            rebuild()
            notifyChanged()
            if let newCell = cellAt(row: row + 1, col: col) {
                window?.makeFirstResponder(newCell)
            }
        }
    }

    private func cellAt(row: Int, col: Int) -> NSTextField? {
        guard col >= 0, col < headers.count else { return nil }
        if row == 0 {
            return col < headerCells.count ? headerCells[col] : nil
        }
        let dataRow = row - 1
        guard dataRow >= 0, dataRow < dataCells.count, col < dataCells[dataRow].count else { return nil }
        return dataCells[dataRow][col]
    }

    private func decodeTag(_ tag: Int) -> (row: Int, col: Int) {
        return (tag / 1000, tag % 1000)
    }

    // MARK: - Attachment Layout Invalidation

    /// Tell the parent NSTextView's layout manager that this attachment changed size.
    /// This forces NSTextView to re-query cellSize() and re-layout the text around it.
    private func invalidateAttachmentLayout() {
        guard let textView = superview as? NSTextView,
              let storage = textView.textStorage,
              let layoutManager = textView.layoutManager else { return }

        // Find our attachment character in the text storage
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let attachment = value as? NSTextAttachment,
                  let cell = attachment.attachmentCell as? InlineTableAttachmentCell,
                  cell.inlineTableView === self else { return }

            // Update attachment bounds to match new intrinsic size
            let newSize = self.intrinsicContentSize
            attachment.bounds = NSRect(origin: .zero, size: newSize)

            // Invalidate layout at the attachment position
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
            stop.pointee = true
        }
    }

    // MARK: - Copy as TSV

    private func copyTableAsTSV() {
        var lines: [String] = []
        lines.append(headers.map { $0.rawText }.joined(separator: "\t"))
        for row in rows {
            lines.append(row.map { $0.rawText }.joined(separator: "\t"))
        }
        let tsv = lines.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
        NSPasteboard.general.setString(tsv, forType: NSPasteboard.PasteboardType(rawValue: "public.utf8-tab-separated-values-text"))

        // Show "Copied" feedback
        copyButton?.setSymbol("\u{2713}") // ✓
        copiedFeedbackTimer?.invalidate()
        copiedFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.copyButton?.setSymbol("\u{2398}") // ⎘
        }
    }

    // MARK: - Focus State Transition

    private func transitionFocusState(from: TableFocusState, to: TableFocusState) {
        let showHandles = (to == .hovered || to == .editing)
        let wasShowingHandles = (from == .hovered || from == .editing)

        if showHandles != wasShowingHandles {
            // Margins are always reserved, so no invalidateAttachmentLayout() needed.
            rebuild()
            if !showHandles {
                clearHoverHandles()
            }
        } else {
            // Just update cell editability — borders and backgrounds stay
            // off in both states so the field editor overlays cleanly.
            let isEditing = (to == .editing)
            for cell in headerCells {
                cell.isEditable = isEditing
            }
            for rowCells in dataCells {
                for cell in rowCells {
                    cell.isEditable = isEditing
                }
            }
            invalidateIntrinsicContentSize()
        }
    }

    // NOTE: `parseInlineMarkdown` and `generateMarkdown` — the
    // widget's local regex inline renderer and TSV/markdown
    // generator — are DELETED. Cell rendering goes through
    // `renderedCellText` → `InlineRenderer.render`; markdown
    // generation flows through `MarkdownSerializer.serialize(.table)`
    // reading `Block.table.raw` (recomputed by
    // `EditingOps.rebuildTableRaw` on every edit). Don't reintroduce
    // — rule 7 prohibits marker-hiding attribute tricks that the
    // old widget path used to need.

    // MARK: - Notify

    /// Called by every structural-mutation path (add/remove row,
    /// add/remove column, move, alignment change) to push the
    /// widget's post-mutation state into the Document via
    /// `EditTextView.pushTableBlockToProjection`.
    func notifyChanged() {
        guard let editTextView = findParentEditTextView() else { return }
        let newBlock = buildCurrentTableBlock()
        self.currentBlock = newBlock
        editTextView.pushTableBlockToProjection(from: self, newBlock: newBlock)
        editTextView.hasUserEdits = true
        editTextView.save()
    }

    private func findParentEditTextView() -> EditTextView? {
        var view: NSView? = superview
        while let v = view {
            if let etv = v as? EditTextView { return etv }
            view = v.superview
        }
        return nil
    }

    // MARK: - Drawing

    /// Draws grid lines, header background, and alternating row colors.
    private func drawGridLines(in context: CGContext) {
        let L = computeLayout()

        // Draw backgrounds FIRST so grid lines paint on top (otherwise the translucent
        // header/row fills dilute the line color and the header lines look fainter).
        let headerRect = NSRect(x: L.leftMargin, y: L.gridHeight - L.headerHeight, width: L.gridWidth, height: L.headerHeight)
        NSColor(calibratedWhite: 0.85, alpha: 1.0).setFill()
        NSBezierPath(rect: headerRect).fill()

        var rowY = L.gridHeight - L.headerHeight
        for row in 0..<L.rowCount {
            let rowH = L.dataRowHeight(row)
            rowY -= rowH
            if row % 2 == 0 {
                NSColor(calibratedWhite: 0.95, alpha: 1.0).setFill()
                NSBezierPath(rect: NSRect(x: L.leftMargin, y: rowY, width: L.gridWidth, height: rowH)).fill()
            }
        }

        context.setStrokeColor(NSColor(calibratedWhite: 0.4, alpha: 1.0).cgColor)
        context.setLineWidth(gridLineWidth)

        // Strokes are centered on the path, so a line at y=0 or y=gridHeight has half its
        // stroke outside the view bounds (clipped). Inset boundary lines by half line width.
        let half = gridLineWidth / 2

        // Horizontal lines
        var lineY: CGFloat = 0
        for i in 0...L.totalRows {
            var y = lineY
            if i == 0 { y = half }
            if i == L.totalRows { y = L.gridHeight - half }
            context.move(to: CGPoint(x: L.leftMargin, y: y))
            context.addLine(to: CGPoint(x: L.leftMargin + L.gridWidth, y: y))
            if i < L.rHeights.count {
                lineY += L.rHeights[L.rHeights.count - 1 - i]
            }
        }

        // Vertical lines
        var xOffset = L.leftMargin
        for i in 0...L.colCount {
            var x = xOffset
            if i == 0 { x = L.leftMargin + half }
            if i == L.colCount { x = L.leftMargin + L.gridWidth - half }
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: L.gridHeight))
            if i < L.colCount { xOffset += L.colWidths[i] }
        }
        context.strokePath()
    }

    // MARK: - Scroll Behavior

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: NSSize {
        let L = computeLayout()
        return NSSize(width: L.scrollWidth, height: L.totalHeight)
    }
}

// MARK: - Horizontal-Only Scroll View

/// A scroll view that only handles horizontal scrolling. Vertical scroll
/// events are forwarded to the next responder (the editor's scroll view),
/// preventing the table widget from capturing page-level vertical scrolls.
///
/// This is critical because NSScrollView's default scrollWheel(with:)
/// consumes ALL scroll events before the parent InlineTableView ever sees
/// them. Without this subclass, the InlineTableView.scrollWheel override
/// is dead code — the inner NSScrollView intercepts first.
private class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let isHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let needsHScroll = (documentView?.frame.width ?? 0) > frame.width

        if isHorizontal && needsHScroll {
            // Horizontal scroll on a wide table — handle it here.
            super.scrollWheel(with: event)
        } else {
            // Vertical scroll (or horizontal on a non-scrollable table) —
            // forward to the editor's scroll view via the responder chain.
            nextResponder?.scrollWheel(with: event)
        }
    }
}

// MARK: - Grid Document View

/// The scrollable content view that draws grid lines (cell borders + header background).
/// Lives inside the NSScrollView so lines scroll with the cells.
private class GridDocumentView: NSView {
    var drawGrid: ((NSRect, CGContext) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawGrid?(dirtyRect, context)
    }
}


// MARK: - Glass Handle View

/// A frosted-glass handle bar for column/row drag and context menu.
/// Obsidian-style: compact, shows only on the hovered row/column,
/// uses a six-dot grip (⠿), changes color when dragging.
class GlassHandleView: NSVisualEffectView {

    enum Orientation { case horizontal, vertical }

    let orientation: Orientation
    var index: Int

    var onRightClick: ((Int) -> Void)?
    var onDragStart: ((Int) -> Void)?

    private let gripLabel = NSTextField(labelWithString: "")

    init(frame: NSRect, orientation: Orientation, index: Int) {
        self.orientation = orientation
        self.index = index
        super.init(frame: frame)
        setupGlass()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    private func setupGlass() {
        material = .titlebar
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor

        // Six-dot grip glyph (⠿) — more visible than "⋮⋮"
        gripLabel.stringValue = "⠿"
        gripLabel.font = NSFont.systemFont(ofSize: max(8, UserDefaultsManagement.noteFont.pointSize * 0.75), weight: .bold)
        gripLabel.textColor = NSColor.secondaryLabelColor
        gripLabel.alignment = .center
        gripLabel.sizeToFit()
        gripLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gripLabel)

        NSLayoutConstraint.activate([
            gripLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            gripLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Change appearance to indicate active drag state.
    /// Uses the toolbar "on" button accent color.
    func setDragActive(_ active: Bool) {
        if active {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            gripLabel.textColor = NSColor.white
        } else {
            layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
            gripLabel.textColor = NSColor.secondaryLabelColor
        }
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            self.animator().layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            self.animator().layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(index)
        // Don't call super — prevents system context menu from appearing
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        return nil  // Suppress system context menu
    }

    override func mouseDown(with event: NSEvent) {
        // Start drag
        onDragStart?(index)
    }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil))
    }
}

// MARK: - Glass Button

/// A circular frosted-glass "+" button for edge add actions.
class GlassButton: NSVisualEffectView {

    var onTap: (() -> Void)?

    private let label = NSTextField(labelWithString: "+")

    override var acceptsFirstResponder: Bool { false }

    init(frame: NSRect, symbol: String) {
        super.init(frame: frame)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2

        label.stringValue = symbol
        label.font = NSFont.systemFont(ofSize: max(10, UserDefaultsManagement.noteFont.pointSize * 0.9), weight: .medium)
        label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSymbol(_ symbol: String) {
        label.stringValue = symbol
    }

    override func mouseDown(with event: NSEvent) {
        // Visual feedback
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.05
            self.animator().alphaValue = 0.6
        }) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                self.animator().alphaValue = 1.0
            }
        }
        onTap?()
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            label.animator().alphaValue = 1.0
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            label.animator().alphaValue = 0.5
        }
    }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil))
    }
}

// MARK: - Attachment Cell

/// Custom NSTextAttachmentCell that hosts an InlineTableView.
class InlineTableAttachmentCell: NSTextAttachmentCell, TableAttachmentHosting {

    let inlineTableView: InlineTableView
    private let desiredSize: NSSize

    init(tableView: InlineTableView, size: NSSize) {
        self.inlineTableView = tableView
        self.desiredSize = size
        super.init()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cellSize() -> NSSize {
        // Return dynamic size based on current table state (editing adds handle space)
        return inlineTableView.intrinsicContentSize
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // No-op: wait for the characterIndex variant which can validate the position.
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        // Don't draw if this attachment is inside a folded region
        if let ts = layoutManager.textStorage,
           charIndex < ts.length,
           ts.attribute(.foldedContent, at: charIndex, effectiveRange: nil) != nil {
            inlineTableView.isHidden = true
            return
        }
        guard let textView = controlView as? NSTextView else { return }

        // Only add and position the live view when the layout manager provides a
        // valid frame. For tables outside the viewport (non-contiguous layout),
        // the frame will be wrong (near 0,0 for a late-document attachment).
        let hasContentBefore = charIndex > 10
        let frameNearTop = cellFrame.origin.y < 50
        if hasContentBefore && frameNearTop {
            return
        }

        // Position the live table view and make it visible
        inlineTableView.frame = cellFrame
        inlineTableView.isHidden = false
        if inlineTableView.superview !== textView {
            textView.addSubview(inlineTableView)
        }
    }
}
