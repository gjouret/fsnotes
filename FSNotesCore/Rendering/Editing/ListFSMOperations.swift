//
//  ListFSMOperations.swift
//  FSNotesCore
//
//  ListEditingFSM transition implementations.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum ListFSMOperations {

    /// the cursor should land (start of the item's inline content in
    /// the re-rendered list).
    public static func indentListItem(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "indentListItem: not a list block")
        }

        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(reason: "indentListItem: cursor not in inline content")
        }
        let entry = entries[entryIdx]

        // Move item to be child of its previous sibling at the same level.
        let newItems = indentItemAtPath(items, path: entry.path)
        guard let newItems = newItems else {
            throw EditingError.unsupported(reason: "indentListItem: no previous sibling to nest under")
        }

        let newBlock = Block.list(items: newItems)
        var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)

        // Find cursor position in re-rendered list: locate the item by
        // walking the new flattened list to find the same content.
        let newEntries = flattenList(newItems)
        // The item moved deeper: its new depth = entry.depth + 1.
        // Find the entry with matching inline length at the new depth.
        if let newEntry = findEntryByContent(entries: newEntries, inline: entry.item.inline, preferDepth: entry.depth + 1) {
            let newInlineStart = result.newProjection.blockSpans[blockIndex].location + newEntry.startOffset + newEntry.prefixLength
            result.newCursorPosition = newInlineStart + inlineOffset
        } else {
            result.newCursorPosition = storageIndex
        }

        return result
    }

    /// Unindent a list item: move it to be the next sibling of its
    /// parent (one level shallower).
    public static func unindentListItem(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "unindentListItem: not a list block")
        }

        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(reason: "unindentListItem: cursor not in inline content")
        }
        let entry = entries[entryIdx]

        guard entry.depth > 0 else {
            throw EditingError.unsupported(reason: "unindentListItem: already at top level")
        }

        let newItems = unindentItemAtPath(items, path: entry.path)
        guard let newItems = newItems else {
            throw EditingError.unsupported(reason: "unindentListItem: cannot unindent")
        }

        let newBlock = Block.list(items: newItems)
        var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)

        let newEntries = flattenList(newItems)
        if let newEntry = findEntryByContent(entries: newEntries, inline: entry.item.inline, preferDepth: entry.depth - 1) {
            let newInlineStart = result.newProjection.blockSpans[blockIndex].location + newEntry.startOffset + newEntry.prefixLength
            result.newCursorPosition = newInlineStart + inlineOffset
        } else {
            result.newCursorPosition = storageIndex
        }

        return result
    }

    /// Exit a list item: remove it from the list and convert it to a
    /// body paragraph. The item is removed from the list, and a new
    /// paragraph block is inserted after the list. If the item was empty,
    /// it is simply deleted and the cursor is placed at the end of the
    /// previous item (or start of list if it was the first item). If this
    /// was the only item, the entire list block is replaced with a paragraph.
    public static func exitListItem(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "exitListItem: not a list block")
        }

        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(reason: "exitListItem: cursor not in inline content")
        }
        let entry = entries[entryIdx]

        // Check if the item being exited is empty
        let isEmpty = isInlineEmpty(entry.item.inline)

        // Remove the item from the tree. Any children of the exiting
        // item are promoted to the same level.
        let remaining = removeItemAtPath(items, path: entry.path, promoteChildren: true)

        // If the item was empty and there are remaining items, just delete it
        // and place cursor at the end of the previous item.
        if isEmpty && !remaining.isEmpty {
            let newBlock = Block.list(items: remaining)
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            
            // Cursor goes to the end of the previous item (if there is one)
            // or the start of the list (if this was the first item)
            let newEntries = flattenList(remaining)
            if entryIdx > 0, entryIdx - 1 < newEntries.count {
                // Place cursor at the end of the previous item's inline content
                let prevEntry = newEntries[entryIdx - 1]
                let prevInlineEnd = prevEntry.startOffset + prevEntry.prefixLength + prevEntry.inlineLength
                result.newCursorPosition = result.newProjection.blockSpans[blockIndex].location + prevInlineEnd
            } else {
                // First item was deleted - cursor at start of list
                result.newCursorPosition = result.newProjection.blockSpans[blockIndex].location
            }
            return result
        }

        // Build the replacement blocks.
        var newBlocks: [Block] = []
        if !remaining.isEmpty {
            newBlocks.append(.list(items: remaining))
        }
        
        // Create a paragraph block for the exited item (only for non-empty items).
        let exitedParagraph: Block = .paragraph(inline: entry.item.inline)
        newBlocks.append(exitedParagraph)

        var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)

        // Cursor goes to the start of the exited paragraph.
        let paraBlockIdx = blockIndex + (remaining.isEmpty ? 0 : 1)
        if paraBlockIdx < result.newProjection.blockSpans.count {
            result.newCursorPosition = result.newProjection.blockSpans[paraBlockIdx].location
        } else {
            result.newCursorPosition = result.newProjection.attributed.length
        }

        return result
    }

    /// Handle Return on an empty list item: either unindent (depth > 0)
    /// or exit to body (depth == 0).
    public static func returnOnEmptyListItem(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let state = ListEditingFSM.detectState(storageIndex: storageIndex, in: projection)
        let transition = ListEditingFSM.transition(state: state, action: .returnOnEmpty)

        switch transition {
        case .unindent:
            return try unindentListItem(at: storageIndex, in: projection)
        case .exitToBody:
            return try exitListItem(at: storageIndex, in: projection)
        default:
            // Shouldn't happen, but fall through to regular split.
            throw EditingError.unsupported(reason: "returnOnEmpty: unexpected transition \(transition)")
        }
    }

    // MARK: - Tree manipulation helpers

    /// Move the item at `path` to be the last child of its previous
    /// sibling. Returns nil if there is no previous sibling.
    /// Updates the item's indent to be parent's indent + 2 spaces.
    private static func indentItemAtPath(
        _ items: [ListItem],
        path: [Int]
    ) -> [ListItem]? {
        guard let first = path.first else { return nil }
        var result = items

        if path.count == 1 {
            // Top-level path: item is items[first]. Previous sibling is items[first-1].
            guard first > 0 else { return nil }
            let movingItem = items[first]
            let prevSibling = items[first - 1]
            // Update indent: child indent = parent indent + 2 spaces.
            let childIndent = prevSibling.indent + "  "
            let reindented = ListItem(
                indent: childIndent, marker: movingItem.marker,
                afterMarker: movingItem.afterMarker, checkbox: movingItem.checkbox,
                inline: movingItem.inline, children: movingItem.children
            )
            // Add reindented movingItem as last child of prevSibling.
            let newPrev = ListItem(
                indent: prevSibling.indent, marker: prevSibling.marker,
                afterMarker: prevSibling.afterMarker, checkbox: prevSibling.checkbox,
                inline: prevSibling.inline, children: prevSibling.children + [reindented]
            )
            result[first - 1] = newPrev
            result.remove(at: first)
            return result
        } else {
            // Recurse into children.
            let oldItem = items[first]
            guard let newChildren = indentItemAtPath(oldItem.children, path: Array(path.dropFirst())) else {
                return nil
            }
            result[first] = ListItem(
                indent: oldItem.indent, marker: oldItem.marker,
                afterMarker: oldItem.afterMarker, checkbox: oldItem.checkbox,
                inline: oldItem.inline, children: newChildren
            )
            return result
        }
    }

    /// Move the item at `path` to be the next sibling of its parent
    /// (one level up). Returns nil if the item is already at the top level.
    /// Updates the item's indent to match the parent's level.
    private static func unindentItemAtPath(
        _ items: [ListItem],
        path: [Int]
    ) -> [ListItem]? {
        // path must have >= 2 elements (parent + child index).
        guard path.count >= 2 else { return nil }

        if path.count == 2 {
            // Parent is items[path[0]], child is parent.children[path[1]].
            let parentIdx = path[0]
            let childIdx = path[1]
            let parent = items[parentIdx]
            let movingItem = parent.children[childIdx]

            // Children after the moving item become children of the
            // moving item (they were siblings, now they nest under it
            // to preserve order).
            let childrenAfter = Array(parent.children[(childIdx + 1)...])
            let childrenBefore = Array(parent.children[..<childIdx])

            let newParent = ListItem(
                indent: parent.indent, marker: parent.marker,
                afterMarker: parent.afterMarker, checkbox: parent.checkbox,
                inline: parent.inline, children: childrenBefore
            )
            // Promoted item gets the same indent as its former parent
            // (it's now a sibling of the parent).
            let promotedItem = ListItem(
                indent: parent.indent, marker: movingItem.marker,
                afterMarker: movingItem.afterMarker, checkbox: movingItem.checkbox,
                inline: movingItem.inline, children: movingItem.children + childrenAfter
            )

            var result = items
            result[parentIdx] = newParent
            result.insert(promotedItem, at: parentIdx + 1)
            return result
        } else {
            // Recurse: the parent is deeper in the tree.
            let first = path[0]
            let oldItem = items[first]
            guard let newChildren = unindentItemAtPath(oldItem.children, path: Array(path.dropFirst())) else {
                return nil
            }
            result[first] = ListItem(
                indent: oldItem.indent, marker: oldItem.marker,
                afterMarker: oldItem.afterMarker, checkbox: oldItem.checkbox,
                inline: oldItem.inline, children: newChildren
            )
            return result
        }
    }

    /// Remove the item at `path` from the tree. If `promoteChildren` is
    /// true, the item's children become siblings at the same level.
    private static func removeItemAtPath(
        _ items: [ListItem],
        path: [Int],
        promoteChildren: Bool
    ) -> [ListItem] {
        guard let first = path.first else { return items }
        var result = items

        if path.count == 1 {
            let removedItem = items[first]
            result.remove(at: first)
            if promoteChildren {
                // Insert children at the position where the item was.
                result.insert(contentsOf: removedItem.children, at: first)
            }
            return result
        } else {
            let oldItem = items[first]
            let newChildren = removeItemAtPath(
                oldItem.children,
                path: Array(path.dropFirst()),
                promoteChildren: promoteChildren
            )
            result[first] = ListItem(
                indent: oldItem.indent, marker: oldItem.marker,
                afterMarker: oldItem.afterMarker, checkbox: oldItem.checkbox,
                inline: oldItem.inline, children: newChildren
            )
            return result
        }
    }

    /// Find an entry in the flattened list that matches the given inline
    /// content and preferably has the given depth.
    private static func findEntryByContent(
        entries: [FlatListEntry],
        inline: [Inline],
        preferDepth: Int
    ) -> FlatListEntry? {
        // First try exact match: same inline content and preferred depth.
        let inlineText = inlinesToText(inline)
        for entry in entries {
            if entry.depth == preferDepth && inlinesToText(entry.item.inline) == inlineText {
                return entry
            }
        }
        // Fallback: any entry with matching content.
        for entry in entries {
            if inlinesToText(entry.item.inline) == inlineText {
                return entry
            }
        }
        return nil
    }

    /// Whether an inline tree renders to zero characters (empty list
    /// or a tree containing only empty leaves / containers of empty
    /// leaves).
    private static func isInlineEmpty(_ inline: [Inline]) -> Bool {
        return inline.allSatisfy { inlineLength($0) == 0 }
    }

    /// Calculate the render length of inline content.
    private static func inlineLength(_ node: Inline) -> Int {
        switch node {
        case .text(let s): return s.count
        case .code(let s): return s.count
        case .bold(let c, _): return c.reduce(0) { $0 + inlineLength($1) }
        case .italic(let c, _): return c.reduce(0) { $0 + inlineLength($1) }
        case .strikethrough(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .underline(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .highlight(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .link(let text, _): return text.reduce(0) { $0 + inlineLength($1) }
        case .image: return 0  // Images render as attachments (length 0 in inlines)
        case .autolink(let text, _): return text.count
        case .escapedChar: return 1
        case .lineBreak: return 1
        case .rawHTML(let s): return s.count
        case .entity(let s): return s.count
        case .math(let s): return s.count
        case .displayMath(let s): return s.count
        case .wikilink(let target, _): return target.count
        }
    }
}
