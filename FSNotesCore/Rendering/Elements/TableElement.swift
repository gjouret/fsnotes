//
//  TableElement.swift
//  FSNotesCore
//
//  Active TK2 element class for tables; dispatched by
//  `BlockModelContentStorageDelegate` and routed to
//  `TableLayoutFragment` by `BlockModelLayoutManagerDelegate`. The
//  attributed string concatenates cell text separated by U+001F (UNIT
//  SEPARATOR) within a row and U+001E (RECORD SEPARATOR) between rows;
//  the authoritative `Block.table` payload is carried alongside so
//  downstream dispatch can reconstruct alignments / widths without
//  re-parsing the flat string.
//

import AppKit

/// Single `NSTextElement` that represents an entire markdown table
/// under the TK2 native-cell path.
public final class TableElement: NSTextParagraph {

    // MARK: - Separator characters

    /// U+001F — inserted between cells within the same row.
    public static let cellSeparator: Character = "\u{001F}"

    /// U+001E — inserted between rows (including between the header
    /// row and the first body row).
    public static let rowSeparator: Character = "\u{001E}"

    /// String form of `cellSeparator`, useful for concatenation.
    public static let cellSeparatorString: String = String(cellSeparator)

    /// String form of `rowSeparator`, useful for concatenation.
    public static let rowSeparatorString: String = String(rowSeparator)

    // MARK: - Block-model payload

    /// The authoritative `Block.table` value this element represents.
    /// Downstream readers (geometry, fragment draw, save path) read
    /// `header`/`alignments`/`rows`/`columnWidths` off this payload to
    /// drive grid geometry and serialization without re-parsing the
    /// attributed string.
    public let block: Block

    // MARK: - Init

    /// Build a `TableElement` from a `Block.table` value plus a
    /// pre-rendered attributed string. The caller owns the attributed
    /// string shape — see the separator helpers below for the encoding
    /// 2e-T2-b will adopt.
    ///
    /// Returns `nil` if `block` is not a `.table` case; the element
    /// contract requires a table-shaped payload.
    public init?(block: Block, attributedString: NSAttributedString) {
        guard case .table = block else { return nil }
        self.block = block
        super.init(attributedString: attributedString)
    }

    // MARK: - Separator encoding (for 2e-T2-b to use)

    /// Encode the block's cells into a single flat string using
    /// `cellSeparator` between cells in a row and `rowSeparator`
    /// between rows. Header row comes first, then `rowSeparator`,
    /// then body rows.
    ///
    /// Pure function — no AppKit types, no side effects. Present here
    /// so 2e-T2-b can emit the attributed string without re-deriving
    /// the encoding from scratch; NOT called by anyone in this slice.
    public static func encodeFlatText(
        header: [TableCell],
        rows: [[TableCell]]
    ) -> String {
        var parts: [String] = []
        parts.append(
            header.map { $0.rawText }.joined(separator: cellSeparatorString)
        )
        for row in rows {
            parts.append(
                row.map { $0.rawText }.joined(separator: cellSeparatorString)
            )
        }
        return parts.joined(separator: rowSeparatorString)
    }

    /// Decode a flat separator-encoded string back into per-row /
    /// per-cell raw markdown strings. Inverse of `encodeFlatText`.
    /// Returns `(header, body)` where `header` is the first decoded
    /// row and `body` is everything after it.
    ///
    /// Pure function — no AppKit types, no side effects. Present here
    /// for 2e-T2-b to use during cell-edit read-back; NOT called by
    /// anyone in this slice.
    public static func decodeFlatText(
        _ flat: String
    ) -> (header: [String], body: [[String]]) {
        let rows = flat
            .split(separator: rowSeparator, omittingEmptySubsequences: false)
            .map { String($0) }
        guard let first = rows.first else {
            return (header: [], body: [])
        }
        let header = first
            .split(separator: cellSeparator, omittingEmptySubsequences: false)
            .map { String($0) }
        let body: [[String]] = rows.dropFirst().map { row in
            row.split(separator: cellSeparator, omittingEmptySubsequences: false)
                .map { String($0) }
        }
        return (header: header, body: body)
    }

    // MARK: - Cursor locator (2e-T2-d)
    //
    // The flat, separator-encoded attributed string produced by
    // `TableTextRenderer.renderNative(...)` lays out as:
    //
    //     <header cell 0>US<header cell 1>US…US<header cell M-1>
    //     RS<body 0 cell 0>US…US<body 0 cell M-1>
    //     RS<body 1 cell 0>US…
    //
    // where `US` = U+001F (cell separator) and `RS` = U+001E (row
    // separator). The header row is `row = 0`; body rows are
    // `row = 1, 2, …`. Column indexing is 0-based within each row.
    //
    // Both helpers operate on *element-local* UTF-16 offsets — i.e.
    // offsets into `self.attributedString.string`. Callers convert
    // global storage offsets to element-local ones via
    // `NSTextContentStorage.offset(from: elementRange.location, …)`.
    //
    // They are pure functions over the decoded `block` payload — no
    // AppKit mutation, no attributed-string walk. That keeps them
    // unit-testable without an `NSWindow` (CLAUDE.md rule 3).

    /// Given an element-local UTF-16 offset, return the cell
    /// `(row, col)` the offset lives inside. Returns `nil` when
    /// `offset` lands exactly on a separator character (U+001F /
    /// U+001E) or falls outside the element.
    ///
    /// Semantic contract: `offset` is inside a cell iff it is in
    /// the half-open range `[cellStart, cellEnd)`, where `cellEnd`
    /// is the index of the following separator (or the end of the
    /// element for the last cell). `offset == cellEnd` is *not*
    /// inside the cell — it's on / past the separator.
    ///
    /// Exception: an offset at the very end of the last body cell
    /// (i.e. at `element.length`) is considered inside that cell,
    /// so a cursor parked at end-of-table still resolves. This
    /// mirrors NSText behaviour where cursor-at-length is a valid
    /// selection.
    public func cellLocation(forOffset offset: Int) -> (row: Int, col: Int)? {
        let string = attributedString.string as NSString
        let length = string.length
        guard offset >= 0, offset <= length else { return nil }

        let cellSep: unichar = unichar(Self.cellSeparator.unicodeScalars.first!.value)
        let rowSep: unichar = unichar(Self.rowSeparator.unicodeScalars.first!.value)

        var row = 0
        var col = 0
        var cellStart = 0
        var i = 0
        // Walk character by character. On each separator we snapshot
        // whether the incoming offset fell inside the just-closed cell
        // and either return it or advance the (row, col) cursor.
        while i < length {
            let ch = string.character(at: i)
            let isCellSep = (ch == cellSep)
            let isRowSep = (ch == rowSep)
            if isCellSep || isRowSep {
                // Non-empty cell: offset in [cellStart, i).
                if cellStart < i, offset >= cellStart, offset < i {
                    return (row: row, col: col)
                }
                // Empty cell (cellStart == i): the cell has no
                // content range, but the position AT the separator
                // IS the cell's insertion point. Resolve to (row,
                // col) so cursor placement and edit routing can
                // target empty cells. Without this, typing into a
                // freshly-inserted empty table fails because every
                // cell's offset is also a separator position.
                if cellStart == i, offset == i {
                    return (row: row, col: col)
                }
                if isCellSep {
                    col += 1
                } else {
                    row += 1
                    col = 0
                }
                cellStart = i + 1
            }
            i += 1
        }
        // Tail cell — from last separator to end of element. Note the
        // closed upper bound: cursor-at-end-of-table resolves to the
        // last cell.
        if offset >= cellStart && offset <= length {
            return (row: row, col: col)
        }
        return nil
    }

    /// Cursor-aware variant of `cellLocation(forOffset:)`. Where the
    /// strict locator returns `nil` for offsets that land exactly on
    /// a separator character (U+001F / U+001E), this variant resolves
    /// such an offset to the cell whose content immediately precedes
    /// the separator. This matches the natural cursor semantics: a
    /// caret parked at the END of a cell's content sits on the
    /// following separator (or at the element's tail for the very
    /// last cell), but the user perceives the cursor as being inside
    /// that cell — Tab from there should advance to the NEXT cell,
    /// not be interpreted as "no cell selected" and fall through to
    /// the default tab-character insertion.
    ///
    /// Used by `EditTextView+TableNav.tableCursorContext()` and
    /// `EditTextView.caretRectIfInTableCell()` so cursor-at-cell-end
    /// (the natural park position after click-to-cell) routes
    /// through table-aware handling instead of falling back to TK2's
    /// natural-flow defaults.
    public func cellAtCursor(forOffset offset: Int) -> (row: Int, col: Int)? {
        if let strict = cellLocation(forOffset: offset) {
            return strict
        }
        // Strict locator returned nil — offset is either out of range
        // or sits exactly on a separator. For the latter, walk
        // backwards one step: the preceding character is the last
        // content character of the cell whose end the cursor is
        // parked at. (For an empty cell whose offset == separator
        // position, `cellLocation` already resolves it via the
        // `cellStart == i, offset == i` branch — so a nil here
        // implies a non-empty preceding cell.)
        let length = (attributedString.string as NSString).length
        guard offset > 0, offset <= length else { return nil }
        return cellLocation(forOffset: offset - 1)
    }

    /// Element-local UTF-16 range of the cell at `(row, col)`. The
    /// range covers the cell's content characters — from the first
    /// character after the preceding separator (or element start) up
    /// to the next separator (or element end). Returns `nil` if the
    /// coordinate is out of range.
    ///
    /// Used by 2e-T2-e to splice a new cell substring into the
    /// separator-encoded storage without disturbing the surrounding
    /// separators.
    public func cellRange(forCellAt position: (row: Int, col: Int)) -> NSRange? {
        guard let start = offset(forCellAt: position) else { return nil }
        let string = attributedString.string as NSString
        let length = string.length
        let cellSep: unichar = unichar(Self.cellSeparator.unicodeScalars.first!.value)
        let rowSep: unichar = unichar(Self.rowSeparator.unicodeScalars.first!.value)
        var end = start
        while end < length {
            let ch = string.character(at: end)
            if ch == cellSep || ch == rowSep { break }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// Given a `(row, col)` coordinate, return the element-local
    /// UTF-16 offset of the FIRST content character of that cell.
    /// Returns `nil` if `(row, col)` is out of range for the block
    /// shape carried on this element.
    ///
    /// For an empty cell, the returned offset is the index of the
    /// cell's opening character — which, being empty, is the
    /// immediately-following separator (or the end of the element
    /// for a trailing empty cell). Callers placing the cursor at
    /// this offset get a valid insertion point; the locator stays
    /// consistent because `cellLocation(forOffset: offset(for: …))`
    /// round-trips by construction (see tests).
    public func offset(forCellAt position: (row: Int, col: Int)) -> Int? {
        guard case .table(let header, _, let rows, _) = block else {
            return nil
        }
        let columns = header.count
        guard position.col >= 0, position.col < columns else { return nil }
        guard position.row >= 0, position.row <= rows.count else { return nil }

        let string = attributedString.string as NSString
        let length = string.length
        let cellSep: unichar = unichar(Self.cellSeparator.unicodeScalars.first!.value)
        let rowSep: unichar = unichar(Self.rowSeparator.unicodeScalars.first!.value)

        var row = 0
        var col = 0
        var cellStart = 0
        var i = 0
        while i < length {
            if row == position.row && col == position.col {
                return cellStart
            }
            let ch = string.character(at: i)
            if ch == cellSep {
                col += 1
                cellStart = i + 1
            } else if ch == rowSep {
                row += 1
                col = 0
                cellStart = i + 1
            }
            i += 1
        }
        // Tail case: the last cell opens exactly at cellStart and
        // runs to length. If the requested (row, col) identifies
        // it, return cellStart.
        if row == position.row && col == position.col {
            return cellStart
        }
        return nil
    }
}
