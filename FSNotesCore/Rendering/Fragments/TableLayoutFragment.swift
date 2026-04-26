//
//  TableLayoutFragment.swift
//  FSNotesCore
//
//  Grid rendering for the TK2 native-cell table path. Pairs with
//  `TableElement`, which carries the authoritative `Block.table`
//  payload (header, alignments, body rows, optional persisted column
//  widths). Paints column borders, row borders, header background,
//  zebra row shading, and per-cell content; editing entry points,
//  caret-rect computation, and hover-handle hit-testing are also
//  implemented here (see `caretRectInCell`, `geometryForHandleOverlay`,
//  and the column-handle overlay region near the top of the fragment).
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
/// Owns grid rendering, caret-rect computation, and column-handle
/// hit-testing.
public final class TableLayoutFragment: NSTextLayoutFragment {

    // MARK: - Visual constants
    //
    // The legacy `InlineTableView` widget that originally mirrored these
    // values was deleted in Phase 2e T2-h (commit `de1f146`); these
    // constants are now the single source of truth for grid stroke
    // widths and zebra fills (alongside `Theme.shared.chrome` for
    // colors).

    /// Grid line thickness. Matches `InlineTableView.gridLineWidth`.
    public static let gridLineWidth: CGFloat = 0.5

    /// Grid line color. Resolves from `Theme.shared.chrome.tableGridLine`
    /// per current appearance. Fallback matches the pre-theme value
    /// (`white=0.4`).
    public static var gridLineColor: NSColor {
        Theme.shared.chrome.tableGridLine.resolvedForCurrentAppearance(
            fallback: NSColor(calibratedWhite: 0.4, alpha: 1.0)
        )
    }

    /// Header row background fill color. Resolves from
    /// `Theme.shared.chrome.tableHeaderFill` per current appearance.
    /// Fallback matches the pre-theme value (`white=0.85`).
    public static var headerFillColor: NSColor {
        Theme.shared.chrome.tableHeaderFill.resolvedForCurrentAppearance(
            fallback: NSColor(calibratedWhite: 0.85, alpha: 1.0)
        )
    }

    /// Alternating body-row zebra-shading color. Resolves from
    /// `Theme.shared.chrome.tableZebraFill` per current appearance.
    /// Fallback matches the pre-theme value (`white=0.95`).
    public static var zebraFillColor: NSColor {
        Theme.shared.chrome.tableZebraFill.resolvedForCurrentAppearance(
            fallback: NSColor(calibratedWhite: 0.95, alpha: 1.0)
        )
    }

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
        /// Mouse is anywhere inside the table. Both the column and row
        /// handle chrome are drawn at the given column and row index so
        /// the user sees handles for the cell they are over. Matches
        /// the TK1 `InlineTableView` UX where hovering anywhere in the
        /// grid showed a column handle at the top of the current
        /// column and a row handle on the left of the current row.
        case cell(column: Int, row: Int)
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
        guard case .table(let header, let alignments, let rows, let widths) = block else {
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
    /// is always a `TableElement` when dispatched here. A nil return
    /// means we were dispatched in error — fall through to zero-sized
    /// draw so we never paint garbage.
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

    /// Public accessor for the fragment's computed column widths +
    /// row heights. Consumed by `TableHandleOverlay` to position
    /// the handle chip subviews over the correct cell. Returns nil
    /// when the underlying element isn't a `.table` block.
    public func geometryForHandleOverlay() -> TableGeometry.Result? {
        guard let element = tableElement,
              case .table = element.block else { return nil }
        return geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        )
    }

    /// Map a click point in fragment-local coordinates to the
    /// (row, col) of the cell that visually contains it. Returns
    /// `nil` if the point is in the handle strips or outside the
    /// grid. Drives click-to-place-cursor: the default TK2 hit
    /// test uses naturally-laid-out text line fragments, but
    /// `TableLayoutFragment.draw` paints cells at custom grid
    /// positions, so the default mapping is wrong. The editor's
    /// `mouseDown` consults this helper before falling through
    /// to `super.mouseDown` so a click on cell text actually
    /// places the cursor inside that cell's storage range.
    ///
    /// `localPoint` is expressed relative to the fragment's
    /// rendering origin (i.e. clicker subtracts the fragment's
    /// `layoutFragmentFrame.origin` before calling).
    public func cellHit(at localPoint: CGPoint) -> (row: Int, col: Int)? {
        guard let element = tableElement,
              case .table(let header, _, _, _) = element.block,
              header.count > 0
        else { return nil }
        let g = geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        )
        guard g.columnWidths.count == header.count else { return nil }
        // Skip the top handle strip — clicks there belong to
        // the column-handle UI, not cell-cursor placement.
        if localPoint.y < TableGeometry.handleBarHeight { return nil }
        // X axis: skip left handle strip; iterate column widths.
        // The trailing edge of the LAST column is treated inclusively —
        // a click exactly on the right border of the rightmost cell
        // still resolves to that cell, matching how
        // `cellLocation(forOffset: length)` resolves end-of-table to
        // the last cell. Without this, corner clicks (especially on
        // the bottom-right cell) returned nil and the user could not
        // place the cursor in the last column.
        var x = TableGeometry.handleBarWidth
        var col = -1
        for (i, w) in g.columnWidths.enumerated() {
            let isLast = (i == g.columnWidths.count - 1)
            let inside = isLast
                ? (localPoint.x >= x && localPoint.x <= x + w)
                : (localPoint.x >= x && localPoint.x < x + w)
            if inside {
                col = i; break
            }
            x += w
        }
        if col < 0 { return nil }
        // Y axis: iterate row heights, starting at the top of the
        // grid (after the handle strip). Same trailing-edge inclusion
        // for the bottom row.
        var y = TableGeometry.handleBarHeight
        var row = -1
        for (i, h) in g.rowHeights.enumerated() {
            let isLast = (i == g.rowHeights.count - 1)
            let inside = isLast
                ? (localPoint.y >= y && localPoint.y <= y + h)
                : (localPoint.y >= y && localPoint.y < y + h)
            if inside {
                row = i; break
            }
            y += h
        }
        if row < 0 { return nil }
        return (row, col)
    }

    /// Compute the visual caret rectangle for a cursor at
    /// `cellLocalOffset` characters into cell `(row, col)`, expressed
    /// in fragment-local coordinates (origin at the fragment's top-
    /// left). Pairs with `EditTextView.drawInsertionPoint` to paint
    /// the caret inside the visible cell rather than at the natural-
    /// flow position TK2's default caret math computes.
    ///
    /// Why this is needed: `draw(at:in:)` paints cells at custom grid
    /// positions via `drawCellContent`. TK2 still lays out the
    /// fragment's `textLineFragments` in natural left-to-right text
    /// order; its caret painter reads positions from those line
    /// fragments and ends up drawing the caret at the top-left of
    /// the fragment, in the column-handle strip area, regardless of
    /// where the cursor actually sits in the grid. This helper
    /// computes the geometrically correct rect so the editor
    /// override can hand the right rect to the caret painter.
    ///
    /// Geometry mirrors `drawRowCells`: each cell's content sub-rect
    /// is `(colX + padH, rowY + padTop, width - padH*2,
    /// rowHeight - padTop - padBot)`. We measure the rendered text up
    /// to `cellLocalOffset` to position the caret horizontally.
    ///
    /// Returns `nil` when the (row, col) is out of range for the
    /// underlying block, or the element isn't a `.table` block.
    public func caretRectInCell(
        row: Int,
        col: Int,
        cellLocalOffset: Int = 0,
        caretWidth: CGFloat = 1.0
    ) -> CGRect? {
        guard let element = tableElement,
              case .table(let header, let alignments, let rows, _) = element.block,
              header.count > 0,
              row >= 0, row <= rows.count,
              col >= 0, col < header.count
        else { return nil }
        let g = geometry(
            block: element.block,
            containerWidth: containerWidth,
            font: bodyFont
        )
        guard g.columnWidths.count == header.count,
              g.rowHeights.count == 1 + rows.count
        else { return nil }

        // Locate the cell (mirror `drawRowCells`).
        var colX = TableGeometry.handleBarWidth
        for i in 0..<col { colX += g.columnWidths[i] }
        let cellWidth = g.columnWidths[col]

        var rowY = TableGeometry.handleBarHeight
        for i in 0..<row { rowY += g.rowHeights[i] }
        let rowHeight = g.rowHeights[row]

        let padH = TableGeometry.cellPaddingH()
        let padTop = TableGeometry.cellPaddingTop()
        let padBot = TableGeometry.cellPaddingBot()
        let contentX = colX + padH
        let contentY = rowY + padTop
        let contentWidth = max(0, cellWidth - padH * 2)
        let contentHeight = max(0, rowHeight - padTop - padBot)

        // Measure rendered text width up to `cellLocalOffset` so the
        // caret sits at the right column inside the cell. For an
        // empty cell, or offset 0, the caret hugs the content's left
        // edge — which matches NSText behaviour for an empty line.
        let isHeader = (row == 0)
        let cellsForRow: [TableCell]
        if isHeader { cellsForRow = header }
        else { cellsForRow = rows[row - 1] }
        guard col < cellsForRow.count else { return nil }
        let cell = cellsForRow[col]

        let baseFont = bodyFont
        let drawFont: NSFont
        if isHeader {
            drawFont = NSFontManager.shared.convert(
                baseFont, toHaveTrait: .boldFontMask
            )
        } else {
            drawFont = baseFont
        }
        let alignment = col < alignments.count
            ? TableGeometry.nsAlignment(for: alignments[col])
            : .left

        // Build the same attributed string `drawRowCells` paints, then
        // measure the substring [0, cellLocalOffset) to find the caret
        // x. NSAttributedString.size() ignores wrapping, which matches
        // single-line cell content; cells with `<br>` newlines are
        // multi-line but the caret still sits on its own line — for
        // this slice we treat the cell as single-line and place the
        // caret at the measured-text x. Multi-line caret routing is a
        // follow-up (the cell's wrapped layout would need to be probed).
        let attributed = NSMutableAttributedString(string: cell.rawText)
        attributed.addAttribute(
            .font, value: drawFont,
            range: NSRange(location: 0, length: attributed.length)
        )

        let clampedOffset = max(0, min(cellLocalOffset, attributed.length))
        let measured: CGFloat
        if clampedOffset == 0 || attributed.length == 0 {
            measured = 0
        } else {
            let prefix = attributed.attributedSubstring(
                from: NSRange(location: 0, length: clampedOffset)
            )
            measured = prefix.size().width
        }

        // Apply alignment so right- / center-aligned cells place the
        // caret next to the visible text rather than at the cell's
        // left edge.
        let caretX: CGFloat
        switch alignment {
        case .right:
            let totalWidth = attributed.size().width
            caretX = contentX + max(0, contentWidth - totalWidth) + measured
        case .center:
            let totalWidth = attributed.size().width
            caretX = contentX + max(0, (contentWidth - totalWidth) / 2) + measured
        default:
            caretX = contentX + measured
        }

        // Caret height should be one line of text, not the full cell
        // content area — the platform's standard caret is line-tall,
        // and using contentHeight makes the caret an out-sized blue
        // stripe that fills the whole cell vertically when the row is
        // tall (e.g. a multi-line cell or a cell rendered at increased
        // line spacing). Use the typeset height of "X" with the cell's
        // draw font (same metric `TableGeometry.minCellHeight` uses
        // for natural row height); fall back to the (smaller of)
        // contentHeight to cap at the cell's own bounds.
        let lineHeight = ceil(
            NSAttributedString(string: "X", attributes: [.font: drawFont])
                .boundingRect(
                    with: CGSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
        )
        let caretHeight = min(max(lineHeight, 1), contentHeight)
        return CGRect(
            x: caretX,
            y: contentY,
            width: caretWidth,
            height: caretHeight
        )
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
              case .table(let header, let alignments, let rows, _) = element.block,
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
        // Handle chrome is now painted by `TableHandleChip` real
        // NSView subviews (created by `TableHandleOverlay.updateHover`),
        // not by the fragment. The chip approach moves with the mouse
        // because AppKit invalidates a chip's dirty rect on `.frame`
        // change for free; the fragment-level paint route never re-
        // ran `draw(at:in:)` after the first hover (TK2 caches the
        // rendering surface), which left "stuck" chrome at the first
        // hovered cell while the chip moved correctly with the mouse.
        // Calling `drawHoverHandles` here is now dead code.
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
        switch hoverState {
        case .none:
            return
        case .column(let col):
            drawColumnHandle(
                context: context, columnWidths: columnWidths,
                col: col, gridLeft: gridLeft, topStripY: topStripY
            )
        case .row(let row):
            drawRowHandle(
                context: context, rowHeights: rowHeights,
                row: row, gridTop: gridTop,
                containerOriginX: containerOriginX
            )
        case .cell(let col, let row):
            drawColumnHandle(
                context: context, columnWidths: columnWidths,
                col: col, gridLeft: gridLeft, topStripY: topStripY
            )
            drawRowHandle(
                context: context, rowHeights: rowHeights,
                row: row, gridTop: gridTop,
                containerOriginX: containerOriginX
            )
        }
    }

    /// Paint a column handle at the top of column `col`. Matches
    /// TK1 `GlassHandleView`: full column width × handleBarHeight,
    /// rectangular (no rounded corners), translucent separator fill,
    /// with `⠿` (six-dot braille grip) centered so the user recognises
    /// it as grabbable.
    private func drawColumnHandle(
        context: CGContext,
        columnWidths: [CGFloat],
        col: Int,
        gridLeft: CGFloat,
        topStripY: CGFloat
    ) {
        guard col >= 0, col < columnWidths.count else { return }
        var x = gridLeft
        for i in 0..<col { x += columnWidths[i] }
        let width = columnWidths[col]
        let rect = CGRect(
            x: x + 1, y: topStripY + 1,
            width: max(0, width - 2),
            height: TableGeometry.handleBarHeight - 2
        )
        Self.paintHandleChrome(context: context, rect: rect)
    }

    /// Paint a row handle on the left of row `row`. Matches
    /// TK1 `GlassHandleView`: handleBarWidth × full row height,
    /// rectangular, translucent separator fill, `⠿` centered.
    private func drawRowHandle(
        context: CGContext,
        rowHeights: [CGFloat],
        row: Int,
        gridTop: CGFloat,
        containerOriginX: CGFloat
    ) {
        guard row >= 0, row < rowHeights.count else { return }
        var y = gridTop
        for i in 0..<row { y += rowHeights[i] }
        let height = rowHeights[row]
        let rect = CGRect(
            x: containerOriginX + 1, y: y + 1,
            width: TableGeometry.handleBarWidth - 2,
            height: max(0, height - 2)
        )
        Self.paintHandleChrome(context: context, rect: rect)
    }

    /// Shared chrome paint for both column and row handles: fill +
    /// centered `⠿` grabber glyph. Uses `NSColor.separatorColor` (at
    /// 0.3 alpha) and `NSColor.secondaryLabelColor` to match the TK1
    /// look; these are appearance-aware so dark mode gets correct
    /// contrast automatically.
    private static func paintHandleChrome(
        context: CGContext, rect: CGRect
    ) {
        let bg = NSColor.separatorColor.withAlphaComponent(0.35)
        context.saveGState()
        context.setFillColor(bg.cgColor)
        context.fill(rect)
        context.restoreGState()

        // Grip glyph ⠿ (BRAILLE PATTERN DOTS-123456 — U+283F). Drawn
        // via NSAttributedString so it picks up current-appearance
        // label colour automatically. Glyph size scales with the
        // handle strip so a wider / taller handle gets a
        // proportionally larger grabber.
        let minDim = min(rect.width, rect.height)
        let pt = max(10, minDim * 0.8)
        let font = NSFont.systemFont(ofSize: pt, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let grip = NSAttributedString(string: "\u{283F}", attributes: attrs)
        let size = grip.size()
        let origin = CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        let nsCtx = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        grip.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
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
              case .table(_, _, _, _) = element.block else { return nil }
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
              case .table(_, _, _, _) = element.block else { return nil }
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
              case .table(let header, _, _, _) = element.block,
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
            // and the header/body font. Shares
            // `TableGeometry.renderCellAttributedString` with the
            // measurement path so painted heights match measured heights.
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

    // Note on caret painting under TK2:
    //
    // `NSTextLayoutManager.enumerateTextSegments(in:type:options:using:)`
    // is the canonical API `NSTextInsertionIndicator` consults to
    // position itself. The previous attempt at this commit overrode
    // `textLineFragments` with one cell-aligned `NSTextLineFragment`
    // per cell, expecting TK2 to route caret rects through them. An
    // empirical diagnostic showed the override broke segment
    // enumeration entirely (`enumerateTextSegments` block was never
    // called for any caret offset inside the table fragment), so
    // the indicator had no frame to render at.
    //
    // The actual canonical pattern — used by STTextView and
    // documented as the workaround for the TK2-26 bug "drawInsertionPoint
    // is never called" (filed by krzyzanowskim) — is to LET the
    // natural typesetting happen, install a text-view-side caret
    // subview, and reposition it on selection change to the rect
    // computed by `caretRectInCell` (already implemented above).
    // That wiring lives in `EditTextView`, not in this fragment.
}
