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

    var headers: [String] = ["", ""]
    var rows: [[String]] = [["", ""]]
    var alignments: [NSTextAlignment] = [.left, .left]

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

    // MARK: - Glass UI Handles

    private var columnHandles: [GlassHandleView] = []
    private var rowHandles: [GlassHandleView] = []
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

    // MARK: - Resize State

    private var isResizing = false
    private var resizeColumnIndex = 0
    private var resizeStartX: CGFloat = 0
    private var columnWidthRatios: [CGFloat] = []

    // MARK: - Layout Constants

    private let minCellHeight: CGFloat = 32
    private let lineHeight: CGFloat = 17
    private let handleSize: CGFloat = 20
    private let edgeButtonSize: CGFloat = 16
    private let minColumnWidth: CGFloat = 80
    private let gridLineWidth: CGFloat = 0.5
    private let handleBarHeight: CGFloat = 22
    private let handleBarWidth: CGFloat = 22
    private let cellPaddingH: CGFloat = 4    // Horizontal inset each side
    private let cellPaddingTop: CGFloat = 3  // Top inset
    private let cellPaddingBot: CGFloat = 3  // Bottom inset
    private let focusRingPadding: CGFloat = 8
    private let columnTextPadding: CGFloat = 20  // Extra width per column for text measurement

    // MARK: - Computed Layout

    /// Margins based on current focus state.
    private var currentLeftMargin: CGFloat {
        (focusState == .hovered || focusState == .editing) ? handleBarWidth : 0
    }
    private var currentTopMargin: CGFloat {
        (focusState == .hovered || focusState == .editing) ? handleBarHeight : 0
    }

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
        let rHeights = rowHeights()
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
            (row + 1) < rHeights.count ? rHeights[row + 1] : 32
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

        scrollView = NSScrollView()
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
        for handle in columnHandles {
            // Each handle stores its original X in its tag-derived position;
            // shift by negative scroll offset so handles track the grid content
            handle.frame.origin.x = handle.layer?.value(forKey: "originalX") as? CGFloat ?? handle.frame.origin.x
        }
        // Reposition all column handles based on scroll offset
        updateColumnHandlePositions(scrollOffsetX: scrollX)
    }

    private func updateColumnHandlePositions(scrollOffsetX: CGFloat) {
        let showHandles = (focusState == .hovered || focusState == .editing)
        guard showHandles else { return }
        let leftMargin: CGFloat = handleBarWidth
        let columnWidths = contentBasedColumnWidths()
        var xOffset = leftMargin
        for (i, handle) in columnHandles.enumerated() {
            if i < columnWidths.count {
                handle.frame.origin.x = xOffset - scrollOffsetX
                xOffset += columnWidths[i]
            }
        }
    }

    // MARK: - Configuration

    func configure(with data: TableUtility.TableData) {
        headers = data.headers
        rows = data.rows
        alignments = data.alignments
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild()
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
    }

    override func mouseExited(with event: NSEvent) {
        if focusState == .hovered {
            focusState = .unfocused
        }
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
        for subview in subviews where subview is NSVisualEffectView {
            if subview.frame.contains(localPoint) {
                return super.hitTest(point)
            }
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

    /// Compute the height for each row based on multi-line content (<br> tags).
    /// Row 0 = header, rows 1..N = data rows.
    func rowHeights() -> [CGFloat] {
        let colCount = headers.count
        guard colCount > 0 else { return [] }

        // Header row
        var heights: [CGFloat] = []
        var maxLines = 1
        for h in headers {
            let lines = h.components(separatedBy: "<br>").count
            maxLines = max(maxLines, lines)
        }
        heights.append(max(minCellHeight, CGFloat(maxLines) * lineHeight + 11))

        // Data rows
        for row in rows {
            maxLines = 1
            for col in 0..<min(colCount, row.count) {
                let lines = row[col].components(separatedBy: "<br>").count
                maxLines = max(maxLines, lines)
            }
            heights.append(max(minCellHeight, CGFloat(maxLines) * lineHeight + 11))
        }
        return heights
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

        let font = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: 13)
        let padding: CGFloat = columnTextPadding

        var widths = Array(repeating: minColumnWidth, count: colCount)
        for col in 0..<colCount {
            let hw = maxLineWidth(headers[col], font: boldFont) + padding
            widths[col] = max(widths[col], hw)
            for row in rows {
                if col < row.count {
                    let cw = maxLineWidth(row[col], font: font) + padding
                    widths[col] = max(widths[col], cw)
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

    func rebuild(skipCollect: Bool = false) {
        if !skipCollect { collectCellData() }

        let L = computeLayout()
        let showHandles = (focusState == .hovered || focusState == .editing)

        if columnWidthRatios.count != L.colCount {
            columnWidthRatios = Array(repeating: 1.0 / CGFloat(L.colCount), count: L.colCount)
        }

        // Apply frames from single layout computation
        applyFrames(L)

        // Remove old handles
        columnHandles.forEach { $0.removeFromSuperview() }
        rowHandles.forEach { $0.removeFromSuperview() }
        columnHandles = []
        rowHandles = []

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
            configureCell(cell, text: headers[col], frame: colRect, isHeader: true, isEditing: isEditing, row: 0, col: col)
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
                let value = col < rows[row].count ? rows[row][col] : ""
                let colRect = NSRect(x: xOffset, y: yBottom, width: L.colWidths[col], height: rowH)
                configureCell(cell, text: value, frame: colRect, isHeader: false, isEditing: isEditing, row: row + 1, col: col)
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

        // -- Glass UI Handles --
        if showHandles {
            buildColumnHandles(colCount: L.colCount, columnWidths: L.colWidths, leftMargin: L.leftMargin, gridHeight: L.gridHeight, topMargin: L.topMargin)
            buildRowHandles(rowCount: L.totalRows, leftMargin: L.leftMargin, gridHeight: L.gridHeight, topMargin: L.topMargin, rowHeights: L.rHeights)
        }

        gridDocumentView.needsDisplay = true
        invalidateIntrinsicContentSize()
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

    private func configureCell(_ cell: NSTextField, text: String, frame: NSRect, isHeader: Bool, isEditing: Bool, row: Int, col: Int) {
        cell.frame = cellFrame(from: frame)

        let cellFont = isHeader ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
        let cellAlignment = col < alignments.count ? alignments[col] : NSTextAlignment.left

        // When not editing, render inline markdown (bold, italic, strikethrough).
        // When editing, show raw markdown markers so the user can edit them.
        if !isEditing && (text.contains("**") || text.contains("*") || text.contains("~~") || text.contains("__")) {
            cell.attributedStringValue = parseInlineMarkdown(text, font: cellFont, alignment: cellAlignment)
        } else {
            cell.stringValue = text.replacingOccurrences(of: "<br>", with: "\n")
            cell.font = cellFont
            cell.alignment = cellAlignment
        }

        cell.isHidden = false
        cell.isEditable = isEditing
        cell.isBordered = isEditing
        cell.bezelStyle = .squareBezel
        cell.drawsBackground = isEditing
        cell.backgroundColor = isHeader ? NSColor.controlBackgroundColor : NSColor.textBackgroundColor
        cell.tag = row * 1000 + col
        // Support multi-line cells (Return inserts newline, stored as <br> in markdown)
        cell.maximumNumberOfLines = 0
        cell.cell?.wraps = true
        cell.cell?.isScrollable = false
    }

    // MARK: - Glass Column Handles

    private func buildColumnHandles(colCount: Int, columnWidths: [CGFloat], leftMargin: CGFloat, gridHeight: CGFloat, topMargin: CGFloat) {
        // Column handles sit between the grid top and the frame top.
        // Grid occupies y=0 to y=gridHeight. Handles go from y=gridHeight to y=gridHeight+handleBarHeight.
        var xOffset = leftMargin
        for col in 0..<colCount {
            let handleFrame = NSRect(x: xOffset, y: gridHeight, width: columnWidths[col], height: handleBarHeight)
            let handle = GlassHandleView(frame: handleFrame, orientation: .horizontal, index: col)
            handle.onRightClick = { [weak self] index in
                self?.showColumnContextMenu(column: index, at: handle.frame.origin)
            }
            handle.onDragStart = { [weak self] index in
                self?.startColumnDrag(column: index)
            }
            addSubview(handle)
            columnHandles.append(handle)
            xOffset += columnWidths[col]
        }
    }

    // MARK: - Glass Row Handles

    private func buildRowHandles(rowCount: Int, leftMargin: CGFloat, gridHeight: CGFloat, topMargin: CGFloat, rowHeights rHeights: [CGFloat] = []) {
        var yBottom = gridHeight
        for row in 0..<rowCount {
            let rowH = row < rHeights.count ? rHeights[row] : minCellHeight
            yBottom -= rowH
            // Skip header row (row 0) — it can't be reordered or deleted
            if row == 0 { continue }
            let handleFrame = NSRect(x: 0, y: yBottom, width: handleBarWidth, height: rowH)
            let handle = GlassHandleView(frame: handleFrame, orientation: .vertical, index: row)
            handle.onRightClick = { [weak self] index in
                self?.showRowContextMenu(row: index, at: handle.frame.origin)
            }
            handle.onDragStart = { [weak self] index in
                self?.startRowDrag(row: index)
            }
            addSubview(handle)
            rowHandles.append(handle)
        }
    }

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
        collectCellData()
        let col = sender.tag
        headers.insert("", at: col)
        alignments.insert(.left, at: col)
        for i in 0..<rows.count { rows[i].insert("", at: min(col, rows[i].count)) }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild(skipCollect: true)
        notifyChanged()
    }

    @objc private func contextInsertColumnRight(_ sender: NSMenuItem) {
        collectCellData()
        let col = min(sender.tag + 1, headers.count)
        headers.insert("", at: col)
        alignments.insert(.left, at: col)
        for i in 0..<rows.count { rows[i].insert("", at: min(col, rows[i].count)) }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild(skipCollect: true)
        notifyChanged()
    }

    @objc private func contextDeleteColumn(_ sender: NSMenuItem) {
        let col = sender.tag
        guard headers.count > 1, col < headers.count else { return }
        collectCellData()
        headers.remove(at: col)
        if col < alignments.count { alignments.remove(at: col) }
        for i in 0..<rows.count {
            if col < rows[i].count { rows[i].remove(at: col) }
        }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild(skipCollect: true)
        notifyChanged()
    }

    @objc private func contextAlignLeft(_ sender: NSMenuItem) { setAlignment(.left, column: sender.tag) }
    @objc private func contextAlignCenter(_ sender: NSMenuItem) { setAlignment(.center, column: sender.tag) }
    @objc private func contextAlignRight(_ sender: NSMenuItem) { setAlignment(.right, column: sender.tag) }

    private func setAlignment(_ alignment: NSTextAlignment, column: Int) {
        guard column < alignments.count else { return }
        collectCellData()
        alignments[column] = alignment
        rebuild(skipCollect: true)
        notifyChanged()
    }

    @objc private func contextInsertRowAbove(_ sender: NSMenuItem) {
        collectCellData()
        let dataRow = sender.tag - 1  // tag 0 = header, data starts at 1
        let newRow = Array(repeating: "", count: headers.count)
        if dataRow < 0 {
            rows.insert(newRow, at: 0)
        } else {
            rows.insert(newRow, at: min(dataRow, rows.count))
        }
        rebuild(skipCollect: true)
        notifyChanged()
    }

    @objc private func contextInsertRowBelow(_ sender: NSMenuItem) {
        collectCellData()
        let dataRow = sender.tag  // insert after this row (tag includes header offset)
        let newRow = Array(repeating: "", count: headers.count)
        rows.insert(newRow, at: min(dataRow, rows.count))
        rebuild(skipCollect: true)
        notifyChanged()
    }

    @objc private func contextDeleteRow(_ sender: NSMenuItem) {
        let dataRow = sender.tag - 1
        guard dataRow >= 0, dataRow < rows.count, rows.count > 1 else { return }
        collectCellData()
        rows.remove(at: dataRow)
        rebuild(skipCollect: true)
        notifyChanged()
    }

    // MARK: - Edge Button Actions

    private func addColumnAtEnd() {
        collectCellData()
        headers.append("")
        alignments.append(.left)
        for i in 0..<rows.count { rows[i].append("") }
        columnWidthRatios = Array(repeating: 1.0 / CGFloat(headers.count), count: headers.count)
        rebuild(skipCollect: true)
        notifyChanged()
    }

    private func addRowAtEnd() {
        collectCellData()
        rows.append(Array(repeating: "", count: headers.count))
        rebuild(skipCollect: true)
        notifyChanged()
    }

    // MARK: - Drag-to-Reorder

    private func startColumnDrag(column: Int) {
        collectCellData()
        let colCount = headers.count
        guard column >= 0, column < colCount else { return }

        let colWidths = contentBasedColumnWidths()
        let rHeights = rowHeights()
        let gridHeight = gridHeightFromRows(rHeights)
        let hasHandles = (focusState == .hovered || focusState == .editing)
        let leftMargin: CGFloat = hasHandles ? handleBarWidth : 0

        let gridWidth = colWidths.reduce(0, +) + leftMargin

        guard let window = self.window else { return }
        var targetIndex = column

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
            }
        }

        indicator.removeFromSuperview()
        sourceHighlight.removeFromSuperview()

        // Calculate destination: after removing source, where should we insert?
        let dst = targetIndex > column ? targetIndex - 1 : targetIndex

        if dst != column {
            moveColumn(from: column, to: dst)
        }
    }

    private func startRowDrag(row: Int) {
        // Row handle indices: 0 = header (not draggable), 1+ = data rows
        guard row >= 1 else { return }  // Can't drag header
        let dataRow = row - 1  // Convert handle index to data row index

        collectCellData()
        let dataRowCount = rows.count
        guard dataRow >= 0, dataRow < dataRowCount else { return }

        let rHeights = rowHeights()
        let gridHeight = rHeights.reduce(0, +)
        let hasHandles = (focusState == .hovered || focusState == .editing)

        guard let window = self.window else { return }
        var targetDataRow = dataRow
        var indicator: NSView? = nil

        let ind = NSView()
        ind.wantsLayer = true
        ind.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(ind)
        indicator = ind

        let leftMargin: CGFloat = hasHandles ? handleBarWidth : 0

        // Create source row highlight (blue border)
        let sourceHighlight = NSView()
        sourceHighlight.wantsLayer = true
        sourceHighlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        sourceHighlight.layer?.borderWidth = 2
        sourceHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        // Row index in rHeights: 0=header, dataRow+1=our row
        var srcY = gridHeight - rHeights[0]  // below header
        for i in 0..<dataRow {
            if (i + 1) < rHeights.count { srcY -= rHeights[i + 1] }
        }
        let srcRowH = (dataRow + 1) < rHeights.count ? rHeights[dataRow + 1] : minCellHeight
        // Include the row handle on the left for visual symmetry
        sourceHighlight.frame = NSRect(x: 0, y: srcY - srcRowH, width: bounds.width, height: srcRowH)
        addSubview(sourceHighlight)

        var keepTracking = true
        while keepTracking {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            let loc = convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseUp {
                keepTracking = false
            } else {
                // Find which data row gap the cursor is nearest
                // rHeights[0] = header, rHeights[1] = data row 0, etc.
                var y = gridHeight - rHeights[0]  // Start below header
                var bestGap = 0
                var bestDist: CGFloat = .greatestFiniteMagnitude

                for i in 0...dataRowCount {
                    let dist = abs(loc.y - y)
                    if dist < bestDist {
                        bestDist = dist
                        bestGap = i
                    }
                    if i < dataRowCount && (i + 1) < rHeights.count {
                        y -= rHeights[i + 1]
                    }
                }
                targetDataRow = bestGap

                // Position indicator below header + above the target gap
                var indY = gridHeight - rHeights[0]
                for i in 0..<targetDataRow {
                    if (i + 1) < rHeights.count { indY -= rHeights[i + 1] }
                }
                indicator?.frame = NSRect(x: leftMargin, y: indY - 1, width: bounds.width - leftMargin, height: 2)
            }
        }

        indicator?.removeFromSuperview()
        sourceHighlight.removeFromSuperview()

        let dst = targetDataRow > dataRow ? targetDataRow - 1 : targetDataRow
        if dst != dataRow {
            moveRow(from: dataRow, to: dst)
        }
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

        rebuild(skipCollect: true)  // Data already swapped — don't read from old cells
        notifyChanged()
    }

    private func moveRow(from src: Int, to dst: Int) {
        guard src >= 0, src < rows.count, dst >= 0, dst < rows.count, src != dst else { return }
        let r = rows.remove(at: src)
        rows.insert(r, at: dst)
        rebuild(skipCollect: true)  // Data already swapped — don't read from old cells
        notifyChanged()
    }

    // MARK: - Data Collection

    func collectCellData() {
        // Only update the data model from cells that show raw markdown text.
        // When not editing, cells may show formatted attributed text (bold/italic
        // rendered, markers stripped). Reading stringValue from those cells would
        // lose the markdown markers (**bold** → bold). The data model already has
        // the correct values for non-edited cells.
        let fieldEditor = window?.fieldEditor(false, for: nil)
        let activeCell = fieldEditor?.delegate as? NSTextField
        let isEditingMode = (focusState == .editing)

        for (i, cell) in headerCells.enumerated() where i < headers.count {
            if cell === activeCell, let editor = fieldEditor {
                // Active cell: read live text from field editor
                headers[i] = editor.string.replacingOccurrences(of: "\n", with: "<br>")
            } else if isEditingMode {
                // Editing mode: cells show raw markdown, safe to read
                headers[i] = cell.stringValue.replacingOccurrences(of: "\n", with: "<br>")
            }
            // Non-editing mode: skip — data model already correct
        }
        for (r, rowCells) in dataCells.enumerated() where r < rows.count {
            for (c, cell) in rowCells.enumerated() where c < rows[r].count {
                if cell === activeCell, let editor = fieldEditor {
                    rows[r][c] = editor.string.replacingOccurrences(of: "\n", with: "<br>")
                } else if isEditingMode {
                    rows[r][c] = cell.stringValue.replacingOccurrences(of: "\n", with: "<br>")
                }
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        collectCellData()
        notifyChanged()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Live-resize columns and table as user types
        collectCellData()
        recalculateAndResize()
        notifyChanged()
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

        // Column handles — above grid, in parent view coordinates (leftMargin offset)
        x = L.leftMargin
        for col in 0..<min(L.colCount, columnHandles.count) {
            columnHandles[col].frame = NSRect(x: x, y: L.gridHeight, width: L.colWidths[col], height: handleBarHeight)
            x += L.colWidths[col]
        }

        // Row handles — left of grid, skip header (row 0)
        var handleY = L.gridHeight - L.headerHeight
        for (idx, handle) in rowHandles.enumerated() {
            let rowH = L.dataRowHeight(idx)
            handleY -= rowH
            handle.frame = NSRect(x: 0, y: handleY, width: handleBarWidth, height: rowH)
        }
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
                    collectCellData()
                    rows.append(Array(repeating: "", count: headers.count))
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
            collectCellData()
            window?.makeFirstResponder(next)
        }
    }

    private func navigateToPreviousCell(from cell: NSTextField?) {
        guard let cell = cell else { return }
        let (row, col) = decodeTag(cell.tag)
        if let prev = cellAt(row: row, col: col - 1) ?? cellAt(row: row - 1, col: headers.count - 1) {
            collectCellData()
            window?.makeFirstResponder(prev)
        }
    }

    private func navigateToCellBelow(from cell: NSTextField?) {
        guard let cell = cell else { return }
        let (row, col) = decodeTag(cell.tag)
        if let below = cellAt(row: row + 1, col: col) {
            collectCellData()
            window?.makeFirstResponder(below)
        } else {
            // At bottom — add new row
            collectCellData()
            rows.append(Array(repeating: "", count: headers.count))
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

    // MARK: - Focus State Transition

    private func transitionFocusState(from: TableFocusState, to: TableFocusState) {
        let showHandles = (to == .hovered || to == .editing)
        let wasShowingHandles = (from == .hovered || from == .editing)

        if showHandles != wasShowingHandles {
            // Rebuild creates new handle views — set alpha AFTER rebuild
            rebuild()
            let targetAlpha: CGFloat = showHandles ? 1.0 : 0.0
            for h in columnHandles { h.alphaValue = targetAlpha; h.isHidden = !showHandles }
            for h in rowHandles { h.alphaValue = targetAlpha; h.isHidden = !showHandles }

            // Notify NSTextView's layout manager that this attachment's size changed.
            // Without this, NSTextView caches the old size and the "phantom row" persists.
            invalidateAttachmentLayout()
        } else {
            // Just update cell editability
            let isEditing = (to == .editing)
            for cell in headerCells {
                cell.isEditable = isEditing
                cell.isBordered = isEditing
                cell.drawsBackground = isEditing
            }
            for rowCells in dataCells {
                for cell in rowCells {
                    cell.isEditable = isEditing
                    cell.isBordered = isEditing
                    cell.drawsBackground = isEditing
                }
            }
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Inline Markdown Formatting

    /// Parse inline markdown (bold, italic, strikethrough) into an NSAttributedString.
    /// Used to render cell text in WYSIWYG style when not actively editing.
    private func parseInlineMarkdown(_ text: String, font: NSFont, alignment: NSTextAlignment) -> NSAttributedString {
        let displayText = text.replacingOccurrences(of: "<br>", with: "\n")
        let result = NSMutableAttributedString(string: displayText, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor
        ])

        let patterns: [(pattern: String, trait: NSFontDescriptor.SymbolicTraits)] = [
            ("\\*\\*(.+?)\\*\\*", .bold),       // **bold**
            ("__(.+?)__", .bold),                // __bold__
            ("(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", .italic),  // *italic* (not **)
            ("_(.+?)_", .italic),                // _italic_
            ("~~(.+?)~~", []),                   // ~~strikethrough~~ (handled separately)
        ]

        // Collect ALL matches across all patterns first, then apply in one reverse pass.
        // Applying per-pattern mutates `result`, making ranges from subsequent patterns invalid.
        struct MatchInfo {
            let fullRange: NSRange
            let content: String
            let attrs: [NSAttributedString.Key: Any]
        }
        var allMatches: [MatchInfo] = []

        let fontManager = NSFontManager.shared
        let nsText = displayText as NSString
        for (pattern, trait) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: displayText, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let fullRange = match.range
                let contentRange = match.range(at: 1)
                let content = nsText.substring(with: contentRange)

                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
                if pattern.contains("~~") {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.font] = font
                } else if trait == .bold {
                    attrs[.font] = fontManager.convert(font, toHaveTrait: .boldFontMask)
                } else if trait == .italic {
                    attrs[.font] = fontManager.convert(font, toHaveTrait: .italicFontMask)
                }

                allMatches.append(MatchInfo(fullRange: fullRange, content: content, attrs: attrs))
            }
        }

        // Sort by location descending so replacements don't invalidate earlier ranges.
        // Also filter out overlapping matches (e.g., _ inside **bold_text**).
        allMatches.sort { $0.fullRange.location > $1.fullRange.location }

        var usedRanges: [NSRange] = []
        allMatches = allMatches.filter { info in
            let overlaps = usedRanges.contains { NSIntersectionRange($0, info.fullRange).length > 0 }
            if !overlaps { usedRanges.append(info.fullRange) }
            return !overlaps
        }

        for info in allMatches {
            let styled = NSAttributedString(string: info.content, attributes: info.attrs)
            result.replaceCharacters(in: info.fullRange, with: styled)
        }

        // Apply alignment as paragraph style
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        result.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: result.length))

        return result
    }

    // MARK: - Markdown Generation

    func generateMarkdown() -> String {
        return TableUtility.generate(headers: headers, rows: rows, alignments: alignments)
    }

    // MARK: - Notify

    func notifyChanged() {
        let md = generateMarkdown()
        guard let editTextView = findParentEditTextView(),
              let storage = editTextView.textStorage else { return }
        // Update the attachment attribute so the save path picks up current table state
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, stop in
            guard let att = value as? NSTextAttachment,
                  let cell = att.attachmentCell as? InlineTableAttachmentCell,
                  cell.inlineTableView === self else { return }
            storage.addAttribute(.renderedBlockOriginalMarkdown, value: md, range: range)
            storage.addAttribute(.renderedBlockSource, value: md, range: range)
            stop.pointee = true
        }
        // Trigger save — table cell edits don't fire textDidChange on the main editor
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

        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(gridLineWidth)

        // Horizontal lines
        var lineY: CGFloat = 0
        for i in 0...L.totalRows {
            context.move(to: CGPoint(x: L.leftMargin, y: lineY))
            context.addLine(to: CGPoint(x: L.leftMargin + L.gridWidth, y: lineY))
            if i < L.rHeights.count {
                lineY += L.rHeights[L.rHeights.count - 1 - i]
            }
        }

        // Vertical lines
        var xOffset = L.leftMargin
        for i in 0...L.colCount {
            context.move(to: CGPoint(x: xOffset, y: 0))
            context.addLine(to: CGPoint(x: xOffset, y: L.gridHeight))
            if i < L.colCount { xOffset += L.colWidths[i] }
        }
        context.strokePath()

        // Header background
        let headerRect = NSRect(x: L.leftMargin, y: L.gridHeight - L.headerHeight, width: L.gridWidth, height: L.headerHeight)
        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: headerRect).fill()

        // Alternating row backgrounds
        var rowY = L.gridHeight - L.headerHeight
        for row in 0..<L.rowCount {
            let rowH = L.dataRowHeight(row)
            rowY -= rowH
            if row % 2 == 1 {
                NSColor.controlBackgroundColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(rect: NSRect(x: L.leftMargin, y: rowY, width: L.gridWidth, height: rowH)).fill()
            }
        }
    }

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: NSSize {
        let L = computeLayout()
        return NSSize(width: L.scrollWidth, height: L.totalHeight)
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
class GlassHandleView: NSVisualEffectView {

    enum Orientation { case horizontal, vertical }

    let orientation: Orientation
    let index: Int

    var onRightClick: ((Int) -> Void)?
    var onDragStart: ((Int) -> Void)?

    private let gripLabel = NSTextField(labelWithString: "⋮⋮")

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
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor

        gripLabel.font = NSFont.systemFont(ofSize: 9)
        gripLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        gripLabel.alignment = .center
        gripLabel.sizeToFit()
        gripLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gripLabel)

        NSLayoutConstraint.activate([
            gripLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            gripLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            gripLabel.animator().alphaValue = 1.0
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            gripLabel.animator().alphaValue = 0.7
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
        // Start drag after hold
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
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
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
class InlineTableAttachmentCell: NSTextAttachmentCell {

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
