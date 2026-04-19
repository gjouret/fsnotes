//
//  ListEditing.swift
//  FSNotesCore
//
//  List-specific editing operations.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum ListEditing {

    ///   item0.prefix + item0.inlineContent + "\n" +
    ///   item1.prefix + item1.inlineContent + "\n" + ...
    /// (no trailing "\n" — stripped by ListRenderer).
    struct FlatListEntry {
        let item: ListItem
        let depth: Int
        let prefixLength: Int   // visual indent + bullet + " "
        let inlineLength: Int   // rendered inline chars
        let startOffset: Int    // offset within block's rendered output
        let path: [Int]         // tree path for reconstruction
    }

    /// Flatten a list's item tree into an ordered array of entries with
    /// their rendered offsets. Mirrors ListRenderer's walk order.
    static func flattenList(
        _ items: [ListItem],
        depth: Int = 0,
        startOffset: Int = 0,
        path: [Int] = []
    ) -> [FlatListEntry] {
        var entries: [FlatListEntry] = []
        var offset = startOffset
        for (i, item) in items.enumerated() {
            // Prefix is always 1 character: the attachment (bullet or
            // checkbox). No separator character — visual gap is
            // controlled by NSParagraphStyle headIndent.
            let prefixLen = 1
            let inlineLen = inlinesLength(item.inline)
            let entryPath = path + [i]
            entries.append(FlatListEntry(
                item: item, depth: depth,
                prefixLength: prefixLen, inlineLength: inlineLen,
                startOffset: offset, path: entryPath
            ))
            offset += prefixLen + inlineLen
            // Recurse into children.
            if !item.children.isEmpty {
                offset += 1 // "\n" separator before children
                let childEntries = flattenList(
                    item.children, depth: depth + 1,
                    startOffset: offset, path: entryPath
                )
                entries.append(contentsOf: childEntries)
                if let last = childEntries.last {
                    offset = last.startOffset + last.prefixLength + last.inlineLength
                }
            }
            // "\n" between sibling items (not after the last).
            if i < items.count - 1 {
                offset += 1
            }
        }
        return entries
    }

    /// Mirror of ListRenderer.visualBullet — must stay in sync.
    private static func listVisualBullet(for marker: String, depth: Int = 0) -> String {
        return ListRenderer.visualBullet(for: marker, depth: depth)
    }

    /// Total rendered character count for an inline tree.
    private static func inlinesLength(_ inlines: [Inline]) -> Int {
        return inlines.reduce(0) { $0 + inlineLength($1) }
    }

    /// Find which flat list entry contains the given rendered offset and
    /// return the offset within the entry's inline content. Returns nil
    /// if the offset lands on a prefix or separator.
    ///
    /// Boundary handling: when the offset is exactly at the end of an
    /// entry's inline content (offset == inlineEnd), it maps to that
    /// entry regardless of mode. This prevents operations at the end
    /// of a list item from failing with nil (which previously caused
    /// cursor jumps and clearBlockModelAndRefill fallbacks).
    private static func listEntryContaining(
        entries: [FlatListEntry],
        offset: Int,
        forInsertion: Bool
    ) -> (entryIndex: Int, inlineOffset: Int)? {
        for (i, entry) in entries.enumerated() {
            let inlineStart = entry.startOffset + entry.prefixLength
            let inlineEnd = inlineStart + entry.inlineLength
            // Both insertion and non-insertion use inclusive upper bound.
            // At the boundary (offset == inlineEnd), the cursor belongs
            // to this entry — it's "at the end of the item's text".
            if offset >= inlineStart && offset <= inlineEnd {
                return (i, offset - inlineStart)
            }
            // RC2: cursor sitting ON the prefix attachment (offset ==
            // inlineStart - 1, i.e. offset == entry.startOffset) clamps
            // to the start of the entry's inline content. Without this,
            // backspace/delete at the very front of a list item lands
            // on the bullet/checkbox attachment, returns nil, and falls
            // back to clearBlockModelAndRefill().
            if entry.prefixLength > 0,
               offset >= entry.startOffset,
               offset < inlineStart {
                return (i, 0)
            }
        }
        return nil
    }

    /// Insert into a list block's inline content. Finds the target item,
    /// splices its inline tree, reconstructs the full item tree.
    private static func insertIntoList(
        items: [ListItem],
        offsetInBlock: Int,
        string: String
    ) throws -> Block {
        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(
                reason: "list: offset \(offsetInBlock) not within editable inline content"
            )
        }
        let entry = entries[entryIdx]
        let newInline: [Inline]
        if entry.item.inline.isEmpty {
            newInline = [.text(string)]
        } else {
            let runs = flatten(entry.item.inline)
            guard let (runIdx, off) = runAtInsertionPoint(runs, offset: inlineOffset) else {
                throw EditingError.unsupported(
                    reason: "list item: offset \(inlineOffset) out of inline bounds"
                )
            }
            let leaf = runs[runIdx]
            let newText = spliceString(leaf.text, at: off, replacing: 0, with: string)
            newInline = updateLeafText(entry.item.inline, at: leaf.path, newText: newText)
        }
        let newItem = ListItem(
            indent: entry.item.indent, marker: entry.item.marker,
            afterMarker: entry.item.afterMarker, checkbox: entry.item.checkbox,
            inline: newInline, children: entry.item.children
        )
        let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
        return .list(items: newItems)
    }

    /// Delete within a list block's inline content.
    /// Supports both single-item deletions and multi-item deletions (when
    /// the user selects across multiple list items and presses Delete).
    private static func deleteInList(
        items: [ListItem],
        from fromOffset: Int,
        to toOffset: Int
    ) throws -> Block {
        let length = toOffset - fromOffset
        if length == 0 { return .list(items: items) }
        let entries = flattenList(items)
        guard let (startEntry, startOff) = listEntryContaining(
            entries: entries, offset: fromOffset, forInsertion: false
        ) else {
            throw EditingError.unsupported(
                reason: "list: delete start \(fromOffset) not within editable inline content"
            )
        }
        guard let (endEntry, endOff) = listEntryContaining(
            entries: entries, offset: toOffset - 1, forInsertion: false
        ) else {
            throw EditingError.unsupported(
                reason: "list: delete end \(toOffset - 1) not within editable inline content"
            )
        }

        // Single-item deletion (existing behavior)
        if startEntry == endEntry {
            let entry = entries[startEntry]
            let runs = flatten(entry.item.inline)
            guard let (startRun, startRunOff) = runContainingChar(runs, charIndex: startOff) else {
                throw EditingError.outOfBounds
            }
            let endOff = startOff + length
            guard let (endRun, endRunOff) = runContainingChar(runs, charIndex: endOff - 1) else {
                throw EditingError.outOfBounds
            }
            guard startRun == endRun else { throw EditingError.crossInlineRange }
            let leaf = runs[startRun]
            let newText = spliceString(leaf.text, at: startRunOff, replacing: endRunOff + 1 - startRunOff, with: "")
            let newInline = updateLeafText(entry.item.inline, at: leaf.path, newText: newText)
            let newItem = ListItem(
                indent: entry.item.indent, marker: entry.item.marker,
                afterMarker: entry.item.afterMarker, checkbox: entry.item.checkbox,
                inline: newInline, children: entry.item.children
            )
            let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
            return .list(items: newItems)
        }

        // Multi-item deletion: remove entire items that are fully covered,
        // and truncate partially covered items at the boundaries.
        return try deleteAcrossListItems(
            items: items,
            entries: entries,
            startEntry: startEntry,
            startOff: startOff,
            endEntry: endEntry,
            endOff: endOff
        )
    }

    /// Delete across multiple list items. Handles the case where the user
    /// selects text spanning multiple list items and presses Delete.
    private static func deleteAcrossListItems(
        items: [ListItem],
        entries: [FlatListEntry],
        startEntry: Int,
        startOff: Int,
        endEntry: Int,
        endOff: Int
    ) throws -> Block {
        let start = entries[startEntry]
        let end = entries[endEntry]

        // Calculate what survives from the first item (everything before startOff)
        let firstItemSurviving: [Inline]?
        if startOff <= 0 {
            // Nothing survives from the first item's inline content
            firstItemSurviving = nil
        } else {
            // Truncate the first item's inline content
            let runs = flatten(start.item.inline)
            guard let (startRun, startRunOff) = runContainingChar(runs, charIndex: startOff) else {
                throw EditingError.outOfBounds
            }
            // Keep everything before the deletion point
            let keepCount = startOff
            firstItemSurviving = keepFirstChars(start.item.inline, count: keepCount)
        }

        // Calculate what survives from the last item (everything after endOff)
        let lastItemSurviving: [Inline]?
        let endInlineStart = end.startOffset + end.prefixLength
        let relativeEndOff = endOff - endInlineStart
        if relativeEndOff >= end.inlineLength {
            // Nothing survives from the last item
            lastItemSurviving = nil
        } else if relativeEndOff <= 0 {
            // All of the last item survives
            lastItemSurviving = end.item.inline
        } else {
            // Truncate the last item: keep everything after the deletion point
            let runs = flatten(end.item.inline)
            guard let (endRun, endRunOff) = runContainingChar(runs, charIndex: relativeEndOff) else {
                throw EditingError.outOfBounds
            }
            let dropCount = relativeEndOff
            lastItemSurviving = dropFirstChars(end.item.inline, count: dropCount)
        }

        // Build the replacement items
        var replacementItems: [ListItem] = []

        // Add truncated first item if it has surviving content
        if let surviving = firstItemSurviving, !surviving.isEmpty {
            replacementItems.append(ListItem(
                indent: start.item.indent,
                marker: start.item.marker,
                afterMarker: start.item.afterMarker,
                checkbox: start.item.checkbox,
                inline: surviving,
                children: start.item.children
            ))
        }

        // Add truncated last item if it has surviving content and is different from first
        if endEntry != startEntry {
            if let surviving = lastItemSurviving, !surviving.isEmpty {
                // Merge surviving content if first item also had surviving content
                // This handles the case where we're deleting across items but the
                // user wants the remaining text to be concatenated
                if let firstSurviving = firstItemSurviving, !firstSurviving.isEmpty {
                    // Merge into the first item (concatenate the surviving inline content)
                    let mergedInline = firstSurviving + surviving
                    replacementItems[replacementItems.count - 1] = ListItem(
                        indent: start.item.indent,
                        marker: start.item.marker,
                        afterMarker: start.item.afterMarker,
                        checkbox: start.item.checkbox,
                        inline: mergedInline,
                        children: start.item.children
                    )
                } else {
                    // First item was fully deleted, add last item as new
                    replacementItems.append(ListItem(
                        indent: end.item.indent,
                        marker: end.item.marker,
                        afterMarker: end.item.afterMarker,
                        checkbox: end.item.checkbox,
                        inline: surviving,
                        children: end.item.children
                    ))
                }
            }
        }

        // Remove the affected items from the tree and insert replacements
        let newItems = replaceItemsInTree(
            items,
            fromPath: start.path,
            toPath: end.path,
            with: replacementItems
        )

        return .list(items: newItems)
    }

    /// Keep the first `count` characters of an inline tree.
    private static func keepFirstChars(_ inlines: [Inline], count: Int) -> [Inline]? {
        let runs = flatten(inlines)
        var result: [Inline] = []
        var remaining = count

        for run in runs {
            if remaining <= 0 { break }
            if run.length <= remaining {
                // Keep this entire run
                result.append(run.inline)
                remaining -= run.length
            } else {
                // Partial run: truncate the text
                let partialText = String(run.text.prefix(remaining))
                result.append(.text(partialText))
                remaining = 0
            }
        }

        return result.isEmpty ? nil : cleanInlines(result)
    }

    /// Drop the first `count` characters of an inline tree, keeping the rest.
    private static func dropFirstChars(_ inlines: [Inline], count: Int) -> [Inline]? {
        let runs = flatten(inlines)
        var result: [Inline] = []
        var toDrop = count

        for run in runs {
            if toDrop >= run.length {
                // Drop this entire run
                toDrop -= run.length
            } else if toDrop > 0 {
                // Partial drop from this run
                let keepText = String(run.text.dropFirst(toDrop))
                result.append(.text(keepText))
                toDrop = 0
            } else {
                // Keep this entire run
                result.append(run.inline)
            }
        }

        return result.isEmpty ? nil : cleanInlines(result)
    }

    /// Remove items in the range [fromPath, toPath] and insert replacement items.
    private static func replaceItemsInTree(
        _ items: [ListItem],
        fromPath: [Int],
        toPath: [Int],
        with replacements: [ListItem]
    ) -> [ListItem] {
        // For now, handle the simple case where both paths are at the same level
        // and refer to siblings (most common case for multi-select delete)
        if fromPath.count == 1 && toPath.count == 1 {
            var result = items
            let fromIndex = fromPath[0]
            let toIndex = toPath[0]
            result.replaceSubrange(fromIndex...toIndex, with: replacements)
            return result
        }

        // For nested cases, we'd need more complex tree surgery
        // For now, fall back to just removing the items at the top level
        // and preserving nested structure in the replacements
        var result = items
        let fromIndex = fromPath[0]
        let toIndex = toPath[0]
        result.replaceSubrange(fromIndex...toIndex, with: replacements)
        return result
    }

    /// Replace an item at the given tree path within a list item tree.
    private static func replaceItemAtPath(
        _ items: [ListItem],
        path: [Int],
        with newItem: ListItem
    ) -> [ListItem] {
        guard let first = path.first else { return items }
        var result = items
        if path.count == 1 {
            result[first] = newItem
        } else {
            let oldItem = items[first]
            let newChildren = replaceItemAtPath(
                oldItem.children,
                path: Array(path.dropFirst()),
                with: newItem
            )
            result[first] = ListItem(
                indent: oldItem.indent, marker: oldItem.marker,
                afterMarker: oldItem.afterMarker, checkbox: oldItem.checkbox,
                inline: oldItem.inline, children: newChildren
            )
        }
        return result
    }
    
    /// Find the index in a flattened list of entries that corresponds to the given path.
    /// Returns nil if the path is not found in the flattened list.
    static func itemIndexInFlattenedList(_ items: [ListItem], path: [Int]) -> Int? {
        let entries = flattenList(items)
        for (index, entry) in entries.enumerated() {
            if entry.path == path {
                return index
            }
        }
        return nil
    }
}

