//
//  TableContainerView.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — A3.
//
//  `NSView` that renders a `Block.table` as a grid of cells with the
//  same visual chrome as `TableLayoutFragment.draw(at:in:)` — header
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
//  local (0, 0) — same offsets `TableLayoutFragment.draw` uses.
//

import AppKit

final class TableContainerView: NSView {

    /// The authoritative `Block.table` value this container renders.
    private(set) var block: Block

    /// Container width — set by the view provider's
    /// `attachmentBounds(...)` so the grid spans the available text-
    /// container width. Defaults to a reasonable size at construction
    /// and is updated when the view's frame changes.
    private var containerWidth: CGFloat

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
    }

    required init?(coder: NSCoder) {
        fatalError("TableContainerView does not support NSCoding")
    }

    /// Update the rendered table to match a new `Block.table` value.
    /// Phase B wires this from the document's splice pipeline.
    func update(block: Block) {
        guard case .table = block else { return }
        self.block = block
        invalidateIntrinsicContentSize()
        rebuildCellSubviews()
        needsDisplay = true
        needsLayout = true
    }

    /// Set the available container width. Called by the provider when
    /// the host text container resizes (window/split-view drag).
    func setContainerWidth(_ width: CGFloat) {
        if abs(width - containerWidth) < 0.5 { return }
        self.containerWidth = width
        invalidateIntrinsicContentSize()
        needsDisplay = true
        needsLayout = true
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
                addSubview(v)
                rowCells.append(v)
            }
            cellSubviews.append(rowCells)
        }
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

    private var bodyFont: NSFont {
        UserDefaultsManagement.noteFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
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
    // Mirrors `TableLayoutFragment.drawRowFills` exactly so the
    // visual is byte-equivalent during the migration.
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
        context.setFillColor(TableLayoutFragment.headerFillColor.cgColor)
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
                context.setFillColor(TableLayoutFragment.zebraFillColor.cgColor)
                context.fill(rect)
                context.restoreGState()
            }
            rowY += h
        }
    }

    // MARK: - Grid lines
    //
    // Mirrors `TableLayoutFragment.drawGridLines` exactly.
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
        context.setStrokeColor(TableLayoutFragment.gridLineColor.cgColor)
        context.setLineWidth(TableLayoutFragment.gridLineWidth)

        let half = TableLayoutFragment.gridLineWidth / 2

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
