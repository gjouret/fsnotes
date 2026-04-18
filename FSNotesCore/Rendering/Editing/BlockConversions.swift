//
//  BlockConversions.swift
//  FSNotesCore
//
//  Block-level conversion operations.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum BlockConversions {

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
            
            // Check if paragraph contains newlines (soft line breaks)
            let text = inlinesToText(inline)
            let lines = text.components(separatedBy: "\n")
            
            if lines.count > 1 {
                // Multi-line paragraph - split at the cursor's line
                // Find which line the cursor is on by calculating offset within the paragraph
                let blockSpan = projection.blockSpans[blockIndex]
                let offsetInBlock = storageIndex - blockSpan.location
                
                // Find the line containing the cursor
                var currentOffset = 0
                var targetLineIndex = 0
                for (i, line) in lines.enumerated() {
                    let lineLength = line.count + (i < lines.count - 1 ? 1 : 0) // +1 for newline except last line
                    if offsetInBlock < currentOffset + lineLength {
                        targetLineIndex = i
                        break
                    }
                    currentOffset += lineLength
                }
                
                // Build three blocks: para (before), heading (target), para (after)
                var newBlocks: [Block] = []
                
                // Lines before target
                if targetLineIndex > 0 {
                    let beforeText = lines[0..<targetLineIndex].joined(separator: "\n")
                    newBlocks.append(.paragraph(inline: parseInlinesFromText(beforeText)))
                }
                
                // Target line as heading
                let targetLine = lines[targetLineIndex]
                newBlocks.append(.heading(level: newLevel, suffix: " " + targetLine))
                
                // Lines after target
                if targetLineIndex < lines.count - 1 {
                    let afterText = lines[(targetLineIndex + 1)...].joined(separator: "\n")
                    newBlocks.append(.paragraph(inline: parseInlinesFromText(afterText)))
                }
                
                // Replace the single paragraph with these blocks
                var result = try EditingPrimitives.replaceBlockRange(
                    blockIndex...blockIndex,
                    with: newBlocks,
                    in: projection
                )
                
                // Cursor at end of the heading block
                let newHeadingSpan = result.newProjection.blockSpans[
                    targetLineIndex > 0 ? blockIndex + 1 : blockIndex
                ]
                result.newCursorPosition = newHeadingSpan.location + newHeadingSpan.length
                return result
            }
            
            // Single-line paragraph - convert entire paragraph to heading
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

    // MARK: - List helper functions for toggleList

    /// Get all list items before the entry at `path`.
    /// Returns items at the top level only.
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
}

