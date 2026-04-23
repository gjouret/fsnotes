//
//  EditingPrimitives.swift
//  FSNotesCore
//
//  Core block-level editing primitives: splicing, merging, block replacement.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum EditingPrimitives {

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
        case (.table(let ha, _, let ra, _, _), .table(let hb, _, let rb, _, _)):
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
        
        // DEBUG
        print("DEBUG narrowSplice: oldStr length=\(oldStr.count), newStr length=\(newStr.count)")
        print("DEBUG narrowSplice: hasAttachmentInOld=\(hasAttachmentInOld), hasAttachmentInNew=\(hasAttachmentInNew)")
        
        // If there are attachments, we need to be more careful about narrowing.
        // When both old and new have attachments at the same positions, we should
        // still narrow. But when new attachments are being added or removed,
        // we need to ensure the splice covers them.
        if hasAttachmentInOld || hasAttachmentInNew {
            // Count attachments in both
            let oldAttachmentCount = oldStr.filter { $0 == attachmentChar }.count
            let newAttachmentCount = newStr.filter { $0 == attachmentChar }.count
            
            // DEBUG
            print("DEBUG narrowSplice: oldAttachmentCount=\(oldAttachmentCount), newAttachmentCount=\(newAttachmentCount)")
            
            // If attachment counts differ, we have structural changes (new item inserted, etc.)
            // Don't narrow - use the full range to ensure proper attachment handling.
            if oldAttachmentCount != newAttachmentCount {
                print("DEBUG narrowSplice: Attachment counts differ, NOT narrowing")
                return EditResult(
                    newProjection: newProjection,
                    spliceRange: oldRange,
                    spliceReplacement: newReplacement
                )
            }
            
            // Same attachment count - attachments may have changed state (checked vs unchecked)
            // Compare the actual attachment objects at each position to determine if narrowing is safe.
            let oldAttachments = extractAttachments(from: oldAttributedString, range: oldRange)
            let newAttachments = extractAttachments(from: newReplacement, range: NSRange(location: 0, length: newReplacement.length))
            
            // If attachments exist and differ, don't narrow - we need full replacement to update attachment state
            if !attachmentsEqual(oldAttachments, newAttachments) {
                return EditResult(
                    newProjection: newProjection,
                    spliceRange: oldRange,
                    spliceReplacement: newReplacement
                )
            }
            // Attachments are equal - safe to proceed with narrowing
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
                if substring.attribute(.attachment, at: index, effectiveRange: nil) != nil {
                    positions.insert(index)
                }
            }
        }
        return positions
    }
    
    /// Extract attachments and their positions from an attributed string.
    /// Returns an array of (position, attachment) tuples for attachment characters.
    private static func extractAttachments(from attrString: NSAttributedString, range: NSRange) -> [(position: Int, attachment: NSTextAttachment)] {
        var result: [(Int, NSTextAttachment)] = []
        let attachmentChar = Character("\u{FFFC}")
        let substring = attrString.attributedSubstring(from: range)
        let str = substring.string
        
        for (index, char) in str.enumerated() {
            if char == attachmentChar {
                if let attachment = substring.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment {
                    result.append((index, attachment))
                }
            }
        }
        return result
    }
    
    /// Compare two arrays of attachments for equality.
    /// Returns true if both arrays have the same count and attachments at matching positions are equal.
    private static func attachmentsEqual(_ a: [(position: Int, attachment: NSTextAttachment)], _ b: [(position: Int, attachment: NSTextAttachment)]) -> Bool {
        guard a.count == b.count else { return false }
        
        for i in 0..<a.count {
            // Positions must match
            guard a[i].position == b[i].position else { return false }
            
            // Attachments must be equal
            let attA = a[i].attachment
            let attB = b[i].attachment
            
            // Compare by content type and identifier if available
            // For checkbox attachments, compare their checked state via associated fileType
            if let fileTypeA = attA.fileType, let fileTypeB = attB.fileType {
                if fileTypeA != fileTypeB {
                    return false
                }
            }
            
            // Compare image data or contents
            if let dataA = attA.fileWrapper?.regularFileContents,
               let dataB = attB.fileWrapper?.regularFileContents {
                if dataA != dataB {
                    return false
                }
            }
        }
        
        return true
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
        case .table(let header, let alignments, let rows, _):
            return EditingOps.rebuildTableRaw(
                header: header, alignments: alignments, rows: rows
            )
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
}

