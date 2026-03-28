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

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image = self.image else { return }
        let x = cellFrame.origin.x + (cellFrame.width - imageSize.width) / 2
        let drawRect = NSRect(origin: NSPoint(x: x, y: cellFrame.origin.y),
                              size: imageSize)
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                   respectFlipped: true, hints: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }
}
#endif

class TextStorageProcessor: NSObject, NSTextStorageDelegate {
    public var editor: EditTextView?
    public var detector = CodeBlockDetector()
    public var isRendering = false

    // MARK: - Block Model (Phase A: shadow mode — populated alongside existing code)

    /// The block model — single source of truth for all WYSIWYG rendering.
    /// Populated by MarkdownBlockParser during process().
    public var blocks: [MarkdownBlock] = []

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

    /// Hide syntax characters by delegating to the shared static method.
    func hideSyntaxRange(_ range: NSRange, in textStorage: NSTextStorage) {
        NotesTextProcessor.applySyntaxHiding(in: textStorage, range: range)
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
            
        if editedMask.contains(.editedCharacters), delta < 0 {
            if let layoutManager = textStorage.layoutManagers.first,
               let textContainer = layoutManager.textContainers.first,
               let textView = textContainer.textView {
                textView.needsDisplay = true
            }
        }
    }
#endif

    private func process(textStorage: NSTextStorage, range editedRange: NSRange, changeInLength delta: Int) {
        guard let note = editor?.note, textStorage.length > 0 else { return }
        guard !isRendering else { return }

        defer {
            loadImages(textStorage: textStorage, checkRange: editedRange)

            // Phase 5: Block-aware paragraph styles (replaces addTabStops)
            // Must run after block model is populated (updateBlockModel runs at end of process body)
            if !blocks.isEmpty {
                let paragraphRange = (textStorage.string as NSString).paragraphRange(for: editedRange)
                phase5_paragraphStyles(textStorage: textStorage, range: paragraphRange)
            } else {
                // Fallback to old addTabStops if block model not yet populated
                textStorage.updateParagraphStyle(range: editedRange)
            }

            // Phase 4: Unified syntax hiding (replaces scattered fence hiding)
            if NotesTextProcessor.hideSyntax && !blocks.isEmpty {
                let paragraphRange = (textStorage.string as NSString).paragraphRange(for: editedRange)
                phase4_hideSyntax(textStorage: textStorage, range: paragraphRange)
            }
        }

        if note.content.length == textStorage.length && (
            note.content.string.fnv1a == note.cacheHash
        ) { return }
        
        // Full load
        if editedRange.length == textStorage.length {
            NotesTextProcessor.highlight(attributedString: textStorage)

            // Populate block model on full load — Phase 4 (syntax hiding) and
            // Phase 5 (paragraph styles) run from the defer block using this model
            updateBlockModel(textStorage: textStorage, editedRange: editedRange, delta: delta)

            return
        }

        let codeBlockRanges = detector.findCodeBlocks(in: textStorage)
        let paragraphRange = (textStorage.string as NSString).paragraphRange(for: editedRange)

        NotesTextProcessor.highlightMarkdown(attributedString: textStorage, paragraphRange: paragraphRange, codeBlockRanges: codeBlockRanges)

        // Code block founds
        var result = detector.codeBlocks(textStorage: textStorage, editedRange: editedRange, delta: delta, newRanges: codeBlockRanges)

        // In WYSIWYG mode, code blocks show all content as-is (no syntax hiding).
        // Fences (```), language names, and code are all visible.
        // Mermaid/math rendering is triggered ONLY when the cursor leaves the code
        // block (in textViewDidChangeSelection), NOT on every keystroke here.

        // Highlight code block end (```), that wiped previously in highlightMarkdown
        for range in codeBlockRanges {
            if NSIntersectionRange(range, paragraphRange).length > 0 {
                if result.edited == nil {
                    result.code?.append(range)
                }
            }
        }

        if let ranges = result.code {
            for range in ranges {
                NotesTextProcessor
                    .getHighlighter()
                    .highlight(in: textStorage, fullRange: range)
            }
        }

        if let editedBlock = result.edited, let editedParagraph = result.editedParagraph {
            NotesTextProcessor
                .getHighlighter()
                .highlight(in: textStorage, fullRange: editedBlock, editedRange: editedParagraph)
        }

        if let ranges = result.md {
            for range in ranges {
                let safeRange = safeRange(range, in: textStorage)
                NotesTextProcessor.resetFont(attributedString: textStorage, paragraphRange: safeRange)
                NotesTextProcessor.highlightMarkdown(attributedString: textStorage, paragraphRange: safeRange)
            }
        }

        // Phase 4 (syntax hiding) runs from defer block after block model is populated.
        // No more scattered fence hiding here — it's unified in phase4_hideSyntax().

        // Populate block model after all highlighting is complete.
        updateBlockModel(textStorage: textStorage, editedRange: editedRange, delta: delta)
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

                // Block-type-specific styles — values from MPreview main.css:
                //   body { font-size: 14px; line-height: 1.2 }
                //   h1,h2,h3,h4,h5,h6 { margin-top: 1em; margin-bottom: 16px; line-height: 1.4 }
                //   h1 { font-size: 1.8em; margin: .67em 0 }
                //   h1:not(.no-border), h2 { padding-bottom: .3em; border-bottom: 1px solid #eee }
                //   h2 { font-size: 1.6em }  h3 { font-size: 1.4em }
                //   h4 { font-size: 1.2em }  h5,h6 { font-size: 1em }
                //   ul,ol { padding-left: 2em; margin-bottom: 16px; margin-top: 0 }
                //   li { line-height: 28px }
                //   p { margin-bottom: 16px }  hr { margin: 16px 0 }
                switch block.type {
                case .heading(let level), .headingSetext(let level):
                    // MPreview CSS: h1-h6 { margin-top: 1em; margin-bottom: 16px }
                    //   h1 { margin: .67em 0 }; h1,h2 { padding-bottom: .3em; border-bottom }
                    // NOTE: .3em padding is handled visually by drawHeaderBottomBorders —
                    // do NOT include it in paragraphSpacing (that would double-count).
                    // Progressive spacing: larger headers get more bottom margin.
                    switch level {
                    case 1:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.67 }
                        paragraph.paragraphSpacing = baseSize * 0.67  // .67em margin-bottom
                    case 2:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize }
                        paragraph.paragraphSpacing = 16  // margin-bottom: 16px
                    case 3:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.8 }
                        paragraph.paragraphSpacing = 12
                    case 4:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.6 }
                        paragraph.paragraphSpacing = 10
                    case 5:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.5 }
                        paragraph.paragraphSpacing = 8
                    default: // h6
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.4 }
                        paragraph.paragraphSpacing = 6
                    }

                case .unorderedList, .orderedList:
                    // MPreview CSS: ul,ol { padding-left: 2em; margin-top: 0; margin-bottom: 16px }
                    //               li { line-height: 28px }
                    let markers = ["\u{2022} ", "- ", "* ", "+ "]
                    let prefix = value.getSpacePrefix()
                    var matchedPrefix: String?

                    if prefix.isEmpty {
                        for marker in markers {
                            if value.hasPrefix(marker) { matchedPrefix = marker; break }
                        }
                    } else {
                        for marker in markers {
                            let full = prefix + marker
                            if value.hasPrefix(full) { matchedPrefix = full; break }
                        }
                    }
                    if matchedPrefix == nil {
                        matchedPrefix = textStorage.getNumberListPrefix(paragraph: value)
                    }

                    // padding-left: 2em
                    let listIndent = baseSize * 2
                    if let mp = matchedPrefix {
                        let markerWidth = mp.widthOfString(usingFont: font, tabs: tabs)
                        paragraph.headIndent = max(markerWidth, listIndent)
                        paragraph.firstLineHeadIndent = paragraph.headIndent - markerWidth
                    } else {
                        paragraph.headIndent = listIndent
                    }

                    // li { line-height: 28px } → inter-item spacing comes from line height
                    // 28px line-height at 14px font = 14px extra → ~7pt spacing per item
                    paragraph.lineSpacing = 7

                    // ul margin-top: 0, margin-bottom: 16px
                    let isFirstLine = (parRange.location == block.range.location)
                    let isLastLine = (NSMaxRange(parRange) >= NSMaxRange(block.range))
                    paragraph.paragraphSpacingBefore = isFirstLine ? 0 : 2
                    paragraph.paragraphSpacing = isLastLine ? 16 : 0

                case .todoItem:
                    let markerWidth = "- [ ] ".widthOfString(usingFont: font, tabs: tabs)
                    paragraph.headIndent = markerWidth
                    let prevIsTodo = prevBlock.map { self.isListBlock($0.type) } ?? false
                    let nextIsTodo = nextBlock.map { self.isListBlock($0.type) } ?? false
                    paragraph.paragraphSpacingBefore = prevIsTodo ? 4 : 8
                    paragraph.paragraphSpacing = nextIsTodo ? 4 : 16

                case .blockquote:
                    // blockquote: margin 0, padding 0 15px, border-left 4px #ddd
                    paragraph.firstLineHeadIndent = 15
                    paragraph.headIndent = 15
                    paragraph.paragraphSpacing = 16

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

                case .empty, .table, .yamlFrontmatter:
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

    /// Single-pass syntax hiding: applies clear color + negative kern to ALL
    /// syntax ranges from the block model. Runs ONCE after highlighting.
    func phase4_hideSyntax(textStorage: NSTextStorage, range: NSRange) {
        guard NotesTextProcessor.hideSyntax else { return }

        // Prevent re-entrant processing from character replacements (e.g., bullet substitution)
        isRendering = true
        defer { isRendering = false }

        let affectedBlocks = MarkdownBlockParser.blocks(in: blocks, intersecting: range)

        for block in affectedBlocks {
            // Skip syntax hiding for list items — bullets use character substitution,
            // ordered lists show numbers as-is (they're already the correct display format)
            let skipHiding: Bool
            switch block.type {
            case .unorderedList, .orderedList:
                skipHiding = true
            default:
                skipHiding = false
            }

            if !skipHiding {
                for syntaxRange in block.syntaxRanges {
                    guard syntaxRange.location < textStorage.length,
                          NSMaxRange(syntaxRange) <= textStorage.length else { continue }
                    hideSyntaxRange(syntaxRange, in: textStorage)
                }
            }

            // Block-specific visual replacements
            switch block.type {
            case .unorderedList:
                // Schedule bullet character substitution outside didProcessEditing
                // (NSTextStorage doesn't allow replaceCharacters inside the delegate callback)
                let syntaxRanges = block.syntaxRanges
                DispatchQueue.main.async { [weak textStorage] in
                    guard let ts = textStorage else { return }
                    self.isRendering = true
                    ts.beginEditing()
                    // Process in reverse order to avoid range invalidation
                    for syntaxRange in syntaxRanges.reversed() {
                        guard syntaxRange.location < ts.length,
                              NSMaxRange(syntaxRange) <= ts.length,
                              syntaxRange.length >= 2 else { continue }
                        let marker = (ts.string as NSString).substring(with: NSRange(location: syntaxRange.location, length: 1))
                        if marker == "-" || marker == "*" || marker == "+" {
                            let bulletRange = NSRange(location: syntaxRange.location, length: 1)
                            // Use BLACK CIRCLE (●) for a larger, more visible bullet like MPreview
                            ts.replaceCharacters(in: bulletRange, with: "\u{2022}")
                            // Mark for save-path reversal and ensure bullet is visible
                            ts.addAttribute(.listBullet, value: marker, range: bulletRange)
                            ts.addAttribute(.foregroundColor, value: NSColor.textColor, range: bulletRange)
                            // Slightly larger font for bullet to match MPreview's disc style
                            let fontSize = CGFloat(UserDefaultsManagement.fontSize)
                            let bulletFont = NSFont.systemFont(ofSize: fontSize * 0.8)
                            ts.addAttribute(.font, value: bulletFont, range: bulletRange)
                            ts.removeAttribute(.kern, range: bulletRange)
                            // Also ensure the full syntax range (bullet + space) has visible color
                            ts.addAttribute(.foregroundColor, value: NSColor.textColor, range: syntaxRange)
                            ts.removeAttribute(.kern, range: syntaxRange)
                        }
                    }
                    ts.endEditing()
                    self.isRendering = false
                }

            case .blockquote:
                // Set .blockquote on the full block range for LayoutManager border drawing
                textStorage.addAttribute(.blockquote, value: true, range: block.range)

            case .horizontalRule:
                // Set .horizontalRule for LayoutManager line drawing
                textStorage.addAttribute(.horizontalRule, value: true, range: block.range)

            case .heading(let level) where level <= 2:
                // Existing highlightMarkdown sets the header font; we just need
                // the attribute for LayoutManager to draw bottom borders.
                // The header regex already handles this.
                break

            default:
                break
            }
        }
    }

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

            // Check if already rendered or rendering — use block model as source of truth,
            // not text attributes (which persist across save/reload and cause false dedup)
            if let blockIdx = blocks.firstIndex(where: {
                if case .codeBlock = $0.type { return $0.range == codeRange }
                return false
            }), blocks[blockIdx].renderMode == .rendered {
                continue
            }

            // Mark as rendering immediately in the block model to prevent duplicate
            // async renders (triggerCodeBlockRenderingIfNeeded can fire from multiple sources)
            if let blockIdx = blocks.firstIndex(where: {
                if case .codeBlock = $0.type { return $0.range == codeRange }
                return false
            }) {
                blocks[blockIdx].renderMode = .rendered
            }

            let maxWidth = getImageMaxWidth()

            // Capture the full original markdown (fences + content) for restoration on click
            let originalMarkdown = string.substring(with: codeRange)

            BlockRenderer.render(source: source, type: type, maxWidth: maxWidth) { [weak self] image in
                guard let image = image, let self = self else { return }

                DispatchQueue.main.async {
                    // Re-find the code block by searching for the original markdown.
                    // The captured codeRange may be stale if other blocks were rendered first.
                    let currentString = textStorage.string as NSString
                    let searchRange = NSRange(location: 0, length: currentString.length)
                    let foundRange = currentString.range(of: originalMarkdown, range: searchRange)
                    guard foundRange.location != NSNotFound else { return }
                    let codeRange = foundRange

                    // Replace the entire code block with a centered rendered image
                    let scale = min(maxWidth / image.size.width, 1.0)
                    let scaledSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

                    // Use a cell that spans the full container width and centers the image.
                    // This is stable against paragraph style resets by addTabStops.
                    let attachment = NSTextAttachment()
                    let cell = CenteredImageCell(image: image, imageSize: scaledSize, containerWidth: maxWidth)
                    attachment.attachmentCell = cell
                    attachment.bounds = NSRect(origin: .zero, size: NSSize(width: maxWidth, height: scaledSize.height))

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
                    // Clear background on the replaced range
                    let replacedRange = NSRange(location: codeRange.location, length: attachmentString.length)
                    if replacedRange.location + replacedRange.length <= textStorage.length {
                        textStorage.removeAttribute(.backgroundColor, range: replacedRange)
                    }
                    // Set flag false BEFORE endEditing so the delegate callback sees it correctly
                    self.isRendering = false
                    textStorage.endEditing()

                    // Mark the block as rendered (not removed). The block stays in the
                    // model with updated range. codeBlockRanges filters it out so
                    // LayoutManager won't draw a gray background behind the image.
                    if let idx = self.blocks.firstIndex(where: { block in
                        if case .codeBlock = block.type { return block.range == codeRange }
                        return false
                    }) {
                        self.blocks[idx].renderMode = .rendered
                        self.blocks[idx].range = replacedRange
                        self.blocks[idx].contentRange = replacedRange
                        self.blocks[idx].syntaxRanges = []
                    }
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
            if let editorWidth = editor?.enclosingScrollView?.contentView.bounds.width {
                return editorWidth - 40 // margin for padding
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
