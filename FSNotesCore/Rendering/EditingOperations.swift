//
//  EditingOperations.swift
//  FSNotesCore
//
//  Block-model editing operations. These are the ONLY functions that
//  mutate a Document. Each operation returns an EditResult containing
//  a new DocumentProjection plus the minimal splice (range + replacement
//  attributed string) that, when applied to the caller's textStorage,
//  yields the same state as the new projection.
//
//  ARCHITECTURAL CONTRACT:
//  - Pure: (oldProjection, input) → (newProjection, splice). No hidden
//    state, no textStorage mutation inside these functions.
//  - Single source of truth: the new Document is the authoritative
//    post-edit state. The splice is derived from the new Document, not
//    composed heuristically.
//  - Character-granular splices: insertion/deletion inside block[i]
//    diffs the old and new rendered output to find the minimal changed
//    substring. A 1-char edit produces a 1-char splice, even in a
//    7000-char block. Sibling blocks are untouched.
//
//  Supported operations:
//  - Single-block insertion/deletion with inline-tree navigation.
//  - Paragraph split on "\n" (Return key).
//  - Adjacent-block merge on cross-boundary delete.
//  - Multi-line paste into paragraphs.
//  - List structural operations (indent/unindent/exit via FSM).
//  - All 7 block types: paragraph, heading, codeBlock, blankLine,
//    list, blockquote, horizontalRule.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Architecture Types (A-Grade Migration)

/// Phantom type for compile-time offset safety.
public struct StorageIndex<T>: Equatable, Comparable, Hashable {
    private let rawValue: Int
    public init(_ value: Int) { self.rawValue = value }
    public var value: Int { rawValue }
    
    public static func < (lhs: StorageIndex<T>, rhs: StorageIndex<T>) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func + (lhs: StorageIndex<T>, rhs: Int) -> StorageIndex<T> { StorageIndex(lhs.rawValue + rhs) }
    public static func - (lhs: StorageIndex<T>, rhs: Int) -> StorageIndex<T> { StorageIndex(lhs.rawValue - rhs) }
    public static func distance(from start: StorageIndex<T>, to end: StorageIndex<T>) -> Int { end.rawValue - start.rawValue }
}

/// Type tags for storage indices.
public enum OldStorage {}
public enum NewStorage {}

/// A range in storage with type safety.
public struct StorageRange<T>: Equatable {
    public let start: StorageIndex<T>
    public let end: StorageIndex<T>
    public init(start: StorageIndex<T>, end: StorageIndex<T>) { self.start = start; self.end = end }
    public var length: Int { StorageIndex<T>.distance(from: start, to: end) }
}

/// Unified error type replacing scattered EditingError.
public enum EditorError: Error, Equatable {
    case invalidStorageIndex(Int)
    case invalidBlockIndex(Int)
    case invalidRange(StorageRange<OldStorage>)
    case emptySelection
    case blockNotFound(at: StorageIndex<OldStorage>)
    case unsupportedBlockType(BlockType)
    case readOnlyBlock(BlockType)
    case crossBlockSelection
    case crossInlineSelection
    case invalidSelection(String)
    case operationFailed(String)
    case serializationFailed
    case parseFailed(String)
    case invalidState(String)
    case transactionFailed(String)
    
    public enum BlockType: Equatable {
        case paragraph, heading, codeBlock, list, blockquote, table, horizontalRule, blankLine, htmlBlock
    }
}

// MARK: - Legacy Error Type (kept for backward compatibility during migration)
/// Errors thrown by editing operations.
public enum EditingError: Error, Equatable {
    case invalidSelection
    case notInsideBlock(storageIndex: Int)
    case unsupported(reason: String)
    case crossBlockRange
    case crossInlineRange
    case outOfBounds
}

/// The output of an editing operation.
public struct EditResult {
    /// The post-edit projection — rendered, block spans, everything.
    public let newProjection: DocumentProjection
    /// The range in the OLD projection's storage that should be
    /// replaced. Callers apply this to their textStorage to sync.
    public let spliceRange: NSRange
    /// The attributed-string content to substitute into `spliceRange`.
    public let spliceReplacement: NSAttributedString
    /// Where the cursor should be placed in the NEW projection's
    /// storage after applying the splice. Callers use this to set
    /// `setSelectedRange`. Set by the top-level `insert` / `delete`
    /// functions; internal primitives initialize to 0.
    public var newCursorPosition: Int = 0
    /// Length of the selection to maintain after the edit. When > 0,
    /// the selection range is `(newCursorPosition, newSelectionLength)`
    /// instead of a zero-length insertion point. Used by formatting
    /// operations (bold, italic, etc.) to keep text selected so the
    /// user can stack additional formatting.
    public var newSelectionLength: Int = 0
}

// NOTE: EditingError is now defined at the top of the file with the
// new architecture types. This section removed as part of A-grade
// architecture migration.

// MARK: - Editing Operations

public enum EditingOps {

    // MARK: - Insert

    /// Insert `string` at `storageIndex` within the projection's
    /// rendered output.
    ///
    /// Behaviour by string content:
    ///  - No newlines: in-block character splice (all supported block
    ///    types).
    ///  - Exactly `"\n"` in a paragraph: splits the paragraph in two
    ///    (Return-key operation).
    ///  - Multi-line string in a paragraph: splits the paragraph,
    ///    inserts pasted lines as new paragraphs between the halves
    ///    (paste operation).
    ///  - Any string (including newlines) in a code block: raw content
    ///    splice — code blocks accept verbatim content.
    ///  - Newlines in headings / structural blocks: `.unsupported`.
    public static func insert(
        _ string: String,
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let oldBlock = projection.document.blocks[blockIndex]

        // Route newline-containing strings by block type.
        if string.contains("\n") {
            switch oldBlock {
            case .codeBlock(let language, let content, let fence):
                // FSM exit (bug 88): pressing Return on a blank line
                // inside a code block ends the code block. Heuristic:
                // cursor is at the END of the content AND the last char
                // is "\n" (i.e. the user just pressed Return on what
                // is now an empty trailing line). Truncate the trailing
                // blank, keep the code block, and insert a new empty
                // paragraph after it. Without this, there's no keyboard
                // way to leave a code block — the user has to switch
                // to source mode.
                if string == "\n",
                   offsetInBlock == content.count,
                   content.hasSuffix("\n") {
                    let trimmedContent = String(content.dropLast())
                    let newCode = Block.codeBlock(
                        language: language, content: trimmedContent, fence: fence
                    )
                    let newPara = Block.paragraph(inline: [])
                    var result = try replaceBlocks(
                        atIndex: blockIndex,
                        with: [newCode, newPara],
                        in: projection
                    )
                    let paraSpan = result.newProjection.blockSpans[blockIndex + 1]
                    result.newCursorPosition = paraSpan.location
                    return result
                }
                // Code blocks accept any content verbatim — fall through
                // to the in-block splice path.
                break
            case .paragraph(let inline):
                if string == "\n" {
                    // Single newline splits paragraph in two.
                    let newBlocks = splitParagraphOnNewline(inline: inline, at: offsetInBlock)
                    var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                    // Cursor goes to start of the LAST new block (the
                    // paragraph after the split point).
                    let lastNewBlockIdx = blockIndex + newBlocks.count - 1
                    result.newCursorPosition = result.newProjection.blockSpans[lastNewBlockIdx].location
                    return result
                }
                // Multi-line paste into paragraph.
                var result = try pasteIntoParagraph(
                    inline: inline, at: offsetInBlock,
                    pastedText: string,
                    blockIndex: blockIndex,
                    in: projection
                )
                // Cursor goes to end of pasted content within the last
                // new block. Approximate: storageIndex + rendered length
                // of the pasted text. Since each "\n" becomes a block
                // separator, count rendered chars = string.count.
                result.newCursorPosition = storageIndex + string.count
                return result
            case .list(let items, _):
                if string == "\n" {
                    do {
                        let newBlocks = try splitListOnNewline(
                            items: items, at: offsetInBlock, blockIndex: blockIndex, in: projection
                        )
                        var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                        // Cursor goes to the start of the new item's inline
                        // content within the list. Re-flatten the new list
                        // to find the entry that was just inserted.
                        let blockSpan = result.newProjection.blockSpans[blockIndex]
                        if case .list(let newItems, _) = result.newProjection.document.blocks[blockIndex] {
                            let newEntries = flattenList(newItems)
                            // The new item is the one whose startOffset is
                            // just after the split point. Find the first
                            // entry whose startOffset > offsetInBlock.
                            if let newEntry = newEntries.first(where: { $0.startOffset > offsetInBlock }) {
                                result.newCursorPosition = blockSpan.location + newEntry.startOffset + newEntry.prefixLength
                            } else {
                                result.newCursorPosition = blockSpan.location + blockSpan.length
                            }
                        } else {
                            result.newCursorPosition = blockSpan.location
                        }
                        return result
                    } catch EditingError.unsupported(let reason) where reason.contains("empty item return") {
                        // FSM: empty item → exit or unindent.
                        return try returnOnEmptyListItem(at: storageIndex, in: projection)
                    }
                }
                // Multi-line paste into list
                var result = try pasteIntoList(
                    items: items, at: offsetInBlock, pastedText: string,
                    blockIndex: blockIndex, in: projection
                )
                result.newCursorPosition = storageIndex + string.count
                return result
            case .blockquote(let lines):
                if string == "\n" {
                    let newBlocks = try splitBlockquoteOnNewline(
                        lines: lines, at: offsetInBlock, blockIndex: blockIndex, in: projection
                    )
                    var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                    // Cursor goes to the new line's inline start.
                    let blockSpan = result.newProjection.blockSpans[blockIndex]
                    if case .blockquote(let newLines) = result.newProjection.document.blocks[blockIndex] {
                        let newFlat = flattenBlockquote(newLines)
                        if let newEntry = newFlat.first(where: { $0.startOffset > offsetInBlock }) {
                            result.newCursorPosition = blockSpan.location + newEntry.startOffset + newEntry.prefixLength
                        } else {
                            result.newCursorPosition = blockSpan.location + blockSpan.length
                        }
                    } else {
                        result.newCursorPosition = blockSpan.location
                    }
                    return result
                }
                // Multi-line paste into blockquote
                var result = try pasteIntoBlockquote(
                    lines: lines, at: offsetInBlock, pastedText: string,
                    blockIndex: blockIndex, in: projection
                )
                result.newCursorPosition = storageIndex + string.count
                return result
            case .htmlBlock:
                // HTML blocks accept any content verbatim, like code blocks.
                break
            case .heading(let level, let suffix):
                if string == "\n" {
                    // Return in heading: split at cursor position
                    // HeadingRenderer strips ONLY leading whitespace from
                    // the suffix — trailing whitespace is rendered. So
                    // rendered offset `o` maps to suffix offset `o + leading`
                    // and the displayed count is `suffix.count - leading`.
                    let leading = leadingWhitespaceCount(in: suffix)
                    let displayedCount = suffix.count - leading
                    _ = displayedCount

                    // offsetInBlock is in rendered coordinates (0..displayedCount)
                    // We need to split the suffix at this offset
                    let suffixOffset = offsetInBlock + leading
                    let beforeSuffix = String(suffix.prefix(suffixOffset))
                    let afterSuffix = String(suffix.dropFirst(suffixOffset))
                    
                    // Build new blocks: heading with text before cursor, then
                    // a plain paragraph with text after cursor. No blankLine
                    // between — the paragraphSpacing on heading and paragraph
                    // provides the visual gap, and serialization round-trips
                    // correctly because MarkdownSerializer emits a blank
                    // separator between non-blank siblings anyway.
                    //
                    // Do NOT trim user-typed whitespace — only the single
                    // leading space that HeadingRenderer strips is re-added.
                    var newBlocks: [Block] = []

                    // First block: heading with text before cursor. If the
                    // heading ended up empty (user split right at the " ##"
                    // marker boundary), degrade it to a blankLine so we
                    // don't render an orphan heading glyph.
                    let headingIsEmpty = String(beforeSuffix.dropFirst(leading)).isEmpty
                    if headingIsEmpty && level > 0 {
                        newBlocks.append(.blankLine)
                    } else {
                        newBlocks.append(.heading(level: level, suffix: beforeSuffix))
                    }

                    // Second block: paragraph with text after cursor (parsed
                    // through the inline parser so completed inline markers
                    // become real inline nodes). Empty when cursor is at
                    // end — that's the expected "Return at end of heading
                    // → new empty paragraph below" behavior.
                    let parsedInlines = afterSuffix.isEmpty
                        ? []
                        : MarkdownParser.parseInlines(afterSuffix)
                    newBlocks.append(.paragraph(inline: parsedInlines))

                    var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                    // Cursor goes to the start of the paragraph (the second
                    // new block).
                    let paraBlockIdx = blockIndex + 1
                    result.newCursorPosition = result.newProjection.blockSpans[paraBlockIdx].location
                    return result
                }
                // Multi-line paste into heading: treat like Return + paste remainder into new paragraph
                var result = try pasteIntoHeading(
                    level: level, suffix: suffix, at: offsetInBlock, pastedText: string,
                    blockIndex: blockIndex, in: projection
                )
                result.newCursorPosition = storageIndex + string.count
                return result
                
            case .blankLine:
                if string == "\n" {
                    // Return on a blank line creates another blank line.
                    let newBlocks: [Block] = [.blankLine, .blankLine]
                    var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                    let lastNewBlockIdx = blockIndex + newBlocks.count - 1
                    result.newCursorPosition = result.newProjection.blockSpans[lastNewBlockIdx].location
                    return result
                }
                throw EditingError.unsupported(
                    reason: "newline insertion in blankLine not supported"
                )
            case .horizontalRule, .table:
                throw EditingError.unsupported(
                    reason: "newline insertion in \(describe(oldBlock)) not supported"
                )
            }
        }

        let newBlock = try insertIntoBlock(oldBlock, offsetInBlock: offsetInBlock, string: string)
        var result = try replaceBlock(
            atIndex: blockIndex,
            with: newBlock,
            in: projection
        )
        result.newCursorPosition = storageIndex + string.count
        return result
    }

    // MARK: - Replace (selection → typed character)

    /// Replace `storageRange` with `string` in a single block mutation.
    /// This preserves the inline formatting context of the selection —
    /// e.g. typing "x" while "hello" is selected inside bold produces
    /// bold "x", not plain "x".
    ///
    /// For cross-block replacements or newline-containing replacements,
    /// falls back to delete + insert (via the caller).
    public static func replace(
        range storageRange: NSRange,
        with string: String,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard storageRange.length > 0, !string.isEmpty else {
            throw EditingError.unsupported(reason: "replace requires non-empty range and string")
        }

        // Only handle single-block, single-line replacements.
        guard !string.contains("\n") else {
            throw EditingError.unsupported(reason: "replace: newline in replacement")
        }

        guard let (startBlock, startOffset) = projection.blockContaining(
            storageIndex: storageRange.location
        ) else {
            throw EditingError.notInsideBlock(storageIndex: storageRange.location)
        }
        let endIndex = storageRange.location + storageRange.length
        guard let (endBlock, _) = projection.blockContaining(storageIndex: endIndex) else {
            throw EditingError.notInsideBlock(storageIndex: endIndex)
        }
        guard startBlock == endBlock else {
            throw EditingError.crossBlockRange
        }

        let block = projection.document.blocks[startBlock]
        let endOffset = startOffset + storageRange.length
        let newBlock = try replaceInBlock(block, from: startOffset, to: endOffset, with: string)
        var result = try replaceBlock(atIndex: startBlock, with: newBlock, in: projection)
        result.newCursorPosition = storageRange.location + string.count
        return result
    }

    /// Replace the text in [fromOffset, toOffset) within a block with
    /// `replacement`. Preserves the inline formatting context.
    private static func replaceInBlock(
        _ block: Block,
        from fromOffset: Int,
        to toOffset: Int,
        with replacement: String
    ) throws -> Block {
        let length = toOffset - fromOffset
        switch block {
        case .paragraph(let inline):
            if inline.isEmpty {
                return .paragraph(inline: [.text(replacement)])
            }
            if containsImage(inline) {
                let (before, _) = splitInlines(inline, at: fromOffset)
                let (_, after) = splitInlines(inline, at: toOffset)
                return .paragraph(inline: before + [.text(replacement)] + after)
            }
            let runs = flatten(inline)
            guard let (startRun, startOff) = runContainingChar(runs, charIndex: fromOffset) else {
                throw EditingError.outOfBounds
            }
            guard let (endRun, endOffInclusive) = runContainingChar(runs, charIndex: toOffset - 1) else {
                throw EditingError.outOfBounds
            }
            if startRun == endRun {
                // Selection is within a single leaf — splice directly,
                // preserving the leaf's formatting context.
                let leaf = runs[startRun]
                let endExclusive = endOffInclusive + 1
                let newText = spliceString(leaf.text, at: startOff, replacing: endExclusive - startOff, with: replacement)
                let newInline = updateLeafText(inline, at: leaf.path, newText: newText)
                return .paragraph(inline: newInline)
            }
            // Cross-inline selection: use splitInlines to cut at both
            // boundaries, then splice the replacement into the first
            // half's formatting context.
            let (before, _) = splitInlines(inline, at: fromOffset)
            let (_, after) = splitInlines(inline, at: toOffset)
            // Insert replacement text. If `before` has formatting context
            // (e.g. ends inside a bold), the text is placed adjacent to it.
            return .paragraph(inline: cleanInlines(before + [.text(replacement)] + after))

        case .heading(let level, let suffix):
            let leading = leadingWhitespaceCount(in: suffix)
            let suffixFrom = fromOffset + leading
            let newSuffix = spliceString(suffix, at: suffixFrom, replacing: length, with: replacement)
            return .heading(level: level, suffix: newSuffix)

        case .codeBlock(let language, let content, let fence):
            let newContent = spliceString(content, at: fromOffset, replacing: length, with: replacement)
            return .codeBlock(language: language, content: newContent, fence: fence)

        case .list(let items, _):
            return try replaceInList(items: items, from: fromOffset, to: toOffset, with: replacement)

        case .blockquote(let lines):
            return try replaceInBlockquote(lines: lines, from: fromOffset, to: toOffset, with: replacement)

        default:
            throw EditingError.unsupported(
                reason: "replaceInBlock: not supported for \(describe(block))"
            )
        }
    }

    /// Replace within a list item's inline content.
    private static func replaceInList(
        items: [ListItem],
        from fromOffset: Int,
        to toOffset: Int,
        with replacement: String
    ) throws -> Block {
        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: fromOffset, forInsertion: false
        ) else {
            throw EditingError.unsupported(reason: "replaceInList: offset not in list item")
        }
        let entry = entries[entryIdx]
        let item = entry.item
        let localEnd = inlineOffset + (toOffset - fromOffset)

        // Use the same approach as paragraph: find the run and splice.
        let runs = flatten(item.inline)
        if let (startRun, startOff) = runContainingChar(runs, charIndex: inlineOffset),
           let (endRun, endOffInclusive) = runContainingChar(runs, charIndex: localEnd - 1),
           startRun == endRun {
            let leaf = runs[startRun]
            let endExclusive = endOffInclusive + 1
            let newText = spliceString(leaf.text, at: startOff, replacing: endExclusive - startOff, with: replacement)
            let newInline = updateLeafText(item.inline, at: leaf.path, newText: newText)
            let newItem = ListItem(
                indent: item.indent, marker: item.marker,
                afterMarker: item.afterMarker, checkbox: item.checkbox,
                inline: newInline, children: item.children
            )
            let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
            return .list(items: newItems)
        }

        // Cross-inline: split and splice
        let (before, _) = splitInlines(item.inline, at: inlineOffset)
        let (_, after) = splitInlines(item.inline, at: localEnd)
        let newInline = cleanInlines(before + [.text(replacement)] + after)
        let newItem = ListItem(
            indent: item.indent, marker: item.marker,
            afterMarker: item.afterMarker, checkbox: item.checkbox,
            inline: newInline, children: item.children
        )
        let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
        return .list(items: newItems)
    }

    /// Replace within a blockquote line's inline content.
    private static func replaceInBlockquote(
        lines: [BlockquoteLine],
        from fromOffset: Int,
        to toOffset: Int,
        with replacement: String
    ) throws -> Block {
        let flattened = flattenBlockquote(lines)
        guard let (lineIdx, inlineOffset) = quoteEntryContaining(
            entries: flattened, offset: fromOffset, forInsertion: false
        ) else {
            throw EditingError.unsupported(reason: "replaceInBlockquote: offset not in line")
        }
        let line = lines[lineIdx]
        let localEnd = inlineOffset + (toOffset - fromOffset)

        let runs = flatten(line.inline)
        if let (startRun, startOff) = runContainingChar(runs, charIndex: inlineOffset),
           let (endRun, endOffInclusive) = runContainingChar(runs, charIndex: localEnd - 1),
           startRun == endRun {
            let leaf = runs[startRun]
            let endExclusive = endOffInclusive + 1
            let newText = spliceString(leaf.text, at: startOff, replacing: endExclusive - startOff, with: replacement)
            let newInline = updateLeafText(line.inline, at: leaf.path, newText: newText)
            var newLines = lines
            newLines[lineIdx] = BlockquoteLine(prefix: line.prefix, inline: newInline)
            return .blockquote(lines: newLines)
        }

        let (before, _) = splitInlines(line.inline, at: inlineOffset)
        let (_, after) = splitInlines(line.inline, at: localEnd)
        let newInline = cleanInlines(before + [.text(replacement)] + after)
        var newLines = lines
        newLines[lineIdx] = BlockquoteLine(prefix: line.prefix, inline: newInline)
        return .blockquote(lines: newLines)
    }

    // MARK: - Delete

    /// Delete the characters in `storageRange`. The range must lie
    /// entirely within a single supported block.
    public static func delete(
        range storageRange: NSRange,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard storageRange.location >= 0,
              storageRange.length >= 0,
              storageRange.location + storageRange.length <= projection.attributed.length else {
            throw EditingError.outOfBounds
        }
        if storageRange.length == 0 {
            // Degenerate: no-op delete. Produce an empty splice at the
            // deletion point (callers may still want a new projection
            // for symmetry; in practice they'll skip this path).
            return EditResult(
                newProjection: projection,
                spliceRange: storageRange,
                spliceReplacement: NSAttributedString(string: "")
            )
        }
        // Locate the block for the start and end. They must be the same.
        guard let (startBlock, startOffset) = projection.blockContaining(storageIndex: storageRange.location) else {
            throw EditingError.notInsideBlock(storageIndex: storageRange.location)
        }
        let endIndex = storageRange.location + storageRange.length
        guard let (endBlock, endOffset) = projection.blockContaining(storageIndex: endIndex) else {
            throw EditingError.notInsideBlock(storageIndex: endIndex)
        }
        if startBlock != endBlock {
            // Multi-block selection: delegate to mergeAdjacentBlocks
            // which properly handles content truncation and merging
            var result = try mergeAdjacentBlocks(
                startBlock: startBlock, startOffset: startOffset,
                endBlock: endBlock, endOffset: endOffset,
                in: projection
            )
            result.newCursorPosition = storageRange.location
            return result
        }
        let oldBlock = projection.document.blocks[startBlock]

        // Atomic-block full-select detection: `.table` and
        // `.horizontalRule` have no editable inner content — their
        // `deleteInBlock` branches return the block unchanged. That
        // used to make "select the table and press delete" a silent
        // no-op. Interpret a range that covers the entire atomic
        // block's span as "remove the block" and replace it with an
        // empty paragraph (which is where the cursor lands after
        // the delete).
        //
        // Check ALL blocks that overlap the selection to handle
        // multi-block selections that fully encompass atomic blocks.
        let overlappingIndices = projection.blockIndices(overlapping: storageRange)
        if overlappingIndices.count == 1,
           let onlyBlockIdx = overlappingIndices.first,
           isAtomicAttachmentBlock(projection.document.blocks[onlyBlockIdx]) {
            let blockSpan = projection.blockSpans[onlyBlockIdx]
            // Use generous coverage check - selection must fully cover the block
            if selectionFullyCoversBlock(blockSpan, in: storageRange) {
                var result = try replaceBlock(
                    atIndex: onlyBlockIdx,
                    with: .paragraph(inline: []),
                    in: projection
                )
                result.newCursorPosition = storageRange.location
                return result
            }
        }

        let newBlock = try deleteInBlock(oldBlock, from: startOffset, to: endOffset)
        var result = try replaceBlock(
            atIndex: startBlock,
            with: newBlock,
            in: projection
        )
        result.newCursorPosition = storageRange.location
        return result
    }

    /// True for blocks that render as a single atomic glyph
    /// (attachment character) with no editable inner content — the
    /// ones where `deleteInBlock` is a no-op and a full-span delete
    /// should therefore be interpreted as block removal.
    private static func isAtomicAttachmentBlock(_ block: Block) -> Bool {
        switch block {
        case .table, .horizontalRule: return true
        default: return false
        }
    }

    /// Check if a selection range fully encompasses a block's span.
    /// Used to detect when an atomic block (table, HR) is fully selected
    /// for removal, even if the selection isn't an exact match.
    private static func selectionFullyCoversBlock(
        _ blockSpan: NSRange,
        in selectionRange: NSRange
    ) -> Bool {
        let blockEnd = blockSpan.location + blockSpan.length
        let selectionEnd = selectionRange.location + selectionRange.length
        // Block is fully covered if:
        // 1. Selection start is at or before block start
        // 2. Selection end is at or after block end
        return selectionRange.location <= blockSpan.location
            && selectionEnd >= blockEnd
    }

    // MARK: - Block-level primitive

    /// Replace `document.blocks[blockIndex]` with `newBlock`, producing
    /// a new projection and a block-granular splice.
    static func replaceBlock(
        atIndex blockIndex: Int,
        with newBlock: Block,
        in projection: DocumentProjection
    ) throws -> EditResult {
        return try replaceBlocks(
            atIndex: blockIndex,
            with: [newBlock],
            in: projection
        )
    }

    /// Replace `document.blocks[range]` (a contiguous span of existing
    /// blocks) with `newBlocks`. The splice range covers from the first
    /// old block's span start to the last old block's span end; the
    /// replacement is the rendered concatenation of the new blocks.
    ///
    /// Public sibling of the single-index `replaceBlock`. Use this when
    /// a multi-block selection needs to collapse into fewer blocks
    /// (e.g. wrapping three paragraphs in a single list, or fencing a
    /// mid-paragraph selection as a code block).
    public static func replaceBlockRange(
        _ range: ClosedRange<Int>,
        with newBlocks: [Block],
        in projection: DocumentProjection
    ) throws -> EditResult {
        precondition(!newBlocks.isEmpty, "replaceBlockRange requires at least one new block")
        guard range.lowerBound >= 0,
              range.upperBound < projection.document.blocks.count else {
            throw EditingError.outOfBounds
        }
        var newDoc = projection.document
        newDoc.blocks.replaceSubrange(range, with: newBlocks)
        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )
        let oldStart = projection.blockSpans[range.lowerBound].location
        let oldEnd = NSMaxRange(projection.blockSpans[range.upperBound])
        let newStart = newProjection.blockSpans[range.lowerBound].location
        let newEnd = NSMaxRange(
            newProjection.blockSpans[range.lowerBound + newBlocks.count - 1]
        )
        let replacement = newProjection.attributed.attributedSubstring(
            from: NSRange(location: newStart, length: newEnd - newStart)
        )
        return narrowSplice(
            oldAttributedString: projection.attributed,
            oldRange: NSRange(location: oldStart, length: oldEnd - oldStart),
            newReplacement: replacement,
            newProjection: newProjection
        )
    }

    /// Replace `document.blocks[blockIndex]` with a sequence of new
    /// blocks, producing a block-granular splice. The splice range
    /// is the OLD block's span; the replacement is the rendered
    /// concatenation of the new blocks, joined by "\n" separators.
    /// Used for 1→N operations like paragraph split on newline.
    private static func replaceBlocks(
        atIndex blockIndex: Int,
        with newBlocks: [Block],
        in projection: DocumentProjection
    ) throws -> EditResult {
        precondition(!newBlocks.isEmpty, "replaceBlocks requires at least one new block")

        // Fast path: single-block replacement where the block kind is
        // unchanged (the common case for typing/deleting characters).
        // Re-renders ONLY the changed block instead of the entire document.
        if newBlocks.count == 1,
           sameBlockKind(projection.document.blocks[blockIndex], newBlocks[0]) {
            return replaceBlockFast(
                atIndex: blockIndex,
                with: newBlocks[0],
                in: projection
            )
        }

        // Slow path: structural changes (splits, merges, block-type
        // changes). Full re-render of all blocks.
        return replaceBlocksSlow(
            atIndex: blockIndex,
            with: newBlocks,
            in: projection
        )
    }

    /// Fast path for single-block, same-kind replacement. Renders only
    /// the changed block, patches the attributed string and blockSpans
    /// in-place, and diffs for a minimal character-level splice.
    private static func replaceBlockFast(
        atIndex blockIndex: Int,
        with newBlock: Block,
        in projection: DocumentProjection
    ) -> EditResult {
        // 1. Build the new Document.
        var newDoc = projection.document
        newDoc.blocks[blockIndex] = newBlock

        // 2. Render ONLY the changed block. Pass the note through so
        //    image inlines can resolve relative paths and emit real
        //    attachments — without this, makeImageAttachment bails on
        //    the nil-note guard and returns alt text instead.
        let blockRendered = DocumentRenderer.renderBlock(
            newBlock,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        // 3. Apply paragraph style to the rendered block.
        let lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        let mutableBlock = NSMutableAttributedString(attributedString: blockRendered)
        DocumentRenderer.applyParagraphStyle(
            to: mutableBlock,
            range: NSRange(location: 0, length: mutableBlock.length),
            block: newBlock,
            isFirst: (blockIndex == 0),
            baseSize: projection.bodyFont.pointSize,
            lineSpacing: lineSpacing
        )

        // 4. Apply auto-links to the rendered block.
        DocumentRenderer.applyAutoLinks(to: mutableBlock)

        // 5. Patch the full attributed string: copy old, replace the
        //    old block span with the newly rendered block.
        let oldSpan = projection.blockSpans[blockIndex]
        let patchedAttr = NSMutableAttributedString(attributedString: projection.attributed)
        patchedAttr.replaceCharacters(in: oldSpan, with: mutableBlock)

        // 6. Rebuild blockSpans. The changed block's span has a new
        //    length; all subsequent spans shift by the length delta.
        let lengthDelta = mutableBlock.length - oldSpan.length
        var patchedSpans = projection.blockSpans
        patchedSpans[blockIndex] = NSRange(location: oldSpan.location, length: mutableBlock.length)
        for i in (blockIndex + 1)..<patchedSpans.count {
            patchedSpans[i] = NSRange(
                location: patchedSpans[i].location + lengthDelta,
                length: patchedSpans[i].length
            )
        }

        // 7. Build the new projection from the patched data.
        let renderedDoc = RenderedDocument(
            document: newDoc,
            attributed: patchedAttr,
            blockSpans: patchedSpans
        )
        let newProjection = DocumentProjection(
            rendered: renderedDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        // 8. Narrow to minimal splice via character diff.
        return narrowSplice(
            oldAttributedString: projection.attributed,
            oldRange: oldSpan,
            newReplacement: mutableBlock,
            newProjection: newProjection
        )
    }

    /// Slow path: full re-render of all blocks. Used for structural
    /// changes (splits, block-type changes, multi-block replacements).
    private static func replaceBlocksSlow(
        atIndex blockIndex: Int,
        with newBlocks: [Block],
        in projection: DocumentProjection
    ) -> EditResult {
        // Build the new Document by splicing the block list.
        var newDoc = projection.document
        newDoc.blocks.replaceSubrange(blockIndex...blockIndex, with: newBlocks)

        // Produce the new projection (full re-render).
        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        let oldSpan = projection.blockSpans[blockIndex]
        let firstNewSpan = newProjection.blockSpans[blockIndex]
        let lastNewSpan = newProjection.blockSpans[blockIndex + newBlocks.count - 1]
        let newSpanStart = firstNewSpan.location
        let newSpanEnd = NSMaxRange(lastNewSpan)
        let newSpanLength = newSpanEnd - newSpanStart

        let replacement = newProjection.attributed.attributedSubstring(
            from: NSRange(location: newSpanStart, length: newSpanLength)
        )

        return narrowSplice(
            oldAttributedString: projection.attributed,
            oldRange: oldSpan,
            newReplacement: replacement,
            newProjection: newProjection
        )
    }

    /// Check whether two blocks have the same discriminator (kind)
    /// without comparing their content. Used to gate the fast path —
    /// if the kind changes, separators and paragraph styles may differ,
    /// so we fall through to the full re-render.
    private static func sameBlockKind(_ a: Block, _ b: Block) -> Bool {
        switch (a, b) {
        case (.paragraph, .paragraph),
             (.codeBlock, .codeBlock),
             (.list, .list),
             (.blockquote, .blockquote),
             (.blankLine, .blankLine),
             (.htmlBlock, .htmlBlock),
             (.horizontalRule, .horizontalRule):
            return true
        case (.heading(let la, _), .heading(let lb, _)):
            // Same kind only if same level — different levels get
            // different paragraph styles.
            return la == lb
        case (.table(let ha, _, let ra, _), .table(let hb, _, let rb, _)):
            // Same kind only if the grid shape is unchanged. Shape
            // changes (row/column added or removed) take the slow path
            // so the attachment can be rebuilt from scratch. Cell
            // content edits keep the same shape and route through the
            // fast path, which is the hot path for typing in a cell.
            return ha.count == hb.count && ra.count == rb.count
        default:
            return false
        }
    }

    /// Narrow a block-granular splice to character-granular by diffing
    /// the old and new rendered strings. Prevents NSLayoutManager from
    /// scrolling when it sees a large replaced region.
    ///
    /// IMPORTANT: When attachment characters (U+FFFC) are present, we must
    /// be conservative. Attachments all use the same character code but
    /// different attachment objects (e.g., checked vs unchecked checkbox).
    /// Character-only diffing would see them as "common" and preserve the
    /// old attachment, causing visual glitches. We detect attachment
    /// characters and avoid narrowing across them.
    private static func narrowSplice(
        oldAttributedString: NSAttributedString,
        oldRange: NSRange,
        newReplacement: NSAttributedString,
        newProjection: DocumentProjection
    ) -> EditResult {
        let oldStr = (oldAttributedString.string as NSString).substring(with: oldRange)
        let newStr = newReplacement.string

        // If the strings are exactly identical but the attributed strings differ,
        // we must not narrow to 0 length, otherwise the attribute changes (e.g. bold, heading level) are lost.
        if oldStr == newStr {
            let oldAttrStr = oldAttributedString.attributedSubstring(from: oldRange)
            if !oldAttrStr.isEqual(to: newReplacement) {
                return EditResult(
                    newProjection: newProjection,
                    spliceRange: oldRange,
                    spliceReplacement: newReplacement
                )
            }
        }

        // Check for attachment characters in the range. If present, don't narrow
        // because attachments all use U+FFFC but have different attachment objects.
        let attachmentChar = Character("\u{FFFC}")
        let hasAttachmentInOld = oldStr.contains(attachmentChar)
        let hasAttachmentInNew = newStr.contains(attachmentChar)

        // If there are attachments, we need to be more careful about narrowing.
        // When both old and new have attachments at the same positions, we should
        // still narrow. But when new attachments are being added or removed,
        // we need to ensure the splice covers them.
        if hasAttachmentInOld || hasAttachmentInNew {
            // Count attachments in both
            let oldAttachmentCount = oldStr.filter { $0 == attachmentChar }.count
            let newAttachmentCount = newStr.filter { $0 == attachmentChar }.count

            // If attachment counts differ, we have structural changes (new item inserted, etc.)
            // Don't narrow - use the full range to ensure proper attachment handling.
            if oldAttachmentCount != newAttachmentCount {
                return EditResult(
                    newProjection: newProjection,
                    spliceRange: oldRange,
                    spliceReplacement: newReplacement
                )
            }

            // Same attachment count - attachments may have changed state (checked vs unchecked)
            // We should compare the actual attachment objects to see if they're equal.
            // For now, be conservative and don't narrow when attachments are present.
            // TODO: Optimize by comparing attachment equality at each position.
            let oldHasAttachmentsAtPositions = findAttachmentPositions(in: oldAttributedString, range: oldRange)
            let newHasAttachmentsAtPositions = findAttachmentPositions(in: newReplacement, range: NSRange(location: 0, length: newReplacement.length))

            if !oldHasAttachmentsAtPositions.isEmpty || !newHasAttachmentsAtPositions.isEmpty {
                // Check if attachments are at the same positions with same attributes
                if oldHasAttachmentsAtPositions != newHasAttachmentsAtPositions {
                    return EditResult(
                        newProjection: newProjection,
                        spliceRange: oldRange,
                        spliceReplacement: newReplacement
                    )
                }
                // Attachments are at the same positions - but we still need to verify
                // the attachment objects themselves are equal. For now, be conservative.
            }
        }

        let oldChars = Array(oldStr.unicodeScalars)
        let newChars = Array(newStr.unicodeScalars)
        let minLen = min(oldChars.count, newChars.count)

        // Character-only comparison for prefix/suffix narrowing.
        // Do NOT compare attributes here: attribute objects from the old
        // projection vs a freshly-rendered projection are semantically
        // equal but not object-equal (NSTextAttachment, NSParagraphStyle
        // instances differ). Comparing them would break the prefix at
        // position 0, replacing the entire block and discarding loaded
        // image/PDF attachments that the hydrator already populated.
        var commonPrefix = 0
        while commonPrefix < minLen && oldChars[commonPrefix] == newChars[commonPrefix] {
            commonPrefix += 1
        }
        var commonSuffix = 0
        while commonSuffix < (minLen - commonPrefix)
                && oldChars[oldChars.count - 1 - commonSuffix] == newChars[newChars.count - 1 - commonSuffix] {
            commonSuffix += 1
        }

        let narrowRange = NSRange(
            location: oldRange.location + commonPrefix,
            length: oldChars.count - commonPrefix - commonSuffix
        )
        let narrowRepLen = newChars.count - commonPrefix - commonSuffix
        let narrowRep = narrowRepLen > 0
            ? newReplacement.attributedSubstring(from: NSRange(location: commonPrefix, length: narrowRepLen))
            : NSAttributedString(string: "")

        return EditResult(
            newProjection: newProjection,
            spliceRange: narrowRange,
            spliceReplacement: narrowRep
        )
    }

    /// Merge two adjacent blocks `blocks[i]` and `blocks[i+1]`,
    /// deleting characters `[startOffset..end)` from the first block
    /// and `[0..endOffset)` from the second. Produces a single merged
    /// block and a splice that covers both old blocks plus the
    /// separator between them.
    ///
    /// The merge pairs are defined by the Cross-Block Merge table in
    /// ARCHITECTURE.md §192. Dispatch happens in `mergeTwoBlocks`.
    private static func mergeAdjacentBlocks(
        startBlock: Int,
        startOffset: Int,
        endBlock: Int,
        endOffset: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let blockA = projection.document.blocks[startBlock]
        let blockB = projection.document.blocks[endBlock]
        let spanA = projection.blockSpans[startBlock]
        let spanB = projection.blockSpans[endBlock]

        // Determine what survives from block A (everything before
        // startOffset) and block B (everything after endOffset).
        // Use deleteInBlock to properly handle all block types
        // including lists and blockquotes.
        let blockALength = spanA.length
        let blockBLength = spanB.length

        // Truncate block A: keep [0, startOffset), delete [startOffset, end).
        let truncatedA: Block?
        if startOffset == 0 {
            // Nothing survives from block A.
            truncatedA = nil
        } else if startOffset >= blockALength {
            // All of block A survives.
            truncatedA = blockA
        } else {
            truncatedA = keepFirstRenderedChars(
                blockA, count: startOffset, totalLength: blockALength
            )
        }

        // Truncate block B: delete [0, endOffset), keep [endOffset, end).
        let truncatedB: Block?
        if endOffset >= blockBLength {
            // Nothing survives from block B.
            truncatedB = nil
        } else if endOffset == 0 {
            // All of block B survives.
            truncatedB = blockB
        } else {
            truncatedB = dropFirstRenderedChars(
                blockB, count: endOffset, totalLength: blockBLength
            )
        }

        // Determine the merged result. When both boundaries have
        // surviving content, merge their inline trees into a paragraph.
        var mergeIncludesPrevious = false
        let replacementBlocks: [Block]
        switch (truncatedA, truncatedB) {
        case (.some(let a), .some(let b)):
            // Both boundary blocks have surviving content. Dispatch
            // through mergeTwoBlocks, which implements the Cross-Block
            // Merge table in ARCHITECTURE.md §192.
            replacementBlocks = mergeTwoBlocks(a, b)
        case (.some(let a), .none):
            // Only block A survives — keep its type.
            replacementBlocks = [a]
        case (.none, .some(let b)):
            // Only block B survives. If the deleted range started at a
            // blankLine that separated two paragraphs, merging block B
            // into the preceding paragraph (by extracting its inlines)
            // is required — otherwise serialize→parse creates a single
            // paragraph from two adjacent non-blank-separated ones.
            //
            // Skip this path when B is a structural block (list,
            // blockquote, heading, code, HR) — flattening them via
            // extractInlines would destroy the structure. For those
            // types, preserve the surviving block as-is.
            let bIsStructural: Bool
            switch b {
            case .paragraph, .blankLine: bIsStructural = false
            default: bIsStructural = true
            }
            if !bIsStructural,
               startBlock > 0,
               case .blankLine = blockA,
               case .paragraph(let prevInline) = projection.document.blocks[startBlock - 1] {
                let inlinesB = extractInlines(from: b)
                // Merge preceding paragraph + block B into one paragraph.
                replacementBlocks = [.paragraph(inline: prevInline + inlinesB)]
                // Expand the merge range to include the preceding paragraph.
                mergeIncludesPrevious = true
            } else {
                replacementBlocks = [b]
            }
        case (.none, .none):
            // Both blocks are fully consumed. If there are no blocks
            // at all after removing [startBlock...endBlock], insert a
            // blank line so the document is never empty.
            let totalBlocks = projection.document.blocks.count
            let removedCount = endBlock - startBlock + 1
            if removedCount >= totalBlocks {
                replacementBlocks = [.paragraph(inline: [.text("")])]
            } else {
                replacementBlocks = []
            }
        }

        // Build new document: remove blocks[startBlock...endBlock],
        // insert replacement(s). When mergeIncludesPrevious is set,
        // also remove the preceding paragraph (it's been merged into
        // the replacement block).
        let effectiveStart = mergeIncludesPrevious ? startBlock - 1 : startBlock
        var newDoc = projection.document
        newDoc.blocks.replaceSubrange(effectiveStart...endBlock, with: replacementBlocks)

        // Splice range: from start of the effective first block's span
        // to end of blockB's span.
        let effectiveSpanA = mergeIncludesPrevious
            ? projection.blockSpans[startBlock - 1]
            : spanA
        let spliceStart = effectiveSpanA.location
        let spliceEnd = spanB.location + spanB.length
        // Also consume the trailing separator "\n" after the last
        // block if it exists (so we don't leave a stale newline).
        let maxSpliceEnd: Int
        if endBlock < projection.document.blocks.count - 1 {
            // There are blocks after endBlock — the separator "\n"
            // after endBlock is at spanB.location + spanB.length.
            // Include it in the splice range when we're removing
            // blocks entirely.
            if replacementBlocks.isEmpty {
                maxSpliceEnd = min(spliceEnd + 1, projection.attributed.length)
            } else {
                maxSpliceEnd = spliceEnd
            }
        } else {
            maxSpliceEnd = spliceEnd
        }
        let spliceRange = NSRange(location: spliceStart, length: maxSpliceEnd - spliceStart)

        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        // Extract the replacement content from the new projection.
        let replacement: NSAttributedString
        if replacementBlocks.isEmpty {
            replacement = NSAttributedString(string: "")
        } else {
            let firstSpan = newProjection.blockSpans[effectiveStart]
            let lastSpan = newProjection.blockSpans[effectiveStart + replacementBlocks.count - 1]
            let repStart = firstSpan.location
            let repEnd = lastSpan.location + lastSpan.length
            replacement = newProjection.attributed.attributedSubstring(
                from: NSRange(location: repStart, length: repEnd - repStart)
            )
        }

        // Narrow the splice to only the changed characters to avoid
        // NSLayoutManager scroll-on-large-replace.
        return narrowSplice(
            oldAttributedString: projection.attributed,
            oldRange: spliceRange,
            newReplacement: replacement,
            newProjection: newProjection
        )
    }

    /// Extract the FIRST `keepCount` rendered characters of a block's
    /// inline content. Returns the inline tree truncated at that offset,
    /// or `nil` if the block has no inline content (blankLine, HR).
    private static func remainingInlineSuffix(
        of block: Block,
        keepingUpTo keepCount: Int
    ) throws -> [Inline]? {
        switch block {
        case .paragraph(let inline):
            let (before, _) = splitInlines(inline, at: keepCount)
            return before
        case .blankLine:
            return nil
        case .horizontalRule:
            // HR rendered content is visual glyphs, not text. On merge,
            // treat as having no inline remainder.
            return nil
        case .heading(let _, let suffix):
            // Use the displayed text portion. HeadingRenderer strips
            // only leading whitespace, so trailing is not trimmed here.
            let leading = leadingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading))
            let (before, _) = splitInlines([.text(displayed)], at: keepCount)
            return before
        case .codeBlock(_, let content, _):
            let (before, _) = splitInlines([.text(content)], at: keepCount)
            return before
        case .htmlBlock(let raw):
            let (before, _) = splitInlines([.text(raw)], at: keepCount)
            return before
        case .list, .blockquote:
            // For merging purposes, extract the block's rendered text as
            // a flat paragraph. This converts the block type but
            // preserves the text content.
            let rendered = blockRenderedText(block)
            let (before, _) = splitInlines([.text(rendered)], at: keepCount)
            return before
        case .table:
            // Table rendered content is a text grid. On merge, treat
            // as having no inline remainder (like HR).
            return nil
        }
    }

    /// Extract the inline content of a block AFTER dropping the first
    /// `dropCount` rendered characters. Returns the remaining inline
    /// tree, or `nil` if the block has no inline content.
    private static func remainingInlinePrefix(
        of block: Block,
        droppingUpTo dropCount: Int
    ) throws -> [Inline]? {
        switch block {
        case .paragraph(let inline):
            let (_, after) = splitInlines(inline, at: dropCount)
            return after
        case .blankLine:
            return nil
        case .horizontalRule:
            return nil
        case .heading(let _, let suffix):
            let leading = leadingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading))
            let (_, after) = splitInlines([.text(displayed)], at: dropCount)
            return after
        case .codeBlock(_, let content, _):
            let (_, after) = splitInlines([.text(content)], at: dropCount)
            return after
        case .htmlBlock(let raw):
            let (_, after) = splitInlines([.text(raw)], at: dropCount)
            return after
        case .list, .blockquote:
            let rendered = blockRenderedText(block)
            let (_, after) = splitInlines([.text(rendered)], at: dropCount)
            return after
        case .table:
            return nil
        }
    }

    /// Structurally drop the first `dropCount` rendered characters from a
    /// block. Unlike `deleteInBlock`, this can cross list-item separators
    /// and blockquote-line separators — entire items/lines fully within
    /// the dropped range are removed, and the boundary item/line is trimmed.
    ///
    /// Returns nil if the entire block is consumed (dropCount >= total).
    /// Used by `mergeAdjacentBlocks` for cross-block delete where the
    /// selection may span multiple list items or blockquote lines.
    private static func dropFirstRenderedChars(
        _ block: Block,
        count dropCount: Int,
        totalLength: Int
    ) -> Block? {
        if dropCount <= 0 { return block }
        if dropCount >= totalLength { return nil }

        switch block {
        case .list(let items, let loose):
            var surviving: [ListItem] = []
            var cursor = 0
            for topItem in items {
                // Full subtree extent for this top-level item.
                let subtree = flattenList([topItem], depth: 0, startOffset: cursor, path: [])
                guard let last = subtree.last else { continue }
                let topEntry = subtree[0]
                let subtreeEnd = last.startOffset + last.prefixLength + last.inlineLength
                let nextCursor = subtreeEnd + 1  // "\n" separator between siblings

                if subtreeEnd <= dropCount {
                    // Whole subtree dropped.
                    cursor = nextCursor
                    continue
                }
                if topEntry.startOffset >= dropCount {
                    // Fully kept.
                    surviving.append(topItem)
                    cursor = nextCursor
                    continue
                }
                // Boundary: dropCount falls within this item's inline
                // range or within its children. Keep the whole item but
                // trim its inline content if the boundary is inside it.
                let topInlineStart = topEntry.startOffset + topEntry.prefixLength
                let topInlineEnd = topInlineStart + topEntry.inlineLength
                if dropCount <= topInlineEnd {
                    let localDrop = max(0, dropCount - topInlineStart)
                    let (_, afterInline) = splitInlines(topItem.inline, at: localDrop)
                    surviving.append(ListItem(
                        indent: topItem.indent, marker: topItem.marker,
                        afterMarker: topItem.afterMarker, checkbox: topItem.checkbox,
                        inline: afterInline, children: topItem.children
                    ))
                } else {
                    // Boundary lies within children — keep the whole item
                    // intact (conservative: we don't recursively trim).
                    surviving.append(topItem)
                }
                cursor = nextCursor
            }
            if surviving.isEmpty { return nil }
            return .list(items: surviving, loose: loose)

        case .blockquote(let lines):
            // Lines are separated by "\n". Each line's rendered length
            // equals its inline length (no prefix chars — indent is via
            // paragraph style).
            var surviving: [BlockquoteLine] = []
            var cursor = 0
            for line in lines {
                let lineLen = inlinesLength(line.inline)
                let lineEnd = cursor + lineLen
                if lineEnd <= dropCount {
                    cursor = lineEnd + 1
                    continue
                }
                if cursor >= dropCount {
                    surviving.append(line)
                    cursor = lineEnd + 1
                    continue
                }
                let localDrop = max(0, dropCount - cursor)
                let (_, after) = splitInlines(line.inline, at: localDrop)
                surviving.append(BlockquoteLine(prefix: line.prefix, inline: after))
                cursor = lineEnd + 1
            }
            if surviving.isEmpty { return nil }
            return .blockquote(lines: surviving)

        default:
            return try? deleteInBlock(block, from: 0, to: dropCount)
        }
    }

    /// Structurally keep the first `keepCount` rendered characters of a
    /// block. Mirror of `dropFirstRenderedChars` for the A-side of a
    /// cross-block merge.
    private static func keepFirstRenderedChars(
        _ block: Block,
        count keepCount: Int,
        totalLength: Int
    ) -> Block? {
        if keepCount <= 0 { return nil }
        if keepCount >= totalLength { return block }

        switch block {
        case .list(let items, let loose):
            var surviving: [ListItem] = []
            var cursor = 0
            for topItem in items {
                let subtree = flattenList([topItem], depth: 0, startOffset: cursor, path: [])
                guard let last = subtree.last else { continue }
                let topEntry = subtree[0]
                let subtreeEnd = last.startOffset + last.prefixLength + last.inlineLength
                let nextCursor = subtreeEnd + 1

                if subtreeEnd <= keepCount {
                    // Wholly kept.
                    surviving.append(topItem)
                    cursor = nextCursor
                    continue
                }
                if topEntry.startOffset >= keepCount {
                    // Fully dropped.
                    cursor = nextCursor
                    continue
                }
                // Boundary item.
                let topInlineStart = topEntry.startOffset + topEntry.prefixLength
                let topInlineEnd = topInlineStart + topEntry.inlineLength
                if keepCount <= topInlineEnd {
                    let localKeep = max(0, keepCount - topInlineStart)
                    let (beforeInline, _) = splitInlines(topItem.inline, at: localKeep)
                    surviving.append(ListItem(
                        indent: topItem.indent, marker: topItem.marker,
                        afterMarker: topItem.afterMarker, checkbox: topItem.checkbox,
                        inline: beforeInline, children: []
                    ))
                } else {
                    // Boundary within children — keep the top item, drop children.
                    surviving.append(ListItem(
                        indent: topItem.indent, marker: topItem.marker,
                        afterMarker: topItem.afterMarker, checkbox: topItem.checkbox,
                        inline: topItem.inline, children: []
                    ))
                }
                cursor = nextCursor
            }
            if surviving.isEmpty { return nil }
            return .list(items: surviving, loose: loose)

        case .blockquote(let lines):
            var surviving: [BlockquoteLine] = []
            var cursor = 0
            for line in lines {
                let lineLen = inlinesLength(line.inline)
                let lineEnd = cursor + lineLen
                if lineEnd <= keepCount {
                    surviving.append(line)
                    cursor = lineEnd + 1
                    continue
                }
                if cursor >= keepCount {
                    cursor = lineEnd + 1
                    continue
                }
                let localKeep = max(0, keepCount - cursor)
                let (before, _) = splitInlines(line.inline, at: localKeep)
                surviving.append(BlockquoteLine(prefix: line.prefix, inline: before))
                cursor = lineEnd + 1
            }
            if surviving.isEmpty { return nil }
            return .blockquote(lines: surviving)

        default:
            return try? deleteInBlock(block, from: keepCount, to: totalLength)
        }
    }

    /// Merge two blocks according to the Cross-Block Merge table in
    /// ARCHITECTURE.md §192. Returns the replacement block(s).
    ///
    /// The caller (`mergeAdjacentBlocks`) has already truncated each
    /// block to the surviving portion on either side of the deleted
    /// range, so this function only implements the type-aware join
    /// logic.
    private static func mergeTwoBlocks(_ a: Block, _ b: Block) -> [Block] {
        // any + horizontalRule → HR dropped (block A survives).
        if case .horizontalRule = b { return [a] }

        // any + codeBlock → code block dropped (content lost).
        if case .codeBlock = b { return [a] }

        // any + blockquote → block A gets the first line's inlines
        // appended to its tail (respecting A's type). Remaining lines
        // survive as a trailing blockquote block.
        if case .blockquote(let lines) = b {
            let firstLineInlines = lines.first?.inline ?? []
            let remaining = Array(lines.dropFirst())
            let mergedA = appendInlinesToTail(a, firstLineInlines)
            if remaining.isEmpty { return [mergedA] }
            return [mergedA, .blockquote(lines: remaining)]
        }

        // blankLine + any → blank removed, second block survives as-is.
        if case .blankLine = a { return [b] }

        // any + blankLine → blank removed, first block survives as-is.
        if case .blankLine = b { return [a] }

        // paragraph + list → paragraph receives the first item's inlines;
        // the first item's children and any remaining items survive as
        // a continuing list block.
        if case .paragraph(let aInline) = a, case .list(let items, let loose) = b,
           let firstItem = items.first {
            let mergedPara = Block.paragraph(inline: aInline + firstItem.inline)
            // Promote firstItem's children + remaining siblings.
            var survivors = firstItem.children
            survivors.append(contentsOf: items.dropFirst())
            if survivors.isEmpty { return [mergedPara] }
            return [mergedPara, .list(items: survivors, loose: loose)]
        }

        // list + paragraph → paragraph's inlines appended to last leaf item.
        if case .list(let items, let loose) = a, case .paragraph(let bInline) = b {
            let newItems = appendInlinesToLastLeafItem(items, inlines: bInline)
            return [.list(items: newItems, loose: loose)]
        }

        // heading + heading → first heading with second's text appended.
        if case .heading(let aLevel, let aSuffix) = a,
           case .heading(_, let bSuffix) = b {
            let bLead = leadingWhitespaceCount(in: bSuffix)
            let bText = String(bSuffix.dropFirst(bLead))
            return [.heading(level: aLevel, suffix: aSuffix + bText)]
        }

        // heading + paragraph → heading with paragraph's inline text appended.
        if case .heading(let aLevel, let aSuffix) = a, case .paragraph(let bInline) = b {
            return [.heading(level: aLevel, suffix: aSuffix + inlinesToText(bInline))]
        }

        // paragraph + heading → paragraph with heading's suffix text appended.
        if case .paragraph(let aInline) = a, case .heading(_, let bSuffix) = b {
            let bLead = leadingWhitespaceCount(in: bSuffix)
            let bText = String(bSuffix.dropFirst(bLead))
            let appended: [Inline] = bText.isEmpty ? aInline : aInline + [.text(bText)]
            return [.paragraph(inline: appended)]
        }

        // Fallback (pairs not listed in ARCHITECTURE.md §192, e.g. list+list
        // or list+heading): extract inlines from both and concatenate as
        // a paragraph. Preserves the previous flattening behavior for
        // unspecified cases.
        let inlinesA = extractInlines(from: a)
        let inlinesB = extractInlines(from: b)
        if inlinesA.isEmpty && inlinesB.isEmpty {
            return [.blankLine]
        }
        return [.paragraph(inline: inlinesA + inlinesB)]
    }

    /// Append inlines to the "tail" of a block, respecting the block's
    /// type. For paragraphs the inlines are concatenated; for headings
    /// the inlines are flattened to text and appended to the suffix;
    /// for lists the inlines are appended to the last leaf item's
    /// inline content. Fallback: flatten both sides to a paragraph.
    private static func appendInlinesToTail(_ block: Block, _ inlines: [Inline]) -> Block {
        if inlines.isEmpty { return block }
        switch block {
        case .paragraph(let aInline):
            return .paragraph(inline: aInline + inlines)
        case .heading(let level, let suffix):
            return .heading(level: level, suffix: suffix + inlinesToText(inlines))
        case .list(let items, let loose):
            let newItems = appendInlinesToLastLeafItem(items, inlines: inlines)
            return .list(items: newItems, loose: loose)
        default:
            let existing = extractInlines(from: block)
            return .paragraph(inline: existing + inlines)
        }
    }

    /// Append inlines to the last leaf item of a list tree. Walks the
    /// last-child chain to find the deepest trailing item, then appends
    /// the new inlines to its inline content.
    private static func appendInlinesToLastLeafItem(
        _ items: [ListItem], inlines: [Inline]
    ) -> [ListItem] {
        guard !items.isEmpty else { return items }
        var result = items
        let lastIdx = result.count - 1
        let last = result[lastIdx]
        let newInline: [Inline]
        let newChildren: [ListItem]
        if last.children.isEmpty {
            newInline = last.inline + inlines
            newChildren = last.children
        } else {
            newInline = last.inline
            newChildren = appendInlinesToLastLeafItem(last.children, inlines: inlines)
        }
        result[lastIdx] = ListItem(
            indent: last.indent,
            marker: last.marker,
            afterMarker: last.afterMarker,
            checkbox: last.checkbox,
            inline: newInline,
            children: newChildren,
            blankLineBefore: last.blankLineBefore
        )
        return result
    }

    /// Extract the inline tree from a block, preserving formatting.
    /// For structured blocks (lists, blockquotes) the content is
    /// flattened to plain text inlines. For paragraphs, the inline
    /// tree is returned as-is to preserve bold/italic/etc.
    private static func extractInlines(from block: Block) -> [Inline] {
        switch block {
        case .paragraph(let inline): return inline
        case .heading(_, let suffix):
            let l = leadingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(l))
            return [.text(displayed)]
        case .codeBlock(_, let content, _): return [.text(content)]
        case .htmlBlock(let raw): return [.text(raw)]
        case .list, .blockquote, .horizontalRule, .blankLine, .table:
            let text = blockRenderedText(block)
            return text.isEmpty ? [] : [.text(text)]
        }
    }

    /// Extract the rendered text content of a block as a plain string.
    /// Used for merge operations where the block type is lost.
    private static func blockRenderedText(_ block: Block) -> String {
        switch block {
        case .paragraph(let inline): return inlinesToText(inline)
        case .heading(_, let suffix):
            let l = leadingWhitespaceCount(in: suffix)
            return String(suffix.dropFirst(l))
        case .codeBlock(_, let content, _): return content
        case .htmlBlock(let raw): return raw
        case .list(let items, _): return listItemsToText(items, depth: 0)
        case .blockquote(let lines):
            return lines.map { inlinesToText($0.inline) }.joined(separator: "\n")
        case .horizontalRule: return ""
        case .blankLine: return ""
        case .table(_, _, _, let raw): return raw
        }
    }

    private static func inlinesToText(_ inlines: [Inline]) -> String {
        return inlines.map { inlineToText($0) }.joined()
    }

    private static func inlineToText(_ inline: Inline) -> String {
        switch inline {
        case .text(let s): return s
        case .code(let s): return s
        case .bold(let c, _): return inlinesToText(c)
        case .italic(let c, _): return inlinesToText(c)
        case .strikethrough(let c): return inlinesToText(c)
        case .underline(let c): return inlinesToText(c)
        case .highlight(let c): return inlinesToText(c)
        case .math(let s): return s
        case .displayMath(let s): return s
        case .link(let text, _): return inlinesToText(text)
        case .image(let alt, _, _): return inlinesToText(alt)
        case .autolink(let text, _): return text
        case .escapedChar(let ch): return String(ch)
        case .lineBreak: return "\n"
        case .rawHTML(let html): return html
        case .entity(let raw): return raw
        case .wikilink(let target, let display): return display ?? target
        }
    }

    private static func listItemsToText(_ items: [ListItem], depth: Int) -> String {
        var parts: [String] = []
        for item in items {
            parts.append(inlinesToText(item.inline))
            if !item.children.isEmpty {
                parts.append(listItemsToText(item.children, depth: depth + 1))
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Multi-line paste

    /// Paste a multi-line string into a paragraph at the given render
    /// offset. The paragraph is split at the offset, the pasted text
    /// is split by `\n` into lines, and each line becomes a paragraph:
    ///
    ///   before-text + first-line   →  first paragraph
    ///   middle lines (if any)      →  one paragraph each
    ///   last-line + after-text     →  last paragraph
    ///
    /// Empty lines become `.blankLine` blocks. Inline formatting from
    /// the original paragraph is preserved on the before/after halves.
    private static func pasteIntoParagraph(
        inline: [Inline],
        at offset: Int,
        pastedText: String,
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let (before, after) = splitInlines(inline, at: offset)

        // Bug 39: parse the pasted text as a full document so inline
        // markers (bold/italic/links/wikilinks) and block structure
        // (paragraphs separated by blank lines, headings, lists) all
        // survive. The previous implementation split on every `\n`
        // and wrapped each line as a single `.text` node, losing:
        //   (a) inline formatting (bold, italic, etc.)
        //   (b) paragraph vs soft-break distinction (single `\n` in
        //       source markdown is a soft break within a paragraph;
        //       `\n\n` is a paragraph separator)
        let pastedDoc = MarkdownParser.parse(pastedText)
        var pastedBlocks = pastedDoc.blocks

        // Merge the `before` inlines into the first pasted block if it
        // is a paragraph, and `after` into the last one, preserving the
        // inline formatting on either side of the insertion point.
        if !before.isEmpty, !pastedBlocks.isEmpty,
           case .paragraph(let firstInline) = pastedBlocks.first! {
            pastedBlocks[0] = .paragraph(inline: before + firstInline)
        } else if !before.isEmpty {
            pastedBlocks.insert(.paragraph(inline: before), at: 0)
        }

        if !after.isEmpty, !pastedBlocks.isEmpty,
           case .paragraph(let lastInline) = pastedBlocks.last! {
            pastedBlocks[pastedBlocks.count - 1] = .paragraph(
                inline: lastInline + after
            )
        } else if !after.isEmpty {
            pastedBlocks.append(.paragraph(inline: after))
        }

        if pastedBlocks.isEmpty {
            // Defensive: empty paste.
            pastedBlocks.append(.paragraph(inline: before + after))
        }

        return try replaceBlocks(atIndex: blockIndex, with: pastedBlocks, in: projection)
    }
    
    /// Multi-line paste into a list. Splits the current item at the offset,
    /// inserts the pasted content (first line merged with before, last line
    /// merged with after), and wraps pasted lines in list items.
    private static func pasteIntoList(
        items: [ListItem],
        at offsetInBlock: Int,
        pastedText: String,
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(reason: "pasteIntoList: offset not in list item")
        }
        
        let entry = entries[entryIdx]
        let item = entry.item
        let (before, after) = splitInlines(item.inline, at: inlineOffset)
        
        // Parse the pasted text as markdown
        let pastedDoc = MarkdownParser.parse(pastedText)
        var pastedBlocks = pastedDoc.blocks
        
        // Convert pasted blocks to list items
        var pastedItems: [ListItem] = []
        for block in pastedBlocks {
            switch block {
            case .paragraph(let inline):
                pastedItems.append(ListItem(
                    indent: item.indent,
                    marker: item.marker,
                    afterMarker: item.afterMarker,
                    checkbox: nil,
                    inline: inline,
                    children: []
                ))
            case .list(let newItems, _):
                // Flatten nested list into items at current level
                pastedItems.append(contentsOf: newItems)
            default:
                // Other block types become paragraphs - extract text content
                let text = blockRenderedText(block)
                pastedItems.append(ListItem(
                    indent: item.indent,
                    marker: item.marker,
                    afterMarker: item.afterMarker,
                    checkbox: nil,
                    inline: [.text(text)],
                    children: []
                ))
            }
        }
        
        // Merge before into first pasted item
        if !before.isEmpty, !pastedItems.isEmpty {
            pastedItems[0] = ListItem(
                indent: pastedItems[0].indent,
                marker: pastedItems[0].marker,
                afterMarker: pastedItems[0].afterMarker,
                checkbox: pastedItems[0].checkbox,
                inline: before + pastedItems[0].inline,
                children: pastedItems[0].children
            )
        } else if !before.isEmpty {
            pastedItems.insert(ListItem(
                indent: item.indent,
                marker: item.marker,
                afterMarker: item.afterMarker,
                checkbox: nil,
                inline: before,
                children: []
            ), at: 0)
        }
        
        // Merge after into last pasted item
        if !after.isEmpty, !pastedItems.isEmpty {
            let last = pastedItems[pastedItems.count - 1]
            pastedItems[pastedItems.count - 1] = ListItem(
                indent: last.indent,
                marker: last.marker,
                afterMarker: last.afterMarker,
                checkbox: last.checkbox,
                inline: last.inline + after,
                children: last.children
            )
        } else if !after.isEmpty {
            pastedItems.append(ListItem(
                indent: item.indent,
                marker: item.marker,
                afterMarker: item.afterMarker,
                checkbox: nil,
                inline: after,
                children: []
            ))
        }
        
        if pastedItems.isEmpty {
            pastedItems = [ListItem(
                indent: item.indent,
                marker: item.marker,
                afterMarker: item.afterMarker,
                checkbox: nil,
                inline: before + after,
                children: []
            )]
        }
        
        // Build new list by replacing the current item with pasted items
        let newItems = replaceItemAtPath(items, path: entry.path, with: pastedItems[0])
        // Insert remaining pasted items after the first
        var finalItems = newItems
        if pastedItems.count > 1 {
            // Find the index where we need to insert using ListEditing helper
            if let insertIdx = itemIndexInFlattenedList(newItems, path: entry.path) {
                for i in 1..<pastedItems.count {
                    finalItems.insert(pastedItems[i], at: insertIdx + i)
                }
            }
        }
        
        return try replaceBlock(
            atIndex: blockIndex,
            with: .list(items: finalItems),
            in: projection
        )
    }
    
    /// Multi-line paste into a blockquote. Splits the current line at the offset,
    /// inserts the pasted content as new blockquote lines.
    private static func pasteIntoBlockquote(
        lines: [BlockquoteLine],
        at offsetInBlock: Int,
        pastedText: String,
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let flattened = flattenBlockquote(lines)
        guard let (lineIdx, inlineOffset) = quoteEntryContaining(
            entries: flattened, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(reason: "pasteIntoBlockquote: offset not in line")
        }
        
        let line = lines[lineIdx]
        let (before, after) = splitInlines(line.inline, at: inlineOffset)
        
        // Parse the pasted text as markdown
        let pastedDoc = MarkdownParser.parse(pastedText)
        var pastedBlocks = pastedDoc.blocks
        
        // Convert pasted blocks to blockquote lines with same prefix
        var pastedLines: [BlockquoteLine] = []
        for block in pastedBlocks {
            switch block {
            case .paragraph(let inline):
                pastedLines.append(BlockquoteLine(prefix: line.prefix, inline: inline))
            case .blockquote(let newLines):
                // Flatten nested blockquote
                pastedLines.append(contentsOf: newLines.map {
                    BlockquoteLine(prefix: line.prefix + $0.prefix, inline: $0.inline)
                })
            default:
                // Other block types become lines - extract text content
                let text = blockRenderedText(block)
                pastedLines.append(BlockquoteLine(prefix: line.prefix, inline: [.text(text)]))
            }
        }
        
        // Merge before into first pasted line
        if !before.isEmpty, !pastedLines.isEmpty {
            pastedLines[0] = BlockquoteLine(
                prefix: pastedLines[0].prefix,
                inline: before + pastedLines[0].inline
            )
        } else if !before.isEmpty {
            pastedLines.insert(BlockquoteLine(prefix: line.prefix, inline: before), at: 0)
        }
        
        // Merge after into last pasted line
        if !after.isEmpty, !pastedLines.isEmpty {
            let last = pastedLines[pastedLines.count - 1]
            pastedLines[pastedLines.count - 1] = BlockquoteLine(
                prefix: last.prefix,
                inline: last.inline + after
            )
        } else if !after.isEmpty {
            pastedLines.append(BlockquoteLine(prefix: line.prefix, inline: after))
        }
        
        if pastedLines.isEmpty {
            pastedLines = [BlockquoteLine(prefix: line.prefix, inline: before + after)]
        }
        
        // Build new blockquote by replacing current line with pasted lines
        var newLines = lines
        newLines.replaceSubrange(lineIdx...lineIdx, with: pastedLines)
        
        return try replaceBlock(
            atIndex: blockIndex,
            with: .blockquote(lines: newLines),
            in: projection
        )
    }
    
    /// Multi-line paste into a heading. Splits at the offset, converts the heading
    /// to a paragraph with before+first-pasted-line, then inserts remaining pasted content.
    private static func pasteIntoHeading(
        level: Int,
        suffix: String,
        at offsetInBlock: Int,
        pastedText: String,
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let leading = leadingWhitespaceCount(in: suffix)
        let suffixOffset = offsetInBlock + leading
        let beforeText = String(suffix.prefix(suffixOffset))
        let afterText = String(suffix.dropFirst(suffixOffset))
        
        // Parse the pasted text as markdown
        let pastedDoc = MarkdownParser.parse(pastedText)
        var pastedBlocks = pastedDoc.blocks
        
        // Build new blocks: heading becomes paragraph, then pasted content
        var newBlocks: [Block] = []
        
        // First block: heading text before cursor + first pasted content
        let beforeInlines = beforeText.isEmpty ? [] : MarkdownParser.parseInlines(beforeText)
        
        if !pastedBlocks.isEmpty, case .paragraph(let firstInline) = pastedBlocks[0] {
            // Merge before text with first pasted paragraph
            newBlocks.append(.paragraph(inline: beforeInlines + firstInline))
            pastedBlocks.removeFirst()
        } else {
            newBlocks.append(.paragraph(inline: beforeInlines))
        }
        
        // Middle blocks: remaining pasted content
        newBlocks.append(contentsOf: pastedBlocks)
        
        // Last block: merge after text
        if !afterText.isEmpty {
            let afterInlines = MarkdownParser.parseInlines(afterText)
            if let lastIdx = newBlocks.indices.last, case .paragraph(let lastInline) = newBlocks[lastIdx] {
                newBlocks[lastIdx] = .paragraph(inline: lastInline + afterInlines)
            } else {
                newBlocks.append(.paragraph(inline: afterInlines))
            }
        }
        
        if newBlocks.isEmpty {
            newBlocks = [.paragraph(inline: [])]
        }
        
        return try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
    }

    // MARK: - List newline (Return key)

    /// Handle Return key in a list. If the item is empty, delegates to
    /// the FSM (exit or unindent). Otherwise splits the item's inline
    /// content and inserts a new item after the current one.
    ///
    /// This is called from the top-level `insert("\n", ...)` path. It
    /// returns `nil` to signal that the caller should use
    /// `returnOnEmptyListItem` instead (which produces an EditResult
    /// directly, not just [Block]).
    static func splitListOnNewline(
        items: [ListItem],
        at offsetInBlock: Int,
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> [Block] {
        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(
                reason: "list: cannot split at offset \(offsetInBlock) (not in inline content)"
            )
        }
        let entry = entries[entryIdx]

        // FSM: if item is empty, signal that we should exit/unindent.
        if isInlineEmpty(entry.item.inline) {
            // Signal to caller to use returnOnEmptyListItem instead.
            throw EditingError.unsupported(
                reason: "list: empty item return — use returnOnEmptyListItem"
            )
        }

        let (before, after) = splitInlines(entry.item.inline, at: inlineOffset)

        // Current item keeps "before" text, new item gets "after" text.
        // New item inherits the same marker/indent but has no children
        // (children stay with the original item).
        let keptItem = ListItem(
            indent: entry.item.indent, marker: entry.item.marker,
            afterMarker: entry.item.afterMarker, checkbox: entry.item.checkbox,
            inline: before, children: entry.item.children
        )
        let newItem = ListItem(
            indent: entry.item.indent, marker: entry.item.marker,
            afterMarker: entry.item.afterMarker,
            checkbox: entry.item.checkbox.map { cb in
                cb.isChecked ? Checkbox(text: "[ ]", afterText: cb.afterText) : cb
            },
            inline: after, children: []
        )

        let newItems = insertItemAfterPath(items, path: entry.path,
                                           keptItem: keptItem, newItem: newItem)
        return [.list(items: newItems)]
    }

    /// Replace the item at `path` with `keptItem` and insert `newItem`
    /// immediately after it at the same level.
    private static func insertItemAfterPath(
        _ items: [ListItem],
        path: [Int],
        keptItem: ListItem,
        newItem: ListItem
    ) -> [ListItem] {
        guard let first = path.first else { return items }
        var result = items
        if path.count == 1 {
            result[first] = keptItem
            result.insert(newItem, at: first + 1)
        } else {
            let oldItem = items[first]
            let newChildren = insertItemAfterPath(
                oldItem.children, path: Array(path.dropFirst()),
                keptItem: keptItem, newItem: newItem
            )
            result[first] = ListItem(
                indent: oldItem.indent, marker: oldItem.marker,
                afterMarker: oldItem.afterMarker, checkbox: oldItem.checkbox,
                inline: oldItem.inline, children: newChildren
            )
        }
        return result
    }

    // MARK: - Blockquote newline (Return key)

    /// Handle Return key in a blockquote. Splits the current line's
    /// inline content at the cursor and inserts a new line after it
    /// with the same prefix.
    private static func splitBlockquoteOnNewline(
        lines: [BlockquoteLine],
        at offsetInBlock: Int,
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> [Block] {
        let entries = flattenBlockquote(lines)
        guard let (entryIdx, inlineOffset) = quoteEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(
                reason: "blockquote: cannot split at offset \(offsetInBlock) (not in inline content)"
            )
        }
        let entry = entries[entryIdx]
        let (before, after) = splitInlines(entry.line.inline, at: inlineOffset)

        var newLines = lines
        newLines[entryIdx] = BlockquoteLine(prefix: entry.line.prefix, inline: before)
        newLines.insert(
            BlockquoteLine(prefix: entry.line.prefix, inline: after),
            at: entryIdx + 1
        )
        return [.blockquote(lines: newLines)]
    }

    // MARK: - Per-block-type mutation

    /// Insert `string` at `offsetInBlock` within `block`. `offsetInBlock`
    /// is a character offset into the block's RENDERED output.
    private static func insertIntoBlock(
        _ block: Block,
        offsetInBlock: Int,
        string: String
    ) throws -> Block {
        switch block {
        case .paragraph(let inline):
            if inline.isEmpty {
                guard offsetInBlock == 0 else {
                    throw EditingError.unsupported(
                        reason: "paragraph: offset \(offsetInBlock) beyond empty paragraph"
                    )
                }
                return .paragraph(inline: [.text(string)])
            }
            // Atomic-aware path: any paragraph that contains an image
            // (length-1 atom) can't be edited with the flatten/runs
            // machinery because flatten only emits leaves for text-like
            // nodes. Use splitInlines instead — it cuts the tree at any
            // render offset, including the boundary on either side of an
            // image — and splice the new text between the halves.
            if containsImage(inline) {
                let (before, after) = splitInlines(inline, at: offsetInBlock)
                let newInline = before + [.text(string)] + after
                return .paragraph(inline: newInline)
            }
            let runs = flatten(inline)
            guard let (runIdx, off) = runAtInsertionPoint(runs, offset: offsetInBlock) else {
                throw EditingError.unsupported(
                    reason: "paragraph: offset \(offsetInBlock) out of inline bounds"
                )
            }
            let leaf = runs[runIdx]
            let newText = spliceString(leaf.text, at: off, replacing: 0, with: string)
            let newInline = updateLeafText(inline, at: leaf.path, newText: newText)
            return .paragraph(inline: newInline)

        case .heading(let level, let suffix):
            // Map render-offset → suffix-offset. HeadingRenderer strips
            // ONLY leading whitespace from the suffix; trailing is
            // rendered verbatim. So render offset `o` corresponds to
            // suffix offset `o + leading` and the displayed count is
            // `suffix.count - leading`. Keeping trailing whitespace in
            // the rendered length is what lets the user type a trailing
            // space into a heading without stranding the cursor.
            let leading = leadingWhitespaceCount(in: suffix)
            let displayedCount = suffix.count - leading
            
            // Special case: empty heading (just whitespace in suffix).
            // When displayedCount <= 0, there's no visible text, so any
            // insertion offset should add text after the leading whitespace.
            if displayedCount <= 0 {
                // Insert after the leading whitespace - this becomes the heading text
                let newSuffix = spliceString(suffix, at: leading, replacing: 0, with: string)
                return .heading(level: level, suffix: newSuffix)
            }
            
            // Normal case: heading has visible text
            guard offsetInBlock >= 0, offsetInBlock <= displayedCount else {
                throw EditingError.unsupported(
                    reason: "heading: offset \(offsetInBlock) out of displayed range [0, \(displayedCount)]"
                )
            }
            let suffixOffset = offsetInBlock + leading
            let newSuffix = spliceString(suffix, at: suffixOffset, replacing: 0, with: string)
            return .heading(level: level, suffix: newSuffix)

        case .codeBlock(let language, let content, let fence):
            // content is raw code; render offset == content offset
            // (no fence characters in the rendered output).
            let newContent = spliceString(content, at: offsetInBlock, replacing: 0, with: string)
            return .codeBlock(language: language, content: newContent, fence: fence)

        case .blankLine:
            // Typing into a blankLine converts it to a paragraph
            // containing the inserted text.
            return .paragraph(inline: [.text(string)])

        case .list(let items, _):
            return try insertIntoList(items: items, offsetInBlock: offsetInBlock, string: string)

        case .blockquote(let lines):
            return try insertIntoBlockquote(lines: lines, offsetInBlock: offsetInBlock, string: string)

        case .htmlBlock(let raw):
            let newRaw = spliceString(raw, at: offsetInBlock, replacing: 0, with: string)
            return .htmlBlock(raw: newRaw)

        case .horizontalRule:
            // HR has no editable content — typing on it inserts a new
            // paragraph. The caller (insert at top level) will detect
            // that the returned block differs in kind from the original
            // and handle appropriately. For now, reject: the user can
            // type above/below the HR, not on it.
            throw EditingError.unsupported(
                reason: "horizontalRule is read-only"
            )

        case .table:
            throw EditingError.unsupported(
                reason: "table is read-only"
            )
        }
    }

    /// Delete characters [fromOffset, toOffset) in the block's
    /// rendered output, returning the mutated block.
    private static func deleteInBlock(
        _ block: Block,
        from fromOffset: Int,
        to toOffset: Int
    ) throws -> Block {
        let length = toOffset - fromOffset
        switch block {
        case .paragraph(let inline):
            if length == 0 { return block }
            // Atomic-aware path: paragraphs containing images (length-1
            // atoms) can't use flatten/runs because flatten skips image
            // nodes. Use splitInlines to cut around the deleted range.
            if containsImage(inline) {
                let (before, _) = splitInlines(inline, at: fromOffset)
                let (_, after) = splitInlines(inline, at: toOffset)
                let newInline = before + after
                return .paragraph(inline: newInline)
            }
            let runs = flatten(inline)
            guard let (startRun, startOff) = runContainingChar(runs, charIndex: fromOffset) else {
                throw EditingError.outOfBounds
            }
            guard let (endRun, endOffInclusive) = runContainingChar(runs, charIndex: toOffset - 1) else {
                throw EditingError.outOfBounds
            }
            if startRun != endRun {
                throw EditingError.crossInlineRange
            }
            let leaf = runs[startRun]
            let endExclusive = endOffInclusive + 1
            let newText = spliceString(leaf.text, at: startOff, replacing: endExclusive - startOff, with: "")
            let newInline = updateLeafText(inline, at: leaf.path, newText: newText)
            return .paragraph(inline: newInline)

        case .heading(let level, let suffix):
            // Trailing whitespace is part of the rendered output —
            // see insertIntoBlock(.heading) for rationale.
            let leading = leadingWhitespaceCount(in: suffix)
            let displayedCount = suffix.count - leading
            guard fromOffset >= 0, toOffset <= displayedCount, fromOffset <= toOffset else {
                throw EditingError.unsupported(
                    reason: "heading: delete range [\(fromOffset), \(toOffset)] out of displayed [0, \(displayedCount)]"
                )
            }
            let suffixFrom = fromOffset + leading
            let newSuffix = spliceString(suffix, at: suffixFrom, replacing: length, with: "")
            return .heading(level: level, suffix: newSuffix)

        case .codeBlock(let language, let content, let fence):
            let newContent = spliceString(content, at: fromOffset, replacing: length, with: "")
            return .codeBlock(language: language, content: newContent, fence: fence)

        case .blankLine:
            // BlankLine has no rendered content — nothing to delete
            // within it. Cross-block deletion handles removing entire
            // blankLines via mergeAdjacentBlocks.
            return .blankLine

        case .list(let items, _):
            return try deleteInList(items: items, from: fromOffset, to: toOffset)

        case .blockquote(let lines):
            return try deleteInBlockquote(lines: lines, from: fromOffset, to: toOffset)

        case .htmlBlock(let raw):
            let newRaw = spliceString(raw, at: fromOffset, replacing: length, with: "")
            return .htmlBlock(raw: newRaw)

        case .horizontalRule:
            // HR has no editable content — deletes within it are no-ops.
            // Cross-block deletion (backspace from next block) is handled
            // by mergeAdjacentBlocks.
            return block

        case .table:
            // Table has no editable content — deletes within it are no-ops.
            return block
        }
    }

    // MARK: - List editing

    /// A flattened list item with its rendered prefix length and tree
    /// path for reconstruction. The rendered output of a list block is:
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
            
            // Check if the entire item is selected (including prefix and separator)
            // In this case, remove the entire item
            let inlineLength = entry.inlineLength
            if startOff <= 0 && length >= inlineLength + entry.prefixLength {
                // Remove the entire item
                var newItems: [ListItem] = []
                for i in 0..<entries.count {
                    if i != startEntry {
                        newItems.append(entries[i].item)
                    }
                }
                return .list(items: newItems)
            }
            
            let runs = flatten(entry.item.inline)
            guard let (startRun, startRunOff) = runContainingChar(runs, charIndex: startOff) else {
                throw EditingError.outOfBounds
            }
            let endOff = startOff + length
            // Clamp endOff to the inline length to handle edge cases
            let clampedEndOff = min(endOff, inlineLength)
            guard let (endRun, endRunOff) = runContainingChar(runs, charIndex: clampedEndOff - 1) else {
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
            firstItemSurviving = keepFirstChars(start.item.inline, count: startOff)
        }

        // Calculate what survives from the last item (everything after endOff)
        let lastItemSurviving: [Inline]?
        let endInlineLength = inlinesLength(end.item.inline)
        let charsToKeepFromEnd = endInlineLength - endOff - 1
        if charsToKeepFromEnd <= 0 {
            // Nothing survives from the last item
            lastItemSurviving = nil
        } else {
            // Keep everything after the deletion point
            lastItemSurviving = dropFirstChars(end.item.inline, count: endOff + 1)
        }

        // Build new inline content by merging survivors
        let mergedInline: [Inline]
        if let first = firstItemSurviving, let last = lastItemSurviving {
            mergedInline = first + last
        } else if let first = firstItemSurviving {
            mergedInline = first
        } else if let last = lastItemSurviving {
            mergedInline = last
        } else {
            mergedInline = []
        }

        // Create the merged item (uses first item's properties)
        let mergedItem = ListItem(
            indent: start.item.indent,
            marker: start.item.marker,
            afterMarker: start.item.afterMarker,
            checkbox: start.item.checkbox,
            inline: mergedInline,
            children: start.item.children
        )

        // Build new items array
        var newItems: [ListItem] = []

        // Add items before the first affected item
        for i in 0..<startEntry {
            newItems.append(entries[i].item)
        }

        // Add the merged item (if it has content or it's the only item)
        if !mergedInline.isEmpty || startEntry == endEntry {
            newItems.append(mergedItem)
        }

        // Add items after the last affected item
        for i in (endEntry + 1)..<entries.count {
            newItems.append(entries[i].item)
        }

        return .list(items: newItems)
    }

    /// Keep only the first n characters of inline content.
    private static func keepFirstChars(_ inlines: [Inline], count: Int) -> [Inline] {
        var result: [Inline] = []
        var remaining = count
        for inline in inlines {
            if remaining <= 0 { break }
            let len = inlineLength(inline)
            if len <= remaining {
                result.append(inline)
                remaining -= len
            } else {
                // Need to split this inline element
                switch inline {
                case .text(let s):
                    let endIndex = s.index(s.startIndex, offsetBy: remaining)
                    result.append(.text(String(s[..<endIndex])))
                    remaining = 0
                case .bold(let children, let marker):
                    let kept = keepFirstChars(children, count: remaining)
                    if !kept.isEmpty {
                        result.append(.bold(kept, marker: marker))
                    }
                    remaining = 0
                case .italic(let children, let marker):
                    let kept = keepFirstChars(children, count: remaining)
                    if !kept.isEmpty {
                        result.append(.italic(kept, marker: marker))
                    }
                    remaining = 0
                case .strikethrough(let children):
                    let kept = keepFirstChars(children, count: remaining)
                    if !kept.isEmpty {
                        result.append(.strikethrough(kept))
                    }
                    remaining = 0
                case .code(let s):
                    let endIndex = s.index(s.startIndex, offsetBy: min(remaining, s.count))
                    result.append(.code(String(s[..<endIndex])))
                    remaining = 0
                case .link(let text, let rawDestination):
                    let kept = keepFirstChars(text, count: remaining)
                    if !kept.isEmpty {
                        result.append(.link(text: kept, rawDestination: rawDestination))
                    }
                    remaining = 0
                default:
                    break
                }
            }
        }
        return result
    }

    /// Drop the first n characters of inline content, return the rest.
    private static func dropFirstChars(_ inlines: [Inline], count: Int) -> [Inline] {
        var result: [Inline] = []
        var remaining = count
        for inline in inlines {
            let len = inlineLength(inline)
            if remaining >= len {
                remaining -= len
                continue
            }
            if remaining == 0 {
                result.append(inline)
            } else {
                // Need to split this inline element
                let keepFrom = remaining
                remaining = 0
                switch inline {
                case .text(let s):
                    let startIndex = s.index(s.startIndex, offsetBy: keepFrom)
                    result.append(.text(String(s[startIndex...])))
                case .bold(let children, let marker):
                    let dropped = dropFirstChars(children, count: keepFrom)
                    if !dropped.isEmpty {
                        result.append(.bold(dropped, marker: marker))
                    }
                case .italic(let children, let marker):
                    let dropped = dropFirstChars(children, count: keepFrom)
                    if !dropped.isEmpty {
                        result.append(.italic(dropped, marker: marker))
                    }
                case .strikethrough(let children):
                    let dropped = dropFirstChars(children, count: keepFrom)
                    if !dropped.isEmpty {
                        result.append(.strikethrough(dropped))
                    }
                case .code(let s):
                    let startIndex = s.index(s.startIndex, offsetBy: min(keepFrom, s.count))
                    result.append(.code(String(s[startIndex...])))
                case .link(let text, let rawDestination):
                    let dropped = dropFirstChars(text, count: keepFrom)
                    if !dropped.isEmpty {
                        result.append(.link(text: dropped, rawDestination: rawDestination))
                    }
                default:
                    break
                }
            }
        }
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

    // MARK: - Blockquote editing

    /// The rendered output of a blockquote is:
    ///   indent0 + inline0 + "\n" + indent1 + inline1 + ...
    /// where indentN = N spaces per `>` level. We map render offset to
    /// (line index, offset within line's inline content).

    private struct FlatQuoteLine {
        let line: BlockquoteLine
        let lineIndex: Int
        let prefixLength: Int  // visual indent spaces
        let inlineLength: Int
        let startOffset: Int   // offset within block's rendered output
    }

    private static func flattenBlockquote(
        _ lines: [BlockquoteLine]
    ) -> [FlatQuoteLine] {
        var entries: [FlatQuoteLine] = []
        var offset = 0
        for (i, qLine) in lines.enumerated() {
            let prefixLen = 0 // indentation is via paragraph style, no visible characters
            let inlineLen = inlinesLength(qLine.inline)
            entries.append(FlatQuoteLine(
                line: qLine, lineIndex: i,
                prefixLength: prefixLen, inlineLength: inlineLen,
                startOffset: offset
            ))
            offset += prefixLen + inlineLen
            if i < lines.count - 1 { offset += 1 } // "\n"
        }
        return entries
    }

    private static func quoteEntryContaining(
        entries: [FlatQuoteLine],
        offset: Int,
        forInsertion: Bool
    ) -> (entryIndex: Int, inlineOffset: Int)? {
        for (i, entry) in entries.enumerated() {
            let inlineStart = entry.startOffset + entry.prefixLength
            let inlineEnd = inlineStart + entry.inlineLength
            if forInsertion {
                if offset >= inlineStart && offset <= inlineEnd {
                    return (i, offset - inlineStart)
                }
            } else {
                if offset >= inlineStart && offset < inlineEnd {
                    return (i, offset - inlineStart)
                }
            }
        }
        return nil
    }

    private static func insertIntoBlockquote(
        lines: [BlockquoteLine],
        offsetInBlock: Int,
        string: String
    ) throws -> Block {
        let entries = flattenBlockquote(lines)
        guard let (entryIdx, inlineOffset) = quoteEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(
                reason: "blockquote: offset \(offsetInBlock) not within editable inline content"
            )
        }
        let entry = entries[entryIdx]
        let newInline: [Inline]
        if entry.line.inline.isEmpty {
            newInline = [.text(string)]
        } else {
            let runs = flatten(entry.line.inline)
            guard let (runIdx, off) = runAtInsertionPoint(runs, offset: inlineOffset) else {
                throw EditingError.unsupported(
                    reason: "blockquote line: offset \(inlineOffset) out of inline bounds"
                )
            }
            let leaf = runs[runIdx]
            let newText = spliceString(leaf.text, at: off, replacing: 0, with: string)
            newInline = updateLeafText(entry.line.inline, at: leaf.path, newText: newText)
        }
        var newLines = lines
        newLines[entryIdx] = BlockquoteLine(prefix: entry.line.prefix, inline: newInline)
        return .blockquote(lines: newLines)
    }

    private static func deleteInBlockquote(
        lines: [BlockquoteLine],
        from fromOffset: Int,
        to toOffset: Int
    ) throws -> Block {
        let length = toOffset - fromOffset
        if length == 0 { return .blockquote(lines: lines) }
        let entries = flattenBlockquote(lines)
        guard let (startEntry, startOff) = quoteEntryContaining(
            entries: entries, offset: fromOffset, forInsertion: false
        ) else {
            throw EditingError.unsupported(
                reason: "blockquote: delete start \(fromOffset) not within editable inline content"
            )
        }
        guard let (endEntry, _) = quoteEntryContaining(
            entries: entries, offset: toOffset - 1, forInsertion: false
        ) else {
            throw EditingError.unsupported(
                reason: "blockquote: delete end \(toOffset - 1) not within editable inline content"
            )
        }
        guard startEntry == endEntry else { throw EditingError.crossInlineRange }
        let entry = entries[startEntry]
        let runs = flatten(entry.line.inline)
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
        let newInline = updateLeafText(entry.line.inline, at: leaf.path, newText: newText)
        var newLines = lines
        newLines[startEntry] = BlockquoteLine(prefix: entry.line.prefix, inline: newInline)
        return .blockquote(lines: newLines)
    }

    // MARK: - Block-split primitives

    /// Split a paragraph's inline tree at the given render offset and
    /// return the resulting blocks. A `blankLine` block is emitted
    /// BETWEEN the two halves so the parser re-reads them as two
    /// distinct paragraphs on round-trip (two adjacent non-blank
    /// lines would be joined into a single paragraph otherwise).
    /// Container formatting (bold / italic) is preserved on both
    /// sides of the split: splitting inside `bold([text("hello")])`
    /// at offset 2 yields `bold([text("he")])` before and
    /// `bold([text("llo")])` after.
    ///
    /// When one half is empty (split at the paragraph's start or
    /// end) the empty paragraph is replaced by a `blankLine` — an
    /// empty paragraph has no canonical markdown form, but a blank
    /// line does.
    private static func splitParagraphOnNewline(
        inline: [Inline],
        at offset: Int
    ) -> [Block] {
        let (before, after) = splitInlines(inline, at: offset)
        let beforeEmpty = isInlineEmpty(before)
        let afterEmpty = isInlineEmpty(after)
        switch (beforeEmpty, afterEmpty) {
        case (true, true):
            return [.blankLine, .blankLine]
        case (true, false):
            return [.blankLine, .paragraph(inline: after)]
        case (false, true):
            return [.paragraph(inline: before), .blankLine]
        case (false, false):
            return [.paragraph(inline: before), .blankLine, .paragraph(inline: after)]
        }
    }

    /// Whether an inline tree renders to zero characters (empty list
    /// or a tree containing only empty leaves / containers of empty
    /// leaves).
    private static func isInlineEmpty(_ inline: [Inline]) -> Bool {
        return inline.allSatisfy { inlineLength($0) == 0 }
    }

    /// Total render length of an inline node (sum of leaf character
    /// counts; containers contribute no characters of their own).
    private static func inlineLength(_ node: Inline) -> Int {
        switch node {
        case .text(let s): return s.count
        case .code(let s): return s.count
        case .bold(let c, _): return c.reduce(0) { $0 + inlineLength($1) }
        case .italic(let c, _): return c.reduce(0) { $0 + inlineLength($1) }
        case .strikethrough(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .underline(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .highlight(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .math(let s): return s.count
        case .displayMath(let s): return s.count
        case .link(let text, _): return text.reduce(0) { $0 + inlineLength($1) }
        // Images render as EXACTLY one character (the NSTextAttachment
        // placeholder emitted by InlineRenderer, both for the native
        // attachment path and for the fallback). The alt text is NOT
        // rendered inline — it only survives in the round-trip markdown
        // and the attachment title. Returning the alt length here would
        // make an image-only paragraph look empty to splitInlines /
        // isInlineEmpty, which would in turn cause Return after an image
        // to replace the whole paragraph with blank lines and destroy
        // the image. Keep this in lock-step with InlineRenderer.
        case .image: return 1
        case .autolink(let text, _): return text.count
        case .escapedChar: return 1
        case .lineBreak: return 1
        case .rawHTML(let html): return html.count
        case .entity(let raw): return raw.count
        case .wikilink(let target, let display):
            return (display ?? target).count
        }
    }

    /// Whether an inline tree contains any `.image` atom at any depth.
    /// Paragraphs containing images must be edited via splitInlines-based
    /// splicing (not the flatten/runs path) because flatten() emits no
    /// leaf run for atomic image nodes, so `runAtInsertionPoint` cannot
    /// find an insertion slot at the image boundary.
    private static func containsImage(_ inlines: [Inline]) -> Bool {
        for node in inlines {
            switch node {
            case .image:
                return true
            case .bold(let c, _):
                if containsImage(c) { return true }
            case .italic(let c, _):
                if containsImage(c) { return true }
            case .strikethrough(let c):
                if containsImage(c) { return true }
            case .link(let c, _):
                if containsImage(c) { return true }
            default:
                break
            }
        }
        return false
    }

    /// Split a list of inline nodes at render offset `offset`, returning
    /// (before, after). Containers straddling the split point are
    /// recursively split and REPRODUCED on both sides.
    // Made internal for use by autoConvertParagraph and trimLeadingText.
    static func splitInlines(
        _ inlines: [Inline],
        at offset: Int
    ) -> ([Inline], [Inline]) {
        var before: [Inline] = []
        var after: [Inline] = []
        var acc = 0
        for node in inlines {
            let nodeLen = inlineLength(node)
            if offset >= acc + nodeLen {
                // Entirely before the split.
                before.append(node)
            } else if offset <= acc {
                // Entirely after the split.
                after.append(node)
            } else {
                // Split within this node.
                let localOffset = offset - acc
                switch node {
                case .text(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.text(String(s[..<idx])))
                    after.append(.text(String(s[idx...])))
                case .code(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.code(String(s[..<idx])))
                    after.append(.code(String(s[idx...])))
                case .bold(let children, let marker):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.bold(b, marker: marker))
                    after.append(.bold(a, marker: marker))
                case .italic(let children, let marker):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.italic(b, marker: marker))
                    after.append(.italic(a, marker: marker))
                case .strikethrough(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.strikethrough(b))
                    after.append(.strikethrough(a))
                case .underline(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.underline(b))
                    after.append(.underline(a))
                case .highlight(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.highlight(b))
                    after.append(.highlight(a))
                case .math(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.math(String(s[..<idx])))
                    after.append(.math(String(s[idx...])))
                case .displayMath(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.displayMath(String(s[..<idx])))
                    after.append(.displayMath(String(s[idx...])))
                case .link(let text, let dest):
                    let (b, a) = splitInlines(text, at: localOffset)
                    before.append(.link(text: b, rawDestination: dest))
                    after.append(.link(text: a, rawDestination: dest))
                case .image:
                    // Images are length-1 atoms — splitInlines can never
                    // enter this branch (it's only reached when the split
                    // point is STRICTLY inside a node, and a length-1
                    // node is either entirely before or entirely after).
                    // Keep the case for exhaustiveness; treat as "before"
                    // defensively so we never drop the image.
                    before.append(node)
                case .autolink(let text, _):
                    let idx = text.index(text.startIndex, offsetBy: localOffset)
                    before.append(.text(String(text[..<idx])))
                    after.append(.text(String(text[idx...])))
                case .rawHTML(let html):
                    let idx = html.index(html.startIndex, offsetBy: localOffset)
                    before.append(.rawHTML(String(html[..<idx])))
                    after.append(.rawHTML(String(html[idx...])))
                case .entity(let raw):
                    let idx = raw.index(raw.startIndex, offsetBy: localOffset)
                    before.append(.text(String(raw[..<idx])))
                    after.append(.text(String(raw[idx...])))
                case .escapedChar, .lineBreak:
                    // Length 1 — cannot be split within; goes entirely before or after.
                    // Since localOffset > 0 and nodeLen == 1, localOffset == 1 == nodeLen,
                    // which means offset >= acc + nodeLen, handled above. This is unreachable.
                    before.append(node)
                case .wikilink(let target, let display):
                    // Wikilinks are atomic: split at a wikilink's interior
                    // would produce two half-targets. Treat as before/after
                    // boundary like images.
                    let visible = display ?? target
                    let idx = visible.index(visible.startIndex, offsetBy: localOffset)
                    let leftStr = String(visible[..<idx])
                    let rightStr = String(visible[idx...])
                    before.append(.text(leftStr))
                    after.append(.text(rightStr))
                    _ = target
                }
            }
            acc += nodeLen
        }
        return (before, after)
    }

    // MARK: - Inline-tree navigation

    /// Path from the root of an `[Inline]` tree to a leaf node. Each
    /// integer indexes into the children at that depth.
    typealias InlinePath = [Int]

    /// A leaf inline run: a `.text(...)` or `.code(...)` node carrying
    /// character content, along with its path from the tree root and
    /// whether it is a code span (affects which Inline case we rebuild).
    struct LeafRun {
        let path: InlinePath
        let text: String
        let isCode: Bool
    }

    /// Flatten an inline tree to its sequence of leaf runs, in render
    /// order. Containers (`.bold`, `.italic`) contribute no characters
    /// of their own — only their descendants do.
    private static func flatten(_ inlines: [Inline]) -> [LeafRun] {
        var runs: [LeafRun] = []
        var path: InlinePath = []
        walkFlatten(inlines, path: &path, into: &runs)
        return runs
    }

    private static func walkFlatten(
        _ inlines: [Inline],
        path: inout InlinePath,
        into runs: inout [LeafRun]
    ) {
        for (i, node) in inlines.enumerated() {
            path.append(i)
            switch node {
            case .text(let s):
                runs.append(LeafRun(path: path, text: s, isCode: false))
            case .code(let s):
                runs.append(LeafRun(path: path, text: s, isCode: true))
            case .bold(let children, _):
                walkFlatten(children, path: &path, into: &runs)
            case .italic(let children, _):
                walkFlatten(children, path: &path, into: &runs)
            case .strikethrough(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .underline(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .highlight(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .math(let s):
                runs.append(LeafRun(path: path, text: s, isCode: true))
            case .displayMath(let s):
                runs.append(LeafRun(path: path, text: s, isCode: true))
            case .link(let text, _):
                walkFlatten(text, path: &path, into: &runs)
            case .image(let alt, _, _):
                walkFlatten(alt, path: &path, into: &runs)
            case .autolink(let text, _):
                runs.append(LeafRun(path: path, text: text, isCode: false))
            case .escapedChar(let ch):
                runs.append(LeafRun(path: path, text: String(ch), isCode: false))
            case .lineBreak:
                runs.append(LeafRun(path: path, text: "\n", isCode: false))
            case .rawHTML(let html):
                runs.append(LeafRun(path: path, text: html, isCode: false))
            case .entity(let raw):
                runs.append(LeafRun(path: path, text: raw, isCode: false))
            case .wikilink(let target, let display):
                // Wikilinks are atomic from the editor's perspective —
                // emit a single leaf run with the visible text so the
                // run-based insertion machinery can position the cursor
                // at the wikilink's edges (but not inside).
                runs.append(LeafRun(path: path, text: display ?? target, isCode: false))
            }
            path.removeLast()
        }
    }

    /// Locate an INSERTION POINT at render offset `offset` within
    /// `runs`. At a run boundary, prefers the EARLIER run (so typing
    /// at offset == end-of-run-i lands at the end of run i, not the
    /// start of run i+1). This matches the editor invariant that the
    /// insertion point belongs to the run whose last character was
    /// just rendered.
    private static func runAtInsertionPoint(
        _ runs: [LeafRun],
        offset: Int
    ) -> (runIndex: Int, offsetInRun: Int)? {
        if runs.isEmpty { return nil }
        var acc = 0
        for (i, run) in runs.enumerated() {
            let end = acc + run.text.count
            if offset >= acc && offset <= end {
                return (i, offset - acc)
            }
            acc = end
        }
        return nil
    }

    /// Locate the run that OWNS the rendered character at index
    /// `charIndex` (strict less-than upper bound). Used for delete
    /// ranges [from, to): each character is owned by exactly one run.
    private static func runContainingChar(
        _ runs: [LeafRun],
        charIndex: Int
    ) -> (runIndex: Int, offsetInRun: Int)? {
        if charIndex < 0 { return nil }
        var acc = 0
        for (i, run) in runs.enumerated() {
            let end = acc + run.text.count
            if charIndex >= acc && charIndex < end {
                return (i, charIndex - acc)
            }
            acc = end
        }
        return nil
    }

    /// Rebuild an inline tree with the leaf at `path` replaced by a
    /// new text value. The Inline case (`.text` vs `.code`) at the
    /// leaf is preserved.
    private static func updateLeafText(
        _ inlines: [Inline],
        at path: InlinePath,
        newText: String
    ) -> [Inline] {
        guard let first = path.first else { return inlines }
        let rest = Array(path.dropFirst())
        var out = inlines
        out[first] = replaceLeafText(in: inlines[first], path: rest, newText: newText)
        return out
    }

    private static func replaceLeafText(
        in inline: Inline,
        path: InlinePath,
        newText: String
    ) -> Inline {
        if path.isEmpty {
            switch inline {
            case .text: return .text(newText)
            case .code: return .code(newText)
            case .math: return .math(newText)
            case .displayMath: return .displayMath(newText)
            case .autolink: return .text(newText)
            case .escapedChar: return .text(newText)
            case .lineBreak: return .text(newText)
            case .rawHTML: return .rawHTML(newText)
            case .entity: return .entity(newText)
            case .wikilink: return .text(newText)
            case .bold, .italic, .strikethrough, .underline, .highlight, .link, .image, .math, .displayMath:
                // Path exhausted on a container: should not happen
                // when paths come from `flatten`. Leave unchanged.
                return inline
            }
        }
        let idx = path.first!
        let rest = Array(path.dropFirst())
        switch inline {
        case .text, .code, .math, .displayMath, .autolink, .escapedChar, .lineBreak, .rawHTML, .entity, .wikilink:
            // Cannot descend into a leaf.
            return inline
        case .bold(let children, let marker):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .bold(c, marker: marker)
        case .italic(let children, let marker):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .italic(c, marker: marker)
        case .strikethrough(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .strikethrough(c)
        case .underline(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .underline(c)
        case .highlight(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .highlight(c)
        case .link(let text, let dest):
            var c = text
            c[idx] = replaceLeafText(in: text[idx], path: rest, newText: newText)
            return .link(text: c, rawDestination: dest)
        case .image(let alt, let dest, let width):
            var c = alt
            c[idx] = replaceLeafText(in: alt[idx], path: rest, newText: newText)
            return .image(alt: c, rawDestination: dest, width: width)
        }
    }

    // MARK: - Helpers

    /// Splice `string` into `source` by replacing `replacing` characters
    /// starting at `at` with `string`. Uses String.Index arithmetic for
    /// Unicode correctness. `at` and `replacing` are character counts.
    private static func spliceString(
        _ source: String,
        at offset: Int,
        replacing count: Int,
        with string: String
    ) -> String {
        let start = source.index(source.startIndex, offsetBy: offset)
        let end = source.index(start, offsetBy: count)
        var out = source
        out.replaceSubrange(start..<end, with: string)
        return out
    }

    /// Number of leading whitespace characters (spaces / tabs) in a
    /// string. Matches CharacterSet.whitespaces (space + tab + &c).
    private static func leadingWhitespaceCount(in s: String) -> Int {
        var n = 0
        for ch in s {
            if ch.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                n += 1
            } else { break }
        }
        return n
    }

    /// Number of trailing whitespace characters.
    private static func trailingWhitespaceCount(in s: String) -> Int {
        var n = 0
        for ch in s.reversed() {
            if ch.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                n += 1
            } else { break }
        }
        return n
    }

    private static func describe(_ block: Block) -> String {
        switch block {
        case .codeBlock:      return "codeBlock"
        case .heading:        return "heading"
        case .paragraph:      return "paragraph"
        case .list:           return "list"
        case .blockquote:     return "blockquote"
        case .horizontalRule: return "horizontalRule"
        case .htmlBlock:      return "htmlBlock"
        case .table:          return "table"
        case .blankLine:      return "blankLine"
        }
    }

    // MARK: - Public flat-list API for ListEditingFSM

    /// Public mirror of FlatListEntry for FSM state detection.
    public struct PublicFlatListEntry {
        public let depth: Int
        public let prefixLength: Int
        public let inlineLength: Int
        public let startOffset: Int
        public let path: [Int]
    }

    /// Public wrapper around flattenList for FSM usage.
    public static func flattenListPublic(_ items: [ListItem]) -> [PublicFlatListEntry] {
        return flattenList(items).map {
            PublicFlatListEntry(
                depth: $0.depth,
                prefixLength: $0.prefixLength,
                inlineLength: $0.inlineLength,
                startOffset: $0.startOffset,
                path: $0.path
            )
        }
    }

    /// Public wrapper around listEntryContaining for FSM usage.
    public static func listEntryContainingPublic(
        entries: [PublicFlatListEntry],
        offset: Int,
        forInsertion: Bool
    ) -> (entryIndex: Int, inlineOffset: Int)? {
        for (i, entry) in entries.enumerated() {
            let inlineStart = entry.startOffset + entry.prefixLength
            let inlineEnd = inlineStart + entry.inlineLength
            if forInsertion {
                if offset >= inlineStart && offset <= inlineEnd {
                    return (i, offset - inlineStart)
                }
            } else {
                if offset >= inlineStart && offset < inlineEnd {
                    return (i, offset - inlineStart)
                }
            }
        }
        return nil
    }

    // MARK: - List structural operations (FSM transitions)

    /// Indent a list item: move it to be the last child of its previous
    /// sibling. Returns the new list block and the storage index where
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

    /// Exit a list item: remove it from the list and optionally convert it to a
    /// body paragraph. The item is removed from the list, and if createParagraphForEmpty
    /// is true, a new paragraph block is inserted after the list.
    /// - Parameter createParagraphForEmpty: If false and the item is empty, just remove it
    ///   and put cursor at end of previous item. If true, always create a paragraph.
    public static func exitListItem(
        at storageIndex: Int,
        in projection: DocumentProjection,
        createParagraphForEmpty: Bool = true
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "exitListItem: not a list block")
        }

        let entries = flattenList(items)
        guard let (entryIdx, _) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(reason: "exitListItem: cursor not in inline content")
        }
        let entry = entries[entryIdx]

        // Check if this is an empty item and we should not create a paragraph
        let isEmpty = entry.item.inline.isEmpty || entry.item.inline == [.text("")]
        if !createParagraphForEmpty && isEmpty {
            // Just remove the empty item and put cursor at end of previous item
            let newItems = removeItemAtPath(items, path: entry.path, promoteChildren: true)
            
            if newItems.isEmpty {
                // List is now empty, replace with blank paragraph
                var result = try replaceBlocks(atIndex: blockIndex, with: [.paragraph(inline: [])], in: projection)
                result.newCursorPosition = result.newProjection.blockSpans[blockIndex].location
                return result
            }
            
            var result = try replaceBlocks(atIndex: blockIndex, with: [.list(items: newItems)], in: projection)
            
            // Cursor goes to end of previous item (if any), or start of list
            if entryIdx > 0 {
                let prevEntry = entries[entryIdx - 1]
                let blockSpan = result.newProjection.blockSpans[blockIndex]
                let newEntries = flattenList(newItems)
                // Find the previous item in the new list
                if let newPrevEntry = newEntries.first(where: { $0.path == prevEntry.path }) {
                    result.newCursorPosition = blockSpan.location + newPrevEntry.startOffset + newPrevEntry.prefixLength + newPrevEntry.inlineLength
                } else {
                    result.newCursorPosition = storageIndex
                }
            } else {
                result.newCursorPosition = result.newProjection.blockSpans[blockIndex].location
            }
            
            return result
        }

        // Build the replacement blocks by splitting the list at the exited item's position.
        // This creates: [items before] + [paragraph] + [items after]
        
        var newBlocks: [Block] = []
        
        // Use removeItemAtPath to keep items before and after in the same list structure
        // This preserves the list as a single block with blankLineBefore flags
        let remaining = removeItemAtPath(items, path: entry.path, promoteChildren: true)
        
        // Build replacement blocks
        if !remaining.isEmpty {
            newBlocks.append(.list(items: remaining))
        }
        
        // Always create a paragraph block for the exited item.
        // For empty items, this creates an empty paragraph (clean exit from list editing).
        let exitedParagraph: Block = .paragraph(inline: entry.item.inline)
        newBlocks.append(exitedParagraph)
        
        // Edge case: if newBlocks is empty, add a blank paragraph
        if newBlocks.isEmpty {
            newBlocks.append(.paragraph(inline: []))
        }

        var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)

        // Cursor goes to the start of the exited paragraph.
        // Paragraph is always the middle block: [list?, paragraph, list?]
        let firstIsList: Bool
        if case .list = newBlocks.first {
            firstIsList = true
        } else {
            firstIsList = false
        }
        let paraBlockIdx = blockIndex + (firstIsList ? 1 : 0)
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
            // When exiting an empty item to body, don't create a paragraph - just remove it
            return try exitListItem(at: storageIndex, in: projection, createParagraphForEmpty: false)
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
            var result = items
            result[first] = ListItem(
                indent: oldItem.indent, marker: oldItem.marker,
                afterMarker: oldItem.afterMarker, checkbox: oldItem.checkbox,
                inline: oldItem.inline, children: newChildren
            )
            return result
        }
    }

    /// Get all list items before the entry at `path`.
    /// Returns items at the top level only (flattened hierarchy is not preserved).
    private static func itemsBeforeEntry(items: [ListItem], path: [Int]) -> [ListItem] {
        guard let first = path.first else { return [] }
        if path.count == 1 {
            // Top-level item: return all items before the index
            return Array(items.prefix(first))
        } else {
            // Nested item: recurse into children
            var result = items
            let childPath = Array(path.dropFirst())
            let newChildren = itemsBeforeEntry(items: items[first].children, path: childPath)
            result[first] = ListItem(
                indent: items[first].indent, marker: items[first].marker,
                afterMarker: items[first].afterMarker, checkbox: items[first].checkbox,
                inline: items[first].inline, children: newChildren
            )
            return result
        }
    }

    /// Get all list items after the entry at `path`, optionally promoting children.
    /// Returns items at the top level only.
    private static func itemsAfterEntry(items: [ListItem], path: [Int], promoteChildren: Bool) -> [ListItem] {
        guard let first = path.first else { return items }
        if path.count == 1 {
            // Top-level item
            var result: [ListItem] = []
            let removedItem = items[first]
            
            // If promoting children, insert them where the item was
            if promoteChildren {
                result.append(contentsOf: removedItem.children)
            }
            
            // Add all items after the removed one
            if first + 1 < items.count {
                result.append(contentsOf: items.suffix(from: first + 1))
            }
            return result
        } else {
            // Nested item: recurse into children
            var result = items
            let childPath = Array(path.dropFirst())
            let newChildren = itemsAfterEntry(
                items: items[first].children,
                path: childPath,
                promoteChildren: promoteChildren
            )
            result[first] = ListItem(
                indent: items[first].indent, marker: items[first].marker,
                afterMarker: items[first].afterMarker, checkbox: items[first].checkbox,
                inline: items[first].inline, children: newChildren
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

    // MARK: - Block-level conversions

    /// Inline trait for toggle operations.
    public enum InlineTrait {
        case bold
        case italic
        case strikethrough
        case code
        case underline
        case highlight
    }

    /// Change a heading's level, or convert paragraph↔heading.
    ///
    /// - `newLevel > 0`: set heading to that level (converts paragraph
    ///   to heading if needed).
    /// - `newLevel == 0`: convert heading to paragraph.
    /// - Toggling: if the block is already a heading at `newLevel`,
    ///   converts it to a paragraph (toggle off).
    public static func changeHeadingLevel(
        _ newLevel: Int,
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]
        let replacementBlock: Block

        switch block {
        case .heading(let level, let suffix):
            if newLevel == 0 || newLevel == level {
                // Toggle off → paragraph. Suffix trimmed to content.
                let text = suffix.trimmingCharacters(in: .whitespaces)
                replacementBlock = .paragraph(inline: parseInlinesFromText(text))
            } else {
                // Change level, preserve suffix.
                replacementBlock = .heading(level: newLevel, suffix: suffix)
            }

        case .paragraph(let inline):
            guard newLevel > 0 else {
                // Already a paragraph, level 0 → no-op.
                return EditResult(
                    newProjection: projection,
                    spliceRange: NSRange(location: storageIndex, length: 0),
                    spliceReplacement: NSAttributedString(string: ""),
                    newCursorPosition: storageIndex
                )
            }
            // Convert paragraph → heading. Content becomes the suffix.
            let text = inlinesToText(inline)
            replacementBlock = .heading(level: newLevel, suffix: " " + text)

        default:
            throw EditingError.unsupported(
                reason: "changeHeadingLevel: not a heading or paragraph"
            )
        }

        var result = try replaceBlock(
            atIndex: blockIndex,
            with: replacementBlock,
            in: projection
        )
        // Place cursor at the end of the new block's content.
        let newSpan = result.newProjection.blockSpans[blockIndex]
        result.newCursorPosition = newSpan.location + newSpan.length
        return result
    }

    /// Toggle an inline trait (bold/italic/code) on a selection range.
    ///
    /// If the entire selection is already wrapped in the trait, the
    /// wrapper is removed (unwrap). Otherwise, the selection is wrapped
    /// in the trait (wrap). Only works on paragraphs, headings, list
    /// items, and blockquotes.
    ///
    /// The selection range is in textStorage coordinates. Both endpoints
    /// must lie within the same block.
    /// Insert `string` at `storageIndex` wrapped in the given inline traits.
    /// Used when the user toggles formatting with an empty selection, then types.
    public static func insertWithTraits(
        _ string: String,
        traits: Set<InlineTrait>,
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]

        // Build the wrapped inline node: text wrapped in each trait.
        var node: Inline = .text(string)
        for trait in traits {
            node = wrapInlineInTrait(node, trait: trait)
        }

        // Replace the block by splitting at the offset and inserting the wrapped node.
        let newBlock: Block
        switch block {
        case .paragraph(let inline):
            let (before, after) = splitInlines(inline, at: offsetInBlock)
            newBlock = .paragraph(inline: cleanInlines(before + [node] + after))
        case .heading(let level, let suffix):
            let leading = leadingWhitespaceCount(in: suffix)
            let inlines = parseInlinesFromText(String(suffix.dropFirst(leading)))
            let (before, after) = splitInlines(inlines, at: offsetInBlock)
            let newText = inlinesToText(cleanInlines(before + [node] + after))
            let leadingWS = String(suffix.prefix(leading))
            newBlock = .heading(level: level, suffix: leadingWS + newText)
        case .list(let items, _):
            let entries = flattenList(items)
            guard let (entryIdx, inlineOffset) = listEntryContaining(
                entries: entries, offset: offsetInBlock, forInsertion: true
            ) else {
                throw EditingError.unsupported(reason: "insertWithTraits: offset not in list item")
            }
            let entry = entries[entryIdx]
            let item = entry.item
            let (before, after) = splitInlines(item.inline, at: inlineOffset)
            let newInline = cleanInlines(before + [node] + after)
            let newItem = ListItem(
                indent: item.indent, marker: item.marker,
                afterMarker: item.afterMarker, checkbox: item.checkbox,
                inline: newInline, children: item.children
            )
            let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
            newBlock = .list(items: newItems)
        case .blockquote(let lines):
            let flattened = flattenBlockquote(lines)
            guard let (lineIdx, inlineOffset) = quoteEntryContaining(
                entries: flattened, offset: offsetInBlock, forInsertion: true
            ) else {
                throw EditingError.unsupported(reason: "insertWithTraits: offset not in blockquote")
            }
            let line = lines[lineIdx]
            let (before, after) = splitInlines(line.inline, at: inlineOffset)
            let newInline = cleanInlines(before + [node] + after)
            var newLines = lines
            newLines[lineIdx] = BlockquoteLine(prefix: line.prefix, inline: newInline)
            newBlock = .blockquote(lines: newLines)
        case .blankLine:
            newBlock = .paragraph(inline: [node])
        default:
            throw EditingError.unsupported(reason: "insertWithTraits: unsupported block type")
        }

        var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
        result.newCursorPosition = storageIndex + string.count
        return result
    }

    /// Wrap an inline node in a trait wrapper.
    private static func wrapInlineInTrait(_ node: Inline, trait: InlineTrait) -> Inline {
        switch trait {
        case .bold: return .bold([node])
        case .italic: return .italic([node])
        case .strikethrough: return .strikethrough([node])
        case .code:
            if case .text(let s) = node { return .code(s) }
            return node
        case .underline: return .underline([node])
        case .highlight: return .highlight([node])
        }
    }

    public static func toggleInlineTrait(
        _ trait: InlineTrait,
        range selectionRange: NSRange,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard selectionRange.length > 0 else {
            // Zero-length selection: no-op (can't wrap nothing).
            return EditResult(
                newProjection: projection,
                spliceRange: NSRange(location: selectionRange.location, length: 0),
                spliceReplacement: NSAttributedString(string: ""),
                newCursorPosition: selectionRange.location
            )
        }

        let startIdx = selectionRange.location
        let endIdx = selectionRange.location + selectionRange.length - 1

        guard let (blockStart, offsetStart) = projection.blockContaining(storageIndex: startIdx),
              let (blockEnd, _) = projection.blockContaining(storageIndex: endIdx),
              blockStart == blockEnd else {
            throw EditingError.crossBlockRange
        }

        let blockIndex = blockStart
        let block = projection.document.blocks[blockIndex]
        let offsetEnd = offsetStart + selectionRange.length

        // Extract inline array based on block type and apply the trait toggle.
        let newBlock: Block
        switch block {
        case .paragraph(let inline):
            let newInline = toggleTraitOnInlines(inline, trait: trait, from: offsetStart, to: offsetEnd)
            newBlock = .paragraph(inline: newInline)

        case .heading(let level, let suffix):
            // Map render offset → suffix offset. HeadingRenderer strips
            // only leading whitespace from the suffix.
            let leading = leadingWhitespaceCount(in: suffix)
            let inlines = parseInlinesFromText(
                String(suffix.dropFirst(leading))
            )
            let newInline = toggleTraitOnInlines(inlines, trait: trait, from: offsetStart, to: offsetEnd)
            // Rebuild suffix from new inlines.
            let newText = inlinesToText(newInline)
            let leadingWS = String(suffix.prefix(leading))
            newBlock = .heading(level: level, suffix: leadingWS + newText)

        case .list(let items, _):
            let entries = flattenList(items)
            guard let (entryIdx, inlineOffset) = listEntryContaining(
                entries: entries, offset: offsetStart, forInsertion: false
            ) else {
                throw EditingError.unsupported(reason: "toggleInlineTrait: offset not in list item inline")
            }
            let entry = entries[entryIdx]
            let item = entry.item
            let localEnd = inlineOffset + selectionRange.length
            let newInline = toggleTraitOnInlines(item.inline, trait: trait, from: inlineOffset, to: localEnd)
            let newItem = ListItem(
                indent: item.indent, marker: item.marker,
                afterMarker: item.afterMarker, checkbox: item.checkbox,
                inline: newInline, children: item.children
            )
            let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
            newBlock = .list(items: newItems)

        case .blockquote(let lines):
            let flattened = flattenBlockquote(lines)
            guard let (lineIdx, inlineOffset) = quoteEntryContaining(
                entries: flattened, offset: offsetStart, forInsertion: false
            ) else {
                throw EditingError.unsupported(reason: "toggleInlineTrait: offset not in blockquote line")
            }
            let line = lines[lineIdx]
            let localEnd = inlineOffset + selectionRange.length
            let newInline = toggleTraitOnInlines(line.inline, trait: trait, from: inlineOffset, to: localEnd)
            var newLines = lines
            newLines[lineIdx] = BlockquoteLine(prefix: line.prefix, inline: newInline)
            newBlock = .blockquote(lines: newLines)

        default:
            throw EditingError.unsupported(
                reason: "toggleInlineTrait: not supported for \(describe(block))"
            )
        }

        var result = try replaceBlock(
            atIndex: blockIndex,
            with: newBlock,
            in: projection
        )
        // Keep the formatted text selected so the user can stack
        // additional formatting (bold → italic, etc.).
        let newSpan = result.newProjection.blockSpans[blockIndex]
        result.newCursorPosition = min(
            newSpan.location + offsetStart,
            newSpan.location + newSpan.length
        )
        result.newSelectionLength = selectionRange.length
        return result
    }

    /// Toggle an HTML tag (e.g. `<u>`, `<mark>`) on the selected range.
    /// Wraps the selected text with rawHTML open/close tags in the inline
    /// tree, or removes them if already present. The tags are serialized
    /// as-is and rendered by InlineTagRegistry.
    public static func toggleHTMLTag(
        open openTag: String,
        close closeTag: String,
        range selectionRange: NSRange,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard selectionRange.length > 0 else {
            return EditResult(
                newProjection: projection,
                spliceRange: NSRange(location: selectionRange.location, length: 0),
                spliceReplacement: NSAttributedString(string: ""),
                newCursorPosition: selectionRange.location
            )
        }

        let startIdx = selectionRange.location
        let endIdx = selectionRange.location + selectionRange.length - 1

        guard let (blockStart, offsetStart) = projection.blockContaining(storageIndex: startIdx),
              let (blockEnd, _) = projection.blockContaining(storageIndex: endIdx),
              blockStart == blockEnd else {
            throw EditingError.crossBlockRange
        }

        let blockIndex = blockStart
        let block = projection.document.blocks[blockIndex]
        let offsetEnd = offsetStart + selectionRange.length

        let newBlock: Block
        switch block {
        case .paragraph(let inline):
            let newInline = toggleHTMLTagOnInlines(
                inline, open: openTag, close: closeTag,
                from: offsetStart, to: offsetEnd
            )
            newBlock = .paragraph(inline: newInline)

        case .heading(let level, let suffix):
            let leading = leadingWhitespaceCount(in: suffix)
            let inlines = parseInlinesFromText(String(suffix.dropFirst(leading)))
            let newInline = toggleHTMLTagOnInlines(
                inlines, open: openTag, close: closeTag,
                from: offsetStart, to: offsetEnd
            )
            let newText = inlinesToText(newInline)
            let leadingWS = String(suffix.prefix(leading))
            newBlock = .heading(level: level, suffix: leadingWS + newText)

        case .list(let items, _):
            let entries = flattenList(items)
            guard let (entryIdx, inlineOffset) = listEntryContaining(
                entries: entries, offset: offsetStart, forInsertion: false
            ) else {
                throw EditingError.unsupported(
                    reason: "toggleHTMLTag: offset not in list item inline"
                )
            }
            let entry = entries[entryIdx]
            let item = entry.item
            let localEnd = inlineOffset + selectionRange.length
            let newInline = toggleHTMLTagOnInlines(
                item.inline, open: openTag, close: closeTag,
                from: inlineOffset, to: localEnd
            )
            let newItem = ListItem(
                indent: item.indent, marker: item.marker,
                afterMarker: item.afterMarker, checkbox: item.checkbox,
                inline: newInline, children: item.children
            )
            let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
            newBlock = .list(items: newItems)

        case .blockquote(let lines):
            let flattened = flattenBlockquote(lines)
            guard let (lineIdx, inlineOffset) = quoteEntryContaining(
                entries: flattened, offset: offsetStart, forInsertion: false
            ) else {
                throw EditingError.unsupported(
                    reason: "toggleHTMLTag: offset not in blockquote line"
                )
            }
            let line = lines[lineIdx]
            let localEnd = inlineOffset + selectionRange.length
            let newInline = toggleHTMLTagOnInlines(
                line.inline, open: openTag, close: closeTag,
                from: inlineOffset, to: localEnd
            )
            var newLines = lines
            newLines[lineIdx] = BlockquoteLine(prefix: line.prefix, inline: newInline)
            newBlock = .blockquote(lines: newLines)

        default:
            throw EditingError.unsupported(
                reason: "toggleHTMLTag: not supported for \(describe(block))"
            )
        }

        var result = try replaceBlock(
            atIndex: blockIndex,
            with: newBlock,
            in: projection
        )
        let newSpan = result.newProjection.blockSpans[blockIndex]
        result.newCursorPosition = min(
            newSpan.location + offsetStart,
            newSpan.location + newSpan.length
        )
        result.newSelectionLength = selectionRange.length
        return result
    }

    /// Toggle HTML tag wrapping on an inline array. Checks if the
    /// range [from, to) is already wrapped with the open/close tag
    /// pair as rawHTML nodes; if so, removes them; otherwise inserts
    /// them at the boundaries.
    private static func toggleHTMLTagOnInlines(
        _ inlines: [Inline],
        open openTag: String,
        close closeTag: String,
        from: Int,
        to: Int
    ) -> [Inline] {
        // Check if the selection is already bracketed by the tags.
        // Look for rawHTML(openTag) immediately before `from` and
        // rawHTML(closeTag) immediately after `to`.
        let serialized = inlines.map { inlineToText($0) }.joined()
        let beforeFrom = String(serialized.prefix(from))
        let afterTo = String(serialized.suffix(from: serialized.index(serialized.startIndex, offsetBy: min(to, serialized.count))))

        if beforeFrom.hasSuffix(openTag) && afterTo.hasPrefix(closeTag) {
            // Already wrapped — remove the tags by splitting and
            // excluding the rawHTML nodes.
            let tagOpenLen = openTag.count
            let tagCloseLen = closeTag.count
            let (beforeOpen, rest1) = splitInlines(inlines, at: from - tagOpenLen)
            let (_, rest2) = splitInlines(rest1, at: tagOpenLen) // skip open tag
            let (middle, rest3) = splitInlines(rest2, at: to - from)
            let (_, afterClose) = splitInlines(rest3, at: tagCloseLen) // skip close tag
            return cleanInlines(beforeOpen + middle + afterClose)
        }

        // Not wrapped — insert tag nodes.
        let (before, rest) = splitInlines(inlines, at: from)
        let middleLength = to - from
        let (middle, after) = splitInlines(rest, at: middleLength)

        return cleanInlines(
            before + [.rawHTML(openTag)] + middle + [.rawHTML(closeTag)] + after
        )
    }

    /// Toggle a list at the cursor position.
    ///
    /// - When `storageIndex` is in a paragraph: wraps it in a single-item
    ///   unordered list with the given marker (default "-").
    /// - When `storageIndex` is in a list: converts ONLY the current item
    ///   at the cursor position to a paragraph, splitting the list into
    ///   parts before and after the current item.
    /// - Multi-selection behavior: handled at the caller level (wraps
    ///   selected blocks into a single list block).
    public static func toggleList(
        marker: String = "-",
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]

        switch block {
        case .paragraph(let inline):
            // Wrap in a single-item list.
            let item = ListItem(
                indent: "", marker: marker,
                afterMarker: " ", inline: inline,
                children: []
            )
            let newBlock = Block.list(items: [item])
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            let newSpan = result.newProjection.blockSpans[blockIndex]
            // Place cursor after bullet + space (start of text content).
            result.newCursorPosition = newSpan.location + 1
            return result

        case .list(let items, _):
            // Find the current item at the cursor position
            let entries = flattenList(items)
            guard let (entryIdx, _) = listEntryContaining(
                entries: entries, offset: offsetInBlock, forInsertion: true
            ) else {
                throw EditingError.unsupported(reason: "toggleList: cursor not in list item content")
            }
            let entry = entries[entryIdx]
            
            // Split the list: items before, current item (as paragraph), items after
            let itemsBefore = itemsBeforeEntry(items: items, path: entry.path)
            let itemsAfter = itemsAfterEntry(items: items, path: entry.path, promoteChildren: true)
            
            // Build the new blocks
            var newBlocks: [Block] = []
            
            // Add list with items before (if any)
            if !itemsBefore.isEmpty {
                newBlocks.append(.list(items: itemsBefore))
            }
            
            // Add the current item as a paragraph
            newBlocks.append(.paragraph(inline: entry.item.inline))
            
            // Add list with items after (if any)
            if !itemsAfter.isEmpty {
                newBlocks.append(.list(items: itemsAfter))
            }
            
            guard !newBlocks.isEmpty else {
                throw EditingError.unsupported(reason: "toggleList: no blocks to replace with")
            }
            
            // Replace the list block with the new blocks
            let result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
            
            // Cursor goes to the paragraph we just created
            // Find the paragraph block (it's the one that's not a list)
            var paraBlockIdx = blockIndex
            for (i, blk) in result.newProjection.document.blocks.enumerated() {
                if i >= blockIndex && i < blockIndex + newBlocks.count {
                    if case .paragraph = blk {
                        paraBlockIdx = i
                        break
                    }
                }
            }
            var newResult = result
            newResult.newCursorPosition = result.newProjection.blockSpans[paraBlockIdx].location
            return newResult

        case .blankLine:
            // Convert blank line to an empty list item.
            let item = ListItem(
                indent: "", marker: marker,
                afterMarker: " ", inline: [],
                children: []
            )
            let newBlock = Block.list(items: [item])
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            let newSpan = result.newProjection.blockSpans[blockIndex]
            result.newCursorPosition = newSpan.location + 1
            return result

        default:
            throw EditingError.unsupported(
                reason: "toggleList: not a paragraph or list"
            )
        }
    }

    /// Convert a paragraph to a blockquote, or a blockquote to a paragraph.
    public static func toggleBlockquote(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]

        switch block {
        case .paragraph(let inline):
            let line = BlockquoteLine(prefix: "> ", inline: inline)
            let newBlock = Block.blockquote(lines: [line])
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            let newSpan = result.newProjection.blockSpans[blockIndex]
            result.newCursorPosition = newSpan.location + newSpan.length
            return result

        case .blockquote(let lines):
            // Unwrap: merge all lines into a single paragraph.
            let allInlines = lines.flatMap { $0.inline }
            let newBlock = Block.paragraph(inline: allInlines)
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            let newSpan = result.newProjection.blockSpans[blockIndex]
            result.newCursorPosition = newSpan.location + newSpan.length
            return result

        default:
            throw EditingError.unsupported(
                reason: "toggleBlockquote: not a paragraph or blockquote"
            )
        }
    }

    /// Insert a horizontal rule after the block at `storageIndex`.
    public static func insertHorizontalRule(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        // Insert HR after the current block. A blankLine separator is
        // needed before the HR to prevent the parser from interpreting
        // "---" as a setext heading underline (e.g. "Before\n---" would
        // become an H2 instead of paragraph + HR).
        var newDoc = projection.document
        let hrBlock = Block.horizontalRule(character: "-", length: 3)
        newDoc.blocks.insert(.blankLine, at: blockIndex + 1)
        newDoc.blocks.insert(hrBlock, at: blockIndex + 2)

        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        // Splice covers from current block's end to the new HR's end.
        let oldSpan = projection.blockSpans[blockIndex]
        let newHRSpan = newProjection.blockSpans[blockIndex + 2]
        let spliceStart = oldSpan.location + oldSpan.length
        let spliceEnd = NSMaxRange(newHRSpan)
        let replacement = newProjection.attributed.attributedSubstring(
            from: NSRange(location: spliceStart, length: spliceEnd - spliceStart)
        )

        var result = EditResult(
            newProjection: newProjection,
            spliceRange: NSRange(location: spliceStart, length: 0),
            spliceReplacement: replacement
        )
        // +1 to skip the inter-block separator "\n" that follows the HR.
        result.newCursorPosition = NSMaxRange(newHRSpan) + 1
        return result
    }

    /// Wrap the text covered by `range` in a fenced code block.
    ///
    /// Three shapes:
    /// 1. Cursor-only (`range.length == 0`): insert an EMPTY code block
    ///    after the containing block. The original block is untouched.
    /// 2. Selection within a single paragraph: split the paragraph at
    ///    the selection boundaries and replace the block with
    ///    `[beforeParagraph?, codeBlock(selectedPlainText), afterParagraph?]`.
    ///    The prefix/suffix halves become their own paragraphs only if
    ///    non-empty.
    /// 3. Selection spanning multiple blocks: replaced by the concatenated
    ///    plain-text of the OVERLAP between `range` and each block's span
    ///    (so partial heads/tails at the endpoints are preserved as
    ///    surrounding paragraphs).
    ///
    /// The goal is that no user text is lost — the bug this replaces
    /// ("Select 'bar' in 'foo bar baz' + Code Block → everything else
    /// disappears") was caused by replacing the entire containing block
    /// with a code block whose content was only the selection.
    public static func wrapInCodeBlock(
        range: NSRange,
        in projection: DocumentProjection
    ) throws -> EditResult {
        // 1. Cursor-only: insert an empty code block after the current block.
        if range.length == 0 {
            guard let (blockIndex, _) = projection.blockContaining(
                storageIndex: range.location
            ) else {
                throw EditingError.notInsideBlock(storageIndex: range.location)
            }
            let emptyCode = Block.codeBlock(
                language: nil, content: "",
                fence: FenceStyle(character: .backtick, length: 3, infoRaw: "")
            )
            let originalBlock = projection.document.blocks[blockIndex]
            var result = try replaceBlockRange(
                blockIndex...blockIndex,
                with: [originalBlock, .blankLine, emptyCode],
                in: projection
            )
            // Position cursor inside the (empty) code block content area.
            let newCodeSpan = result.newProjection.blockSpans[blockIndex + 2]
            result.newCursorPosition = newCodeSpan.location
            return result
        }

        // 2 / 3. Non-empty range.
        let overlapping = projection.blockIndices(overlapping: range)
        guard let firstIdx = overlapping.first,
              let lastIdx = overlapping.last else {
            throw EditingError.notInsideBlock(storageIndex: range.location)
        }

        let rangeStart = range.location
        let rangeEnd = NSMaxRange(range)

        // Extract the plain text for each overlapped block's intersection
        // with `range`. For partial-first and partial-last, also record
        // the leading/trailing halves so we can preserve them as
        // surrounding paragraphs.
        var leadingInline: [Inline] = []
        var trailingInline: [Inline] = []
        var codeLines: [String] = []

        for (i, idx) in overlapping.enumerated() {
            let span = projection.blockSpans[idx]
            let block = projection.document.blocks[idx]
            let overlapStart = max(span.location, rangeStart)
            let overlapEnd = min(NSMaxRange(span), rangeEnd)
            let inBlockStart = overlapStart - span.location
            let inBlockEnd = overlapEnd - span.location

            // Extract plain text for the selected portion of the block.
            let blockText = plainTextOfBlock(block)
            let startClamped = min(max(inBlockStart, 0), blockText.count)
            let endClamped = min(max(inBlockEnd, startClamped), blockText.count)
            let startI = blockText.index(blockText.startIndex, offsetBy: startClamped)
            let endI = blockText.index(blockText.startIndex, offsetBy: endClamped)
            codeLines.append(String(blockText[startI..<endI]))

            // First block: the portion BEFORE the selection becomes the
            // leading paragraph (keeps inline formatting for paragraphs).
            if i == 0, inBlockStart > 0 {
                if case .paragraph(let inline) = block {
                    let (before, _) = splitInlines(inline, at: inBlockStart)
                    leadingInline = before
                } else {
                    // For non-paragraph blocks, preserve the leading
                    // half as plain text (loses formatting, but at
                    // least no data loss).
                    let leadStr = String(blockText[blockText.startIndex..<startI])
                    if !leadStr.isEmpty { leadingInline = [.text(leadStr)] }
                }
            }

            // Last block: the portion AFTER the selection becomes the
            // trailing paragraph.
            if i == overlapping.count - 1, inBlockEnd < blockText.count {
                if case .paragraph(let inline) = block {
                    let (_, after) = splitInlines(inline, at: inBlockEnd)
                    trailingInline = after
                } else {
                    let tailStr = String(blockText[endI..<blockText.endIndex])
                    if !tailStr.isEmpty { trailingInline = [.text(tailStr)] }
                }
            }
        }

        let codeContent = codeLines.joined(separator: "\n")
        let codeBlock = Block.codeBlock(
            language: nil, content: codeContent,
            fence: FenceStyle(character: .backtick, length: 3, infoRaw: "")
        )

        var replacementBlocks: [Block] = []
        if !leadingInline.isEmpty {
            replacementBlocks.append(.paragraph(inline: leadingInline))
        }
        replacementBlocks.append(codeBlock)
        if !trailingInline.isEmpty {
            replacementBlocks.append(.paragraph(inline: trailingInline))
        }

        var result = try replaceBlockRange(
            firstIdx...lastIdx, with: replacementBlocks, in: projection
        )
        // Position cursor at the start of the code block's content area.
        let codeBlockOffsetInReplacement = leadingInline.isEmpty ? 0 : 1
        let codeBlockIdx = firstIdx + codeBlockOffsetInReplacement
        let codeSpan = result.newProjection.blockSpans[codeBlockIdx]
        result.newCursorPosition = codeSpan.location
        return result
    }

    /// Plain-text projection of a block's inline content, matching the
    /// character length used by `blockSpans`. Used by `wrapInCodeBlock`
    /// to extract selection-aligned substrings.
    private static func plainTextOfBlock(_ block: Block) -> String {
        switch block {
        case .paragraph(let inline):
            return inlinesToText(inline)
        case .heading(_, let suffix):
            // `suffix` is the raw heading text (after `#` markers) — it
            // typically has a leading space; trim it to match the
            // rendered block span which omits that space.
            return suffix.hasPrefix(" ") ? String(suffix.dropFirst()) : suffix
        case .blockquote(let lines):
            return lines.map { inlinesToText($0.inline) }.joined(separator: "\n")
        case .codeBlock(_, let content, _):
            return content
        case .list(let items, _):
            return listItemsToText(items, depth: 0)
        case .htmlBlock(let raw):
            return raw
        default:
            return ""
        }
    }

    /// Insert an image (or PDF) attachment as a new paragraph block
    /// immediately after the block containing `storageIndex`. Returns
    /// an EditResult whose splice inserts just the new block (plus its
    /// leading separator newline) and positions the cursor at the end
    /// of the newly inserted image block.
    ///
    /// This is the clean block-model path for pasted / dragged images:
    /// - A single `.image` inline is wrapped in a fresh `.paragraph`
    ///   block and inserted into the Document.
    /// - The downstream renderer emits a placeholder attachment char
    ///   (InlineRenderer.makeImageAttachment).
    /// - The editor's `ImageAttachmentHydrator` hydrates the cell on
    ///   the main queue after the splice is applied.
    ///
    /// - Parameters:
    ///   - alt: alt text for the image (ends up as `![alt](...)` on save).
    ///   - destination: the path (relative or absolute) to the image file.
    ///   - storageIndex: current cursor position; used only to locate
    ///     the containing block. The image is inserted AFTER that block
    ///     regardless of intra-block offset.
    public static func insertImage(
        alt: String,
        destination: String,
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }

        // Build the new image block.
        let altInline: [Inline] = alt.isEmpty ? [] : [.text(alt)]
        let imageInline: Inline = .image(alt: altInline, rawDestination: destination, width: nil)
        let imageBlock = Block.paragraph(inline: [imageInline])

        var newDoc = projection.document
        newDoc.blocks.insert(imageBlock, at: blockIndex + 1)

        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        // Splice covers from the end of the current block's span to the
        // end of the new image block's span (includes the inter-block
        // "\n" separator).
        let oldSpan = projection.blockSpans[blockIndex]
        let newImageSpan = newProjection.blockSpans[blockIndex + 1]
        let spliceStart = oldSpan.location + oldSpan.length
        let spliceEnd = NSMaxRange(newImageSpan)
        let replacement = newProjection.attributed.attributedSubstring(
            from: NSRange(location: spliceStart, length: spliceEnd - spliceStart)
        )

        var result = EditResult(
            newProjection: newProjection,
            spliceRange: NSRange(location: spliceStart, length: 0),
            spliceReplacement: replacement
        )
        result.newCursorPosition = NSMaxRange(newImageSpan)
        return result
    }

    // MARK: - Image size

    /// Find the path to an `.image` inline at a specific render offset
    /// within a paragraph-style inline tree. Returns nil if no `.image`
    /// atom sits exactly at `offset`.
    ///
    /// Used by the view layer to translate a click on an attachment
    /// character into the `(blockIndex, inlinePath)` coordinates
    /// `setImageSize` expects. The paragraph block's inline tree is
    /// walked depth-first, accumulating render offsets via
    /// `inlineLength`. Images are length-1 atoms, so the match check
    /// is "current offset == target and node is an image".
    public static func findImageInlinePath(
        in inlines: [Inline],
        at offset: Int
    ) -> [Int]? {
        var running = 0
        return findImageInlinePathHelper(in: inlines, at: offset, running: &running, path: [])
    }

    private static func findImageInlinePathHelper(
        in inlines: [Inline],
        at target: Int,
        running: inout Int,
        path: [Int]
    ) -> [Int]? {
        for (idx, node) in inlines.enumerated() {
            let nodeStart = running
            let nodeEnd = running + inlineLength(node)
            // Only descend / consider nodes that can span the target.
            if target < nodeStart {
                return nil
            }
            if target >= nodeEnd {
                running = nodeEnd
                continue
            }
            // target is inside this node.
            switch node {
            case .image:
                // Images are length-1 atoms. Match only when the target
                // equals the node's starting offset.
                if target == nodeStart {
                    return path + [idx]
                }
                return nil
            case .bold(let c, _), .italic(let c, _),
                 .strikethrough(let c), .underline(let c),
                 .highlight(let c):
                // Descend into container. Children's offsets are
                // relative to the container's start.
                var childRunning = nodeStart
                if let found = findImageInlinePathHelper(
                    in: c, at: target, running: &childRunning, path: path + [idx]
                ) {
                    return found
                }
                running = nodeEnd
            case .link(let text, _):
                var childRunning = nodeStart
                if let found = findImageInlinePathHelper(
                    in: text, at: target, running: &childRunning, path: path + [idx]
                ) {
                    return found
                }
                running = nodeEnd
            default:
                // Leaf inline that isn't an image — no match.
                return nil
            }
        }
        return nil
    }

    /// Update the width hint of an inline image at `(blockIndex, inlinePath)`
    /// and route the edit through the standard replaceBlock pipeline.
    ///
    /// - `newWidth == nil` removes the size hint and reverts to natural
    ///   (container-clamped) size. Any existing non-size title text is
    ///   preserved — only the `width=N` token is stripped.
    /// - `newWidth > 0` writes (or replaces) the `width=N` token in the
    ///   title segment of the image's rawDestination. Existing non-size
    ///   title text is preserved alongside the token.
    ///
    /// Supports images inside `.paragraph` blocks. Other block types
    /// (heading, list, blockquote) throw `.unsupported` — images in
    /// those contexts are rare and deliberately out of scope for the
    /// phase-1 primitive.
    ///
    /// - Returns: an EditResult with a block-granular splice. The
    ///   spliceReplacement is a fresh attachment character carrying
    ///   the new `.renderedImageWidth` attribute; the hydrator picks
    ///   it up and scales the rendered bounds on its next pass.
    public static func setImageSize(
        blockIndex: Int,
        inlinePath: [Int],
        newWidth: Int?,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard blockIndex >= 0, blockIndex < projection.document.blocks.count else {
            throw EditingError.outOfBounds
        }
        let block = projection.document.blocks[blockIndex]

        guard case .paragraph(let inline) = block else {
            throw EditingError.unsupported(reason: "setImageSize: only paragraph blocks supported in phase 1 (got \(block))")
        }

        guard let newInline = setImageWidthAtPath(inline, path: inlinePath, newWidth: newWidth) else {
            throw EditingError.unsupported(reason: "setImageSize: path does not lead to an image at \(inlinePath)")
        }

        let newBlock = Block.paragraph(inline: newInline)
        return try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
    }

    /// Recursive helper: walk `inlines` to `path`, find the `.image`
    /// inline at the terminal position, and return a new inline tree
    /// with that image's rawDestination + width updated to reflect
    /// `newWidth`. Returns nil if the path is invalid or the target
    /// is not an image.
    ///
    /// The rawDestination is rebuilt from (preserved-title + new size
    /// hint) so round-trip serialization produces canonical output.
    private static func setImageWidthAtPath(
        _ inlines: [Inline],
        path: InlinePath,
        newWidth: Int?
    ) -> [Inline]? {
        guard !path.isEmpty else { return nil }
        let idx = path.first!
        guard idx >= 0, idx < inlines.count else { return nil }
        let rest = Array(path.dropFirst())
        var result = inlines

        if rest.isEmpty {
            // Terminal: target must be an .image.
            guard case let .image(alt, rawDest, _) = inlines[idx] else { return nil }
            let (url, oldTitle) = MarkdownParser.extractURLAndTitle(from: rawDest)
            let (preserved, _) = MarkdownParser.ImageSizeTitle.parse(oldTitle ?? "")
            let newTitle = MarkdownParser.ImageSizeTitle.emit(preserved: preserved, width: newWidth)
            let newRawDest = MarkdownParser.buildRawDest(url: url, title: newTitle)
            result[idx] = .image(alt: alt, rawDestination: newRawDest, width: newWidth)
            return result
        }

        // Descend into a container inline.
        switch inlines[idx] {
        case .bold(let c, let marker):
            guard let modified = setImageWidthAtPath(c, path: rest, newWidth: newWidth) else { return nil }
            result[idx] = .bold(modified, marker: marker)
        case .italic(let c, let marker):
            guard let modified = setImageWidthAtPath(c, path: rest, newWidth: newWidth) else { return nil }
            result[idx] = .italic(modified, marker: marker)
        case .strikethrough(let c):
            guard let modified = setImageWidthAtPath(c, path: rest, newWidth: newWidth) else { return nil }
            result[idx] = .strikethrough(modified)
        case .underline(let c):
            guard let modified = setImageWidthAtPath(c, path: rest, newWidth: newWidth) else { return nil }
            result[idx] = .underline(modified)
        case .highlight(let c):
            guard let modified = setImageWidthAtPath(c, path: rest, newWidth: newWidth) else { return nil }
            result[idx] = .highlight(modified)
        case .link(let text, let dest):
            guard let modified = setImageWidthAtPath(text, path: rest, newWidth: newWidth) else { return nil }
            result[idx] = .link(text: modified, rawDestination: dest)
        default:
            // Leaf or non-container inline — cannot descend.
            return nil
        }
        return result
    }

    // MARK: - Block swap (move up/down)

    /// Swap block at `blockIndex` with the block above it.
    /// Returns the new projection and a splice covering both blocks.
    public static func moveBlockUp(
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard blockIndex > 0 else {
            throw EditingError.unsupported(reason: "Cannot move first block up")
        }
        return try swapBlocks(blockIndex - 1, blockIndex, in: projection)
    }

    /// Swap block at `blockIndex` with the block below it.
    public static func moveBlockDown(
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard blockIndex < projection.document.blocks.count - 1 else {
            throw EditingError.unsupported(reason: "Cannot move last block down")
        }
        return try swapBlocks(blockIndex, blockIndex + 1, in: projection)
    }

    /// Swap two adjacent blocks in the document. `indexA` must be < `indexB`.
    private static func swapBlocks(
        _ indexA: Int,
        _ indexB: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        var newDoc = projection.document
        let blockA = newDoc.blocks[indexA]
        let blockB = newDoc.blocks[indexB]
        newDoc.blocks[indexA] = blockB
        newDoc.blocks[indexB] = blockA

        // Splice covers both blocks + the separator between them.
        let spanA = projection.blockSpans[indexA]
        let spanB = projection.blockSpans[indexB]
        let spliceStart = spanA.location
        let spliceEnd = spanB.location + spanB.length
        let spliceRange = NSRange(location: spliceStart, length: spliceEnd - spliceStart)

        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        // Extract the rendered content for the swapped region.
        let newSpanA = newProjection.blockSpans[indexA]
        let newSpanB = newProjection.blockSpans[indexB]
        let newStart = newSpanA.location
        let newEnd = newSpanB.location + newSpanB.length
        let newRange = NSRange(location: newStart, length: newEnd - newStart)
        let replacement = newProjection.attributed.attributedSubstring(from: newRange)

        return EditResult(
            newProjection: newProjection,
            spliceRange: spliceRange,
            spliceReplacement: replacement
        )
    }

    // MARK: - Todo checkbox toggle

    /// Toggle the checkbox on a list item at `storageIndex`.
    /// If the item is a todo, toggles checked ↔ unchecked.
    /// If the item is a regular list item, converts it to an unchecked todo.
    public static func toggleTodoCheckbox(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]

        guard case .list(let items, _) = block else {
            throw EditingError.unsupported(reason: "toggleTodoCheckbox: not a list block")
        }

        let entries = flattenList(items)
        let offsetInBlock = storageIndex - projection.blockSpans[blockIndex].location

        // Find the entry containing this offset — allow prefix area too
        // (user may click on the checkbox glyph itself).
        let entryIdx: Int
        if let (idx, _) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) {
            entryIdx = idx
        } else {
            // Check if offset is in a prefix area.
            guard let idx = entries.firstIndex(where: { entry in
                let entryEnd = entry.startOffset + entry.prefixLength + entry.inlineLength
                return offsetInBlock >= entry.startOffset && offsetInBlock <= entryEnd
            }) else {
                throw EditingError.unsupported(reason: "toggleTodoCheckbox: not in a list item")
            }
            entryIdx = idx
        }

        let entry = entries[entryIdx]
        let item = entry.item
        let newCheckbox: Checkbox?
        if let existing = item.checkbox {
            newCheckbox = existing.toggled()
        } else {
            // Convert regular item to unchecked todo.
            newCheckbox = Checkbox(text: "[ ]", afterText: " ")
        }
        let newItem = ListItem(
            indent: item.indent, marker: item.marker,
            afterMarker: item.afterMarker, checkbox: newCheckbox,
            inline: item.inline, children: item.children
        )
        let newItems = replaceItemAtPath(items, path: entry.path, with: newItem)
        let newBlock = Block.list(items: newItems)
        var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
        result.newCursorPosition = storageIndex
        return result
    }

    /// Convert a paragraph or list to a todo list (with unchecked items).
    /// If already a todo list, convert back to a regular list.
    public static func toggleTodoList(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]

        switch block {
        case .paragraph(let inline):
            // Wrap in a single-item todo list.
            let item = ListItem(
                indent: "", marker: "-",
                afterMarker: " ",
                checkbox: Checkbox(text: "[ ]", afterText: " "),
                inline: inline, children: []
            )
            let newBlock = Block.list(items: [item])
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            let newSpan = result.newProjection.blockSpans[blockIndex]
            // Place cursor after checkbox + space (start of text content).
            result.newCursorPosition = newSpan.location + 1
            return result

        case .list(let items, _):
            // If all top-level items have checkboxes, unwrap to paragraphs.
            // Otherwise, add unchecked checkboxes to items that lack them.
            let allTodo = items.allSatisfy { $0.checkbox != nil }
            if allTodo {
                // Unwrap: each top-level item becomes a paragraph.
                let newBlocks = items.map { item -> Block in
                    .paragraph(inline: item.inline)
                }
                var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                result.newCursorPosition = result.newProjection.blockSpans[blockIndex].location
                return result
            } else {
                let newItems = items.map { item in
                    if item.checkbox != nil { return item }
                    return ListItem(
                        indent: item.indent, marker: item.marker,
                        afterMarker: item.afterMarker,
                        checkbox: Checkbox(text: "[ ]", afterText: " "),
                        inline: item.inline, children: item.children
                    )
                }
                let newBlock = Block.list(items: newItems)
                var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
                result.newCursorPosition = storageIndex
                return result
            }

        case .blankLine:
            // Convert blank line to a todo item with empty text.
            let item = ListItem(
                indent: "", marker: "-",
                afterMarker: " ",
                checkbox: Checkbox(text: "[ ]", afterText: " "),
                inline: [], children: []
            )
            let newBlock = Block.list(items: [item])
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            let newSpan = result.newProjection.blockSpans[blockIndex]
            // Place cursor after checkbox + space (start of text content).
            result.newCursorPosition = newSpan.location + 1
            return result

        case .heading(_, let suffix):
            // Convert heading to a todo item, preserving the text.
            let leading = leadingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading))
            let item = ListItem(
                indent: "", marker: "-",
                afterMarker: " ",
                checkbox: Checkbox(text: "[ ]", afterText: " "),
                inline: [.text(displayed)], children: []
            )
            let newBlock = Block.list(items: [item])
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            let newSpan = result.newProjection.blockSpans[blockIndex]
            // Place cursor after checkbox + space (start of text content).
            result.newCursorPosition = newSpan.location + 1
            return result

        default:
            throw EditingError.unsupported(
                reason: "toggleTodoList: unsupported block type"
            )
        }
    }

    // MARK: - Inline trait toggle internals

    /// Toggle a trait on a subrange [from, to) within an inline tree.
    /// If the entire range is already wrapped in the trait, unwrap it.
    /// Otherwise, split at the boundaries and wrap the middle.
    private static func toggleTraitOnInlines(
        _ inlines: [Inline],
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        // Check if the entire [from, to) range is already inside the
        // target trait. This is approximate: we check if ALL leaf runs
        // in the range share a common ancestor of the target trait type.
        let runs = flatten(inlines)
        let coveredRuns = runsInRange(runs, from: from, to: to)

        if !coveredRuns.isEmpty && allRunsInsideTrait(coveredRuns, trait: trait, in: inlines) {
            // Unwrap: remove the trait wrapper.
            return unwrapTrait(inlines, trait: trait, from: from, to: to)
        }

        // Wrap: split at boundaries and insert trait wrapper.
        return wrapTrait(inlines, trait: trait, from: from, to: to)
    }

    /// Find which leaf runs overlap [from, to).
    private static func runsInRange(
        _ runs: [LeafRun],
        from: Int,
        to: Int
    ) -> [(index: Int, run: LeafRun)] {
        var result: [(index: Int, run: LeafRun)] = []
        var acc = 0
        for (i, run) in runs.enumerated() {
            let runEnd = acc + run.text.count
            if acc < to && runEnd > from {
                result.append((i, run))
            }
            acc = runEnd
        }
        return result
    }

    /// Check if all runs have a parent of the given trait type in their
    /// path within the inline tree, or are themselves that trait (for code).
    private static func allRunsInsideTrait(
        _ runs: [(index: Int, run: LeafRun)],
        trait: InlineTrait,
        in inlines: [Inline]
    ) -> Bool {
        for (_, run) in runs {
            // Code is a leaf, not a container — check the leaf itself.
            if trait == .code {
                if !run.isCode { return false }
            } else {
                if !pathContainsTrait(run.path, trait: trait, in: inlines) {
                    return false
                }
            }
        }
        return true
    }

    /// Check if any node along the path (including the leaf) is the given trait.
    private static func pathContainsTrait(
        _ path: InlinePath,
        trait: InlineTrait,
        in inlines: [Inline]
    ) -> Bool {
        var current: [Inline] = inlines
        for (depth, idx) in path.enumerated() {
            guard idx < current.count else { return false }
            let node = current[idx]
            // Check if this node IS the trait (at any depth, including leaf).
            switch (node, trait) {
            case (.bold, .bold): return true
            case (.italic, .italic): return true
            case (.strikethrough, .strikethrough): return true
            case (.underline, .underline): return true
            case (.highlight, .highlight): return true
            default: break
            }
            // Descend into interior nodes.
            if depth < path.count - 1 {
                switch node {
                case .bold(let c, _): current = c
                case .italic(let c, _): current = c
                case .strikethrough(let c): current = c
                case .underline(let c): current = c
                case .highlight(let c): current = c
                case .link(let text, _): current = text
                case .image(let alt, _, _): current = alt
                default: return false
                }
            }
        }
        return false
    }

    /// Wrap a subrange [from, to) in a trait. Splits at boundaries.
    private static func wrapTrait(
        _ inlines: [Inline],
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        let (before, rest) = splitInlines(inlines, at: from)
        let middleLength = to - from
        let (middle, after) = splitInlines(rest, at: middleLength)

        let wrapped: Inline
        switch trait {
        case .bold:          wrapped = .bold(middle, marker: .asterisk)
        case .italic:        wrapped = .italic(middle, marker: .asterisk)
        case .strikethrough: wrapped = .strikethrough(middle)
        case .underline:     wrapped = .underline(middle)
        case .highlight:     wrapped = .highlight(middle)
        case .code:
            // Code wrapping: flatten the middle to plain text.
            let text = middle.map { inlineToText($0) }.joined()
            wrapped = .code(text)
        }

        return cleanInlines(before + [wrapped] + after)
    }

    /// Unwrap a trait from a subrange. This is the inverse of wrap.
    private static func unwrapTrait(
        _ inlines: [Inline],
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        // Strategy: rebuild the inline tree, and for any trait node
        // of the target type whose content overlaps [from, to),
        // replace it with its children (i.e., remove the wrapper).
        var acc = 0
        var result: [Inline] = []
        for node in inlines {
            let nodeLen = inlineLength(node)
            let nodeStart = acc
            let nodeEnd = acc + nodeLen

            if nodeStart >= from && nodeEnd <= to {
                // Fully inside the selection.
                switch (node, trait) {
                case (.bold(let children, _), .bold):
                    result.append(contentsOf: children)
                case (.italic(let children, _), .italic):
                    result.append(contentsOf: children)
                case (.strikethrough(let children), .strikethrough):
                    result.append(contentsOf: children)
                case (.underline(let children), .underline):
                    result.append(contentsOf: children)
                case (.highlight(let children), .highlight):
                    result.append(contentsOf: children)
                case (.code(let s), .code):
                    result.append(.text(s))
                default:
                    // Different trait or leaf — recurse if container.
                    result.append(contentsOf: unwrapTraitInNode(node, trait: trait, from: from - nodeStart, to: to - nodeStart))
                }
            } else if nodeEnd > from && nodeStart < to {
                // Partially overlaps — recurse into children.
                result.append(contentsOf: unwrapTraitInNode(node, trait: trait, from: from - nodeStart, to: to - nodeStart))
            } else {
                // Outside selection — keep unchanged.
                result.append(node)
            }
            acc = nodeEnd
        }
        return cleanInlines(result)
    }

    /// Unwrap a trait within a single inline node that partially overlaps
    /// the selection [from, to).
    ///
    /// When the node's own trait matches the target, we split the children
    /// into three segments:
    ///   1. [0, from)  — stays wrapped in the trait
    ///   2. [from, to) — unwrapped (trait removed)
    ///   3. [to, end)  — stays wrapped in the trait
    ///
    /// When the node's trait doesn't match, we recurse into children
    /// preserving the wrapper.
    private static func unwrapTraitInNode(
        _ node: Inline,
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        let clampedFrom = max(from, 0)

        switch node {
        case .bold(let children, let marker):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .bold {
                return splitAndUnwrap(children, wrapWith: { .bold($0, marker: marker) }, from: clampedFrom, to: clampedTo)
            }
            return [.bold(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo), marker: marker)]
        case .italic(let children, let marker):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .italic {
                return splitAndUnwrap(children, wrapWith: { .italic($0, marker: marker) }, from: clampedFrom, to: clampedTo)
            }
            return [.italic(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo), marker: marker)]
        case .strikethrough(let children):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .strikethrough {
                return splitAndUnwrap(children, wrapWith: { .strikethrough($0) }, from: clampedFrom, to: clampedTo)
            }
            return [.strikethrough(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo))]
        case .underline(let children):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .underline {
                return splitAndUnwrap(children, wrapWith: { .underline($0) }, from: clampedFrom, to: clampedTo)
            }
            return [.underline(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo))]
        case .highlight(let children):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .highlight {
                return splitAndUnwrap(children, wrapWith: { .highlight($0) }, from: clampedFrom, to: clampedTo)
            }
            return [.highlight(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo))]
        case .link(let text, let dest):
            let len = inlinesLength(text)
            let clampedTo = min(to, len)
            return [.link(text: unwrapTrait(text, trait: trait, from: clampedFrom, to: clampedTo), rawDestination: dest)]
        case .image(let alt, let dest, let width):
            let len = inlinesLength(alt)
            let clampedTo = min(to, len)
            return [.image(alt: unwrapTrait(alt, trait: trait, from: clampedFrom, to: clampedTo), rawDestination: dest, width: width)]
        case .text, .code, .math, .displayMath, .autolink, .escapedChar, .lineBreak, .rawHTML, .entity, .wikilink:
            return [node]
        }
    }

    /// Split children at [from, to), keeping the portions outside the
    /// range wrapped via `wrapWith` and leaving the inside unwrapped.
    private static func splitAndUnwrap(
        _ children: [Inline],
        wrapWith: ([Inline]) -> Inline,
        from: Int,
        to: Int
    ) -> [Inline] {
        var result: [Inline] = []
        let len = inlinesLength(children)

        // Part before selection — stays wrapped
        if from > 0 {
            let (beforePart, _) = splitInlines(children, at: from)
            let cleaned = cleanInlines(beforePart)
            if !cleaned.isEmpty {
                result.append(wrapWith(cleaned))
            }
        }

        // Part inside selection — unwrapped (trait removed)
        let innerStart = max(from, 0)
        let innerEnd = min(to, len)
        if innerStart < innerEnd {
            let (_, afterStart) = splitInlines(children, at: innerStart)
            let (middle, _) = splitInlines(afterStart, at: innerEnd - innerStart)
            let cleaned = cleanInlines(middle)
            result.append(contentsOf: cleaned)
        }

        // Part after selection — stays wrapped
        if to < len {
            let (_, afterPart) = splitInlines(children, at: to)
            let cleaned = cleanInlines(afterPart)
            if !cleaned.isEmpty {
                result.append(wrapWith(cleaned))
            }
        }

        return result
    }

    /// Remove empty text nodes and merge adjacent text nodes.
    private static func cleanInlines(_ inlines: [Inline]) -> [Inline] {
        var result: [Inline] = []
        for node in inlines {
            switch node {
            case .text(let s):
                if s.isEmpty { continue }
                if case .text(let prev) = result.last {
                    result[result.count - 1] = .text(prev + s)
                } else {
                    result.append(node)
                }
            case .code(let s):
                if s.isEmpty { continue }
                result.append(node)
            case .math(let s):
                if s.isEmpty { continue }
                result.append(node)
            case .displayMath(let s):
                if s.isEmpty { continue }
                result.append(node)
            case .bold(let children, let marker):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.bold(cleaned, marker: marker))
            case .italic(let children, let marker):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.italic(cleaned, marker: marker))
            case .strikethrough(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.strikethrough(cleaned))
            case .underline(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.underline(cleaned))
            case .highlight(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.highlight(cleaned))
            case .link(let text, let dest):
                let cleaned = cleanInlines(text)
                if cleaned.isEmpty { continue }
                result.append(.link(text: cleaned, rawDestination: dest))
            case .image(let alt, let dest, let width):
                let cleaned = cleanInlines(alt)
                if cleaned.isEmpty { continue }
                result.append(.image(alt: cleaned, rawDestination: dest, width: width))
            case .autolink(let text, _):
                if text.isEmpty { continue }
                result.append(node)
            case .escapedChar:
                result.append(node)
            case .lineBreak:
                result.append(node)
            case .rawHTML(let html):
                if html.isEmpty { continue }
                result.append(node)
            case .entity(let raw):
                if raw.isEmpty { continue }
                result.append(node)
            case .wikilink(let target, _):
                if target.isEmpty { continue }
                result.append(node)
            }
        }
        return result
    }

    /// Simple inline parser: treats the string as plain text (no inline
    /// formatting). Used when converting headings to paragraphs or vice
    /// versa, where the suffix is a raw string.
    private static func parseInlinesFromText(_ text: String) -> [Inline] {
        if text.isEmpty { return [] }
        return [.text(text)]
    }

    // MARK: - Inline re-parsing (RC4)

    /// Check if the block at `blockIndex` has inline content that would
    /// parse differently if its markdown source were re-parsed. This
    /// detects cases where character-by-character insertion has built up
    /// a completed inline pattern (e.g. `[text](url)`) that is still
    /// stored as plain `.text` nodes.
    ///
    /// Returns a new EditResult if re-parsing changed the inlines,
    /// or nil if no change is needed.
    public static func reparseInlinesIfNeeded(
        blockIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult? {
        let block = projection.document.blocks[blockIndex]

        // Extract current inlines and re-parse.
        let currentInlines: [Inline]
        let reParsedBlock: Block

        switch block {
        case .paragraph(let inline):
            currentInlines = inline
            let markdown = MarkdownSerializer.serializeInlines(inline)
            let newInlines = MarkdownParser.parseInlines(markdown)
            if inlinesEqual(currentInlines, newInlines) { return nil }
            reParsedBlock = .paragraph(inline: newInlines)

        case .heading(let level, let suffix):
            // Heading suffix contains inline content after the leading space.
            // Re-parse it to detect completed patterns.
            let trimmed = String(suffix.drop(while: { $0 == " " }))
            guard !trimmed.isEmpty else { return nil }
            let currentHeadingInlines = MarkdownParser.parseInlines(trimmed)
            let markdown = MarkdownSerializer.serializeInlines(currentHeadingInlines)
            let newInlines = MarkdownParser.parseInlines(markdown)
            // For headings, we check if re-parsing the suffix text yields
            // a different result. Since heading suffix is raw text (not
            // an inline tree), we can't compare directly — skip for now.
            // Heading inline content is stored in the suffix string, so
            // re-parsing only helps if the suffix itself changes meaning.
            return nil

        case .list(let items, let loose):
            // Check each list item's inlines.
            var anyChanged = false
            let newItems = items.map { item -> ListItem in
                let markdown = MarkdownSerializer.serializeInlines(item.inline)
                let newInlines = MarkdownParser.parseInlines(markdown)
                if !inlinesEqual(item.inline, newInlines) {
                    anyChanged = true
                    return ListItem(
                        indent: item.indent, marker: item.marker,
                        afterMarker: item.afterMarker, checkbox: item.checkbox,
                        inline: newInlines, children: reparseListChildren(item.children),
                        blankLineBefore: item.blankLineBefore
                    )
                }
                return item
            }
            if !anyChanged { return nil }
            reParsedBlock = .list(items: newItems, loose: loose)

        case .blockquote(let lines):
            var anyChanged = false
            let newLines = lines.map { line -> BlockquoteLine in
                let markdown = MarkdownSerializer.serializeInlines(line.inline)
                let newInlines = MarkdownParser.parseInlines(markdown)
                if !inlinesEqual(line.inline, newInlines) {
                    anyChanged = true
                    return BlockquoteLine(prefix: line.prefix, inline: newInlines)
                }
                return line
            }
            if !anyChanged { return nil }
            reParsedBlock = .blockquote(lines: newLines)

        default:
            return nil
        }

        return try replaceBlock(atIndex: blockIndex, with: reParsedBlock, in: projection)
    }

    /// Recursively re-parse inlines in list children.
    private static func reparseListChildren(_ children: [ListItem]) -> [ListItem] {
        return children.map { child in
            let markdown = MarkdownSerializer.serializeInlines(child.inline)
            let newInlines = MarkdownParser.parseInlines(markdown)
            return ListItem(
                indent: child.indent, marker: child.marker,
                afterMarker: child.afterMarker, checkbox: child.checkbox,
                inline: newInlines, children: reparseListChildren(child.children),
                blankLineBefore: child.blankLineBefore
            )
        }
    }

    /// Compare two inline trees for structural equality. Uses the
    /// Equatable conformance on Inline.
    private static func inlinesEqual(_ a: [Inline], _ b: [Inline]) -> Bool {
        return a == b
    }

    // MARK: - Table cell editing
    //
    // The table cell refactor (see CLAUDE.md "Rules That Exist Because I
    // Broke Them" → the InlineTableView cautionary tale). Tables were
    // originally special-cased: the widget owned its own mutable cell
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

    /// Find positions of attachment characters (U+FFFC) in an attributed string
    /// within the given range. Returns a set of relative positions.
    private static func findAttachmentPositions(in attrString: NSAttributedString, range: NSRange) -> Set<Int> {
        var positions = Set<Int>()
        let attachmentChar = Character("\u{FFFC}")
        let substring = attrString.attributedSubstring(from: range)
        let str = substring.string

        for (index, char) in str.enumerated() {
            if char == attachmentChar {
                // Verify it actually has an attachment attribute
                let charRange = NSRange(location: index, length: 1)
                if substring.attribute(.attachment, at: index, effectiveRange: nil) != nil {
                    positions.insert(index)
                }
            }
        }
        return positions
    }

}
