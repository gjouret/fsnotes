//
//  TableGeometry.swift
//  FSNotesCore
//
//  Phase 2e-T2-a — Pure-function column-width and row-height computer
//  for table grids. Originally ported verbatim from the geometry
//  methods of the since-deleted `InlineTableView` widget
//  (`contentBasedColumnWidths`, `rowHeights`, `wrappedCellHeight`) so
//  that pixel-for-pixel identical grid sizing is available to the TK2
//  native-cell path without having to stand up an `NSWindow` +
//  `NSView` pair.
//
//  This type is a value type with no mutable state. Input is a
//  block-model table plus the container width and note font; output is
//  column widths, row heights, and total grid height. No AppKit views,
//  no `NSTextContentStorage`, no side effects.
//
//  The original widget that this file replaced lived in
//  `FSNotes/Helpers/InlineTableView.swift` and was deleted in slice
//  2e-T2-h (commit de1f146). `TableGeometry` is now the sole source of
//  truth for grid measurement.
//

import AppKit

public enum TableGeometry {

    /// Result bundle — matches the shape slice 2e-T2-c needs for
    /// `TableLayoutFragment.draw(at:in:)`.
    public struct Result: Equatable {
        public let columnWidths: [CGFloat]
        /// Row heights in natural grid order: `[0]` is the header row,
        /// `[1..N]` are body rows.
        public let rowHeights: [CGFloat]
        /// `rowHeights.reduce(0, +)` — the full grid's vertical extent
        /// before any focus-ring padding or table-level margins.
        public let totalHeight: CGFloat
    }

    // MARK: - Layout constants
    //
    // Originally ported verbatim from the deleted `InlineTableView`
    // widget (slice 2e-T2-h). These values are now the sole source of
    // truth for grid measurement.

    /// Minimum column width. Matches `InlineTableView.minColumnWidth`.
    public static let minColumnWidth: CGFloat = 80

    /// Horizontal cell padding, derived from `marginSize`. Matches
    /// `InlineTableView.cellPaddingH`.
    ///
    /// Public as of 2e-T2-c so `TableLayoutFragment.draw(at:in:)` can
    /// inset per-cell rects by the same horizontal padding that
    /// `wrappedCellHeight` used during measurement. Keeping the source
    /// of truth in one place prevents measure/draw drift.
    public static func cellPaddingH() -> CGFloat {
        return max(3, ceil(CGFloat(UserDefaultsManagement.marginSize) * 0.2))
    }

    /// Vertical cell padding (top), derived from `editorLineSpacing`.
    /// Matches `InlineTableView.cellPaddingTop`. Public for 2e-T2-c.
    public static func cellPaddingTop() -> CGFloat {
        return max(2, ceil(CGFloat(UserDefaultsManagement.editorLineSpacing) * 0.75))
    }

    /// Vertical cell padding (bottom). Matches
    /// `InlineTableView.cellPaddingBot`. Public for 2e-T2-c.
    public static func cellPaddingBot() -> CGFloat {
        return max(2, ceil(CGFloat(UserDefaultsManagement.editorLineSpacing) * 0.75))
    }

    /// Extra width per column for text measurement, scales with margin.
    /// Matches `InlineTableView.columnTextPadding`.
    private static func columnTextPadding() -> CGFloat {
        return max(16, ceil(CGFloat(UserDefaultsManagement.marginSize)))
    }

    /// The `focusRingPadding` constant from `InlineTableView`. Used by
    /// the width-auto-wrap path to compute available column space.
    /// Public for 2e-T2-c: `TableLayoutFragment` adds the same padding
    /// to its rendering-surface width so grid strokes at the right edge
    /// don't get clipped.
    public static let focusRingPadding: CGFloat = 8

    /// Left margin reserved for drag handles. Matches
    /// `InlineTableView.currentLeftMargin` (= `handleBarWidth`). Public
    /// for 2e-T2-c so the fragment draws the grid starting at the same
    /// x-offset the widget uses, preserving visual parity.
    public static let handleBarWidth: CGFloat = 18

    /// Top margin reserved for column drag handles. Mirrors
    /// `InlineTableView.handleBarHeight`. Public as of 2e-T2-g so
    /// `TableLayoutFragment` and the `TableHandleOverlay` agree on the
    /// strip height above the header row where column handles sit.
    public static let handleBarHeight: CGFloat = 18

    // MARK: - Rendered cell text
    //
    // Runs the cell's inline tree through `InlineRenderer` with the
    // given font + alignment, re-applies the paragraph style uniformly
    // so alignment takes effect across runs, and replaces the HTML
    // `<br>` token with a real newline. The replacement is load-bearing
    // for measurement: cells store multi-line content as `<br>` but
    // measure as wrapped lines.
    //
    // Shared between `TableGeometry`'s measurement path and
    // `TableLayoutFragment`'s draw path so measured heights always
    // match painted heights.

    internal static func renderCellAttributedString(
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
        let rendered = InlineRenderer.render(cell.inline, baseAttributes: attrs, note: nil)
        let mutable = NSMutableAttributedString(attributedString: rendered)
        if mutable.length > 0 {
            mutable.addAttribute(
                .paragraphStyle, value: para,
                range: NSRange(location: 0, length: mutable.length)
            )
        }
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

    // MARK: - Min cell height

    /// Natural one-line rendered height + vertical padding. Mirrors
    /// `InlineTableView.minCellHeight`. Measured from the actual font
    /// via `usesFontLeading` so single-line cells are tight.
    private static func minCellHeight(font: NSFont) -> CGFloat {
        let natural = ceil(
            NSAttributedString(string: "X", attributes: [.font: font])
                .boundingRect(
                    with: NSSize(
                        width: CGFloat.greatestFiniteMagnitude,
                        height: CGFloat.greatestFiniteMagnitude
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height
        )
        return natural + cellPaddingTop() + cellPaddingBot()
    }

    // MARK: - Alignment mapping

    /// Block-model `TableAlignment` → AppKit `NSTextAlignment`.
    /// Mirrors `InlineTableView.nsAlignment(for:)`.
    ///
    /// Public as of 2e-T2-c so `TableLayoutFragment` can use the same
    /// alignment-mapping function when it renders per-cell text. Keeping
    /// the mapping in one place prevents drift between geometry
    /// measurement and the draw path.
    public static func nsAlignment(for a: TableAlignment) -> NSTextAlignment {
        switch a {
        case .left, .none: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    // MARK: - wrappedCellHeight (ported verbatim)

    /// Height needed for a cell in a constrained column width. Ported
    /// verbatim from `InlineTableView.wrappedCellHeight`.
    private static func wrappedCellHeight(
        _ cell: TableCell,
        font: NSFont,
        alignment: NSTextAlignment,
        colWidth: CGFloat?
    ) -> CGFloat {
        let minH = minCellHeight(font: font)
        let cellPad = cellPaddingH() * 2
        let rendered = renderCellAttributedString(
            cell: cell, font: font, alignment: alignment
        )
        guard let colWidth = colWidth else {
            // Fallback: count visible lines from the rendered string.
            let displayText = rendered.string
            let lineCount = max(1, displayText.components(separatedBy: "\n").count)
            let fontSize = font.pointSize
            let spacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
            let lineHeight = ceil(fontSize + spacing)
            return max(minH, CGFloat(lineCount) * lineHeight + cellPaddingTop() + cellPaddingBot())
        }
        let availableWidth = max(1, colWidth - cellPad)
        let boundingRect = rendered.boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(minH, ceil(boundingRect.height) + cellPaddingTop() + cellPaddingBot())
    }

    // MARK: - rowHeights (ported verbatim)

    /// Per-row height. Row 0 is the header; rows 1..N are body rows.
    /// Ported verbatim from `InlineTableView.rowHeights`.
    private static func rowHeights(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [NSTextAlignment],
        font: NSFont,
        boldFont: NSFont,
        colWidths: [CGFloat]?
    ) -> [CGFloat] {
        let colCount = header.count
        guard colCount > 0 else { return [] }

        let minH = minCellHeight(font: font)
        var heights: [CGFloat] = []

        // Header row.
        var maxH: CGFloat = minH
        for col in 0..<colCount {
            let alignment = col < alignments.count ? alignments[col] : .left
            let cw = (colWidths != nil && col < colWidths!.count) ? colWidths![col] : nil
            let h = wrappedCellHeight(header[col], font: boldFont, alignment: alignment, colWidth: cw)
            maxH = max(maxH, h)
        }
        heights.append(maxH)

        // Data rows.
        for row in rows {
            maxH = minH
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

    // MARK: - contentBasedColumnWidths (ported verbatim)

    /// Column widths derived from cell content. Ported verbatim from
    /// `InlineTableView.contentBasedColumnWidths`.
    private static func contentBasedColumnWidths(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [NSTextAlignment],
        font: NSFont,
        boldFont: NSFont,
        containerWidth: CGFloat
    ) -> [CGFloat] {
        let colCount = header.count
        guard colCount > 0 else { return [] }

        let padding: CGFloat = columnTextPadding()

        func renderedMaxLineWidth(_ cell: TableCell, alignment: NSTextAlignment, font: NSFont) -> CGFloat {
            let attributed = renderCellAttributedString(
                cell: cell, font: font, alignment: alignment
            )
            let displayText = attributed.string
            let lines = displayText.components(separatedBy: "\n")
            if lines.count <= 1 {
                return attributed.size().width
            }
            var maxWidth: CGFloat = 0
            var offset = 0
            for line in lines {
                let lineLen = (line as NSString).length
                if lineLen == 0 {
                    offset += 1
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
            let hw = renderedMaxLineWidth(header[col], alignment: alignment, font: boldFont) + padding
            widths[col] = max(widths[col], hw)
            for row in rows {
                if col < row.count {
                    let cw = renderedMaxLineWidth(row[col], alignment: alignment, font: font) + padding
                    widths[col] = max(widths[col], cw)
                }
            }
        }

        // Auto-wrap: if total width exceeds available space, shrink wide columns.
        let availableWidth = containerWidth - handleBarWidth - focusRingPadding
        let totalWidth = widths.reduce(0, +)
        if totalWidth > availableWidth && availableWidth > 0 {
            let fairShare = availableWidth / CGFloat(colCount)
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

    // MARK: - Public entry point

    /// Compute column widths, row heights, and total grid height for
    /// a block-model table given the container width and the note
    /// font. This is the public contract the T2 dispatch path will
    /// consume.
    public static func compute(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        containerWidth: CGFloat,
        font: NSFont,
        columnWidthsOverride: [CGFloat]? = nil
    ) -> Result {
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let nsAlignments = alignments.map { nsAlignment(for: $0) }
        // T2-g.4: authoritative widths override content measurement
        // when well-shaped; otherwise fall back to content-based widths.
        let colWidths: [CGFloat]
        if let override = columnWidthsOverride,
           override.count == header.count,
           override.allSatisfy({ $0 > 0 }) {
            colWidths = override
        } else {
            colWidths = contentBasedColumnWidths(
                header: header,
                rows: rows,
                alignments: nsAlignments,
                font: font,
                boldFont: boldFont,
                containerWidth: containerWidth
            )
        }
        let rHeights = rowHeights(
            header: header,
            rows: rows,
            alignments: nsAlignments,
            font: font,
            boldFont: boldFont,
            colWidths: colWidths
        )
        let total = rHeights.reduce(0, +)
        return Result(
            columnWidths: colWidths,
            rowHeights: rHeights,
            totalHeight: total
        )
    }
}
