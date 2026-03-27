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

    // Legacy compatibility
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
    // Edge buttons removed — add row/column via context menus on handles
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
    private let lineHeight: CGFloat = 17  // Approximate line height for 13pt font
    private let handleSize: CGFloat = 20
    private let edgeButtonSize: CGFloat = 16
    private let minColumnWidth: CGFloat = 80
    private let gridLineWidth: CGFloat = 0.5
    private let handleBarHeight: CGFloat = 22
    private let handleBarWidth: CGFloat = 22

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
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        updateTrackingAreas()
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
        let padding: CGFloat = 20  // left + right cell padding

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
        // Collect current data before rebuilding (skip when data was just modified directly, e.g. moveColumn/moveRow)
        if !skipCollect {
            collectCellData()
        }

        let colCount = headers.count
        let rowCount = rows.count
        let totalRows = 1 + rowCount

        // Ensure width ratios match column count
        if columnWidthRatios.count != colCount {
            columnWidthRatios = Array(repeating: 1.0 / CGFloat(colCount), count: colCount)
        }

        // Calculate layout
        let showHandles = (focusState == .hovered || focusState == .editing)
        let leftMargin: CGFloat = showHandles ? handleBarWidth : 0
        // Column handles go ABOVE the grid; they need space in the frame
        let topMargin: CGFloat = showHandles ? handleBarHeight : 0

        // Column widths and row heights from content
        let columnWidths = contentBasedColumnWidths()
        let gridWidth = columnWidths.reduce(0, +)
        let rHeights = rowHeights()
        let gridHeight = gridHeightFromRows(rHeights)

        // Frame includes: left margin (row handles) + grid + top margin (column handles)
        let totalWidth = min(gridWidth + leftMargin, containerWidth)
        let totalHeight = gridHeight + topMargin
        self.frame.size = NSSize(width: totalWidth, height: totalHeight)

        // Remove old handles/buttons (they're recreated based on state)
        columnHandles.forEach { $0.removeFromSuperview() }
        rowHandles.forEach { $0.removeFromSuperview() }
        // Edge buttons removed
        columnHandles = []
        rowHandles = []

        // -- Build cells using pool --
        let neededCells = totalRows * colCount
        ensureCellPool(count: neededCells)

        // Reset header/data cell arrays
        headerCells = []
        dataCells = Array(repeating: [], count: rowCount)

        var cellIndex = 0
        let isEditing = (focusState == .editing)

        // Header row — grid occupies y=0 to y=gridHeight (bottom-up NSView coords)
        // Header is the TOP row. Calculate Y from cumulative row heights.
        let headerHeight = rHeights.isEmpty ? minCellHeight : rHeights[0]
        var xOffset = leftMargin
        for col in 0..<colCount {
            let cell = cellPool[cellIndex]
            cellIndex += 1
            configureCell(cell,
                text: headers[col],
                frame: NSRect(x: xOffset, y: gridHeight - headerHeight, width: columnWidths[col], height: headerHeight),
                isHeader: true, isEditing: isEditing,
                row: 0, col: col)
            headerCells.append(cell)
            xOffset += columnWidths[col]
        }

        // Data rows — positioned below header, using per-row heights
        var yBottom = gridHeight - headerHeight  // Bottom of header row
        for row in 0..<rowCount {
            let rowH = (row + 1) < rHeights.count ? rHeights[row + 1] : minCellHeight
            yBottom -= rowH
            xOffset = leftMargin
            var rowCellArray: [NSTextField] = []
            for col in 0..<colCount {
                let cell = cellPool[cellIndex]
                cellIndex += 1
                let value = col < rows[row].count ? rows[row][col] : ""
                configureCell(cell,
                    text: value,
                    frame: NSRect(x: xOffset, y: yBottom, width: columnWidths[col], height: rowH),
                    isHeader: false, isEditing: isEditing,
                    row: row + 1, col: col)
                rowCellArray.append(cell)
                xOffset += columnWidths[col]
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
            buildColumnHandles(colCount: colCount, columnWidths: columnWidths, leftMargin: leftMargin, gridHeight: gridHeight, topMargin: topMargin)
            buildRowHandles(rowCount: totalRows, leftMargin: leftMargin, gridHeight: gridHeight, topMargin: topMargin, rowHeights: rHeights)
        }

        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    // MARK: - Cell Pool Management

    private func ensureCellPool(count: Int) {
        while cellPool.count < count {
            let cell = NSTextField()
            cell.delegate = self
            cell.cell?.truncatesLastVisibleLine = false
            cell.cell?.lineBreakMode = .byClipping
            addSubview(cell)
            cellPool.append(cell)
        }
    }

    private func configureCell(_ cell: NSTextField, text: String, frame: NSRect, isHeader: Bool, isEditing: Bool, row: Int, col: Int) {
        // Asymmetric padding: 5pt top for visual centering, 2pt bottom to leave room for descenders
        cell.frame = NSRect(x: frame.minX + 4, y: frame.minY + 2, width: frame.width - 8, height: frame.height - 7)
        // Convert <br> from markdown to newlines for display
        cell.stringValue = text.replacingOccurrences(of: "<br>", with: "\n")
        cell.isHidden = false
        cell.isEditable = isEditing
        cell.isBordered = isEditing
        cell.bezelStyle = .squareBezel
        cell.drawsBackground = isEditing
        cell.backgroundColor = isHeader ? NSColor.controlBackgroundColor : NSColor.textBackgroundColor
        cell.font = isHeader ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
        cell.alignment = col < alignments.count ? alignments[col] : .left
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

    // MARK: - Edge Buttons (removed — add via context menus on handles)

    // MARK: - Context Menus

    private func showColumnContextMenu(column: Int, at point: NSPoint) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Insert Column Left", action: #selector(contextInsertColumnLeft(_:)), keyEquivalent: "").tag = column
        menu.addItem(withTitle: "Insert Column Right", action: #selector(contextInsertColumnRight(_:)), keyEquivalent: "").tag = column
        if headers.count > 1 {
            menu.addItem(.separator())
            let deleteItem = menu.addItem(withTitle: "Delete Column", action: #selector(contextDeleteColumn(_:)), keyEquivalent: "\u{8}")  // ⌫
            deleteItem.tag = column
        }
        menu.addItem(.separator())

        let leftItem = menu.addItem(withTitle: "Align Left", action: #selector(contextAlignLeft(_:)), keyEquivalent: "l")
        leftItem.tag = column
        leftItem.keyEquivalentModifierMask = .command
        if column < alignments.count && alignments[column] == .left { leftItem.state = .on }

        let centerItem = menu.addItem(withTitle: "Align Center", action: #selector(contextAlignCenter(_:)), keyEquivalent: "e")
        centerItem.tag = column
        centerItem.keyEquivalentModifierMask = .command
        if column < alignments.count && alignments[column] == .center { centerItem.state = .on }

        let rightItem = menu.addItem(withTitle: "Align Right", action: #selector(contextAlignRight(_:)), keyEquivalent: "r")
        rightItem.tag = column
        rightItem.keyEquivalentModifierMask = .command
        if column < alignments.count && alignments[column] == .right { rightItem.state = .on }

        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: self)
    }

    private func showRowContextMenu(row: Int, at point: NSPoint) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Insert Row Above", action: #selector(contextInsertRowAbove(_:)), keyEquivalent: "").tag = row
        menu.addItem(withTitle: "Insert Row Below", action: #selector(contextInsertRowBelow(_:)), keyEquivalent: "").tag = row
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

        // Run a mouse tracking loop until mouseUp
        guard let window = self.window else { return }
        var targetIndex = column
        var indicator: NSView? = nil

        // Create insertion indicator (blue line)
        let ind = NSView()
        ind.wantsLayer = true
        ind.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(ind)
        indicator = ind

        // Create source column highlight (blue border)
        let sourceHighlight = NSView()
        sourceHighlight.wantsLayer = true
        sourceHighlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        sourceHighlight.layer?.borderWidth = 2
        sourceHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        var srcX = leftMargin
        for i in 0..<column { srcX += colWidths[i] }
        // Include the column handle above the grid for visual symmetry
        let topMargin: CGFloat = hasHandles ? handleBarHeight : 0
        sourceHighlight.frame = NSRect(x: srcX, y: 0, width: colWidths[column], height: gridHeight + topMargin)
        addSubview(sourceHighlight)

        var keepTracking = true
        while keepTracking {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            let loc = convert(event.locationInWindow, from: nil)

            if event.type == .leftMouseUp {
                keepTracking = false
            } else {
                // Find which column gap the cursor is nearest
                var x = leftMargin
                var bestGap = 0
                var bestDist: CGFloat = .greatestFiniteMagnitude
                for i in 0...colCount {
                    let dist = abs(loc.x - x)
                    if dist < bestDist {
                        bestDist = dist
                        bestGap = i
                    }
                    if i < colCount { x += colWidths[i] }
                }
                targetIndex = bestGap

                // Position indicator — clamp to stay within bounds
                var indX = leftMargin
                for i in 0..<targetIndex {
                    if i < colWidths.count { indX += colWidths[i] }
                }
                let clampedX = min(indX - 1, bounds.width - 2)
                indicator?.frame = NSRect(x: clampedX, y: 0, width: 2, height: bounds.height)
            }
        }

        indicator?.removeFromSuperview()
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
        // Read current text from each cell. If a cell is being edited, its stringValue
        // is stale — the live text is in the shared field editor. Read from the field
        // editor for the active cell instead.
        // Convert display newlines back to <br> for markdown storage.
        let fieldEditor = window?.fieldEditor(false, for: nil)
        let activeCell = fieldEditor?.delegate as? NSTextField

        for (i, cell) in headerCells.enumerated() where i < headers.count {
            let text: String
            if cell === activeCell, let editor = fieldEditor {
                text = editor.string
            } else {
                text = cell.stringValue
            }
            headers[i] = text.replacingOccurrences(of: "\n", with: "<br>")
        }
        for (r, rowCells) in dataCells.enumerated() where r < rows.count {
            for (c, cell) in rowCells.enumerated() where c < rows[r].count {
                let text: String
                if cell === activeCell, let editor = fieldEditor {
                    text = editor.string
                } else {
                    text = cell.stringValue
                }
                rows[r][c] = text.replacingOccurrences(of: "\n", with: "<br>")
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
        let colWidths = contentBasedColumnWidths()
        guard !colWidths.isEmpty else { return }

        let leftMargin: CGFloat = (focusState == .unfocused) ? 0 : handleBarWidth
        let gridWidth = colWidths.reduce(0, +)
        let totalWidth = min(gridWidth + leftMargin, containerWidth)

        // Resize the frame to fit content
        let newSize = NSSize(width: totalWidth, height: frame.height)
        if abs(frame.width - newSize.width) > 1 {
            setFrameSize(newSize)
        }

        // Update cell AND handle frames without full rebuild (avoids losing first responder)
        layoutCells(colWidths: colWidths, leftMargin: leftMargin)
    }

    /// Update cell AND handle frames in-place without rebuilding (preserves first responder).
    /// Uses the SAME coordinate system as rebuild():
    ///   - Grid occupies y=0 to y=gridHeight (NSView Y=0 is at bottom)
    ///   - Header row at y = gridHeight - headerHeight (top of grid)
    ///   - Data rows at y = cumulative from top using per-row heights
    ///   - Column handles at y = gridHeight (above grid)
    private func layoutCells(colWidths: [CGFloat], leftMargin: CGFloat) {
        let colCount = headers.count
        guard colCount > 0 else { return }

        let rHeights = rowHeights()
        let gridHeight = gridHeightFromRows(rHeights)

        // Header row — top of grid
        let headerH = rHeights.isEmpty ? minCellHeight : rHeights[0]
        var x = leftMargin
        for col in 0..<min(colCount, headerCells.count) {
            let w = colWidths[col]
            let hf = NSRect(x: x, y: gridHeight - headerH, width: w, height: headerH)
            headerCells[col].frame = NSRect(x: hf.minX + 4, y: hf.minY + 2, width: hf.width - 8, height: hf.height - 7)
            x += w
        }

        // Data rows — below header, using per-row heights
        var yBottom = gridHeight - headerH
        for (rowIdx, rowCellArray) in dataCells.enumerated() {
            let rowH = (rowIdx + 1) < rHeights.count ? rHeights[rowIdx + 1] : minCellHeight
            yBottom -= rowH
            x = leftMargin
            for col in 0..<min(colCount, rowCellArray.count) {
                let w = colWidths[col]
                rowCellArray[col].frame = NSRect(x: x, y: yBottom, width: w, height: rowH).insetBy(dx: 4, dy: 6)
                x += w
            }
        }

        // Column handles — above grid
        x = leftMargin
        for col in 0..<min(colCount, columnHandles.count) {
            let w = colWidths[col]
            columnHandles[col].frame = NSRect(x: x, y: gridHeight, width: w, height: handleBarHeight)
            x += w
        }

        // Row handles — left of grid, matching row heights
        yBottom = gridHeight
        for (idx, handle) in rowHandles.enumerated() {
            let rowH = idx < rHeights.count ? rHeights[idx] : minCellHeight
            yBottom -= rowH
            handle.frame = NSRect(x: 0, y: yBottom, width: handleBarWidth, height: rowH)
        }

        needsDisplay = true
        invalidateIntrinsicContentSize()
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let showHandles = (focusState == .hovered || focusState == .editing)
        let leftMargin: CGFloat = showHandles ? handleBarWidth : 0
        let colCount = headers.count
        let totalRows = 1 + rows.count
        // Use content-based widths (single source of truth) — NOT columnWidthRatios
        let columnWidths = contentBasedColumnWidths()
        let gridWidth = columnWidths.reduce(0, +)
        let rHeights = rowHeights()
        let gridHeight = gridHeightFromRows(rHeights)

        // Grid border — grid occupies y=0 to y=gridHeight
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(gridLineWidth)

        // Horizontal lines using per-row heights
        var lineY: CGFloat = 0
        for i in 0...totalRows {
            context.move(to: CGPoint(x: leftMargin, y: lineY))
            context.addLine(to: CGPoint(x: leftMargin + gridWidth, y: lineY))
            if i < rHeights.count {
                lineY += rHeights[rHeights.count - 1 - i]  // Bottom-up: start from bottom row
            }
        }

        // Vertical lines
        var xOffset = leftMargin
        for i in 0...colCount {
            context.move(to: CGPoint(x: xOffset, y: 0))
            context.addLine(to: CGPoint(x: xOffset, y: gridHeight))
            if i < colCount {
                xOffset += columnWidths[i]
            }
        }

        context.strokePath()

        // Header background — header is the top row of the grid
        let headerH = rHeights.isEmpty ? minCellHeight : rHeights[0]
        let headerRect = NSRect(x: leftMargin, y: gridHeight - headerH, width: gridWidth, height: headerH)
        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: headerRect).fill()
    }

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: NSSize {
        let showHandles = (focusState == .hovered || focusState == .editing)
        let leftMargin: CGFloat = showHandles ? handleBarWidth : 0
        let topMargin: CGFloat = showHandles ? handleBarHeight : 0

        let colWidths = contentBasedColumnWidths()
        let gridWidth = colWidths.reduce(0, +)
        let gridHeight = gridHeightFromRows(rowHeights())
        let tableWidth = min(gridWidth + leftMargin, containerWidth)
        return NSSize(width: tableWidth, height: gridHeight + topMargin)
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
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor

        gripLabel.font = NSFont.systemFont(ofSize: 9)
        gripLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.4)
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
            gripLabel.animator().alphaValue = 0.7
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            gripLabel.animator().alphaValue = 0.4
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
        guard let textView = controlView as? NSTextView else { return }

        // Only add and position the live view when the layout manager provides a
        // valid frame. For tables outside the viewport (non-contiguous layout),
        // the frame will be wrong (near 0,0 for a late-document attachment).
        // The layout manager will call draw again when the area becomes visible.
        let hasContentBefore = charIndex > 10
        let frameNearTop = cellFrame.origin.y < 50
        if hasContentBefore && frameNearTop {
            // Frame not yet computed for this position — don't render
            return
        }

        // Position the live table view
        inlineTableView.frame = cellFrame
        if inlineTableView.superview !== textView {
            textView.addSubview(inlineTableView)
        }
    }
}
