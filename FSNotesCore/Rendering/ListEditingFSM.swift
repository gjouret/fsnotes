//
//  ListEditingFSM.swift
//  FSNotesCore
//
//  Finite state machine for list editing in the block-model pipeline.
//
//  The FSM defines states (where the cursor is), actions (what the user
//  did), and transitions (what happens to the document). It is a PURE
//  FUNCTION: (State, Action) → Transition. The caller (EditTextView or
//  EditingOps) applies the transition to the Document.
//
//  STATES:
//    .bodyText         — cursor is in a non-list block (paragraph, heading, etc.)
//    .listItem(depth)  — cursor is inside a list item at nesting depth `depth`
//                         (0 = top-level item, 1 = child of top-level, etc.)
//
//  ACTIONS:
//    .tab              — Tab key pressed
//    .shiftTab         — Shift+Tab pressed
//    .deleteAtHome     — Backspace pressed at offset 0 of item's inline content
//    .returnKey        — Return pressed on a non-empty item
//    .returnOnEmpty    — Return pressed on an item with empty inline content
//
//  TRANSITIONS:
//    .indent           — Move item one level deeper (become child of prev sibling)
//    .unindent         — Move item one level shallower (become sibling of parent)
//    .exitToBody       — Remove item from list, convert to paragraph
//    .newItem          — Insert new empty item after current at same depth
//    .noOp             — Do nothing (action not applicable in this state)
//

import Foundation

public enum ListEditingFSM {

    // MARK: - State

    /// The cursor's structural position.
    public enum State: Equatable {
        /// Cursor is not inside any list block.
        case bodyText
        /// Cursor is inside a list item at the given nesting depth.
        /// depth 0 = top-level item.
        case listItem(depth: Int, hasPreviousSibling: Bool)
    }

    // MARK: - Action

    /// A user action that the FSM responds to.
    public enum Action: Equatable {
        /// Tab key pressed.
        case tab
        /// Shift+Tab pressed.
        case shiftTab
        /// Backspace at position 0 of the item's inline content.
        case deleteAtHome
        /// Return key pressed, item has non-empty content.
        case returnKey
        /// Return key pressed, item's inline content is empty.
        case returnOnEmpty
    }

    // MARK: - Transition

    /// The structural mutation to apply.
    public enum Transition: Equatable {
        /// Move item one level deeper (child of previous sibling).
        case indent
        /// Move item one level shallower (sibling of parent).
        case unindent
        /// Remove item from list, convert to body paragraph.
        case exitToBody
        /// Insert a new empty item after the current one at the same depth.
        case newItem
        /// No structural change.
        case noOp
    }

    // MARK: - Transition function

    /// Pure transition: (state, action) → transition.
    ///
    /// This is the core of the FSM. Every list editing behavior is
    /// defined here in one place.
    public static func transition(
        state: State,
        action: Action
    ) -> Transition {
        switch (state, action) {

        // --- bodyText: no list operations ---
        case (.bodyText, _):
            return .noOp

        // --- depth 0: top-level item ---
        case (.listItem(depth: 0, hasPreviousSibling: true), .tab):
            return .indent
        case (.listItem(depth: 0, hasPreviousSibling: false), .tab):
            // Can't indent the first item — no previous sibling to nest under.
            return .noOp
        case (.listItem(depth: 0, _), .shiftTab):
            return .exitToBody
        case (.listItem(depth: 0, _), .deleteAtHome):
            return .exitToBody
        case (.listItem(depth: 0, _), .returnKey):
            return .newItem
        case (.listItem(depth: 0, _), .returnOnEmpty):
            return .exitToBody

        // --- depth > 0: nested item ---
        case (.listItem(depth: _, hasPreviousSibling: true), .tab):
            return .indent
        case (.listItem(depth: _, hasPreviousSibling: false), .tab):
            return .noOp
        case (.listItem(depth: _, _), .shiftTab):
            return .unindent
        case (.listItem(depth: _, _), .deleteAtHome):
            return .unindent
        case (.listItem(depth: _, _), .returnKey):
            return .newItem
        case (.listItem(depth: _, _), .returnOnEmpty):
            return .unindent
        }
    }

    // MARK: - State detection

    /// Determine the FSM state for a cursor position in a document
    /// projection. Returns `.bodyText` if the cursor is not in a list
    /// block, or `.listItem(depth:hasPreviousSibling:)` with the
    /// item's nesting depth and whether it has a previous sibling.
    public static func detectState(
        storageIndex: Int,
        in projection: DocumentProjection
    ) -> State {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            return .bodyText
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items, _) = block else {
            return .bodyText
        }

        let entries = EditingOps.flattenListPublic(items)
        guard let (entryIdx, _) = EditingOps.listEntryContainingPublic(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            // Cursor is on the visual prefix, not in inline content.
            // Treat as the nearest item. Find the nearest entry.
            if let nearest = nearestEntry(entries: entries, offset: offsetInBlock) {
                return .listItem(
                    depth: nearest.depth,
                    hasPreviousSibling: hasPreviousSiblingAtPath(items: items, path: nearest.path)
                )
            }
            return .bodyText
        }
        let entry = entries[entryIdx]
        return .listItem(
            depth: entry.depth,
            hasPreviousSibling: hasPreviousSiblingAtPath(items: items, path: entry.path)
        )
    }

    /// Whether the cursor is at the home position (offset 0) of a list
    /// item's inline content.
    public static func isAtHomePosition(
        storageIndex: Int,
        in projection: DocumentProjection
    ) -> Bool {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            return false
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items, _) = block else {
            return false
        }
        let entries = EditingOps.flattenListPublic(items)
        guard let (entryIdx, inlineOffset) = EditingOps.listEntryContainingPublic(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            return false
        }
        return inlineOffset == 0
    }

    /// Whether the current list item has empty inline content.
    public static func isCurrentItemEmpty(
        storageIndex: Int,
        in projection: DocumentProjection
    ) -> Bool {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            return false
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items, _) = block else {
            return false
        }
        let entries = EditingOps.flattenListPublic(items)
        guard let (entryIdx, _) = EditingOps.listEntryContainingPublic(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            return false
        }
        return entries[entryIdx].inlineLength == 0
    }

    // MARK: - Helpers

    /// Find the nearest flat entry to a given offset (for when offset
    /// falls on a prefix/separator).
    private static func nearestEntry(
        entries: [EditingOps.PublicFlatListEntry],
        offset: Int
    ) -> EditingOps.PublicFlatListEntry? {
        var best: EditingOps.PublicFlatListEntry?
        var bestDist = Int.max
        for entry in entries {
            let inlineStart = entry.startOffset + entry.prefixLength
            let dist = abs(offset - inlineStart)
            if dist < bestDist {
                bestDist = dist
                best = entry
            }
        }
        return best
    }

    /// Check whether the item at `path` has a previous sibling in the
    /// item tree.
    private static func hasPreviousSiblingAtPath(
        items: [ListItem],
        path: [Int]
    ) -> Bool {
        guard let last = path.last else { return false }
        return last > 0
    }
}
