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

    /// Render a document to an attributed string + per-block span map.
    public static func render(
        _ document: Document,
        bodyFont: PlatformFont,
        codeFont: PlatformFont
    ) -> RenderedDocument {
        let out = NSMutableAttributedString()
        var spans: [NSRange] = []
        spans.reserveCapacity(document.blocks.count)

        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]

        // Near-zero-height separator for "\n" characters adjacent to
        // blankLine blocks. BlankLines are structural (for markdown
        // round-trip) but should be visually invisible.
        let collapsedStyle = NSMutableParagraphStyle()
        collapsedStyle.minimumLineHeight = 0.01
        collapsedStyle.maximumLineHeight = 0.01
        collapsedStyle.lineSpacing = 0
        collapsedStyle.paragraphSpacing = 0
        collapsedStyle.paragraphSpacingBefore = 0
        let collapsedSepAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label,
            .paragraphStyle: collapsedStyle
        ]

        let lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)

        for (i, block) in document.blocks.enumerated() {
            let start = out.length
            let blockRendered = renderBlock(block, bodyFont: bodyFont, codeFont: codeFont)
            out.append(blockRendered)
            let end = out.length
            let blockRange = NSRange(location: start, length: end - start)
            spans.append(blockRange)

            // Apply paragraph styles (spacing, indentation) based on
            // block type. This replicates the essential parts of the
            // source-mode phase5_paragraphStyles.
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
                let isAdjacentToBlankLine: Bool = {
                    if case .blankLine = block { return true }
                    if i + 1 < document.blocks.count,
                       case .blankLine = document.blocks[i + 1] { return true }
                    return false
                }()
                if isAdjacentToBlankLine {
                    // Collapse separators next to blankLines to near-zero
                    // height. BlankLines exist only for serialization
                    // round-trip — visually the paragraphSpacing on
                    // surrounding blocks provides all inter-block gaps.
                    out.append(NSAttributedString(string: "\n", attributes: collapsedSepAttrs))
                } else {
                    out.append(NSAttributedString(string: "\n", attributes: separatorAttrs))
                }
            }
        }

        // Optional trailing newline: preserved for byte-equal round-trip
        // with the source markdown file. NOT part of any block's span.
        if document.trailingNewline && !document.blocks.isEmpty {
            out.append(NSAttributedString(string: "\n", attributes: separatorAttrs))
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
                if !isFirst { style.paragraphSpacingBefore = baseSize * 1.2 }
                style.paragraphSpacing = baseSize * 0.67
            case 2:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 1.0 }
                style.paragraphSpacing = baseSize * 0.5
            case 3:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.9 }
                style.paragraphSpacing = baseSize * 0.4
            case 4:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.8 }
                style.paragraphSpacing = baseSize * 0.35
            case 5:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.7 }
                style.paragraphSpacing = baseSize * 0.3
            default:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.6 }
                style.paragraphSpacing = baseSize * 0.25
            }

        case .paragraph:
            style.paragraphSpacing = 12

        case .codeBlock:
            style.lineSpacing = 0
            style.paragraphSpacing = 16
            style.paragraphSpacingBefore = 0

        case .blankLine:
            break

        case .list, .blockquote, .horizontalRule, .table:
            // Structural block types. Basic spacing for read-only display.
            style.paragraphSpacing = 16

        case .htmlBlock:
            style.lineSpacing = 0
            style.paragraphSpacing = 16
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
        guard range.length > 0 else { return }

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
        codeFont: PlatformFont
    ) -> NSAttributedString {
        switch block {
        case .paragraph(let inline):
            return ParagraphRenderer.render(inline: inline, bodyFont: bodyFont)
        case .heading(let level, let suffix):
            return HeadingRenderer.render(level: level, suffix: suffix, bodyFont: bodyFont)
        case .codeBlock(let language, let content, _):
            return CodeBlockRenderer.render(language: language, content: content, codeFont: codeFont)
        case .list(let items, _):
            return ListRenderer.render(items: items, bodyFont: bodyFont)
        case .blockquote(let lines):
            return BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont)
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
            return NSAttributedString(string: "", attributes: [:])
        }
    }
}
