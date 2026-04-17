//
//  TableEditing.swift
//  FSNotesCore
//
//  Table cell editing operations.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum TableEditing {

    // state and the save path walked live view attachments to rewrite
    // `Block.table.raw` before serialize. That produced cross-cell
    // data-loss bugs and zero testability.
    //
    // `replaceTableCell(...)` is the pure primitive that puts table
    // cells on the same footing as every other block type: cell edits
    // produce a new `Document` via a pure function on value types, and
    // the view becomes a read-only projection of the current block.
    //
    // Contract:
    //  - Input: a projection, a block index, a `TableCellLocation`, and
    //    the new raw source text for that cell (e.g. `"**foo**"`).
    //  - Output: a new projection whose `.table` at `blockIndex` has
    //    the cell updated AND `raw` recomputed from the structural
    //    fields so `MarkdownSerializer` sees the edit immediately.
    //  - `raw` is recomputed ONLY for edited tables. Untouched tables
    //    keep their exact source text byte-for-byte — this preserves
    //    the byte-equal round-trip invariant for notes that contain
    //    tables the user never edits.
    //  - Errors: `.unsupported` if the block is not a table,
    //    `.outOfBounds` if the row/column index is past the end.

    /// Addresses a single cell within a `Block.table`.
    ///
    /// Tables have two structurally distinct row classes: the header
    /// row (which renders with different typography and cannot be
    /// deleted without removing the whole table) and data rows. A
    /// typed enum forces call sites to declare which one they're
    /// editing, eliminating `-1`-sentinel-style bugs.
    public enum TableCellLocation: Equatable {
        /// The header cell at `col` (0-indexed).
        case header(col: Int)
        /// The data cell at `(row, col)` (both 0-indexed). `row` refers
        /// to `Block.table.rows[row]`, NOT to a display row that
        /// includes the header.
        case body(row: Int, col: Int)
    }

    /// Replace a single cell inside a table block using a raw
    /// markdown source string. The string is parsed via
    /// `MarkdownParser.parseInlines` into an inline tree and
    /// forwarded to `replaceTableCellInline`.
    ///
    /// Preserved as a convenience for callers that already have a
    /// raw markdown string (paste paths, the transitional
    /// `controlTextDidChange` → field-editor.string bridge, tests
    /// that operate at the string layer). New editing paths that
    /// already have an inline tree in hand should call
    /// `replaceTableCellInline` directly — no re-parse.
    ///
    /// Throws `.unsupported` if `blockIndex` does not address a
    /// table block, and `.outOfBounds` if the location addresses a
    /// cell that does not exist.
    public static func replaceTableCell(
        blockIndex: Int,
        at location: TableCellLocation,
        newSourceText: String,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let inline = MarkdownParser.parseInlines(newSourceText, refDefs: [:])
        return try replaceTableCellInline(
            blockIndex: blockIndex,
            at: location,
            inline: inline,
            in: projection
        )
    }

    /// Replace a single cell inside a table block using a pre-parsed
    /// inline tree. This is the Stage 3 primitive: the field editor's
    /// attributed string is converted to `[Inline]` via
    /// `InlineRenderer.inlineTreeFromAttributedString`, and that tree
    /// is passed here. No re-parse, no string round-trip — the edit
    /// flows from user keystroke (attributes on a field-editor run)
    /// to Document mutation without ever touching raw markdown.
    ///
    /// `raw` is recomputed canonically from the new structural fields
    /// so the serializer reflects the edit immediately. Empty inline
    /// trees are allowed (represent empty cells).
    ///
    /// Throws `.unsupported` if `blockIndex` does not address a
    /// table block, and `.outOfBounds` if the location addresses a
    /// cell that does not exist.
    public static func replaceTableCellInline(
        blockIndex: Int,
        at location: TableCellLocation,
        inline: [Inline],
        in projection: DocumentProjection
    ) throws -> EditResult {
        // 1. Destructure and validate.
        guard blockIndex >= 0,
              blockIndex < projection.document.blocks.count else {
            throw EditingError.outOfBounds
        }
        guard case .table(let header, let alignments, let rows, _) =
                projection.document.blocks[blockIndex] else {
            throw EditingError.unsupported(
                reason: "replaceTableCellInline: block \(blockIndex) is not a table"
            )
        }

        // 2. Produce the new header/rows with the target cell rewritten.
        var newHeader = header
        var newRows = rows
        let newCell = TableCell(inline)
        switch location {
        case .header(let col):
            guard col >= 0, col < newHeader.count else {
                throw EditingError.outOfBounds
            }
            newHeader[col] = newCell
        case .body(let row, let col):
            guard row >= 0, row < newRows.count else {
                throw EditingError.outOfBounds
            }
            guard col >= 0, col < newRows[row].count else {
                throw EditingError.outOfBounds
            }
            newRows[row][col] = newCell
        }

        // 3. Recompute `raw` from the new structural fields so the
        //    serializer sees the edit directly.
        let newRaw = rebuildTableRaw(
            header: newHeader, alignments: alignments, rows: newRows
        )

        // 4. Build the new block and route through the standard block
        //    replacement path. `sameBlockKind` routes unchanged-shape
        //    table edits through `replaceBlockFast` — the hot path for
        //    cell typing.
        let newBlock: Block = .table(
            header: newHeader, alignments: alignments,
            rows: newRows, raw: newRaw
        )
        return try replaceBlock(
            atIndex: blockIndex, with: newBlock, in: projection
        )
    }

    /// Rebuild a canonical pipe-delimited representation of a table
    /// from its structural fields. Called by `replaceTableCell` after
    /// every mutation so `Block.table.raw` stays consistent with the
    /// `header` / `alignments` / `rows` it was built from.
    ///
    /// The canonical form is `| cell | cell |` with one space on either
    /// side of each cell, and the separator row uses `---` per column
    /// (with leading/trailing `:` for alignment). Untouched tables do
    /// not pass through this function — they keep whatever source-text
    /// layout the user wrote.
    ///
    /// Public because `InlineTableView` also uses it when pushing its
    /// post-structural-change state (add row, add column, move, etc.)
    /// back into the Document model via `notifyChanged()`.
    public static func rebuildTableRaw(
        header: [TableCell],
        alignments: [TableAlignment],
        rows: [[TableCell]]
    ) -> String {
        func renderRow(_ cells: [TableCell]) -> String {
            if cells.isEmpty { return "|" }
            // Serialize each cell's inline tree back to markdown source.
            // For a cell whose inline tree is [.bold([.text("foo")])]
            // this produces "**foo**", so the rebuilt `raw` contains
            // the same markers the parser will re-read on load.
            let padded = cells.map { " \($0.rawText) " }
            return "|" + padded.joined(separator: "|") + "|"
        }
        func renderSeparator(_ alignments: [TableAlignment], colCount: Int) -> String {
            // Defensive: if alignments array is out of sync with the
            // column count, pad/truncate. This matches the parser's
            // behavior for malformed tables.
            var effective = alignments
            while effective.count < colCount { effective.append(.none) }
            if effective.count > colCount {
                effective = Array(effective.prefix(colCount))
            }
            let cells = effective.map { alignment -> String in
                switch alignment {
                case .none:   return "---"
                case .left:   return ":---"
                case .right:  return "---:"
                case .center: return ":---:"
                }
            }
            if cells.isEmpty { return "|" }
            return "|" + cells.joined(separator: "|") + "|"
        }

        var lines: [String] = []
        lines.append(renderRow(header))
        lines.append(renderSeparator(alignments, colCount: header.count))
        for row in rows {
            // Pad/truncate data rows to match the header column count,
            // mirroring the parser's normalization so round-tripping
            // through the primitive never produces a malformed table.
            var padded = row
            while padded.count < header.count {
                padded.append(TableCell([]))
            }
            if padded.count > header.count {
                padded = Array(padded.prefix(header.count))
            }
            lines.append(renderRow(padded))
        }
        return lines.joined(separator: "\n")
    }

}
