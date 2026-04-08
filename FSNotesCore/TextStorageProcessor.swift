//
//  TextStorageProcessor.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 26.06.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

#if os(OSX)
import Cocoa
import AVKit
#else
import UIKit
import AVKit
#endif

#if os(OSX)
/// Attachment cell that centers an image within the full container width.
/// The cell spans the container width so paragraph alignment doesn't matter —
/// centering is handled in the draw method, immune to addTabStops resets.
class CenteredImageCell: NSTextAttachmentCell {
    private let imageSize: NSSize
    private let containerWidth: CGFloat

    init(image: NSImage, imageSize: NSSize, containerWidth: CGFloat) {
        self.imageSize = imageSize
        self.containerWidth = containerWidth
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        self.imageSize = .zero
        self.containerWidth = 400
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize {
        return NSSize(width: containerWidth, height: imageSize.height)
    }

    /// Called by the layout manager with the CURRENT line fragment rect.
    /// This lets us shrink the attachment dynamically when the editor is
    /// resized narrower than the image's intrinsic width.
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = lineFrag.width
        guard imageSize.width > 0, available > 0 else {
            return NSRect(x: 0, y: -2, width: containerWidth, height: imageSize.height)
        }
        // If image is wider than available line-fragment width, scale down proportionally.
        if imageSize.width > available {
            let scale = available / imageSize.width
            return NSRect(x: 0, y: -2, width: available, height: imageSize.height * scale)
        }
        // Image fits; cell spans the available width so it can center horizontally.
        return NSRect(x: 0, y: -2, width: available, height: imageSize.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image = self.image else { return }
        // Scale the image to fit the current cellFrame, preserving aspect ratio.
        // cellFrame.height is already the scaled height (from cellFrame(for:...)),
        // so the image's drawn height should match cellFrame.height.
        var drawSize = imageSize
        if drawSize.width > cellFrame.width && drawSize.width > 0 {
            let fitScale = cellFrame.width / drawSize.width
            drawSize = NSSize(width: drawSize.width * fitScale, height: drawSize.height * fitScale)
        }
        let x = cellFrame.origin.x + (cellFrame.width - drawSize.width) / 2
        let drawRect = NSRect(origin: NSPoint(x: x, y: cellFrame.origin.y),
                              size: drawSize)
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                   respectFlipped: true, hints: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        // Don't draw if this attachment is inside a folded region
        if let ts = layoutManager.textStorage,
           charIndex < ts.length,
           ts.attribute(.foldedContent, at: charIndex, effectiveRange: nil) != nil {
            return
        }
        draw(withFrame: cellFrame, in: controlView)
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }
}
#endif

class TextStorageProcessor: NSObject, NSTextStorageDelegate, RenderingFlagProvider {
    /// Protocol-based reference — breaks concrete dependency on EditTextView.
    public weak var editorDelegate: EditorDelegate?

    /// Legacy accessor — callers that need the concrete type use this.
    /// Each caller should migrate to editorDelegate over time.
    public var editor: EditTextView? {
        get { return editorDelegate as? EditTextView }
        set { editorDelegate = newValue }
    }

    public var isRendering = false
    /// When true, the block-model pipeline owns rendering. The old
    /// process() pipeline must not run — it would apply syntax colors,
    /// kern, and clear-foreground to storage that has no markdown markers.
    public var blockModelActive = false

    // MARK: - Source-Mode Block Array

    /// Source-mode block array used by fold/unfold and the source-mode
    /// rendering pipeline. When blockModelActive==true, populated
    /// via syncBlocksFromProjection() instead of updateBlockModel().
    public var blocks: [MarkdownBlock] = []
    private var pendingRenderedBlockIDs = Set<UUID>()

    /// Code block ranges in source mode (excludes rendered mermaid/math images).
    /// Used by LayoutManager for gray background and by triggerCodeBlockRenderingIfNeeded.
    public var codeBlockRanges: [NSRange] {
        return blocks.compactMap { block in
            if case .codeBlock = block.type, block.renderMode == .source { return block.range }
            return nil
        }
    }

    /// Find the block at a given character index. O(log n).
    public func block(at characterIndex: Int) -> MarkdownBlock? {
        guard let idx = MarkdownBlockParser.blockIndex(in: blocks, containing: characterIndex) else { return nil }
        return blocks[idx]
    }

    /// Count leading tabs and 4-space groups as nesting levels.
    public static func leadingListDepth(_ str: String) -> Int {
        var depth = 0
        var spaces = 0
        for ch in str {
            if ch == "\t" { depth += 1; spaces = 0 }
            else if ch == " " { spaces += 1; if spaces == 4 { depth += 1; spaces = 0 } }
            else { break }
        }
        return depth
    }

    // MARK: - Block Model Sync for Fold/Unfold

    /// Populate the source-mode `blocks` array from a DocumentProjection so
    /// that fold/unfold (which reads `blocks`) works when
    /// `blockModelActive == true`.
    ///
    /// The block-model pipeline bypasses `process()` (which normally
    /// populates `blocks`), so fold operations would silently no-op.
    /// This method bridges the gap by creating MarkdownBlock entries
    /// from the Document model's block types + the rendered blockSpans.
    ///
    /// IMPORTANT: preserves the `collapsed` flag from any existing blocks
    /// that match by type + position, so fold state survives re-renders.
    public func syncBlocksFromProjection(_ projection: DocumentProjection) {
        let doc = projection.document
        let spans = projection.blockSpans
        guard doc.blocks.count == spans.count else {
            blocks = []
            return
        }

        // Snapshot previous collapsed states keyed by block index
        let previousCollapsed = Dictionary(
            uniqueKeysWithValues: blocks.enumerated()
                .filter { $0.element.collapsed }
                .map { ($0.offset, true) }
        )

        var newBlocks: [MarkdownBlock] = []
        for (i, block) in doc.blocks.enumerated() {
            let span = spans[i]
            let blockType: MarkdownBlockType
            switch block {
            case .heading(let level, _):
                blockType = .heading(level: level)
            case .paragraph:
                // Check if this paragraph's rendered content looks like a
                // markdown table (lines starting/ending with `|` and a
                // separator row). If so, tag it as .table so renderTables()
                // can pick it up and overlay the table widget.
                let content = projection.attributed.attributedSubstring(from: span).string
                if Self.looksLikeTable(content) {
                    blockType = .table
                } else {
                    blockType = .paragraph
                }
            case .codeBlock(let lang, _, _):
                blockType = .codeBlock(language: lang)
            case .list(let items, _):
                // Determine list type from first item
                if items.first?.checkbox != nil {
                    blockType = .todoItem(checked: items.first?.isChecked ?? false)
                } else if let marker = items.first?.marker,
                          marker == "-" || marker == "*" || marker == "+" {
                    blockType = .unorderedList
                } else {
                    blockType = .orderedList
                }
            case .blockquote:
                blockType = .blockquote
            case .horizontalRule:
                blockType = .horizontalRule
            case .htmlBlock:
                blockType = .paragraph  // HTML blocks render as plain text blocks
            case .blankLine:
                blockType = .empty
            case .table:
                blockType = .table
            }

            var mb = MarkdownBlock(
                type: blockType,
                range: span,
                contentRange: span
            )
            // Preserve collapsed state from previous blocks at the same index
            if previousCollapsed[i] == true {
                mb.collapsed = true
            }
            newBlocks.append(mb)
        }
        blocks = newBlocks
    }

    /// Heuristic: does the text content look like a markdown table?
    /// Requires at least 2 lines starting with `|`, and a separator line
    /// containing `|--` or `|:--` patterns.
    private static func looksLikeTable(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return false }
        // First line must start with |
        guard lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return false }
        // Must have a separator row (|--|, |:--|, etc.)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.contains("--") {
                return true
            }
        }
        return false
    }

    // MARK: - Header Fold/Unfold

    /// Toggle fold state for the header block at the given index in `blocks`.
    public func toggleFold(headerBlockIndex idx: Int, textStorage: NSTextStorage) {
        guard idx < blocks.count else { return }
        let header = blocks[idx]

        let headerLevel: Int
        switch header.type {
        case .heading(let l): headerLevel = l
        case .headingSetext(let l): headerLevel = l
        default: return
        }

        let foldRange = foldRangeForHeader(at: idx, level: headerLevel, in: textStorage)
        guard foldRange.length > 0 else { return }

        isRendering = true
        textStorage.beginEditing()

        if header.collapsed {
            // Unfold: remove fold marker. Rendering gate in LayoutManager handles the rest.
            textStorage.removeAttribute(.foldedContent, range: foldRange)
            textStorage.removeAttribute(.foregroundColor, range: foldRange)
            blocks[idx].collapsed = false
            textStorage.endEditing()
            isRendering = false

            if blockModelActive {
                // Block-model path: the rendered text already has correct
                // attributes from DocumentRenderer. We just need to restore
                // them after removing the fold's clear-foreground override.
                // Trigger a re-render of the affected range by re-splicing
                // the projection's attributed string for the fold range.
                if let editTextView = editor as? EditTextView,
                   let projection = editTextView.documentProjection {
                    let attrSource = projection.attributed
                    let safeEnd = min(NSMaxRange(foldRange), attrSource.length)
                    let safeStart = min(foldRange.location, safeEnd)
                    let safeRange = NSRange(location: safeStart, length: safeEnd - safeStart)
                    if safeRange.length > 0 {
                        let originalAttrs = attrSource.attributedSubstring(from: safeRange)
                        isRendering = true
                        textStorage.beginEditing()
                        textStorage.replaceCharacters(in: safeRange, with: originalAttrs)
                        textStorage.endEditing()
                        isRendering = false
                    }
                }
            } else {
                // Legacy path: re-highlight the unfolded range to restore colors
                let paragraphRange = (textStorage.string as NSString).paragraphRange(for: foldRange)
                NotesTextProcessor.highlightMarkdown(
                    attributedString: textStorage,
                    paragraphRange: paragraphRange,
                    codeBlockRanges: codeBlockRanges)
            }
            editor?.needsDisplay = true
        } else {
            blocks[idx].collapsed = true
            textStorage.endEditing()
            // Set fold attributes AFTER endEditing so process()/highlightMarkdown
            // doesn't strip them during the editing session's processEditing callback.
            isRendering = true
            textStorage.addAttribute(.foldedContent, value: true, range: foldRange)
            textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: foldRange)
            isRendering = false
            // Hide live subviews (InlineTableView) — they draw independently of LayoutManager
            if let textView = editor {
                for subview in textView.subviews {
                    guard let tv = subview as? InlineTableView, !tv.isHidden else { continue }
                    tv.isHidden = true
                }
            }
        }

        // Invalidate layout for the fold range so the rendering gate takes effect
        textStorage.layoutManagers.first?.invalidateLayout(
            forCharacterRange: foldRange, actualCharacterRange: nil)
        editor?.needsDisplay = true

        // Invalidate layout so zero-height lines take effect
        textStorage.layoutManagers.first?.invalidateLayout(
            forCharacterRange: foldRange, actualCharacterRange: nil)
    }

    /// Find the range to fold: from end of the header line to the next header
    /// with the same level, matching the folding spec literally.
    private func foldRangeForHeader(at idx: Int, level: Int, in textStorage: NSTextStorage) -> NSRange {
        let header = blocks[idx]
        let string = textStorage.string as NSString

        // Fold starts after the header's line (including newline)
        let headerLineRange = string.paragraphRange(for: NSRange(location: header.range.location, length: 0))
        let foldStart = NSMaxRange(headerLineRange)
        guard foldStart < string.length else { return NSRange(location: foldStart, length: 0) }

        // Follow the folding spec literally:
        // stop only at the next header with the same level, regardless of
        // whether that header is ATX or Setext. Horizontal rules must not
        // affect folding.
        var foldEnd = string.length
        findEnd: for i in (idx + 1)..<blocks.count {
            switch blocks[i].type {
            case .heading(let l) where l == level:
                foldEnd = blocks[i].range.location
                break findEnd
            case .headingSetext(let l) where l == level:
                foldEnd = blocks[i].range.location
                break findEnd
            default:
                continue
            }
        }

        return NSRange(location: foldStart, length: foldEnd - foldStart)
    }

    /// Fold the header block at `idx` if it is currently expanded. No-op if
    /// already collapsed.
    public func foldHeader(headerBlockIndex idx: Int, textStorage: NSTextStorage) {
        guard idx < blocks.count, !blocks[idx].collapsed else { return }
        toggleFold(headerBlockIndex: idx, textStorage: textStorage)
    }

    /// Unfold the header block at `idx` if it is currently collapsed. No-op if
    /// already expanded.
    public func unfoldHeader(headerBlockIndex idx: Int, textStorage: NSTextStorage) {
        guard idx < blocks.count, blocks[idx].collapsed else { return }
        toggleFold(headerBlockIndex: idx, textStorage: textStorage)
    }

    /// Fold all headers in the note.
    /// Process deepest headers first (highest level number) so nested fold ranges
    /// are calculated before their parent headers fold over them.
    public func foldAll(textStorage: NSTextStorage) {
        // Collect header indices with their levels
        var headers: [(index: Int, level: Int)] = []
        for i in 0..<blocks.count {
            switch blocks[i].type {
            case .heading(let l): headers.append((i, l))
            case .headingSetext(let l): headers.append((i, l))
            default: break
            }
        }
        // Sort by level descending (deepest first), then by position descending
        headers.sort { ($0.level, -$0.index) > ($1.level, -$1.index) }
        for h in headers {
            if !blocks[h.index].collapsed {
                toggleFold(headerBlockIndex: h.index, textStorage: textStorage)
            }
        }
    }

    /// Unfold all headers in the note.
    public func unfoldAll(textStorage: NSTextStorage) {
        for i in 0..<blocks.count {
            switch blocks[i].type {
            case .heading, .headingSetext:
                if blocks[i].collapsed {
                    toggleFold(headerBlockIndex: i, textStorage: textStorage)
                }
            default: break
            }
        }
    }

    /// Find the header block index for a character position.
    public func headerBlockIndex(at charIndex: Int) -> Int? {
        for (i, block) in blocks.enumerated() {
            switch block.type {
            case .heading, .headingSetext:
                if block.range.contains(charIndex) || block.range.location == charIndex {
                    return i
                }
            default: break
            }
        }
        return nil
    }

#if os(iOS)
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorage.EditActions,
        range editedRange: NSRange,
        changeInLength delta: Int) {

        guard editedMask != .editedAttributes else { return }
        process(textStorage: textStorage, range: editedRange, changeInLength: delta)
    }
#else
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int) {

        guard editedMask != .editedAttributes else { return }
        process(textStorage: textStorage, range: editedRange, changeInLength: delta)

        // Force redraw after any character edit so gutter icons update
        // (previously only triggered on deletions, missing new headers)
        if editedMask.contains(.editedCharacters) {
            if let layoutManager = textStorage.layoutManagers.first,
               let textContainer = layoutManager.textContainers.first,
               let textView = textContainer.textView {
                textView.needsDisplay = true
            }
        }
    }
#endif

    /// Legacy rendering pipeline. Runs ONLY when blockModelActive==false
    /// (source mode, non-markdown notes). When blockModelActive==true,
    /// all rendering is handled by DocumentRenderer + EditingOps.
    private func process(textStorage: NSTextStorage, range editedRange: NSRange, changeInLength delta: Int) {
        guard let note = editor?.note, textStorage.length > 0 else { return }
        guard !isRendering else { return }

        // Block-model pipeline owns rendering — bail out entirely.
        if blockModelActive {
            return
        }

        defer {
            loadImages(textStorage: textStorage, checkRange: editedRange)

            // Block-aware paragraph styles (spacing, indentation).
            if !blocks.isEmpty {
                let nsString = textStorage.string as NSString
                let paragraphRange = expandedParagraphRange(for: editedRange, in: nsString)
                phase5_paragraphStyles(textStorage: textStorage, range: paragraphRange)
            } else {
                textStorage.updateParagraphStyle(range: editedRange)
            }
        }

        if note.content.length == textStorage.length && (
            note.content.string.fnv1a == note.cacheHash
        ) { return }

        let previousBlocks = blocks
        updateBlockModel(textStorage: textStorage, editedRange: editedRange, delta: delta)

        let renderRanges = processingRanges(
            textStorage: textStorage,
            editedRange: editedRange,
            previousBlocks: previousBlocks
        )
        let currentCodeRanges = codeBlockRanges

        for range in renderRanges.markdownRanges {
            let safe = safeRange(range, in: textStorage)
            NotesTextProcessor.resetFont(attributedString: textStorage, paragraphRange: safe)
            NotesTextProcessor.highlightMarkdown(
                attributedString: textStorage,
                paragraphRange: safe,
                codeBlockRanges: currentCodeRanges
            )
        }

        for range in renderRanges.codeRanges {
            // Look up the block's contentRange — the authoritative content
            // bounds from MarkdownBlockParser. Passing it ensures the highlighter
            // touches ONLY code content, never fence characters.
            let contentRange = blocks.first(where: {
                if case .codeBlock = $0.type, $0.range == range { return true }
                return false
            })?.contentRange
            NotesTextProcessor
                .getHighlighter()
                .highlight(in: textStorage, fullRange: range, contentRange: contentRange)
        }
    }

    /// Populate the block model from the current text storage.
    /// In shadow mode, this is informational only — no rendering depends on it yet.
    private func updateBlockModel(textStorage: NSTextStorage, editedRange: NSRange, delta: Int) {
        let string = textStorage.string as NSString
        guard string.length > 0 else {
            blocks = []
            return
        }

        if editedRange.length == textStorage.length || blocks.isEmpty {
            // Full parse (initial load or first time).
            MarkdownBlockParser.parsePreservingRendered(&blocks, string: string)
        } else {
            // Incremental: adjust existing blocks, re-parse dirty ones
            var dirtyIndices = MarkdownBlockParser.adjustBlocks(&blocks, forEditAt: editedRange.location, delta: delta)

            // Also mark the block at the edit location as dirty
            if let editIdx = MarkdownBlockParser.blockIndex(in: blocks, containing: min(editedRange.location, string.length - 1)) {
                dirtyIndices.insert(editIdx)
            }

            if !dirtyIndices.isEmpty {
                MarkdownBlockParser.reparseBlocks(&blocks, dirtyIndices: dirtyIndices, string: string)
            }
        }
    }

    private func processingRanges(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        previousBlocks: [MarkdownBlock]
    ) -> (markdownRanges: [NSRange], codeRanges: [NSRange]) {
        if editedRange.length == textStorage.length {
            return (
                markdownRanges: [NSRange(location: 0, length: textStorage.length)],
                codeRanges: codeBlockRanges
            )
        }

        let string = textStorage.string as NSString
        let paragraphRange = expandedParagraphRange(for: editedRange, in: string)
        let previousCodeRanges = codeRanges(in: previousBlocks)
        let currentCodeRanges = codeBlockRanges

        var markdownRanges = [paragraphRange]
        let contextualCodeRanges = (previousCodeRanges + currentCodeRanges).filter { codeRange in
            NSIntersectionRange(codeRange, paragraphRange).length > 0 ||
            NSLocationInRange(editedRange.location, codeRange) ||
            (editedRange.location > 0 && NSLocationInRange(editedRange.location - 1, codeRange))
        }
        markdownRanges.append(contentsOf: contextualCodeRanges)

        let mergedMarkdownRanges = mergeRanges(markdownRanges)
        let codeToHighlight = currentCodeRanges.filter { codeRange in
            mergedMarkdownRanges.contains { NSIntersectionRange($0, codeRange).length > 0 }
        }

        return (markdownRanges: mergedMarkdownRanges, codeRanges: codeToHighlight)
    }

    private func expandedParagraphRange(for editedRange: NSRange, in string: NSString) -> NSRange {
        var paragraphRange = string.paragraphRange(for: editedRange)

        if paragraphRange.location > 0 {
            let prevParaRange = string.paragraphRange(for: NSRange(location: paragraphRange.location - 1, length: 0))
            paragraphRange = NSUnionRange(paragraphRange, prevParaRange)
        }

        let afterEdit = NSMaxRange(paragraphRange)
        if afterEdit < string.length {
            let nextParaRange = string.paragraphRange(for: NSRange(location: afterEdit, length: 0))
            paragraphRange = NSUnionRange(paragraphRange, nextParaRange)
        }

        return paragraphRange
    }

    private func codeRanges(in blocks: [MarkdownBlock]) -> [NSRange] {
        return blocks.compactMap { block in
            if case .codeBlock = block.type, block.renderMode == .source {
                return block.range
            }
            return nil
        }
    }

    private func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.length > 0 }
            .sorted { lhs, rhs in lhs.location < rhs.location }

        guard var current = sorted.first else { return [] }
        var merged: [NSRange] = []

        for range in sorted.dropFirst() {
            if range.location <= NSMaxRange(current) {
                current = NSUnionRange(current, range)
            } else {
                merged.append(current)
                current = range
            }
        }

        merged.append(current)
        return merged
    }

    // MARK: - Phase 5: Block-Aware Paragraph Styles

    /// Apply paragraph styles based on the block model.
    /// Reads block types to determine spacing, indentation, alignment.
    /// ONLY sets .paragraphStyle — does not touch .foregroundColor, .kern, or .font.
    func phase5_paragraphStyles(textStorage: NSTextStorage, range: NSRange) {
        let font = UserDefaultsManagement.noteFont
        let baseSize = CGFloat(font.pointSize)
        let lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        let tabs = textStorage.getTabStops()
        let string = textStorage.string as NSString

        // Get blocks that intersect the range
        let affectedBlocks = MarkdownBlockParser.blocks(in: blocks, intersecting: range)

        for block in affectedBlocks {
            guard block.range.location < string.length,
                  NSMaxRange(block.range) <= string.length else { continue }

            // Find this block's global index for neighbor lookups
            let globalIdx = MarkdownBlockParser.blockIndex(in: blocks, containing: block.range.location)
            let prevBlock = globalIdx.flatMap { $0 > 0 ? blocks[$0 - 1] : nil }
            let nextBlock = globalIdx.flatMap { $0 < blocks.count - 1 ? blocks[$0 + 1] : nil }
            let isFirst = (globalIdx == 0)

            // Process each paragraph within the block
            // CRITICAL: use enclosingRange (3rd param) not substringRange (2nd param)
            // because paragraphSpacing must be set on the \n separator character
            string.enumerateSubstrings(in: block.range, options: .byParagraphs) { [self] value, _, parRange, _ in
                guard let value = value else { return }

                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = lineSpacing
                paragraph.tabStops = tabs
                paragraph.alignment = .left

                // Block-type-specific spacing values for the editor renderer.
                switch block.type {
                case .heading(let level), .headingSetext(let level):
                    switch level {
                    case 1:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.67 }
                        paragraph.paragraphSpacing = baseSize * 0.67
                    case 2:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize }
                        paragraph.paragraphSpacing = 16
                    case 3:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.8 }
                        paragraph.paragraphSpacing = 12
                    case 4:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.6 }
                        paragraph.paragraphSpacing = 10
                    case 5:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.5 }
                        paragraph.paragraphSpacing = 8
                    default:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.4 }
                        paragraph.paragraphSpacing = 6
                    }

                case .unorderedList, .orderedList, .todoItem:
                    // Legacy source-mode list indentation:
                    //  - firstLineHeadIndent = slotWidth (constant).
                    //  - headIndent = slotWidth + depth*listStep for wrap alignment.
                    //  - Tab stops placed at depth-based intervals.
                    let depth = Self.leadingListDepth(value)
                    let listStep = baseSize * 4
                    let slotWidth = baseSize * 2
                    let depthIndent = slotWidth + CGFloat(depth) * listStep
                    paragraph.firstLineHeadIndent = slotWidth
                    paragraph.headIndent = depthIndent
                    var listTabStops: [NSTextTab] = []
                    for i in 1...12 {
                        listTabStops.append(NSTextTab(textAlignment: .left,
                                                      location: slotWidth + CGFloat(i) * listStep,
                                                      options: [:]))
                    }
                    paragraph.tabStops = listTabStops
                    paragraph.lineSpacing = 7

                    let isFirstLine = (parRange.location == block.range.location)
                    let isLastLine = (NSMaxRange(parRange) >= NSMaxRange(block.range))
                    if case .todoItem = block.type {
                        let prevIsList = prevBlock.map { self.isListBlock($0.type) } ?? false
                        let nextIsList = nextBlock.map { self.isListBlock($0.type) } ?? false
                        paragraph.paragraphSpacingBefore = prevIsList ? 2 : 0
                        paragraph.paragraphSpacing = nextIsList ? 0 : 16
                    } else {
                        paragraph.paragraphSpacingBefore = isFirstLine ? 0 : 2
                        paragraph.paragraphSpacing = isLastLine ? 16 : 0
                    }

                case .blockquote:
                    // blockquote: vertical bars at depth-1 positions; text must
                    // indent past the last bar per line. baseX=lineFragmentPadding+2,
                    // each bar 4pt wide at 10pt spacing — so text must start past
                    // 2 + depth*10 + 5pt gap + a bit of padding. Use depth*10 + 20.
                    var depth = 0
                    for ch in value { if ch == ">" { depth += 1 } else if ch == " " { continue } else { break } }
                    // Bar extends to baseX + (depth-1)*10 + 4 from container leading edge.
                    // Add ~6pt gap after the last bar for readability.
                    let qIndent = CGFloat(max(depth, 1)) * 10 + 2
                    paragraph.firstLineHeadIndent = qIndent
                    paragraph.headIndent = qIndent
                    paragraph.lineSpacing = 0
                    let isLastLine = (NSMaxRange(parRange) >= NSMaxRange(block.range))
                    paragraph.paragraphSpacing = isLastLine ? 16 : 0
                    paragraph.paragraphSpacingBefore = 0

                case .horizontalRule:
                    // hr: margin 16px 0, height 4px, background #e7e7e7
                    paragraph.paragraphSpacingBefore = 16
                    paragraph.paragraphSpacing = 16

                case .codeBlock:
                    // pre: margin-bottom 16px — only on the LAST line (closing fence).
                    // Internal lines should have tight spacing (code style).
                    paragraph.lineSpacing = 0
                    let isLastLine = (NSMaxRange(parRange) >= NSMaxRange(block.range))
                    paragraph.paragraphSpacing = isLastLine ? 16 : 0
                    paragraph.paragraphSpacingBefore = 0

                case .paragraph:
                    // p: margin-bottom 16px
                    // CSS collapses margins, NSTextView adds them. Use half to compensate.
                    paragraph.paragraphSpacing = 12

                case .empty:
                    // Explicitly set body paragraph style — otherwise empty lines
                    // inherit heading/list paragraph style from the previous character,
                    // causing wrong line height and cursor size.
                    paragraph.paragraphSpacing = 0
                    paragraph.paragraphSpacingBefore = 0

                case .table, .yamlFrontmatter:
                    break
                }

                textStorage.addAttribute(.paragraphStyle, value: paragraph, range: parRange)
            }
        }
    }

    private func isListBlock(_ type: MarkdownBlockType) -> Bool {
        switch type {
        case .unorderedList, .orderedList, .todoItem: return true
        default: return false
        }
    }

    // MARK: - Phase 4: Unified Syntax Hiding

    private func loadImages(textStorage: NSTextStorage, checkRange: NSRange) {
        guard let note = editor?.note else { return }

        var start = checkRange.lowerBound
        var finish = checkRange.upperBound

        if checkRange.upperBound < textStorage.length {
            finish = checkRange.upperBound + 1
        }

        if checkRange.lowerBound > 1 {
            start = checkRange.lowerBound - 1
        }

        let affectedRange = NSRange(start..<finish)
        textStorage.enumerateAttribute(.attachment, in: affectedRange) { (value, range, _) in
            guard let attachment = value as? NSTextAttachment,
                  let meta = textStorage.getMeta(at: range.location) else { return }

            var url = meta.url

            // 1. check data to save (copy/paste, drag/drop)
            if let data = textStorage.getData(at: range.location),
               let result = note.save(data: data, preferredName: meta.url.lastPathComponent) {

                textStorage.addAttributes([
                    .attachmentUrl: result.1,
                    .attachmentPath: result.0
                ], range: range)

                url = result.1
            }

            // 2. load
            let maxWidth = getImageMaxWidth()
            loadImage(attachment: attachment, url: url, range: range, textStorage: textStorage, maxWidth: maxWidth)
        }
    }

    public func loadImage(attachment: NSTextAttachment, url: URL, range: NSRange, textStorage: NSTextStorage, maxWidth: CGFloat) {
        editor?.imagesLoaderQueue.addOperation {
            var image: PlatformImage?
            var size: CGSize?

            if url.isMedia {
                let imageSize = url.getBorderSize(maxWidth: maxWidth)

                size = imageSize
                image = NoteAttachment.getImage(url: url, size: imageSize)
            } else {
                let attachment = NoteAttachment(url: url)
                if let attachmentImage = attachment.getAttachmentImage() {
                    size = attachmentImage.size
                    image = attachmentImage
                }
            }

            DispatchQueue.main.async {
                guard let manager = self.editor?.layoutManager as? NSLayoutManager else { return }

            #if os(iOS)
                attachment.image = image
                if let size = size {
                    attachment.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                }

                // iOS only unknown behaviour
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = url.isMedia ? .center : .left
                textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            #elseif os(OSX)
                guard let container = self.editor?.textContainer,
                      let attachmentImage = image,
                      let size = size else { return }

                let cell = FSNTextAttachmentCell(textContainer: container, image: attachmentImage)
                cell.image?.size = size
                attachment.image = nil
                attachment.attachmentCell = cell
                attachment.bounds = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            #endif

                let safe = self.safeRange(range, in: textStorage)

                textStorage.edited(.editedAttributes, range: safe, changeInLength: 0)
                manager.invalidateLayout(forCharacterRange: safe, actualCharacterRange: nil)
            }
        }
    }

    #if os(OSX)
    /// Render mermaid/math code blocks as inline images in WYSIWYG mode
    public func renderSpecialCodeBlocks(textStorage: NSTextStorage, codeBlockRanges: [NSRange]) {
        guard NotesTextProcessor.hideSyntax else { return }
        let string = textStorage.string as NSString

        for codeRange in codeBlockRanges {
            guard codeRange.location < string.length, NSMaxRange(codeRange) <= string.length else { continue }

            let firstLineRange = string.lineRange(for: NSRange(location: codeRange.location, length: 0))
            let firstLine = string.substring(with: firstLineRange).trimmingCharacters(in: .whitespacesAndNewlines)

            var blockType: BlockRenderer.BlockType?
            if firstLine.hasPrefix("```mermaid") {
                blockType = .mermaid
            } else if firstLine.hasPrefix("```math") || firstLine.hasPrefix("```latex") {
                blockType = .math
            }
            guard let type = blockType else { continue }

            // Extract the source content (between fences)
            let afterFirstLine = NSMaxRange(firstLineRange)
            let lastCharLoc = max(codeRange.location, NSMaxRange(codeRange) - 1)
            let lastLineRange = string.lineRange(for: NSRange(location: lastCharLoc, length: 0))
            let contentEnd = lastLineRange.location

            guard afterFirstLine < contentEnd else { continue }
            let contentRange = NSRange(location: afterFirstLine, length: contentEnd - afterFirstLine)
            let source = string.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !source.isEmpty else { continue }

            guard let blockIdx = blocks.firstIndex(where: {
                if case .codeBlock = $0.type { return $0.range == codeRange }
                return false
            }) else {
                continue
            }
            let blockID = blocks[blockIdx].id

            // Skip blocks that are already rendered or already scheduled.
            if blocks[blockIdx].renderMode == .rendered || pendingRenderedBlockIDs.contains(blockID) {
                continue
            }
            pendingRenderedBlockIDs.insert(blockID)

            let maxWidth = getImageMaxWidth()

            // Capture the full original markdown (fences + content) for restoration on click
            let originalMarkdown = string.substring(with: codeRange)

            BlockRenderer.render(source: source, type: type, maxWidth: maxWidth) { [weak self] image in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    defer { self.pendingRenderedBlockIDs.remove(blockID) }
                    guard let image = image else { return }
                    guard let blockIdx = self.blocks.firstIndex(where: { $0.id == blockID }) else { return }
                    guard case .codeBlock = self.blocks[blockIdx].type else { return }

                    let codeRange = self.blocks[blockIdx].range
                    guard codeRange.location < textStorage.length,
                          NSMaxRange(codeRange) <= textStorage.length else { return }

                    // Replace the entire code block with a centered rendered image
                    let scale = min(maxWidth / image.size.width, 1.0)
                    let scaledSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

                    // Use a cell that spans the full container width and centers the image.
                    // This is stable against paragraph style resets by addTabStops.
                    let attachment = NSTextAttachment()
                    let cell = CenteredImageCell(image: image, imageSize: scaledSize, containerWidth: maxWidth)
                    attachment.attachmentCell = cell
                    // DO NOT set attachment.bounds — it would override the dynamic
                    // cellFrame(for:proposedLineFragment:...) query on the cell,
                    // preventing the image from shrinking when the pane is resized.

                    let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    let attRange = NSRange(location: 0, length: attachmentString.length)
                    attachmentString.addAttributes([
                        .renderedBlockSource: source,
                        .renderedBlockType: (type == .mermaid ? RenderedBlockType.mermaid : RenderedBlockType.math).rawValue,
                        .renderedBlockOriginalMarkdown: originalMarkdown
                    ], range: attRange)
                    // Clear code block background so no border appears
                    attachmentString.removeAttribute(.backgroundColor, range: attRange)

                    // Temporarily disable processing to avoid re-highlight cycle
                    self.isRendering = true
                    textStorage.beginEditing()
                    textStorage.replaceCharacters(in: codeRange, with: attachmentString)
                    let replacedRange = NSRange(location: codeRange.location, length: attachmentString.length)
                    // Set flag false BEFORE endEditing so the delegate callback sees it correctly
                    self.isRendering = false
                    textStorage.endEditing()

                    // Re-find the block by ID after endEditing, because endEditing
                    // triggers process() which may rebuild self.blocks, invalidating blockIdx.
                    guard let updatedIdx = self.blocks.firstIndex(where: { $0.id == blockID }) else { return }

                    // Mark the block as rendered (not removed). The block stays in the
                    // model with updated range. codeBlockRanges filters it out so
                    // LayoutManager won't draw a gray background behind the image.
                    self.blocks[updatedIdx].renderMode = .rendered
                    self.blocks[updatedIdx].range = replacedRange
                    self.blocks[updatedIdx].contentRange = replacedRange
                    self.blocks[updatedIdx].syntaxRanges = []
                }
            }
        }
    }

    // Table rendering moved to EditTextView (InlineTableView types not available in FSNotesCore)
    #endif

    private func getImageMaxWidth() -> CGFloat {
        #if os(iOS)
            return UIApplication.getVC().view.frame.width - 35
        #else
            // Prefer the text container width — this is the actual drawable
            // width inside the text view. Using the scroll view's content
            // width overshoots by the text container inset and line fragment
            // padding, causing rendered images to exceed the cellFrame during
            // layout and appear clipped on the left (negative x offset).
            if let container = editor?.textContainer {
                let lfp = container.lineFragmentPadding
                let w = container.size.width - lfp * 2
                if w > 0 { return w }
            }
            if let editorWidth = editor?.enclosingScrollView?.contentView.bounds.width {
                return editorWidth - 40
            }
            return CGFloat(UserDefaultsManagement.imagesWidth)
        #endif
    }

    private func safeRange(_ range: NSRange, in textStorage: NSTextStorage) -> NSRange {
        let storageLength = textStorage.length
        let loc = min(max(0, range.location), storageLength)
        let end = min(max(0, range.location + range.length), storageLength)
        return NSRange(location: loc, length: end - loc)
    }
}
