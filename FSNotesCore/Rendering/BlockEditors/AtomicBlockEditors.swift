//
//  AtomicBlockEditors.swift
//  FSNotesCore
//
//  Phase 12.B.4 — Per-block-kind dispatch (atomic / read-only kinds).
//
//  Three editors live together because their per-primitive bodies are
//  trivially small and they share a single conceptual model: blocks
//  with no editable inline content. Splitting them into 3 files would
//  cost more in import / file overhead than the per-kind split saves
//  in cognitive load.
//
//  - `BlankLineBlockEditor`: typing into a blank line CONVERTS it to
//    a paragraph (the one non-trivial behaviour in this group).
//  - `HorizontalRuleBlockEditor`: read-only. Insert throws `unsupported`
//    (the caller's HR-typing path inserts a paragraph above/below the
//    HR rather than mutating the HR itself). Delete is a no-op (cross-
//    block delete via `mergeAdjacentBlocks` handles HR removal).
//  - `TableBlockEditor` (Phase 12.B.4 shell): read-only at the in-block
//    primitive level. Cell editing routes through
//    `EditingOps.replaceTableCellInline` from the editor view layer,
//    NOT through this primitive. A future Phase 12.B.5 may move the
//    cell-edit dispatch here.
//

import Foundation

#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - BlankLineBlockEditor

/// In-block editor for the `.blankLine` block kind.
///
/// Typing into a blank line is the one mutating operation — it converts
/// the blank into a paragraph carrying the inserted text. Delete is a
/// no-op (blank lines have no rendered characters).
public enum BlankLineBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .blankLine = block else {
            throw EditingError.unsupported(reason: "BlankLineBlockEditor.insert called with non-blankLine block")
        }
        return .paragraph(inline: [.text(string)])
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .blankLine = block else {
            throw EditingError.unsupported(reason: "BlankLineBlockEditor.delete called with non-blankLine block")
        }
        return .blankLine
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .blankLine = block else {
            throw EditingError.unsupported(reason: "BlankLineBlockEditor.replace called with non-blankLine block")
        }
        // Blank line has no rendered characters; treat replace as
        // equivalent to "insert into empty content".
        return .paragraph(inline: [.text(replacement)])
    }
}

// MARK: - HorizontalRuleBlockEditor

/// In-block editor for the `.horizontalRule(character:length:)` block kind.
///
/// HR has no editable content. Insert throws `unsupported` so the
/// caller's outer-level insert can detect "typing on the HR" and route
/// to a paragraph above/below instead. Delete is a no-op (cross-block
/// delete via `mergeAdjacentBlocks` removes the HR entirely).
public enum HorizontalRuleBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .horizontalRule = block else {
            throw EditingError.unsupported(reason: "HorizontalRuleBlockEditor.insert called with non-horizontalRule block")
        }
        throw EditingError.unsupported(reason: "horizontalRule is read-only")
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .horizontalRule = block else {
            throw EditingError.unsupported(reason: "HorizontalRuleBlockEditor.delete called with non-horizontalRule block")
        }
        return block
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .horizontalRule = block else {
            throw EditingError.unsupported(reason: "HorizontalRuleBlockEditor.replace called with non-horizontalRule block")
        }
        throw EditingError.unsupported(reason: "horizontalRule is read-only")
    }
}

// MARK: - TableBlockEditor (read-only shell)

/// In-block editor shell for the `.table` block kind.
///
/// Tables are read-only at this primitive level — cell content edits
/// route through `EditingOps.replaceTableCellInline` and structural
/// edits route through `insertTableRow` / `insertTableColumn` /
/// `deleteTableRow` / `deleteTableColumn` / `setTableColumnAlignment`
/// / `setTableColumnWidths`, all called from the view layer, NOT from
/// `insertIntoBlock` / `deleteInBlock`. This shell exists only so the
/// `BlockEditor` protocol is exhaustively conformed across all kinds —
/// the view-layer table edits remain on their existing path.
public enum TableBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .table = block else {
            throw EditingError.unsupported(reason: "TableBlockEditor.insert called with non-table block")
        }
        throw EditingError.unsupported(reason: "table is read-only at the per-character primitive level (use replaceTableCellInline)")
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .table = block else {
            throw EditingError.unsupported(reason: "TableBlockEditor.delete called with non-table block")
        }
        return block
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .table = block else {
            throw EditingError.unsupported(reason: "TableBlockEditor.replace called with non-table block")
        }
        throw EditingError.unsupported(reason: "table is read-only at the per-character primitive level (use replaceTableCellInline)")
    }
}
