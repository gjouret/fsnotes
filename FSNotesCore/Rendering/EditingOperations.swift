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
                throw EditingError.unsupported(
                    reason: "multi-line paste in list not supported"
                )
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
                throw EditingError.unsupported(
                    reason: "multi-line paste in blockquote not supported"
                )
            case .htmlBlock:
                // HTML blocks accept any content verbatim, like code blocks.
                break
            case .heading, .horizontalRule, .blankLine, .table:
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
            // Merge blocks when delete crosses one or more block boundaries.
            // For a 2-block span this is the common backspace-at-block-start
            // case. For 3+ blocks (multi-line selection delete), all
            // intermediate blocks are removed and the surviving tails of
            // the first and last blocks are merged into a single block.
            var result = try mergeAdjacentBlocks(
                startBlock: startBlock, startOffset: startOffset,
                endBlock: endBlock, endOffset: endOffset,
                in: projection
            )
            result.newCursorPosition = storageRange.location
            return result
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

        // 2. Render ONLY the changed block.
        let blockRendered = DocumentRenderer.renderBlock(
            newBlock, bodyFont: projection.bodyFont, codeFont: projection.codeFont
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
            codeFont: projection.codeFont
        )

        // 8. Narrow to minimal splice via character diff.
        return narrowSplice(
            oldString: projection.attributed.string,
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
            codeFont: projection.codeFont
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
            oldString: projection.attributed.string,
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
        default:
            return false
        }
    }

    /// Narrow a block-granular splice to character-granular by diffing
    /// the old and new rendered strings. Prevents NSLayoutManager from
    /// scrolling when it sees a large replaced region.
    private static func narrowSplice(
        oldString: String,
        oldRange: NSRange,
        newReplacement: NSAttributedString,
        newProjection: DocumentProjection
    ) -> EditResult {
        let oldStr = (oldString as NSString).substring(with: oldRange)
        let newStr = newReplacement.string
        let oldChars = Array(oldStr.unicodeScalars)
        let newChars = Array(newStr.unicodeScalars)
        let minLen = min(oldChars.count, newChars.count)

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
    /// Supported merge pairs:
    ///   paragraph + paragraph → concatenated paragraph
    ///   paragraph + blankLine → paragraph
    ///   blankLine  + paragraph → paragraph
    ///   blankLine  + blankLine → blankLine
    ///   heading + anything → heading (preserves heading level)
    ///   anything + heading → first block type wins (heading demoted to paragraph)
    ///   paragraph + heading → paragraph (heading text appended)
    ///   blankLine + heading → heading (blank removed, heading preserved)
    ///   codeBlock, list, blockquote merges → paragraph (flattened)
    ///
    /// The first block's type wins when both have inline content.
    /// If the first block is empty (blankLine/HR), the second block's
    /// type wins.
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
            truncatedA = try? deleteInBlock(blockA, from: startOffset, to: blockALength)
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
            truncatedB = try? deleteInBlock(blockB, from: 0, to: endOffset)
        }

        // Determine the merged result. When both boundaries have
        // surviving content, merge their inline trees into a paragraph.
        let replacementBlocks: [Block]
        switch (truncatedA, truncatedB) {
        case (.some(let a), .some(let b)):
            // Both boundary blocks have surviving content. Extract
            // inline trees and concatenate, preserving formatting.
            let inlinesA = extractInlines(from: a)
            let inlinesB = extractInlines(from: b)
            if inlinesA.isEmpty && inlinesB.isEmpty {
                replacementBlocks = [.blankLine]
            } else {
                replacementBlocks = [.paragraph(inline: inlinesA + inlinesB)]
            }
        case (.some(let a), .none):
            // Only block A survives — keep its type.
            replacementBlocks = [a]
        case (.none, .some(let b)):
            // Only block B survives — keep its type.
            replacementBlocks = [b]
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
        // insert replacement(s).
        var newDoc = projection.document
        newDoc.blocks.replaceSubrange(startBlock...endBlock, with: replacementBlocks)

        // Splice range: from start of blockA's span to end of blockB's
        // span, INCLUDING the separator "\n" between them.
        let spliceStart = spanA.location
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
            codeFont: projection.codeFont
        )

        // Extract the replacement content from the new projection.
        let replacement: NSAttributedString
        if replacementBlocks.isEmpty {
            replacement = NSAttributedString(string: "")
        } else {
            let firstSpan = newProjection.blockSpans[startBlock]
            let lastSpan = newProjection.blockSpans[startBlock + replacementBlocks.count - 1]
            let repStart = firstSpan.location
            let repEnd = lastSpan.location + lastSpan.length
            replacement = newProjection.attributed.attributedSubstring(
                from: NSRange(location: repStart, length: repEnd - repStart)
            )
        }

        // Narrow the splice to only the changed characters to avoid
        // NSLayoutManager scroll-on-large-replace.
        return narrowSplice(
            oldString: projection.attributed.string,
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
            // Use the displayed text portion.
            let leading = leadingWhitespaceCount(in: suffix)
            let trailing = trailingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading).dropLast(trailing))
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
            let trailing = trailingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading).dropLast(trailing))
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

    /// Extract the inline tree from a block, preserving formatting.
    /// For structured blocks (lists, blockquotes) the content is
    /// flattened to plain text inlines. For paragraphs, the inline
    /// tree is returned as-is to preserve bold/italic/etc.
    private static func extractInlines(from block: Block) -> [Inline] {
        switch block {
        case .paragraph(let inline): return inline
        case .heading(_, let suffix):
            let l = leadingWhitespaceCount(in: suffix)
            let t = trailingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(l).dropLast(t))
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
            let t = trailingWhitespaceCount(in: suffix)
            return String(suffix.dropFirst(l).dropLast(t))
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
        case .link(let text, _): return inlinesToText(text)
        case .image(let alt, _): return inlinesToText(alt)
        case .autolink(let text, _): return text
        case .escapedChar(let ch): return String(ch)
        case .lineBreak: return "\n"
        case .rawHTML(let html): return html
        case .entity(let raw): return raw
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
        case .link(let text, _): return text.reduce(0) { $0 + inlineLength($1) }
        case .image(let alt, _): return alt.reduce(0) { $0 + inlineLength($1) }
        case .autolink(let text, _): return text.count
        case .escapedChar: return 1
        case .lineBreak: return 1
        case .rawHTML(let html): return html.count
        case .entity(let raw): return raw.count
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
                case .link(let text, let dest):
                    let (b, a) = splitInlines(text, at: localOffset)
                    before.append(.link(text: b, rawDestination: dest))
                    after.append(.link(text: a, rawDestination: dest))
                case .image(let alt, let dest):
                    let (b, a) = splitInlines(alt, at: localOffset)
                    before.append(.image(alt: b, rawDestination: dest))
                    after.append(.image(alt: a, rawDestination: dest))
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
            case .link(let text, _):
                walkFlatten(text, path: &path, into: &runs)
            case .image(let alt, _):
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
            case .autolink: return .text(newText)
            case .escapedChar: return .text(newText)
            case .lineBreak: return .text(newText)
            case .rawHTML: return .rawHTML(newText)
            case .entity: return .entity(newText)
            case .bold, .italic, .strikethrough, .link, .image:
                // Path exhausted on a container: should not happen
                // when paths come from `flatten`. Leave unchanged.
                return inline
            }
        }
        let idx = path.first!
        let rest = Array(path.dropFirst())
        switch inline {
        case .text, .code, .autolink, .escapedChar, .lineBreak, .rawHTML, .entity:
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
        case .link(let text, let dest):
            var c = text
            c[idx] = replaceLeafText(in: text[idx], path: rest, newText: newText)
            return .link(text: c, rawDestination: dest)
        case .image(let alt, let dest):
            var c = alt
            c[idx] = replaceLeafText(in: alt[idx], path: rest, newText: newText)
            return .image(alt: c, rawDestination: dest)
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
            // Place cursor after bullet + space (start of text content).
            result.newCursorPosition = newSpan.location + 1
            return result

        case .list(let items, _):
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
            codeFont: projection.codeFont
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
            let trailing = trailingWhitespaceCount(in: suffix)
            let displayed = String(suffix.dropFirst(leading).dropLast(trailing))
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
                case .bold(let c, _): current = c
                case .italic(let c, _): current = c
                case .strikethrough(let c): current = c
                case .link(let text, _): current = text
                case .image(let alt, _): current = alt
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
        case .link(let text, let dest):
            let len = inlinesLength(text)
            let clampedTo = min(to, len)
            return [.link(text: unwrapTrait(text, trait: trait, from: clampedFrom, to: clampedTo), rawDestination: dest)]
        case .image(let alt, let dest):
            let len = inlinesLength(alt)
            let clampedTo = min(to, len)
            return [.image(alt: unwrapTrait(alt, trait: trait, from: clampedFrom, to: clampedTo), rawDestination: dest)]
        case .text, .code, .autolink, .escapedChar, .lineBreak, .rawHTML, .entity:
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
            case .link(let text, let dest):
                let cleaned = cleanInlines(text)
                if cleaned.isEmpty { continue }
                result.append(.link(text: cleaned, rawDestination: dest))
            case .image(let alt, let dest):
                let cleaned = cleanInlines(alt)
                if cleaned.isEmpty { continue }
                result.append(.image(alt: cleaned, rawDestination: dest))
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
