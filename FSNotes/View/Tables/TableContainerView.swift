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

    init(block: Block, containerWidth: CGFloat = 600) {
        self.block = block
        self.containerWidth = containerWidth
        super.init(frame: .zero)
        self.wantsLayer = true
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
        needsDisplay = true
    }

    /// Set the available container width. Called by the provider when
    /// the host text container resizes (window/split-view drag).
    func setContainerWidth(_ width: CGFloat) {
        if abs(width - containerWidth) < 0.5 { return }
        self.containerWidth = width
        invalidateIntrinsicContentSize()
        needsDisplay = true
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
        guard case .table(let header, let alignments, _, _) = block,
              header.count > 0,
              let g = geometry(),
              g.columnWidths.count == header.count,
              g.rowHeights.count >= 1,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        let nsAlignments = alignments.map { TableGeometry.nsAlignment(for: $0) }

        // Grid origin: skip the top + left handle strips so handles
        // (Phase F) have reserved space without overlapping cells.
        let gridLeft = TableGeometry.handleBarWidth
        let gridTop = TableGeometry.handleBarHeight
        let gridWidth = g.columnWidths.reduce(0, +)
        let gridHeight = g.totalHeight

        context.saveGState()
        defer { context.restoreGState() }

        drawRowFills(
            context: context,
            rowHeights: g.rowHeights,
            gridLeft: gridLeft,
            gridTop: gridTop,
            gridWidth: gridWidth
        )
        drawCellContent(
            header: header,
            rows: tableRows,
            columnWidths: g.columnWidths,
            rowHeights: g.rowHeights,
            alignments: nsAlignments,
            font: bodyFont,
            gridLeft: gridLeft,
            gridTop: gridTop
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

    private var tableRows: [[TableCell]] {
        if case .table(_, _, let rows, _) = block { return rows }
        return []
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

    // MARK: - Cell content
    //
    // Read-only paint — Phase C replaces this with per-cell
    // `TableCellTextView` subviews. Until then, cells are
    // `attributed.draw(...)` calls onto the view's CG context, same
    // as `TableLayoutFragment.drawRowCells` does. Header cells get
    // the bold variant.
    private func drawCellContent(
        header: [TableCell],
        rows: [[TableCell]],
        columnWidths: [CGFloat],
        rowHeights: [CGFloat],
        alignments: [NSTextAlignment],
        font: NSFont,
        gridLeft: CGFloat,
        gridTop: CGFloat
    ) {
        let boldFont = NSFontManager.shared.convert(
            font, toHaveTrait: .boldFontMask
        )
        let padH = TableGeometry.cellPaddingH()
        let padTop = TableGeometry.cellPaddingTop()
        let padBot = TableGeometry.cellPaddingBot()

        drawRowCells(
            cells: header,
            rowY: gridTop,
            rowHeight: rowHeights[0],
            columnWidths: columnWidths,
            alignments: alignments,
            gridLeft: gridLeft,
            font: boldFont,
            padH: padH, padTop: padTop, padBot: padBot
        )

        var rowY = gridTop + rowHeights[0]
        for (idx, row) in rows.enumerated() {
            let h = rowHeights[idx + 1]
            drawRowCells(
                cells: row,
                rowY: rowY,
                rowHeight: h,
                columnWidths: columnWidths,
                alignments: alignments,
                gridLeft: gridLeft,
                font: font,
                padH: padH, padTop: padTop, padBot: padBot
            )
            rowY += h
        }
    }

    private func drawRowCells(
        cells: [TableCell],
        rowY: CGFloat,
        rowHeight: CGFloat,
        columnWidths: [CGFloat],
        alignments: [NSTextAlignment],
        gridLeft: CGFloat,
        font: NSFont,
        padH: CGFloat, padTop: CGFloat, padBot: CGFloat
    ) {
        var colX = gridLeft
        for (col, width) in columnWidths.enumerated() {
            defer { colX += width }
            guard col < cells.count else { continue }
            let cell = cells[col]
            let alignment = col < alignments.count ? alignments[col] : .left

            let cellRect = CGRect(
                x: colX + padH,
                y: rowY + padTop,
                width: max(0, width - padH * 2),
                height: max(0, rowHeight - padTop - padBot)
            )
            if cellRect.width <= 0 || cellRect.height <= 0 { continue }

            let attributed = TableGeometry.renderCellAttributedString(
                cell: cell, font: font, alignment: alignment
            )
            attributed.draw(
                with: cellRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
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
