//
//  MiscEditing.swift
//  FSNotesCore
//
//  Miscellaneous editing operations.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Todo operations

public enum TodoEditing {

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


// MARK: - Block swap (move up/down)

public enum BlockSwap {
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


// MARK: - Image operations

public enum ImageEditing {
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


// MARK: - Inline re-parsing (RC4)

public enum InlineReparsing {
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
}
