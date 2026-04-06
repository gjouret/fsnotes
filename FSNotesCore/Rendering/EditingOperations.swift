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
//  - Block-granular splices: insertion/deletion inside block[i] produces
//    a splice whose range is the OLD blockSpans[i], replaced by the
//    NEW rendered output for block[i]. Sibling blocks are untouched.
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
}

/// Errors raised by editing operations.
public enum EditingError: Error, Equatable {
    /// The storage index lies outside any block (on a separator, or
    /// past the end of the document).
    case notInsideBlock(storageIndex: Int)
    /// The operation is not supported for this block type or
    /// configuration.
    case unsupported(reason: String)
    /// A range-based operation spans more than one block.
    case crossBlockRange
    /// A range-based operation spans more than one inline leaf (e.g.
    /// text→bold→text) within a paragraph.
    case crossInlineRange
    /// A delete range would reach beyond the document's rendered length.
    case outOfBounds
}

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
            case .codeBlock:
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
            case .list(let items):
                if string == "\n" {
                    do {
                        let newBlocks = try splitListOnNewline(
                            items: items, at: offsetInBlock, blockIndex: blockIndex, in: projection
                        )
                        var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                        let lastIdx = blockIndex + newBlocks.count - 1
                        result.newCursorPosition = result.newProjection.blockSpans[lastIdx].location
                        return result
                    } catch EditingError.unsupported(let reason) where reason.contains("empty item return") {
                        // FSM: empty item → exit or unindent.
                        return try returnOnEmptyListItem(at: storageIndex, in: projection)
                    }
                }
                throw EditingError.unsupported(
                    reason: "multi-line paste in list not supported"
                )
            case .blockquote(let lines):
                if string == "\n" {
                    let newBlocks = try splitBlockquoteOnNewline(
                        lines: lines, at: offsetInBlock, blockIndex: blockIndex, in: projection
                    )
                    var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
                    let lastIdx = blockIndex + newBlocks.count - 1
                    result.newCursorPosition = result.newProjection.blockSpans[lastIdx].location
                    return result
                }
                throw EditingError.unsupported(
                    reason: "multi-line paste in blockquote not supported"
                )
            case .heading, .horizontalRule, .blankLine:
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
            // Merge adjacent blocks when delete crosses exactly
            // one block boundary (backspace at block start, or selection
            // spanning the separator).
            if endBlock == startBlock + 1 {
                var result = try mergeAdjacentBlocks(
                    startBlock: startBlock, startOffset: startOffset,
                    endBlock: endBlock, endOffset: endOffset,
                    in: projection
                )
                result.newCursorPosition = storageRange.location
                return result
            }
            throw EditingError.crossBlockRange
        }
        let oldBlock = projection.document.blocks[startBlock]
        let newBlock = try deleteInBlock(oldBlock, from: startOffset, to: endOffset)
        var result = try replaceBlock(
            atIndex: startBlock,
            with: newBlock,
            in: projection
        )
        result.newCursorPosition = storageRange.location
        return result
    }

    // MARK: - Block-level primitive

    /// Replace `document.blocks[blockIndex]` with `newBlock`, producing
    /// a new projection and a block-granular splice.
    private static func replaceBlock(
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

        // Build the new Document by splicing the block list.
        var newDoc = projection.document
        newDoc.blocks.replaceSubrange(blockIndex...blockIndex, with: newBlocks)

        // Produce the new projection (full re-render). This is the
        // authoritative post-edit state with correct paragraph styles,
        // collapsed blankLine separators, etc.
        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont
        )

        // Extract the splice replacement from the new projection.
        // It covers the new blocks' spans plus the inter-block
        // separators between them.
        let firstNewSpan = newProjection.blockSpans[blockIndex]
        let lastNewSpan = newProjection.blockSpans[blockIndex + newBlocks.count - 1]
        let spliceStart = firstNewSpan.location
        let spliceEnd = NSMaxRange(lastNewSpan)
        let replacementRange = NSRange(location: spliceStart, length: spliceEnd - spliceStart)
        let replacement = newProjection.attributed.attributedSubstring(from: replacementRange)

        let oldSpan = projection.blockSpans[blockIndex]

        return EditResult(
            newProjection: newProjection,
            spliceRange: oldSpan,
            spliceReplacement: replacement
        )
    }

    /// Merge two adjacent blocks `blocks[i]` and `blocks[i+1]`,
    /// deleting characters `[startOffset..end)` from the first block
    /// and `[0..endOffset)` from the second. Produces a single merged
    /// block and a splice that covers both old blocks plus the
    /// separator between them.
    ///
    /// Supported merge pairs:
    ///   paragraph + paragraph → concatenated paragraph
    ///   paragraph + blankLine → paragraph
    ///   blankLine  + paragraph → paragraph
    ///   blankLine  + blankLine → blankLine
    ///
    /// Other combinations (heading, codeBlock, list, etc.) throw
    /// `.unsupported`.
    private static func mergeAdjacentBlocks(
        startBlock: Int,
        startOffset: Int,
        endBlock: Int,
        endOffset: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        let blockA = projection.document.blocks[startBlock]
        let blockB = projection.document.blocks[endBlock]

        // Compute what remains of each block after deleting the
        // specified range tails.
        let remainA = try remainingInlineSuffix(of: blockA, keepingUpTo: startOffset)
        let remainB = try remainingInlinePrefix(of: blockB, droppingUpTo: endOffset)

        // Merge the two remainders into a single block.
        let merged: Block
        switch (remainA, remainB) {
        case (.some(let a), .some(let b)):
            merged = .paragraph(inline: a + b)
        case (.some(let a), .none):
            merged = .paragraph(inline: a)
        case (.none, .some(let b)):
            merged = .paragraph(inline: b)
        case (.none, .none):
            merged = .blankLine
        }

        // Build new document: remove blocks[startBlock...endBlock],
        // insert `merged` at startBlock.
        var newDoc = projection.document
        newDoc.blocks.replaceSubrange(startBlock...endBlock, with: [merged])

        // Splice range: from start of blockA's span to end of blockB's
        // span, INCLUDING the separator "\n" between them.
        let spanA = projection.blockSpans[startBlock]
        let spanB = projection.blockSpans[endBlock]
        let spliceStart = spanA.location
        let spliceEnd = spanB.location + spanB.length
        let spliceRange = NSRange(location: spliceStart, length: spliceEnd - spliceStart)

        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont
        )

        // Extract the merged block's rendered content from the new
        // projection (includes paragraph styles).
        let mergedSpan = newProjection.blockSpans[startBlock]
        let mergedRendered = newProjection.attributed.attributedSubstring(from: mergedSpan)

        return EditResult(
            newProjection: newProjection,
            spliceRange: spliceRange,
            spliceReplacement: mergedRendered
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
            // Use the displayed text portion.
            let leading = leadingWhitespaceCount(in: suffix)
            let trailing = trailingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading).dropLast(trailing))
            let (before, _) = splitInlines([.text(displayed)], at: keepCount)
            return before
        case .codeBlock(_, let content, _):
            let (before, _) = splitInlines([.text(content)], at: keepCount)
            return before
        case .list, .blockquote:
            // For merging purposes, extract the block's rendered text as
            // a flat paragraph. This converts the block type but
            // preserves the text content.
            let rendered = blockRenderedText(block)
            let (before, _) = splitInlines([.text(rendered)], at: keepCount)
            return before
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
            let trailing = trailingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading).dropLast(trailing))
            let (_, after) = splitInlines([.text(displayed)], at: dropCount)
            return after
        case .codeBlock(_, let content, _):
            let (_, after) = splitInlines([.text(content)], at: dropCount)
            return after
        case .list, .blockquote:
            let rendered = blockRenderedText(block)
            let (_, after) = splitInlines([.text(rendered)], at: dropCount)
            return after
        }
    }

    /// Extract the rendered text content of a block as a plain string.
    /// Used for merge operations where the block type is lost.
    private static func blockRenderedText(_ block: Block) -> String {
        switch block {
        case .paragraph(let inline): return inlinesToText(inline)
        case .heading(_, let suffix):
            let l = leadingWhitespaceCount(in: suffix)
            let t = trailingWhitespaceCount(in: suffix)
            return String(suffix.dropFirst(l).dropLast(t))
        case .codeBlock(_, let content, _): return content
        case .list(let items): return listItemsToText(items, depth: 0)
        case .blockquote(let lines):
            return lines.map { inlinesToText($0.inline) }.joined(separator: "\n")
        case .horizontalRule: return ""
        case .blankLine: return ""
        }
    }

    private static func inlinesToText(_ inlines: [Inline]) -> String {
        return inlines.map { inlineToText($0) }.joined()
    }

    private static func inlineToText(_ inline: Inline) -> String {
        switch inline {
        case .text(let s): return s
        case .code(let s): return s
        case .bold(let c): return inlinesToText(c)
        case .italic(let c): return inlinesToText(c)
        case .strikethrough(let c): return inlinesToText(c)
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
        let lines = pastedText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)

        var newBlocks: [Block] = []

        for (i, line) in lines.enumerated() {
            let isFirst = (i == 0)
            let isLast = (i == lines.count - 1)

            var lineInline: [Inline] = line.isEmpty ? [] : [.text(line)]
            if isFirst { lineInline = before + lineInline }
            if isLast  { lineInline = lineInline + after }

            if isInlineEmpty(lineInline) {
                newBlocks.append(.blankLine)
            } else {
                newBlocks.append(.paragraph(inline: lineInline))
            }
        }

        if newBlocks.isEmpty {
            // Defensive: shouldn't happen (split always produces ≥ 1 part).
            newBlocks.append(.paragraph(inline: before + after))
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
            afterMarker: entry.item.afterMarker, checkbox: entry.item.checkbox,
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
            // Map render-offset → suffix-offset. The renderer trims
            // whitespace from the suffix. The displayed text is
            // suffix with leading/trailing whitespace trimmed, so
            // render offset `o` corresponds to suffix offset
            // `o + leadingWS.count`.
            let leading = leadingWhitespaceCount(in: suffix)
            let trailing = trailingWhitespaceCount(in: suffix)
            let displayedCount = suffix.count - leading - trailing
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

        case .list(let items):
            return try insertIntoList(items: items, offsetInBlock: offsetInBlock, string: string)

        case .blockquote(let lines):
            return try insertIntoBlockquote(lines: lines, offsetInBlock: offsetInBlock, string: string)

        case .horizontalRule:
            // HR has no editable content — typing on it inserts a new
            // paragraph. The caller (insert at top level) will detect
            // that the returned block differs in kind from the original
            // and handle appropriately. For now, reject: the user can
            // type above/below the HR, not on it.
            throw EditingError.unsupported(
                reason: "horizontalRule is read-only"
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
            let leading = leadingWhitespaceCount(in: suffix)
            let trailing = trailingWhitespaceCount(in: suffix)
            let displayedCount = suffix.count - leading - trailing
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

        case .list(let items):
            return try deleteInList(items: items, from: fromOffset, to: toOffset)

        case .blockquote(let lines):
            return try deleteInBlockquote(lines: lines, from: fromOffset, to: toOffset)

        case .horizontalRule:
            // HR has no editable content — deletes within it are no-ops.
            // Cross-block deletion (backspace from next block) is handled
            // by mergeAdjacentBlocks.
            return block
        }
    }

    // MARK: - List editing

    /// A flattened list item with its rendered prefix length and tree
    /// path for reconstruction. The rendered output of a list block is:
    ///   item0.prefix + item0.inlineContent + "\n" +
    ///   item1.prefix + item1.inlineContent + "\n" + ...
    /// (no trailing "\n" — stripped by ListRenderer).
    private struct FlatListEntry {
        let item: ListItem
        let depth: Int
        let prefixLength: Int   // visual indent + bullet + " "
        let inlineLength: Int   // rendered inline chars
        let startOffset: Int    // offset within block's rendered output
        let path: [Int]         // tree path for reconstruction
    }

    /// Flatten a list's item tree into an ordered array of entries with
    /// their rendered offsets. Mirrors ListRenderer's walk order.
    private static func flattenList(
        _ items: [ListItem],
        depth: Int = 0,
        startOffset: Int = 0,
        path: [Int] = []
    ) -> [FlatListEntry] {
        var entries: [FlatListEntry] = []
        var offset = startOffset
        for (i, item) in items.enumerated() {
            let visualIndent = depth * 2 // matches ListRenderer.indentWidth
            let bullet = listVisualBullet(for: item.marker, depth: depth)
            let prefixLen = visualIndent + bullet.count + 1 // indent + bullet + " "
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
    private static func listEntryContaining(
        entries: [FlatListEntry],
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
        guard let (endEntry, _) = listEntryContaining(
            entries: entries, offset: toOffset - 1, forInsertion: false
        ) else {
            throw EditingError.unsupported(
                reason: "list: delete end \(toOffset - 1) not within editable inline content"
            )
        }
        guard startEntry == endEntry else {
            throw EditingError.crossInlineRange
        }
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
            let prefixLen = qLine.level * 2 // matches BlockquoteRenderer.indentPerLevel
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
        case .bold(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .italic(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .strikethrough(let c): return c.reduce(0) { $0 + inlineLength($1) }
        }
    }

    /// Split a list of inline nodes at render offset `offset`, returning
    /// (before, after). Containers straddling the split point are
    /// recursively split and REPRODUCED on both sides.
    private static func splitInlines(
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
                case .bold(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.bold(b))
                    after.append(.bold(a))
                case .italic(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.italic(b))
                    after.append(.italic(a))
                case .strikethrough(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.strikethrough(b))
                    after.append(.strikethrough(a))
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
            case .bold(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .italic(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .strikethrough(let children):
                walkFlatten(children, path: &path, into: &runs)
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
            case .bold, .italic, .strikethrough:
                // Path exhausted on a container: should not happen
                // when paths come from `flatten`. Leave unchanged.
                return inline
            }
        }
        let idx = path.first!
        let rest = Array(path.dropFirst())
        switch inline {
        case .text, .code:
            // Cannot descend into a leaf.
            return inline
        case .bold(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .bold(c)
        case .italic(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .italic(c)
        case .strikethrough(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .strikethrough(c)
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
        guard case .list(let items) = block else {
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
        guard case .list(let items) = block else {
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
    /// body paragraph. If this was the only item, the entire list block
    /// is replaced with the paragraph. Otherwise the list continues
    /// without this item, and a new paragraph block is inserted after
    /// the list (or before, or the list splits).
    public static func exitListItem(
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: storageIndex) else {
            throw EditingError.notInsideBlock(storageIndex: storageIndex)
        }
        let block = projection.document.blocks[blockIndex]
        guard case .list(let items) = block else {
            throw EditingError.unsupported(reason: "exitListItem: not a list block")
        }

        let entries = flattenList(items)
        guard let (entryIdx, inlineOffset) = listEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(reason: "exitListItem: cursor not in inline content")
        }
        let entry = entries[entryIdx]

        // The exiting item's inline content becomes a paragraph.
        let exitedParagraph: Block
        if isInlineEmpty(entry.item.inline) {
            exitedParagraph = .blankLine
        } else {
            exitedParagraph = .paragraph(inline: entry.item.inline)
        }

        // Remove the item from the tree. Any children of the exiting
        // item are promoted to the same level.
        let remaining = removeItemAtPath(items, path: entry.path, promoteChildren: true)

        // Build the replacement blocks.
        var newBlocks: [Block] = []
        if !remaining.isEmpty {
            // Split: items before the exited one stay in a list, then
            // the paragraph, then items after. For simplicity, keep one
            // list with the item removed + paragraph after.
            newBlocks.append(.list(items: remaining))
        }
        newBlocks.append(exitedParagraph)

        var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)

        // Cursor goes to the start of the exited paragraph.
        let paraBlockIdx = blockIndex + (remaining.isEmpty ? 0 : 1)
        if paraBlockIdx < result.newProjection.blockSpans.count {
            result.newCursorPosition = result.newProjection.blockSpans[paraBlockIdx].location + inlineOffset
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
            var result = items
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

    // MARK: - Block-level conversions

    /// Inline trait for toggle operations.
    public enum InlineTrait {
        case bold
        case italic
        case strikethrough
        case code
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
            // Map render offset → suffix offset.
            let leading = leadingWhitespaceCount(in: suffix)
            let inlines = parseInlinesFromText(
                String(suffix.dropFirst(leading).prefix(suffix.count - leading - trailingWhitespaceCount(in: suffix)))
            )
            let newInline = toggleTraitOnInlines(inlines, trait: trait, from: offsetStart, to: offsetEnd)
            // Rebuild suffix from new inlines.
            let newText = inlinesToText(newInline)
            let leadingWS = String(suffix.prefix(leading))
            newBlock = .heading(level: level, suffix: leadingWS + newText)

        case .list(let items):
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
        // Cursor stays at the end of the selection.
        let newSpan = result.newProjection.blockSpans[blockIndex]
        result.newCursorPosition = min(
            newSpan.location + offsetEnd,
            newSpan.location + newSpan.length
        )
        return result
    }

    /// Convert a paragraph to an unordered list, or a list to paragraphs.
    ///
    /// - When `storageIndex` is in a paragraph: wraps it in a single-item
    ///   unordered list with the given marker (default "-").
    /// - When `storageIndex` is in a list: unwraps the list, converting
    ///   each top-level item to a paragraph.
    public static func toggleList(
        marker: String = "-",
        at storageIndex: Int,
        in projection: DocumentProjection
    ) throws -> EditResult {
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: storageIndex) else {
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
            result.newCursorPosition = newSpan.location + newSpan.length
            return result

        case .list(let items):
            // Unwrap: each top-level item becomes a paragraph.
            let newBlocks = items.map { item -> Block in
                .paragraph(inline: item.inline)
            }
            var result = try replaceBlocks(atIndex: blockIndex, with: newBlocks, in: projection)
            result.newCursorPosition = result.newProjection.blockSpans[blockIndex].location
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
        // Insert HR after the current block, followed by a blank line.
        var newDoc = projection.document
        let hrBlock = Block.horizontalRule(character: "-", length: 3)
        newDoc.blocks.insert(hrBlock, at: blockIndex + 1)

        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont
        )

        // Splice covers from current block's end to the new HR's end.
        let oldSpan = projection.blockSpans[blockIndex]
        let newHRSpan = newProjection.blockSpans[blockIndex + 1]
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
        result.newCursorPosition = NSMaxRange(newHRSpan)
        return result
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

        guard case .list(let items) = block else {
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
            result.newCursorPosition = newSpan.location + newSpan.length
            return result

        case .list(let items):
            // If all top-level items have checkboxes, remove them.
            // Otherwise, add unchecked checkboxes to items that lack them.
            let allTodo = items.allSatisfy { $0.checkbox != nil }
            let newItems: [ListItem]
            if allTodo {
                newItems = items.map { item in
                    ListItem(
                        indent: item.indent, marker: item.marker,
                        afterMarker: item.afterMarker, checkbox: nil,
                        inline: item.inline, children: item.children
                    )
                }
            } else {
                newItems = items.map { item in
                    if item.checkbox != nil { return item }
                    return ListItem(
                        indent: item.indent, marker: item.marker,
                        afterMarker: item.afterMarker,
                        checkbox: Checkbox(text: "[ ]", afterText: " "),
                        inline: item.inline, children: item.children
                    )
                }
            }
            let newBlock = Block.list(items: newItems)
            var result = try replaceBlock(atIndex: blockIndex, with: newBlock, in: projection)
            result.newCursorPosition = storageIndex
            return result

        default:
            throw EditingError.unsupported(
                reason: "toggleTodoList: not a paragraph or list"
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

    /// Check if any ancestor along the path is the given trait.
    private static func pathContainsTrait(
        _ path: InlinePath,
        trait: InlineTrait,
        in inlines: [Inline]
    ) -> Bool {
        var current: [Inline] = inlines
        for (depth, idx) in path.enumerated() {
            guard idx < current.count else { return false }
            let node = current[idx]
            if depth < path.count - 1 {
                // Interior node — check if it's the trait.
                switch (node, trait) {
                case (.bold, .bold): return true
                case (.italic, .italic): return true
                case (.strikethrough, .strikethrough): return true
                default: break
                }
                // Descend.
                switch node {
                case .bold(let c): current = c
                case .italic(let c): current = c
                case .strikethrough(let c): current = c
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
        case .bold:          wrapped = .bold(middle)
        case .italic:        wrapped = .italic(middle)
        case .strikethrough: wrapped = .strikethrough(middle)
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
                case (.bold(let children), .bold):
                    result.append(contentsOf: children)
                case (.italic(let children), .italic):
                    result.append(contentsOf: children)
                case (.strikethrough(let children), .strikethrough):
                    result.append(contentsOf: children)
                case (.code(let s), .code):
                    result.append(.text(s))
                default:
                    // Different trait or leaf — recurse if container.
                    result.append(unwrapTraitInNode(node, trait: trait, from: from - nodeStart, to: to - nodeStart))
                }
            } else if nodeEnd > from && nodeStart < to {
                // Partially overlaps — recurse into children.
                result.append(unwrapTraitInNode(node, trait: trait, from: from - nodeStart, to: to - nodeStart))
            } else {
                // Outside selection — keep unchanged.
                result.append(node)
            }
            acc = nodeEnd
        }
        return cleanInlines(result)
    }

    private static func unwrapTraitInNode(
        _ node: Inline,
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> Inline {
        switch node {
        case .bold(let children):
            if trait == .bold {
                // Remove this bold wrapper, keep children.
                // But we need to handle partial overlap — for simplicity,
                // unwrap the entire node.
                return .bold(unwrapTrait(children, trait: trait, from: max(from, 0), to: min(to, inlinesLength(children))))
            }
            return .bold(unwrapTrait(children, trait: trait, from: max(from, 0), to: min(to, inlinesLength(children))))
        case .italic(let children):
            if trait == .italic {
                return .italic(unwrapTrait(children, trait: trait, from: max(from, 0), to: min(to, inlinesLength(children))))
            }
            return .italic(unwrapTrait(children, trait: trait, from: max(from, 0), to: min(to, inlinesLength(children))))
        case .strikethrough(let children):
            if trait == .strikethrough {
                return .strikethrough(unwrapTrait(children, trait: trait, from: max(from, 0), to: min(to, inlinesLength(children))))
            }
            return .strikethrough(unwrapTrait(children, trait: trait, from: max(from, 0), to: min(to, inlinesLength(children))))
        case .text, .code:
            return node
        }
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
            case .bold(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.bold(cleaned))
            case .italic(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.italic(cleaned))
            case .strikethrough(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.strikethrough(cleaned))
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


}
