//
//  BlockquoteBlockEditor.swift
//  FSNotesCore
//
//  Phase 12.B.6 — Per-block-kind dispatch (blockquote kind).
//
//  Like lists, blockquotes have multi-line internal structure
//  (`[BlockquoteLine]`) and the actual editing logic lives in the
//  well-tested `EditingOps.{insertIntoBlockquote, deleteInBlockquote,
//  replaceInBlockquote}` helpers (≈250 LoC of multi-line awareness).
//  This editor is a thin protocol-conformant wrapper.
//

import Foundation

#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// In-block editor for the `.blockquote(lines:)` block kind.
public enum BlockquoteBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .blockquote(let lines) = block else {
            throw EditingError.unsupported(reason: "BlockquoteBlockEditor.insert called with non-blockquote block")
        }
        return try EditingOps.insertIntoBlockquote(
            lines: lines, offsetInBlock: offsetInBlock, string: string
        )
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .blockquote(let lines) = block else {
            throw EditingError.unsupported(reason: "BlockquoteBlockEditor.delete called with non-blockquote block")
        }
        return try EditingOps.deleteInBlockquote(lines: lines, from: fromOffset, to: toOffset)
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .blockquote(let lines) = block else {
            throw EditingError.unsupported(reason: "BlockquoteBlockEditor.replace called with non-blockquote block")
        }
        return try EditingOps.replaceInBlockquote(
            lines: lines, from: fromOffset, to: toOffset, with: replacement
        )
    }
}
