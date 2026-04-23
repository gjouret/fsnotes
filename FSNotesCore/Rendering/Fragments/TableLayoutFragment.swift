//
//  TableLayoutFragment.swift
//  FSNotesCore
//
//  Phase 2e-T2-c — Read-only grid rendering for the TK2 native-cell
//  table path. Pairs with `TableElement`. The element carries a
//  `Block.table` payload (placeholder in 2e-T2-c: body cells are the
//  decoded separator-encoded text, alignments default to `.none` until
//  2e-T2-e threads the authoritative alignments through — see the
//  content-storage delegate's `synthesizePlaceholderTableBlock`).
//
//  This slice paints the grid: column borders, row borders, header
//  background, zebra row shading, and per-cell content. Editing, cursor,
//  and hover handles are deliberately out of scope and land in later
//  slices (2e-T2-d, -e, -g).
//
//  Draw contract:
//    * `layoutFragmentFrame` returns `TableGeometry.compute(...).totalHeight`
//      as the fragment height and the full text-container width. Without
//      the height override TK2 would fall back to super's frame, which
//      measures the separator-encoded attributed string as one line.
//    * `renderingSurfaceBounds` widens to the container so vertical grid
//      strokes at the right edge don't get clipped.
//    * `draw(at:in:)` NEVER calls `super.draw(at:in:)`. The backing
//      storage contains cell text separated by U+001F / U+001E — painting
//      those raw separators would show as flowed text with control
//      characters.
//
//  Caching: `TableGeometry.compute(...)` is hit once per fragment per
//  container width + cell-hash tuple. Changes in the backing attributed
//  string (cell edit, new block) invalidate the cache by construction:
//  on any mutation TK2 builds a new fragment, so the cache is per-instance
//  and dies with the fragment.
//
//  Why the fragment owns the draw (not the text view / attachment cell):
//  under TK2, `NSTextAttachmentCell.draw(...)` is never called —
//  composition flows exclusively through `NSTextLayoutFragment.draw(at:in:)`
//  for element-backed content. Keeping the draw here avoids the
//  `InlineTableView` subview-of-text-view dance and lets the grid paint
//  identically to every other block-model fragment.
//

import AppKit

/// Custom `NSTextLayoutFragment` for the TK2 native-cell table path.
/// Landed in 2e-T2-c with read-only grid rendering; editing, cursor
/// routing, and hover handles land in 2e-T2-d / -e / -g.
public final class TableLayoutFragment: NSTextLayoutFragment {

    // MARK: - Visual constants
    //
    // Mirrors `InlineTableView.drawGridLines` so the native-cell path is
    // pixel-identical to the widget path. Any change here must be
    // mirrored in the widget until slice 2e-T2-h deletes it.

    /// Grid line thickness. Matches `InlineTableView.gridLineWidth`.
    public static let gridLineWidth: CGFloat = 0.5

    /// Grid line color. Matches the stroke color used in
    /// `InlineTableView.drawGridLines` (white=0.4).
    public static let gridLineColor = NSColor(calibratedWhite: 0.4, alpha: 1.0)

    /// Header row background fill color. Matches
    /// `InlineTableView.drawGridLines` (white=0.85).
    public static let headerFillColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)

    /// Alternating body-row zebra-shading color. Matches
    /// `InlineTableView.drawGridLines` (white=0.95).
    public static let zebraFillColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)

    // MARK: - Hover state (2e-T2-g)
    //
    // External view code (the `TableHandleOverlay`) updates this when
    // the mouse enters / leaves the fragment's handle strips. The draw
    // path reads it to decide whether to paint the handle chrome at all
    // — in the unhovered state, the strips are entirely invisible so a
    // steady-state table looks identical to the pre-T2-g read-only
    // render.
    //
    // We do NOT invalidate layout on hover changes — the fragment's
    // frame already includes the handle strip reservation (see
    // `layoutFragmentFrame`), so only a redraw is needed. Callers call
    // `setHoverState(_:)` which marks the rendering surface dirty via
    // the layout manager's `invalidateRenderingForTextRange(for:)`.

    /// Hover / focus state. `none` is the default — no handles visible.
    /// `column(col)` highlights the top handle-strip slice for the
    /// given column (0-indexed). `row(row)` highlights the left handle-
    /// strip slice for the given row (row=0 → header, row>=1 → body).
    public enum HoverState: Equatable {
        case none
        case column(Int)
        case row(Int)
    }

    private var hoverState: HoverState = .none

    /// Update the hover state. Returns `true` if the state actually
    /// changed (the caller should then mark the hosting text view's
    /// rendering dirty). The fragment itself does NOT invalidate layout
    /// — `layoutFragmentFrame` is independent of hover state, so only
    /// a redraw is needed; that's the overlay's responsibility.
    @discardableResult
    public func setHoverState(_ newValue: HoverState) -> Bool {
        guard hoverState != newValue else { return false }
        hoverState = newValue
        return true
    }

    /// Current hover state. Exposed for tests + the overlay.
    public var currentHoverState: HoverState { hoverState }

    // MARK: - Geometry cache
    //
    // `TableGeometry.compute(...)` walks every cell's attributed string
    // to measure it. For a large table that is not free. Cache the
    // result per container width + cell-shape hash. The hash is cheap
    // enough that recomputing it on every access (vs. tracking
    // invalidation via KVO) is the simpler, lower-risk choice for
    // 2e-T2-c. Later slices may add explicit invalidation if profiling
    // shows the lookup on the hot path.

    private struct GeometryKey: Equatable {
        let containerWidth: CGFloat
        let fontPointSize: CGFloat
        let shapeHash: Int
    }

    private var cachedGeometryKey: GeometryKey?
    private var cachedGeometry: TableGeometry.Result?

    /// Compute grid geometry, hitting the cache when the inputs haven't
    /// changed since the last draw. The cell shape hash collapses every
    /// cell's raw text into a single integer — any content change
    /// produces a different hash and busts the cache.
    private func geometry(
        block: Block,
        containerWidth: CGFloat,
        font: NSFont
    ) -> TableGeometry.Result {
        guard case .table(let header, let alignments, let rows, let widths, _) = block else {
            return TableGeometry.Result(
                columnWidths: [], rowHeights: [], totalHeight: 0
            )
        }
        var hasher = Hasher()
        for cell in header { hasher.combine(cell.rawText) }
        for row in rows {
            hasher.combine("|")
            for cell in row { hasher.combine(cell.rawText) }
        }
        for a in alignments {
            hasher.combine(String(describing: a))
        }
        // T2-g.4: persisted widths are part of the cache key — a
        // drag-resize invalidates the cache.
        if let widths = widths {
            hasher.combine("W")
            for w in widths { hasher.combine(w) }
        }
        let key = GeometryKey(
            containerWidth: containerWidth,
            fontPointSize: font.pointSize,
            shapeHash: hasher.finalize()
        )
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

    // MARK: - Element accessors

    /// The backing `TableElement`. The content-storage delegate is the
    /// sole construction path (see `BlockModelContentStorageDelegate
    /// .textContentStorage(_:textParagraphWith:)`), so `textElement`
    /// is always a `TableElement` when `FeatureFlag.nativeTableElements`
    /// is on. A nil return here means we were dispatched in error —
    /// fall through to zero-sized draw so we never paint garbage.
    ///
    /// 2e-T2-c limitation flagged for 2e-T2-e: the `block` payload on
    /// this element is the decoded placeholder synthesized from the flat
    /// separator-encoded storage. `alignments` is `[.none, .none, ...]`
    /// because the decode path has no alignment information — alignments
    /// are tagged on the `DocumentProjection` block-span map, not on the
    /// flat storage. 2e-T2-e will thread the authoritative `Block.table`
    /// through (either via a content-storage-delegate cache keyed by
    /// range, or by storing the alignments as an `NSAttributedString`
    /// attribute during render). Until then, body and header text align
    /// left — matching the source-mode default.
    private var tableElement: TableElement? {
        return textElement as? TableElement
    }

    /// Convenience: the container's usable width (the width the element
    /// was laid out in). Falls back to the fragment's own frame width
    /// during early layout windows when the text container has not yet
    /// been sized.
    private var containerWidth: CGFloat {
        let width = textLayoutManager?.textContainer?.size.width ?? 0
        if width > 0 { return width }
        return super.layoutFragmentFrame.width
    }

    /// Body font — the measurement + render font for every body cell.
    /// Header cells get the bold variant applied at draw time.
    private var bodyFont: NSFont {
        return UserDefaultsManagement.noteFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    // MARK: - Geometry overrides

    /// Height = `handleBarHeight` (top strip reserved for column hover
    /// handles, T2-g) + total row-height sum from `TableGeometry`;
    /// width = full text container width. Without this override TK2
    /// measures the separator-encoded backing string as a single line
    /// fragment — the table would render one-line-tall and clip.
    ///
    /// `super.layoutFragmentFrame.origin` is preserved so TK2 stacks the
    /// fragment vertically in the same slot it would have for the
    /// paragraph.
    public override var layoutFragmentFrame: CGRect {
        let base = super.layoutFragmentFrame
        guard let element = tableElement else { return base }
        let width = containerWidth
        let g = geometry(
            block: element.block,
            containerWidth: width,
            font: bodyFont
        )
        let total = TableGeometry.handleBarHeight + g.totalHeight
        return CGRect(
            x: base.origin.x,
            y: base.origin.y,
            width: width,
            height: max(base.height, total)
        )
    }

    /// Cover the full container width so vertical grid strokes at the
    /// right edge (and any future focus-ring padding) don't clip to the
    /// fragment's text-natural width.
    public override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        let containerW = containerWidth
        // Fragment-local coordinates: the fragment's origin sits at x=0
        // in its own surface; the container's left edge is at
        // `-frame.origin.x`.
        let localLeft = -frame.origin.x
        return CGRect(
            x: localLeft,
            y: 0,
            width: containerW,
            height: frame.height
        )
    }

    // MARK: - Drawing

    /// Paint the full grid. Never calls `super.draw(at:in:)` — the
    /// element's backing attributed string is cell text joined by
    /// U+001F / U+001E separators, which would render as unreadable
    /// text with embedded control characters.
    public override func draw(at point: CGPoint, in context: CGContext) {
        guard let element = tableElement,
              case .table(let header, let alignments, let rows, _, _) = element.block,
              header.count > 0 else {
            return
        }

        let frame = layoutFragmentFrame
        guard frame.width > 0, frame.height > 0 else { return }

        let width = containerWidth
        let font = bodyFont
        let g = geometry(block: element.block, containerWidth: width, font: font)
        guard g.columnWidths.count == header.count,
              g.rowHeights.count == 1 + rows.count else {
            return
        }

        // Map block-model `TableAlignment` → AppKit `NSTextAlignment`
        // using the geometry module's canonical mapping so drawing and
        // measurement stay in lockstep.
        let nsAlignments = alignments.map { TableGeometry.nsAlignment(for: $0) }

        // Origin of the grid in drawing-context coordinates. The text
        // container's left edge is at `point.x - frame.origin.x`; offset
        // further by `handleBarWidth` so the grid starts at the same
        // x-offset the widget uses. The grid's top edge sits at
        // `point.y + handleBarHeight` — the top strip is reserved for
        // column drag handles (T2-g). Every row is stacked downward
        // from there (TK2 uses flipped y-down coordinates inside
        // `draw(at:in:)`).
        let containerOriginX = point.x - frame.origin.x
        let gridLeft = containerOriginX + TableGeometry.handleBarWidth
        let gridTop = point.y + TableGeometry.handleBarHeight
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
            context: context,
            header: header,
            rows: rows,
            columnWidths: g.columnWidths,
            rowHeights: g.rowHeights,
            alignments: nsAlignments,
            font: font,
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
        // Hover-driven handle chrome. In the default (`.none`) state
        // this is a no-op — a steady-state table looks identical to
        // the pre-T2-g render.
        drawHoverHandles(
            context: context,
            columnWidths: g.columnWidths,
            rowHeights: g.rowHeights,
            gridLeft: gridLeft,
            gridTop: gridTop,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            containerOriginX: containerOriginX,
            topStripY: point.y
        )
        // T2-g.4 live drag-resize preview line. No-op when no preview
        // is set (the steady state).
        drawResizePreview(
            at: point, in: context, fragmentHeight: frame.height
        )
    }

    // MARK: - Hover handle chrome (T2-g.1)

    /// Paint the hover-state column/row handle chip when `hoverState`
    /// is non-`.none`. `.none` draws nothing so the handle strips stay
    /// invisible until the overlay reports a hover.
    ///
    /// Column handle: a thin colored pill at the top of the hovered
    /// column, inside the top `handleBarHeight` strip.
    /// Row handle: a thin colored pill on the left of the hovered
    /// row, inside the left `handleBarWidth` strip.
    private func drawHoverHandles(
        context: CGContext,
        columnWidths: [CGFloat],
        rowHeights: [CGFloat],
        gridLeft: CGFloat,
        gridTop: CGFloat,
        gridWidth: CGFloat,
        gridHeight: CGFloat,
        containerOriginX: CGFloat,
        topStripY: CGFloat
    ) {
        let fill = Theme.shared.chrome.tableHandle
            .resolvedForCurrentAppearance(fallback: NSColor(white: 0.5, alpha: 0.8))

        switch hoverState {
        case .none:
            return

        case .column(let col):
            guard col >= 0, col < columnWidths.count else { return }
            var x = gridLeft
            for i in 0..<col {
                x += columnWidths[i]
            }
            let width = columnWidths[col]
            // Center a 2/3-width pill inside the column's top strip.
            let pillInset: CGFloat = max(2, width * 0.16)
            let pillRect = CGRect(
                x: x + pillInset,
                y: topStripY + 2,
                width: max(0, width - 2 * pillInset),
                height: TableGeometry.handleBarHeight - 4
            )
            context.saveGState()
            context.setFillColor(fill.cgColor)
            let radius = min(pillRect.height / 2, 4)
            let path = CGPath(
                roundedRect: pillRect,
                cornerWidth: radius, cornerHeight: radius,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
            context.restoreGState()

        case .row(let row):
            guard row >= 0, row < rowHeights.count else { return }
            var y = gridTop
            for i in 0..<row {
                y += rowHeights[i]
            }
            let height = rowHeights[row]
            let pillInset: CGFloat = max(2, height * 0.16)
            let pillRect = CGRect(
                x: containerOriginX + 2,
                y: y + pillInset,
                width: TableGeometry.handleBarWidth - 4,
                height: max(0, height - 2 * pillInset)
            )
            context.saveGState()
            context.setFillColor(fill.cgColor)
            let radius = min(pillRect.width / 2, 4)
            let path = CGPath(
                roundedRect: pillRect,
                cornerWidth: radius, cornerHeight: radius,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
    }

    // MARK: - Geometry helpers for the overlay (T2-g)
    //
    // The `TableHandleOverlay` needs to translate mouse locations
    // (text-view coordinate space) into (row, col) hits on the table's
    // handle strips. These helpers keep the math in one place so the
    // overlay doesn't re-derive column-x boundaries or row-y boundaries.

    /// Column (0-indexed) whose top-strip contains `localX` — a point
    /// in the fragment's rendering-surface coordinate space
    /// (i.e. `0` = fragment left edge). Returns `nil` if `localX` is
    /// outside the grid's horizontal extent.
    ///
    /// The fragment origin isn't known here — callers subtract the
    /// fragment's `layoutFragmentFrame.origin.x` before calling.
    public func columnAt(localX: CGFloat) -> Int? {
        guard let element = tableElement,
              case .table(_, _, _, _, _) = element.block else { return nil }
        let g = geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        )
        var x = TableGeometry.handleBarWidth
        for (idx, w) in g.columnWidths.enumerated() {
            if localX >= x, localX < x + w {
                return idx
            }
            x += w
        }
        return nil
    }

    /// Row (0 = header, 1..N = body) whose left-strip contains
    /// `localY` — a point in the fragment's rendering-surface
    /// coordinate space where `0` is the fragment's top. Returns `nil`
    /// if `localY` is outside the grid's vertical extent.
    public func rowAt(localY: CGFloat) -> Int? {
        guard let element = tableElement,
              case .table(_, _, _, _, _) = element.block else { return nil }
        let g = geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        )
        var y = TableGeometry.handleBarHeight
        for (idx, h) in g.rowHeights.enumerated() {
            if localY >= y, localY < y + h {
                return idx
            }
            y += h
        }
        return nil
    }

    /// `true` if `localY` falls inside the fragment's top handle
    /// strip (0 ≤ localY < handleBarHeight).
    public func isInTopHandleStrip(localY: CGFloat) -> Bool {
        return localY >= 0 && localY < TableGeometry.handleBarHeight
    }

    /// `true` if `localX` falls inside the fragment's left handle
    /// strip (0 ≤ localX < handleBarWidth).
    public func isInLeftHandleStrip(localX: CGFloat) -> Bool {
        return localX >= 0 && localX < TableGeometry.handleBarWidth
    }

    // MARK: - T2-g.4 drag-resize helpers

    /// Hit-test slop (in points) around a column boundary that counts
    /// as "on the boundary" for drag-resize hit-testing.
    public static let resizeHitSlop: CGFloat = 4.0

    /// Return the interior column index `col` (0-indexed) whose right
    /// edge is within `resizeHitSlop` of `localX`. Returns `nil` for
    /// the last column's right edge (dragging past the right margin is
    /// out of scope) and for single-column tables.
    public func columnBoundaryAt(localX: CGFloat) -> Int? {
        guard let element = tableElement,
              case .table(let header, _, _, _, _) = element.block,
              header.count > 1 else { return nil }
        let g = geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        )
        var x = TableGeometry.handleBarWidth
        for i in 0..<(g.columnWidths.count - 1) {
            x += g.columnWidths[i]
            if abs(localX - x) <= Self.resizeHitSlop {
                return i
            }
        }
        return nil
    }

    /// The X coordinate of the left edge of column `col` (in
    /// rendering-surface local coordinates), or `nil` for out-of-range.
    public func columnLeftEdge(_ col: Int) -> CGFloat? {
        guard let element = tableElement,
              case .table = element.block else { return nil }
        let g = geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        )
        guard col >= 0, col <= g.columnWidths.count else { return nil }
        var x = TableGeometry.handleBarWidth
        for i in 0..<col { x += g.columnWidths[i] }
        return x
    }

    /// Current (cached/measured) column widths — either the persisted
    /// override or the content-based measurement. Used as the baseline
    /// for computing new widths from a drag delta.
    public func currentColumnWidths() -> [CGFloat] {
        guard let element = tableElement,
              case .table = element.block else { return [] }
        return geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        ).columnWidths
    }

    // MARK: - Live resize preview

    /// Transient preview state. `nil` means no preview. When set, a
    /// vertical line is painted at `previewX` (local coordinates).
    private var resizePreviewLocalX: CGFloat?

    /// Set or clear the drag-resize preview X. Returns `true` if the
    /// value changed (so the caller can mark the host view dirty).
    @discardableResult
    public func setResizePreview(localX: CGFloat?) -> Bool {
        guard resizePreviewLocalX != localX else { return false }
        resizePreviewLocalX = localX
        return true
    }

    /// Paint the resize-preview line if one is set. Called at the end
    /// of `draw(at:in:)` so the line sits on top of grid strokes.
    public func drawResizePreview(
        at point: CGPoint,
        in context: CGContext,
        fragmentHeight: CGFloat
    ) {
        guard let localX = resizePreviewLocalX else { return }
        let frame = layoutFragmentFrame
        let containerOriginX = point.x - frame.origin.x
        let x = containerOriginX + localX
        // T2-g.4: live-preview line color resolves from the theme,
        // with a system-blue fallback if the theme predates this field.
        let fallback = NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        let strokeColor = Theme.shared.chrome.tableResizePreview
            .resolvedForCurrentAppearance(fallback: fallback)
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: x + 0.5, y: point.y))
        context.addLine(to: CGPoint(x: x + 0.5, y: point.y + fragmentHeight))
        context.strokePath()
    }

    // MARK: - Row fills (header + zebra body shading)

    /// Header row gets a solid fill; alternating body rows get a subtle
    /// zebra shade. Matches the shading order in
    /// `InlineTableView.drawGridLines`.
    private func drawRowFills(
        context: CGContext,
        rowHeights: [CGFloat],
        gridLeft: CGFloat,
        gridTop: CGFloat,
        gridWidth: CGFloat
    ) {
        guard !rowHeights.isEmpty else { return }

        // Header row at top.
        let headerRect = CGRect(
            x: gridLeft,
            y: gridTop,
            width: gridWidth,
            height: rowHeights[0]
        )
        context.saveGState()
        context.setFillColor(Self.headerFillColor.cgColor)
        context.fill(headerRect)
        context.restoreGState()

        // Body rows: zebra shade every other row. `InlineTableView`
        // fills even-indexed body rows (row 0, row 2, ...) — mirror that
        // here so the shade matches row-for-row.
        var rowY = gridTop + rowHeights[0]
        for bodyIdx in 0..<(rowHeights.count - 1) {
            let h = rowHeights[bodyIdx + 1]
            if bodyIdx % 2 == 0 {
                let rect = CGRect(
                    x: gridLeft, y: rowY, width: gridWidth, height: h
                )
                context.saveGState()
                context.setFillColor(Self.zebraFillColor.cgColor)
                context.fill(rect)
                context.restoreGState()
            }
            rowY += h
        }
    }

    // MARK: - Cell content

    /// Draw each cell's inline-rendered attributed string into its
    /// sub-rect. Header cells use the bold font variant; body cells use
    /// the note body font.
    private func drawCellContent(
        context: CGContext,
        header: [TableCell],
        rows: [[TableCell]],
        columnWidths: [CGFloat],
        rowHeights: [CGFloat],
        alignments: [NSTextAlignment],
        font: NSFont,
        gridLeft: CGFloat,
        gridTop: CGFloat
    ) {
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let padH = TableGeometry.cellPaddingH()
        let padTop = TableGeometry.cellPaddingTop()
        let padBot = TableGeometry.cellPaddingBot()

        // Header row.
        drawRowCells(
            cells: header,
            isHeader: true,
            rowY: gridTop,
            rowHeight: rowHeights[0],
            columnWidths: columnWidths,
            alignments: alignments,
            gridLeft: gridLeft,
            font: boldFont,
            padH: padH,
            padTop: padTop,
            padBot: padBot
        )

        // Body rows.
        var rowY = gridTop + rowHeights[0]
        for (idx, row) in rows.enumerated() {
            let h = rowHeights[idx + 1]
            drawRowCells(
                cells: row,
                isHeader: false,
                rowY: rowY,
                rowHeight: h,
                columnWidths: columnWidths,
                alignments: alignments,
                gridLeft: gridLeft,
                font: font,
                padH: padH,
                padTop: padTop,
                padBot: padBot
            )
            rowY += h
        }
    }

    private func drawRowCells(
        cells: [TableCell],
        isHeader: Bool,
        rowY: CGFloat,
        rowHeight: CGFloat,
        columnWidths: [CGFloat],
        alignments: [NSTextAlignment],
        gridLeft: CGFloat,
        font: NSFont,
        padH: CGFloat,
        padTop: CGFloat,
        padBot: CGFloat
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

            // Render the cell's inline tree with the per-cell alignment
            // and the header/body font. Matches the measurement path
            // used by `TableGeometry.renderedCellText`.
            let attributed = makeRenderedCellText(
                cell: cell, font: font, alignment: alignment
            )

            attributed.draw(
                with: cellRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
    }

    /// Mirror of `TableGeometry.renderedCellText`. The geometry module
    /// keeps its copy private (measurement path) and we keep ours here
    /// (draw path); both must produce the same attributed string so
    /// measured heights match painted heights. The `<br>` → `\n`
    /// replacement is load-bearing: cells store multi-line content as
    /// `<br>` but lay out as wrapped lines.
    ///
    /// If this ever drifts from the geometry-side copy, row heights
    /// will disagree with their painted content — the whole grid will
    /// clip. Keep them in sync until slice 2e-T2-h collapses the
    /// measurement/draw paths.
    private func makeRenderedCellText(
        cell: TableCell,
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
        let rendered = InlineRenderer.render(
            cell.inline, baseAttributes: attrs, note: nil
        )
        let mutable = NSMutableAttributedString(attributedString: rendered)
        if mutable.length > 0 {
            mutable.addAttribute(
                .paragraphStyle, value: para,
                range: NSRange(location: 0, length: mutable.length)
            )
        }
        // `<br>` → `\n` for multi-line cell content.
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

    // MARK: - Grid lines

    /// Stroke horizontal and vertical grid lines over the already-filled
    /// row backgrounds. Order matches `InlineTableView.drawGridLines`:
    /// fills go first, strokes go on top so the lines stay crisp.
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
        context.setStrokeColor(Self.gridLineColor.cgColor)
        context.setLineWidth(Self.gridLineWidth)

        let half = Self.gridLineWidth / 2

        // Horizontal lines: one above each row + one below the last.
        // Inset the outer lines by `half` so the stroke stays inside the
        // fragment's rendering surface (prevents clipping at y=0 and
        // y=gridHeight).
        var y = gridTop
        // Top edge.
        context.move(to: CGPoint(x: gridLeft, y: y + half))
        context.addLine(to: CGPoint(x: gridLeft + gridWidth, y: y + half))
        for rh in rowHeights {
            y += rh
            let lineY: CGFloat
            if y >= gridTop + gridHeight - 0.001 {
                lineY = y - half // bottom edge
            } else {
                lineY = y
            }
            context.move(to: CGPoint(x: gridLeft, y: lineY))
            context.addLine(to: CGPoint(x: gridLeft + gridWidth, y: lineY))
        }

        // Vertical lines: one at each column boundary + inner separators.
        var x = gridLeft
        // Left edge.
        context.move(to: CGPoint(x: x + half, y: gridTop))
        context.addLine(to: CGPoint(x: x + half, y: gridTop + gridHeight))
        for (idx, cw) in columnWidths.enumerated() {
            x += cw
            let lineX: CGFloat
            if idx == columnWidths.count - 1 {
                lineX = x - half // right edge
            } else {
                lineX = x
            }
            context.move(to: CGPoint(x: lineX, y: gridTop))
            context.addLine(to: CGPoint(x: lineX, y: gridTop + gridHeight))
        }
        context.strokePath()
    }
}
