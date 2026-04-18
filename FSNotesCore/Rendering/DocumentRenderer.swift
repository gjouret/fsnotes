//
//  DocumentRenderer.swift
//  FSNotesCore
//
//  Top-level block-model renderer. Walks Document.blocks, dispatches
//  to the per-block renderer, joins blocks with "\n" separators, and
//  tracks each block's span in the rendered output.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: Document (block model).
//  - Output: RenderedDocument with attributed string + blockSpans.
//  - Pure function: same input → byte-equal attributed string.
//  - Zero markdown syntax markers in the rendered output. Zero `.kern`.
//    Zero clear-color foreground. (Architectural invariants carried
//    through from the per-block renderers.)
//
//  Block joining: the renderer emits each block WITHOUT its own
//  trailing newline. The top-level walker inserts a single "\n"
//  between consecutive blocks. A final trailing newline is appended
//  iff `document.trailingNewline == true`.
//
//  Block spans: `blockSpans[i]` covers the characters produced by
//  block[i] ONLY — NOT the inter-block separator newline that follows
//  it. This is the invariant that EditingOperations relies on to
//  compute splice ranges.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// The output of rendering a Document: the rendered attributed string
/// plus a per-block source map (which storage range came from which
/// block). This is the input to DocumentProjection / EditingOperations.
public struct RenderedDocument {
    public let document: Document
    public let attributed: NSAttributedString
    /// Storage range of each block's content. blockSpans[i] covers ONLY
    /// the characters produced by block[i] — it does NOT include the
    /// inter-block "\n" separator that follows (if any) or the document's
    /// trailing newline (if any).
    public let blockSpans: [NSRange]
}

public enum DocumentRenderer {

    // MARK: - Debug Logging
    
    private static let logFilePath = NSHomeDirectory() + "/Documents/render-debug.log"
    
    private static func logAttributes(_ label: String, range: NSRange, style: NSParagraphStyle, font: PlatformFont) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let log = """
            [\(timestamp)] \(label)
              Range: \(range.location),\(range.length)
              Font: \(font.fontName) \(font.pointSize)pt
              LineSpacing: \(style.lineSpacing)
              ParagraphSpacing: \(style.paragraphSpacing)
              ParagraphSpacingBefore: \(style.paragraphSpacingBefore)
              MinLineHeight: \(style.minimumLineHeight)
              MaxLineHeight: \(style.maximumLineHeight)
            ---
            """
        
        if let data = log.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFilePath) {
                if let fileHandle = FileHandle(forWritingAtPath: logFilePath) {
                    _ = fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logFilePath))
            }
        }
    }

    // MARK: - Paragraph Spacing Constants
    // These multipliers are applied to the base font size to determine
    // paragraph spacing. Defined here to avoid magic numbers.
    
    /// Spacing after paragraphs and blank lines (0.85 × font size)
    private static let paragraphSpacingMultiplier: CGFloat = 0.85
    
    /// Spacing after structural blocks (code, lists, blockquotes, etc.)
    /// (1.1 × font size) - slightly more visual separation
    private static let structuralBlockSpacingMultiplier: CGFloat = 1.1
    
    // Heading spacing multipliers (proportional to level)
    private static let h1SpacingMultiplier: CGFloat = 0.67
    private static let h2SpacingMultiplier: CGFloat = 0.5
    private static let h3SpacingMultiplier: CGFloat = 0.4
    private static let h4SpacingMultiplier: CGFloat = 0.35
    private static let h5SpacingMultiplier: CGFloat = 0.3
    private static let h6SpacingMultiplier: CGFloat = 0.25
    
    private static let h1SpacingBeforeMultiplier: CGFloat = 1.2
    private static let h2SpacingBeforeMultiplier: CGFloat = 1.0
    private static let h3SpacingBeforeMultiplier: CGFloat = 0.9
    private static let h4SpacingBeforeMultiplier: CGFloat = 0.8
    private static let h5SpacingBeforeMultiplier: CGFloat = 0.7
    private static let h6SpacingBeforeMultiplier: CGFloat = 0.6

    /// Render a document to an attributed string + per-block span map.
    ///
    /// - Parameter note: optional note context threaded through to
    ///   InlineRenderer for resolving relative image/PDF paths. Defaults
    ///   to nil so tests without a note stay source-compatible.
    public static func render(
        _ document: Document,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        note: Note? = nil
    ) -> RenderedDocument {
        let out = NSMutableAttributedString()
        var spans: [NSRange] = []
        spans.reserveCapacity(document.blocks.count)

        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]

        let lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)

        for (i, block) in document.blocks.enumerated() {
            let start = out.length
            let blockRendered = renderBlock(block, bodyFont: bodyFont, codeFont: codeFont, note: note)
            out.append(blockRendered)
            let end = out.length
            let blockRange = NSRange(location: start, length: end - start)
            spans.append(blockRange)

            // Apply paragraph styles (spacing, indentation) based on
            // block type. This replicates the essential parts of the
            // source-mode phase5_paragraphStyles.
            // DEBUG: Log paragraph style application
            let paraStyle = paragraphStyle(
                for: block, isFirst: (i == 0),
                baseSize: bodyFont.pointSize, lineSpacing: lineSpacing
            )
            logAttributes("BLOCK-\(i)-\(type(of: block))", range: blockRange, style: paraStyle, font: bodyFont)
            // Skip paragraph style application for blank lines (zero-length content)
            // and for blocks with actual content.
            if blockRange.length > 0 {
                applyParagraphStyle(
                    to: out,
                    range: blockRange,
                    block: block,
                    isFirst: (i == 0),
                    baseSize: bodyFont.pointSize,
                    lineSpacing: lineSpacing
                )
            }

            // Inter-block separator: a single "\n" between consecutive
            // blocks. NOT included in the block's span.
            if i < document.blocks.count - 1 {
                // For blank lines, use paragraph spacing (not the previous block's spacing)
                // to ensure consistent visual appearance when they convert to paragraphs.
                let nextBlock = document.blocks[i + 1]
                if case .blankLine = nextBlock {
                    let paraStyle = paragraphStyle(
                        for: .paragraph(inline: []), isFirst: false,
                        baseSize: bodyFont.pointSize, lineSpacing: lineSpacing
                    )
                    var blankLineSepAttrs = separatorAttrs
                    blankLineSepAttrs[.paragraphStyle] = paraStyle
                    out.append(NSAttributedString(string: "\n", attributes: blankLineSepAttrs))
                } else {
                    // For other blocks, apply the block's paragraph style to the separator.
                    let blockStyle = paragraphStyle(
                        for: block, isFirst: (i == 0),
                        baseSize: bodyFont.pointSize, lineSpacing: lineSpacing
                    )
                    var blockSepAttrs = separatorAttrs
                    blockSepAttrs[.paragraphStyle] = blockStyle
                    let sepRange = NSRange(location: out.length, length: 1)
                    logAttributes("SEPARATOR-\(i)", range: sepRange, style: blockStyle, font: bodyFont)
                    out.append(NSAttributedString(string: "\n", attributes: blockSepAttrs))
                }
            }
        }

        // Optional trailing newline: preserved for byte-equal round-trip
        // with the source markdown file. NOT part of any block's span.
        if document.trailingNewline && !document.blocks.isEmpty {
            // Always apply the last block's paragraph style to the trailing
            // newline for consistent line metrics.
            let lastIdx = document.blocks.count - 1
            let lastBlock = document.blocks[lastIdx]
            let lastStyle = paragraphStyle(
                for: lastBlock, isFirst: (lastIdx == 0),
                baseSize: bodyFont.pointSize, lineSpacing: lineSpacing
            )
            var lastAttrs = separatorAttrs
            lastAttrs[.paragraphStyle] = lastStyle
            out.append(NSAttributedString(string: "\n", attributes: lastAttrs))
        }

        // Post-processing: auto-link bare URLs in paragraph/heading text.
        // This doesn't modify the Document model — bare URLs stay as
        // plain text and serialize back without [text](url) wrapping.
        applyAutoLinks(to: out)

        return RenderedDocument(
            document: document,
            attributed: out,
            blockSpans: spans
        )
    }

    // MARK: - Auto-linking

    /// Regex matching bare URLs with protocols (https, http, sftp, file, ftp).
    static let autolinkRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "((?:https?|sftp|file|ftp)://[^`\\'\\\"\\>\\s\\*]+)",
        options: []
    )

    /// Regex matching bare www. URLs without protocol prefix.
    static let wwwRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?<=\\s|^)(www\\.[a-zA-Z0-9\\-]+\\.[a-zA-Z]{2,}(?:[/\\?#][^\\s]*)?)",
        options: [.anchorsMatchLines]
    )

    /// Scan the rendered attributed string for bare URLs and apply
    /// `.link` attributes. Skips ranges that already have a `.link`
    /// attribute (e.g., markdown `[text](url)` links) and ranges
    /// inside code blocks (monospace font).
    static func applyAutoLinks(to attrStr: NSMutableAttributedString) {
        let string = attrStr.string
        let fullRange = NSRange(location: 0, length: attrStr.length)

        #if os(OSX)
        let linkColor = NSColor(named: "link") ?? NSColor.systemBlue
        #else
        let linkColor = UIColor.systemBlue
        #endif

        let processMatch: (NSTextCheckingResult) -> Void = { match in
            var range = match.range
            guard range.length > 0 else { return }

            let substring = (string as NSString).substring(with: range)

            // Trim trailing punctuation that's unlikely part of the URL.
            if let last = substring.last, ["!", "?", ";", ":", ".", ","].contains(String(last)) {
                range = NSRange(location: range.location, length: range.length - 1)
            }

            // Skip if already linked (e.g., markdown [text](url) link).
            if attrStr.attribute(.link, at: range.location, effectiveRange: nil) != nil {
                return
            }

            // Skip if inside a code block (monospace font).
            if let font = attrStr.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont,
               font.isFixedPitch || font.fontName.lowercased().contains("mono") || font.fontName.lowercased().contains("courier") {
                return
            }

            let urlString = (string as NSString).substring(with: range)
            let finalURL: String
            if urlString.hasPrefix("www.") {
                finalURL = "https://\(urlString)"
            } else {
                finalURL = urlString
            }

            if let url = URL(string: finalURL) {
                attrStr.addAttribute(.link, value: url, range: range)
                attrStr.addAttribute(.foregroundColor, value: linkColor, range: range)
            }
        }

        autolinkRegex?.enumerateMatches(in: string, options: [], range: fullRange) { match, _, _ in
            guard let match = match else { return }
            processMatch(match)
        }

        wwwRegex?.enumerateMatches(in: string, options: [], range: fullRange) { match, _, _ in
            guard let match = match else { return }
            processMatch(match)
        }
    }

    // MARK: - Paragraph styles

    /// Build a paragraph style for a rendered block, matching the
    /// spacing values from the source-mode phase5_paragraphStyles.
    static func paragraphStyle(
        for block: Block,
        isFirst: Bool,
        baseSize: CGFloat,
        lineSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.alignment = .left

        switch block {
        case .heading(let level, _):
            // Spacing proportional to heading level for clear visual hierarchy.
            switch level {
            case 1:
                if !isFirst { style.paragraphSpacingBefore = baseSize * h1SpacingBeforeMultiplier }
                style.paragraphSpacing = baseSize * h1SpacingMultiplier
            case 2:
                if !isFirst { style.paragraphSpacingBefore = baseSize * h2SpacingBeforeMultiplier }
                style.paragraphSpacing = baseSize * h2SpacingMultiplier
            case 3:
                if !isFirst { style.paragraphSpacingBefore = baseSize * h3SpacingBeforeMultiplier }
                style.paragraphSpacing = baseSize * h3SpacingMultiplier
            case 4:
                if !isFirst { style.paragraphSpacingBefore = baseSize * h4SpacingBeforeMultiplier }
                style.paragraphSpacing = baseSize * h4SpacingMultiplier
            case 5:
                if !isFirst { style.paragraphSpacingBefore = baseSize * h5SpacingBeforeMultiplier }
                style.paragraphSpacing = baseSize * h5SpacingMultiplier
            default:
                if !isFirst { style.paragraphSpacingBefore = baseSize * h6SpacingBeforeMultiplier }
                style.paragraphSpacing = baseSize * h6SpacingMultiplier
            }

        case .paragraph(let inline):
            // Use proportional spacing based on actual font size
            style.paragraphSpacing = baseSize * paragraphSpacingMultiplier
            // Image-only paragraphs (a single `.image` inline) are
            // centered in the text column. Without centering, an
            // image resize drag visually grows/shrinks from the left
            // edge (anchored at the glyph's text-flow position);
            // with centering, it grows/shrinks symmetrically from
            // the middle, matching typical Markdown editor behavior
            // (Obsidian, Typora, iA Writer).
            if inline.count == 1, case .image = inline[0] {
                style.alignment = .center
            }

        case .codeBlock:
            style.lineSpacing = 0
            style.paragraphSpacing = baseSize * structuralBlockSpacingMultiplier
            style.paragraphSpacingBefore = 0

        case .blankLine:
            // Blank lines should have same spacing as empty paragraphs
            // to prevent visual jumps when they convert to paragraphs
            style.paragraphSpacing = baseSize * paragraphSpacingMultiplier

        case .list, .blockquote, .horizontalRule, .table:
            // Structural block types. Basic spacing for read-only display.
            style.paragraphSpacing = baseSize * structuralBlockSpacingMultiplier

        case .htmlBlock:
            style.lineSpacing = 0
            style.paragraphSpacing = baseSize * structuralBlockSpacingMultiplier
            style.paragraphSpacingBefore = 0
        }

        return style
    }

    /// Apply the appropriate paragraph style to a rendered block within an attributed string.
    /// For blockquotes and lists, merges spacing into existing per-line styles (preserving
    /// indentation). For all other block types, overwrites with a single style.
    ///
    /// - Parameters:
    ///   - attrStr: The mutable attributed string containing the block.
    ///   - range: The range within `attrStr` that corresponds to the block.
    ///   - block: The block type (determines merge vs overwrite behavior).
    ///   - isFirst: Whether this is the first block in the document.
    ///   - baseSize: The body font point size.
    ///   - lineSpacing: The user's configured line spacing.
    static func applyParagraphStyle(
        to attrStr: NSMutableAttributedString,
        range: NSRange,
        block: Block,
        isFirst: Bool,
        baseSize: CGFloat,
        lineSpacing: CGFloat
    ) {
        switch block {
        case .blockquote, .list:
            let blockSpacing = paragraphStyle(
                for: block, isFirst: isFirst,
                baseSize: baseSize, lineSpacing: lineSpacing
            )
            attrStr.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, subRange, _ in
                if let existing = value as? NSParagraphStyle {
                    let merged = existing.mutableCopy() as! NSMutableParagraphStyle
                    merged.paragraphSpacing = blockSpacing.paragraphSpacing
                    merged.paragraphSpacingBefore = blockSpacing.paragraphSpacingBefore
                    merged.lineSpacing = blockSpacing.lineSpacing
                    attrStr.addAttribute(.paragraphStyle, value: merged, range: subRange)
                }
            }
        default:
            let paraStyle = paragraphStyle(
                for: block, isFirst: isFirst,
                baseSize: baseSize, lineSpacing: lineSpacing
            )
            attrStr.addAttribute(.paragraphStyle, value: paraStyle, range: range)
        }
    }

    /// Render a single block. Dispatches to the per-block renderer.
    /// Output contains NO trailing newline — the caller owns separators.
    public static func renderBlock(
        _ block: Block,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        note: Note? = nil
    ) -> NSAttributedString {
        switch block {
        case .paragraph(let inline):
            return ParagraphRenderer.render(inline: inline, bodyFont: bodyFont, note: note)
        case .heading(let level, let suffix):
            return HeadingRenderer.render(level: level, suffix: suffix, bodyFont: bodyFont)
        case .codeBlock(let language, let content, _):
            return CodeBlockRenderer.render(language: language, content: content, codeFont: codeFont)
        case .list(let items, _):
            return ListRenderer.render(items: items, bodyFont: bodyFont, note: note)
        case .blockquote(let lines):
            return BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont, note: note)
        case .horizontalRule:
            return HorizontalRuleRenderer.render(bodyFont: bodyFont)
        case .htmlBlock(let raw):
            // Render HTML blocks as plain text with code font.
            return CodeBlockRenderer.render(language: nil, content: raw, codeFont: codeFont)
        case .table(let header, let alignments, let rows, let raw):
            return TableTextRenderer.render(header: header, rows: rows, alignments: alignments, rawMarkdown: raw, bodyFont: bodyFont)
        case .blankLine:
            // A blank line has no rendered content — it is represented
            // purely by the inter-block "\n" separators on either side.
            // The block's span will be empty (length 0).
            // Note: No paragraph style is applied to the separator for
            // blank lines to avoid visual jumps when they become paragraphs.
            return NSAttributedString(string: "", attributes: [:])
        }
    }
}
