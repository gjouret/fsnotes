//
//  TableTextRenderer.swift
//  FSNotesCore
//
//  Renders a `Block.table` as a flat, separator-encoded attributed
//  string of cell text — header cells first, then body rows, with
//  `U+001F` between cells and `U+001E` between rows. The range is
//  tagged with `.blockModelKind = .table`; the TK2 content-storage
//  delegate (`BlockModelContentStorageDelegate`) picks up the tag and
//  vends a `TableElement`, which the layout-manager delegate dispatches
//  to `TableLayoutFragment`.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: header cells, data rows, alignments, raw markdown, body font.
//  - Output: NSAttributedString containing the flat cell-text encoding
//    described above. No `U+FFFC` attachment characters — cell text is
//    part of the text view's searchable string natively (Bug #60 fix).
//  - Pure function: same input → equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Renderer

public enum TableTextRenderer {

    /// Phase 8 / Subview Tables — A4. Emits a single-character
    /// attributed string (U+FFFC) carrying a `TableAttachment` that
    /// holds the authoritative `Block.table` payload. The TK2 view
    /// provider on the attachment vends a `TableContainerView` which
    /// paints the cells and (Phase C) hosts per-cell `TableCellTextView`
    /// subviews for editing.
    ///
    /// Used only when `UserDefaultsManagement.useSubviewTables` is
    /// `true`. The current native-cell path stays the default and is
    /// served by `render(...)` below.
    #if os(OSX)
    public static func renderAsAttachment(block: Block) -> NSAttributedString {
        guard case .table = block else { return NSAttributedString() }
        let attachment = TableAttachment(block: block)
        return NSAttributedString(attachment: attachment)
    }
    #endif

    /// Render a table to an attributed string.
    ///
    /// Emits a flat, separator-encoded string of each cell's
    /// inline-rendered attributed text. Header cells come first
    /// (cells joined by U+001F), then U+001E, then body rows (cells
    /// joined by U+001F, rows joined by U+001E). The range is
    /// tagged with `.blockModelKind = .table`; header-cell subranges
    /// additionally carry `.tableHeader = true`. The TK2 content-
    /// storage delegate picks up the tag and vends a `TableElement`.
    public static func render(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont,
        columnWidths: [CGFloat]? = nil
    ) -> NSAttributedString {
        #if os(OSX)
        return renderNative(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: rawMarkdown,
            bodyFont: bodyFont,
            columnWidths: columnWidths
        )
        #else
        // iOS currently has no native-element TK2 path. Return an empty
        // attributed string; iOS rendering is handled by the preview
        // pipeline, not by this function.
        return NSAttributedString()
        #endif
    }

    // MARK: - Native element path

    /// Cells are rendered through the same `InlineRenderer` paragraphs
    /// use; the per-cell attributed strings are concatenated with
    /// U+001F between cells in a row and U+001E between rows. The
    /// result carries `.blockModelKind = .table` so the TK2 content-
    /// storage delegate (`BlockModelContentStorageDelegate`) vends a
    /// `TableElement`, which is then routed to `TableLayoutFragment`
    /// by the layout-manager delegate.
    ///
    /// The separator characters themselves are rendered with `bodyFont`
    /// so they contribute zero visual kerning damage if any downstream
    /// path paints them (`TableLayoutFragment.draw` suppresses
    /// `super.draw` precisely to keep them invisible). They appear in
    /// `.string` — that is the whole point: `NSTextFinder` can see
    /// "Alice"/"Bob" across cells.
    ///
    /// Invariant: the emitted storage contains ZERO `U+FFFC` characters.
    /// A test-time grep asserts this.
    #if os(OSX)
    private static func renderNative(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont,
        columnWidths: [CGFloat]? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
        let cellSep = NSAttributedString(
            string: TableElement.cellSeparatorString,
            attributes: separatorAttrs
        )
        let rowSep = NSAttributedString(
            string: TableElement.rowSeparatorString,
            attributes: separatorAttrs
        )

        // Header row first.
        appendRow(
            to: result,
            cells: header,
            baseAttrs: baseAttrs,
            cellSeparator: cellSep,
            isHeader: true
        )
        // Header → body boundary. Always emit a U+001E, even if there
        // are zero body rows, so the decode path sees an explicit
        // "header done" marker and downstream cell-locator math can
        // index from a stable offset.
        result.append(rowSep)

        // Body rows, row-separated. No trailing separator after the
        // last body row — the element range ends cleanly on cell text.
        for (rowIdx, row) in rows.enumerated() {
            appendRow(
                to: result,
                cells: row,
                baseAttrs: baseAttrs,
                cellSeparator: cellSep,
                isHeader: false
            )
            if rowIdx < rows.count - 1 {
                result.append(rowSep)
            }
        }

        // Tag the entire range with `.blockModelKind = .table` so the
        // content-storage delegate returns a `TableElement`. Also keep
        // the legacy `.renderedBlockType`/`renderedBlockOriginalMarkdown`
        // tags so any code that already introspects for tables (save
        // path, export path, etc.) keeps working.
        //
        // Also tag the authoritative `Block.table` value on the same
        // range. The content-storage delegate reads this back so the
        // `TableElement` it vends has accurate alignments / structural
        // fields (vs. the placeholder decoded from the flat string,
        // which has no alignment information).
        let fullRange = NSRange(location: 0, length: result.length)
        if fullRange.length > 0 {
            result.addAttribute(.blockModelKind, value: BlockModelKind.table.rawValue, range: fullRange)
            result.addAttribute(.renderedBlockType, value: RenderedBlockType.table.rawValue, range: fullRange)
            result.addAttribute(.renderedBlockOriginalMarkdown, value: rawMarkdown, range: fullRange)
            let authBlock: Block = .table(
                header: header,
                alignments: alignments,
                rows: rows,
                columnWidths: columnWidths
            )
            result.addAttribute(
                .tableAuthoritativeBlock,
                value: TableAuthoritativeBlockBox(authBlock),
                range: fullRange
            )
        }

        return result
    }

    /// Append a single table row to `result`: cells are rendered via
    /// `InlineRenderer.render(...)` and joined by `cellSeparator`.
    /// Header cells additionally get `.tableHeader = true` tagged on
    /// their rendered-text range (not on the separator).
    private static func appendRow(
        to result: NSMutableAttributedString,
        cells: [TableCell],
        baseAttrs: [NSAttributedString.Key: Any],
        cellSeparator: NSAttributedString,
        isHeader: Bool
    ) {
        for (cellIdx, cell) in cells.enumerated() {
            let rendered = InlineRenderer.render(
                cell.inline,
                baseAttributes: baseAttrs,
                note: nil,
                theme: .shared
            )
            // Bug #12 + return-in-cell-fragments-the-table: cells must
            // not contain `\n`. NSTextStorage treats `\n` as a paragraph
            // terminator, so even a single `<br>` (which `InlineRenderer`
            // renders as `\n`) splits the table's storage range across
            // multiple paragraphs — and the content-storage delegate
            // returns one `TableElement` per paragraph, producing
            // multiple `TableLayoutFragment`s for a single table block.
            // Substitute `\n` with U+2028 (Unicode LINE SEPARATOR), which
            // NSLayoutManager treats as a soft line break within a
            // paragraph: same visual line break, no paragraph
            // termination, single fragment per table.
            let safe = sanitizeCellNewlines(rendered)
            let start = result.length
            result.append(safe)
            let cellRange = NSRange(location: start, length: result.length - start)
            if isHeader, cellRange.length > 0 {
                result.addAttribute(.tableHeader, value: true, range: cellRange)
            }
            if cellIdx < cells.count - 1 {
                result.append(cellSeparator)
            }
        }
    }

    /// Replace every `\n` (U+000A) in the rendered cell content with
    /// U+2028 (LINE SEPARATOR). Preserves all attributes byte-for-byte
    /// because `NSMutableString.replaceCharacters` on a same-length
    /// substitution doesn't disturb attribute runs. See bug #12 above.
    private static func sanitizeCellNewlines(
        _ rendered: NSAttributedString
    ) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: rendered)
        let str = m.string as NSString
        let len = str.length
        var i = 0
        while i < len {
            if str.character(at: i) == 0x0A {
                m.mutableString.replaceCharacters(
                    in: NSRange(location: i, length: 1),
                    with: "\u{2028}"
                )
            }
            i += 1
        }
        return m
    }
    #endif
}
