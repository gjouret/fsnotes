//
//  ListBlockEditor.swift
//  FSNotesCore
//
//  Phase 12.B.5 — Per-block-kind dispatch (list kind).
//
//  Lists are the most structurally-rich block kind: a tree of
//  `ListItem`s with arbitrary nesting. The actual editing logic
//  remains in the well-tested `EditingOps.{insertIntoList,
//  deleteInList, replaceInList}` helpers (≈300 LoC of list-FSM
//  awareness, prefix-aware offset translation, sibling/child
//  reconstruction). This editor is a thin protocol-conformant wrapper
//  around those helpers — it gets paragraph-style isolation without
//  rewriting the list FSM logic that has 485 LoC of pinning tests in
//  `ListEditingFSMTests`.
//
//  A future Phase 12.B.X could move the list FSM helpers into this
//  type (or split into a dedicated `ListBlockEditors/` subdirectory).
//  For now: wrapper.
//

import Foundation

#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// In-block editor for the `.list(items:loose:)` block kind.
public enum ListBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "ListBlockEditor.insert called with non-list block")
        }
        return try EditingOps.insertIntoList(
            items: items, offsetInBlock: offsetInBlock, string: string
        )
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "ListBlockEditor.delete called with non-list block")
        }
        return try EditingOps.deleteInList(items: items, from: fromOffset, to: toOffset)
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "ListBlockEditor.replace called with non-list block")
        }
        return try EditingOps.replaceInList(
            items: items, from: fromOffset, to: toOffset, with: replacement
        )
    }
}
