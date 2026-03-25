//
//  InlineTableView.swift
//  FSNotes
//
//  Inline WYSIWYG table editor that embeds in NSTextView as a subview.
//  Shows editable cells + add/delete/alignment controls when focused,
//  hides controls when unfocused (clean table view).
//

import Cocoa

class InlineTableView: NSView, NSTextFieldDelegate {

    // MARK: - Data

    var headers: [String] = ["", ""]
    var rows: [[String]] = [["", ""]]
    var alignments: [NSTextAlignment] = [.left, .left]

    var isFocused: Bool = false {
        didSet {
            guard oldValue != isFocused else { return }
            updateControlVisibility()
        }
    }

    var onMarkdownChanged: ((String) -> Void)?
    var containerWidth: CGFloat = 400

    // MARK: - Subviews

    private var gridContainer = NSView()
    private(set) var headerCells: [NSTextField] = []
    private(set) var dataCells: [[NSTextField]] = []
    private var columnControlViews: [NSView] = []
    private var rowControlViews: [NSView] = []

    private let cellHeight: CGFloat = 26
    private let controlSize: CGFloat = 20
    private let controlBarHeight: CGFloat = 24
    private let rowControlWidth: CGFloat = 28
    private let borderColor = NSColor.separatorColor
    private let headerBgColor = NSColor.controlBackgroundColor
    private let cellBgColor = NSColor.textBackgroundColor

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func configure(with data: TableUtility.TableData) {
        headers = data.headers
        rows = data.rows
        alignments = data.alignments
    }

    func focusFirstCell() {
        headerCells.first?.becomeFirstResponder()
    }

    // MARK: - Build

    func rebuild() {
        // Remove all subviews
        subviews.forEach { $0.removeFromSuperview() }
        headerCells = []
        dataCells = []
        columnControlViews = []
        rowControlViews = []

        let colCount = headers.count
        let totalRows = 1 + rows.count // header + data rows
        let availableWidth = containerWidth - (isFocused ? rowControlWidth : 0)
        let colWidth = max(60, availableWidth / CGFloat(colCount))
        let gridOriginX: CGFloat = isFocused ? rowControlWidth : 0
        let gridOriginY: CGFloat = 0
        let topOffset: CGFloat = isFocused ? controlBarHeight : 0

        // Total height
        let gridHeight = CGFloat(totalRows) * cellHeight
        let totalHeight = gridHeight + topOffset
        self.frame.size = NSSize(width: containerWidth, height: totalHeight)

        // -- Column controls (above grid) --
        if isFocused {
            for col in 0..<colCount {
                let x = gridOriginX + CGFloat(col) * colWidth
                let controlView = makeColumnControls(column: col, x: x, y: gridHeight, width: colWidth)
                addSubview(controlView)
                columnControlViews.append(controlView)
            }
        }

        // -- Header row --
        for col in 0..<colCount {
            let x = gridOriginX + CGFloat(col) * colWidth
            let y = topOffset + gridHeight - cellHeight
            let cell = makeCell(
                text: headers[col],
                frame: NSRect(x: x, y: y, width: colWidth, height: cellHeight),
                isHeader: true,
                row: 0, col: col
            )
            addSubview(cell)
            headerCells.append(cell)
        }

        // -- Data rows --
        for row in 0..<rows.count {
            var rowCells: [NSTextField] = []
            let y = topOffset + gridHeight - CGFloat(row + 2) * cellHeight
            for col in 0..<colCount {
                let x = gridOriginX + CGFloat(col) * colWidth
                let cellValue = col < rows[row].count ? rows[row][col] : ""
                let cell = makeCell(
                    text: cellValue,
                    frame: NSRect(x: x, y: y, width: colWidth, height: cellHeight),
                    isHeader: false,
                    row: row + 1, col: col
                )
                addSubview(cell)
                rowCells.append(cell)
            }
            dataCells.append(rowCells)
        }

        // -- Row controls (left side) --
        if isFocused {
            // Header row control
            let headerY = topOffset + gridHeight - cellHeight
            let hrc = makeRowControls(row: 0, x: 0, y: headerY, height: cellHeight)
            addSubview(hrc)
            rowControlViews.append(hrc)

            for row in 0..<rows.count {
                let y = topOffset + gridHeight - CGFloat(row + 2) * cellHeight
                let rc = makeRowControls(row: row + 1, x: 0, y: y, height: cellHeight)
                addSubview(rc)
                rowControlViews.append(rc)
            }
        }

        // Draw grid lines
        needsDisplay = true
    }

    // MARK: - Cell Factory

    private func makeCell(text: String, frame: NSRect, isHeader: Bool, row: Int, col: Int) -> NSTextField {
        let cell = NSTextField(frame: frame.insetBy(dx: 1, dy: 1))
        cell.stringValue = text
        cell.isEditable = true
        cell.isBordered = true
        cell.bezelStyle = .squareBezel
        cell.drawsBackground = true
        cell.backgroundColor = isHeader ? headerBgColor : cellBgColor
        cell.font = isHeader ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
        cell.alignment = col < alignments.count ? alignments[col] : .left
        cell.tag = row * 1000 + col // encode row/col in tag
        cell.delegate = self
        cell.cell?.truncatesLastVisibleLine = true
        cell.cell?.lineBreakMode = .byTruncatingTail
        return cell
    }

    // MARK: - Column Controls

    private func makeColumnControls(column: Int, x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: x, y: y, width: width, height: controlBarHeight))

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // Add column button
        let addBtn = makeSmallButton(title: "+", tag: column, action: #selector(addColumnAction(_:)))
        addBtn.toolTip = "Add column"
        stack.addArrangedSubview(addBtn)

        // Alignment button
        let alignSymbol: String
        switch (column < alignments.count ? alignments[column] : .left) {
        case .center: alignSymbol = "⫿"
        case .right: alignSymbol = "⫸"
        default: alignSymbol = "⫷"
        }
        let alignBtn = makeSmallButton(title: alignSymbol, tag: column, action: #selector(toggleAlignmentAction(_:)))
        alignBtn.toolTip = "Toggle alignment"
        stack.addArrangedSubview(alignBtn)

        // Delete column button (only if > 1 column)
        if headers.count > 1 {
            let delBtn = makeSmallButton(title: "×", tag: column, action: #selector(deleteColumnAction(_:)))
            delBtn.toolTip = "Delete column"
            stack.addArrangedSubview(delBtn)
        }

        return container
    }

    // MARK: - Row Controls

    private func makeRowControls(row: Int, x: CGFloat, y: CGFloat, height: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: x, y: y, width: rowControlWidth, height: height))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // Add row button
        let addBtn = makeSmallButton(title: "+", tag: row, action: #selector(addRowAction(_:)))
        addBtn.toolTip = "Add row"
        stack.addArrangedSubview(addBtn)

        // Delete row button (only if > 1 data row, and not the header)
        if row > 0 && rows.count > 1 {
            let delBtn = makeSmallButton(title: "×", tag: row, action: #selector(deleteRowAction(_:)))
            delBtn.toolTip = "Delete row"
            stack.addArrangedSubview(delBtn)
        }

        return container
    }

    // MARK: - Button Factory

    private func makeSmallButton(title: String, tag: Int, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: controlSize, height: controlSize))
        btn.title = title
        btn.bezelStyle = .inline
        btn.font = NSFont.systemFont(ofSize: 10)
        btn.tag = tag
        btn.target = self
        btn.action = action
        btn.widthAnchor.constraint(equalToConstant: controlSize).isActive = true
        btn.heightAnchor.constraint(equalToConstant: controlSize).isActive = true
        return btn
    }

    // MARK: - Actions

    @objc private func addColumnAction(_ sender: NSButton) {
        let col = sender.tag
        collectCellData()
        let insertAt = min(col + 1, headers.count)
        headers.insert("", at: insertAt)
        alignments.insert(.left, at: insertAt)
        for i in 0..<rows.count {
            rows[i].insert("", at: min(insertAt, rows[i].count))
        }
        rebuild()
        notifyChanged()
    }

    @objc private func deleteColumnAction(_ sender: NSButton) {
        let col = sender.tag
        guard headers.count > 1, col < headers.count else { return }
        collectCellData()
        headers.remove(at: col)
        if col < alignments.count { alignments.remove(at: col) }
        for i in 0..<rows.count {
            if col < rows[i].count { rows[i].remove(at: col) }
        }
        rebuild()
        notifyChanged()
    }

    @objc private func toggleAlignmentAction(_ sender: NSButton) {
        let col = sender.tag
        guard col < alignments.count else { return }
        collectCellData()
        switch alignments[col] {
        case .left: alignments[col] = .center
        case .center: alignments[col] = .right
        default: alignments[col] = .left
        }
        rebuild()
        notifyChanged()
    }

    @objc private func addRowAction(_ sender: NSButton) {
        let row = sender.tag
        collectCellData()
        let newRow = Array(repeating: "", count: headers.count)
        let insertAt = row > 0 ? min(row, rows.count) : 0
        rows.insert(newRow, at: insertAt)
        rebuild()
        notifyChanged()
    }

    @objc private func deleteRowAction(_ sender: NSButton) {
        let row = sender.tag - 1 // row 0 in tag is header, data rows start at 1
        guard row >= 0, row < rows.count, rows.count > 1 else { return }
        collectCellData()
        rows.remove(at: row)
        rebuild()
        notifyChanged()
    }

    // MARK: - Data Collection

    private func collectCellData() {
        // Read current values from text fields back into data arrays
        for (i, cell) in headerCells.enumerated() where i < headers.count {
            headers[i] = cell.stringValue
        }
        for (r, rowCells) in dataCells.enumerated() where r < rows.count {
            for (c, cell) in rowCells.enumerated() where c < rows[r].count {
                rows[r][c] = cell.stringValue
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        collectCellData()
        notifyChanged()
    }

    // MARK: - Markdown Generation

    func generateMarkdown() -> String {
        let colCount = headers.count
        let hdrs = headers.map { $0.isEmpty ? " " : $0 }
        let dataRows = rows.map { row in
            (0..<colCount).map { col in
                col < row.count ? (row[col].isEmpty ? " " : row[col]) : " "
            }
        }

        // Column widths
        var widths = hdrs.map { $0.count }
        for row in dataRows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        widths = widths.map { max($0, 3) }

        // Header line
        let headerLine = "| " + hdrs.enumerated().map { i, h in
            h.padding(toLength: widths[i], withPad: " ", startingAt: 0)
        }.joined(separator: " | ") + " |"

        // Separator with alignment markers
        let sepLine = "| " + (0..<colCount).map { i in
            let w = widths[i]
            switch (i < alignments.count ? alignments[i] : .left) {
            case .center:
                return ":" + String(repeating: "-", count: max(w - 2, 1)) + ":"
            case .right:
                return String(repeating: "-", count: max(w - 1, 1)) + ":"
            default:
                return String(repeating: "-", count: w)
            }
        }.joined(separator: " | ") + " |"

        // Data rows
        let rowLines = dataRows.map { row -> String in
            "| " + row.enumerated().map { i, cell in
                let w = i < widths.count ? widths[i] : cell.count
                return cell.padding(toLength: w, withPad: " ", startingAt: 0)
            }.joined(separator: " | ") + " |"
        }

        return ([headerLine, sepLine] + rowLines).joined(separator: "\n")
    }

    // MARK: - Focus

    private func updateControlVisibility() {
        rebuild()
    }

    // MARK: - Notify

    private func notifyChanged() {
        let md = generateMarkdown()
        onMarkdownChanged?(md)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw thin grid lines
        let context = NSGraphicsContext.current?.cgContext
        context?.setStrokeColor(borderColor.cgColor)
        context?.setLineWidth(0.5)

        let topOffset: CGFloat = isFocused ? controlBarHeight : 0
        let gridOriginX: CGFloat = isFocused ? rowControlWidth : 0
        let colCount = headers.count
        let totalRows = 1 + rows.count
        let availableWidth = bounds.width - gridOriginX
        let colWidth = max(60, availableWidth / CGFloat(colCount))
        let gridHeight = CGFloat(totalRows) * cellHeight

        // Horizontal lines
        for i in 0...totalRows {
            let y = topOffset + CGFloat(i) * cellHeight
            context?.move(to: CGPoint(x: gridOriginX, y: y))
            context?.addLine(to: CGPoint(x: gridOriginX + CGFloat(colCount) * colWidth, y: y))
        }

        // Vertical lines
        for i in 0...colCount {
            let x = gridOriginX + CGFloat(i) * colWidth
            context?.move(to: CGPoint(x: x, y: topOffset))
            context?.addLine(to: CGPoint(x: x, y: topOffset + gridHeight))
        }

        context?.strokePath()
    }

    // MARK: - Intrinsic size

    override var intrinsicContentSize: NSSize {
        let totalRows = 1 + rows.count
        let gridHeight = CGFloat(totalRows) * cellHeight
        let topOffset: CGFloat = isFocused ? controlBarHeight : 0
        return NSSize(width: containerWidth, height: gridHeight + topOffset)
    }
}

// MARK: - Attachment Cell

/// Custom NSTextAttachmentCell that hosts an InlineTableView.
/// The cell provides sizing info; the live InlineTableView is positioned
/// as a subview of the EditTextView on top of the glyph rect.
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
        return desiredSize
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // Draw a light placeholder — the live view covers this
        NSColor.controlBackgroundColor.withAlphaComponent(0.3).setFill()
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        path.fill()

        // Position the live view
        if let textView = controlView as? NSTextView {
            inlineTableView.frame = cellFrame
            if inlineTableView.superview !== textView {
                textView.addSubview(inlineTableView)
            }
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
