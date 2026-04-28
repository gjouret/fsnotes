//
//  TableReader.swift
//  FSNotesCore
//
//  Phase 12.C.5 — Block parsing port: pipe tables (GFM extension).
//
//  GFM pipe tables — header row of pipe-delimited cells, separator
//  row whose cells are runs of `-` with optional leading/trailing `:`
//  for alignment, then zero or more body rows. Two detection modes:
//
//    (a) `lines[start]` is the header, `lines[start+1]` is the separator.
//    (b) `rawBuffer.last` is the header (already buffered as a
//        paragraph line by the parser), `lines[start]` is the
//        separator.
//
//  Spec bucket: GFM extension; not part of base CommonMark.
//
//  Self-contained: this reader owns row-splitting (`parseRow`),
//  separator validation (`isSeparator`), and alignment extraction
//  (`parseAlignments`). It calls back into the caller's
//  `parseInlines` to convert each cell's raw text into an `[Inline]`
//  tree, mirroring the way the legacy `detectTable` used
//  `parseInlines(_:refDefs:)` — refDefs are intentionally empty for
//  cells (link refs don't cross block boundaries inside a table).
//

import Foundation

public enum TableReader {

    public struct ReadResult {
        public let block: Block
        public let nextIndex: Int
        /// True when the header row came from `rawBuffer.last` rather
        /// than `lines[start]`. The caller must drop the buffered
        /// header line before flushing the paragraph buffer.
        public let headerFromBuffer: Bool
    }

    /// Try to read a pipe table starting at `lines[start]` (mode a) or
    /// using `rawBuffer.last` as the header line (mode b). Returns nil
    /// if neither mode finds a valid header + separator pair.
    public static func read(
        lines: [String],
        at start: Int,
        rawBuffer: [String],
        trailingNewline: Bool,
        parseInlines: (String) -> [Inline]
    ) -> ReadResult? {
        // Mode (a): current line is header, next line is separator.
        if start + 1 < lines.count {
            let headerLine = lines[start]
            let sepLine = lines[start + 1]
            let sepIsSyntheticTerminator =
                start + 1 == lines.count - 1 && sepLine.isEmpty && trailingNewline
            if !sepIsSyntheticTerminator,
               isRow(headerLine),
               isSeparator(sepLine) {
                let result = collect(
                    lines: lines,
                    headerLine: headerLine,
                    sepLine: sepLine,
                    bodyStart: start + 2,
                    trailingNewline: trailingNewline,
                    parseInlines: parseInlines
                )
                return ReadResult(
                    block: result.block,
                    nextIndex: result.nextIndex,
                    headerFromBuffer: false
                )
            }
        }

        // Mode (b): rawBuffer.last is the header, current line is separator.
        if !rawBuffer.isEmpty, isSeparator(lines[start]) {
            let headerLine = rawBuffer.last!
            guard isRow(headerLine) else { return nil }
            let sepLine = lines[start]
            let result = collect(
                lines: lines,
                headerLine: headerLine,
                sepLine: sepLine,
                bodyStart: start + 1,
                trailingNewline: trailingNewline,
                parseInlines: parseInlines
            )
            return ReadResult(
                block: result.block,
                nextIndex: result.nextIndex,
                headerFromBuffer: true
            )
        }

        return nil
    }

    // MARK: - Public detection helpers

    /// Whether `line` looks like a table row (contains at least one `|`).
    public static func isRow(_ line: String) -> Bool {
        line.contains("|")
    }

    /// Whether `line` is a valid separator row: all cells contain only
    /// `-`, `:`, and spaces, with at least one `-` per cell.
    public static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return false }
        let cells = parseRow(line)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            if c.isEmpty { return false }
            for ch in c {
                guard ch == "-" || ch == ":" || ch == " " else { return false }
            }
            guard c.contains("-") else { return false }
        }
        return true
    }

    /// Parse the column alignments from a separator row.
    public static func parseAlignments(_ line: String) -> [TableAlignment] {
        let cells = parseRow(line)
        return cells.map { cell -> TableAlignment in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            if left { return .left }
            return .none
        }
    }

    /// Split a pipe-delimited row into cell strings, trimming
    /// whitespace from each cell. Handles leading and trailing `|`.
    public static func parseRow(_ line: String) -> [String] {
        var work = line
        let trimmed = work.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            work = String(trimmed.dropFirst())
        }
        if work.hasSuffix("|") {
            work = String(work.dropLast())
        }
        let parts = work.split(separator: "|", omittingEmptySubsequences: false)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Internals

    private struct CollectResult {
        let block: Block
        let nextIndex: Int
    }

    /// Build the `Block.table` value from a header line, a separator
    /// line, and the body-row range `[bodyStart, ...)`. Stops at the
    /// first non-row line OR the synthetic trailing empty line.
    private static func collect(
        lines: [String],
        headerLine: String,
        sepLine: String,
        bodyStart: Int,
        trailingNewline: Bool,
        parseInlines: (String) -> [Inline]
    ) -> CollectResult {
        let headerStrings = parseRow(headerLine)
        let alignments = parseAlignments(sepLine)
        let colCount = headerStrings.count
        let headerCells = headerStrings.map {
            TableCell(parseInlines($0))
        }

        var dataRows: [[TableCell]] = []
        var j = bodyStart
        while j < lines.count {
            let l = lines[j]
            if j == lines.count - 1 && l.isEmpty && trailingNewline { break }
            guard isRow(l) else { break }
            var rowStrings = parseRow(l)
            // Pad or truncate to match header column count.
            while rowStrings.count < colCount { rowStrings.append("") }
            if rowStrings.count > colCount {
                rowStrings = Array(rowStrings.prefix(colCount))
            }
            let rowCells = rowStrings.map {
                TableCell(parseInlines($0))
            }
            dataRows.append(rowCells)
            j += 1
        }

        return CollectResult(
            block: .table(
                header: headerCells,
                alignments: alignments,
                rows: dataRows,
                columnWidths: nil
            ),
            nextIndex: j
        )
    }
}
