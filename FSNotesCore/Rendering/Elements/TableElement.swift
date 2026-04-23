//
//  TableElement.swift
//  FSNotesCore
//
//  Phase 2e-T2-a — Additive foundation for the TK2 native-cell table
//  path. This class is dead code on disk: no dispatch path instantiates
//  it, no layout manager consults it, no content-storage delegate vends
//  it. Later slices will wire it in.
//
//  Design (from the T2 spike):
//    * Each table will be ONE `NSTextElement` whose `attributedString`
//      concatenates cell text. Cells within a row are separated by
//      U+001F (UNIT SEPARATOR); rows are separated by U+001E (RECORD
//      SEPARATOR). The header row comes first, followed by a single
//      header/body boundary separator (U+001E), then the body rows.
//    * The element carries the authoritative `Block.table` payload so
//      downstream dispatch can reconstruct the structural shape without
//      re-parsing the attributed string. The attributed string remains
//      the source of truth for TextFinder / selection / accessibility.
//
//  This slice only ships the type and the separator-encoding helpers.
//  Slice 2e-T2-b will stand up the emission path (feature flag + content
//  storage delegate) and slice 2e-T2-c will override layout-fragment
//  dispatch on the element's concrete class.
//

import AppKit

/// Single `NSTextElement` that represents an entire markdown table
/// under the TK2 native-cell path. Dead code as of 2e-T2-a — no
/// production code path constructs this yet.
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
    /// Downstream slices read `header`/`alignments`/`rows`/`raw` off
    /// this payload to drive grid geometry and serialization without
    /// re-parsing the attributed string.
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
}
