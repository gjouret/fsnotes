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
            // legacy phase5_paragraphStyles.
            if blockRange.length > 0 {
                let paraStyle = paragraphStyle(
                    for: block,
                    isFirst: (i == 0),
                    baseSize: bodyFont.pointSize,
                    lineSpacing: lineSpacing
                )
                out.addAttribute(.paragraphStyle, value: paraStyle, range: blockRange)
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

        return RenderedDocument(
            document: document,
            attributed: out,
            blockSpans: spans
        )
    }

    // MARK: - Paragraph styles

    /// Build a paragraph style for a rendered block, matching the
    /// spacing values from the legacy phase5_paragraphStyles.
    private static func paragraphStyle(
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
            switch level {
            case 1:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.67 }
                style.paragraphSpacing = baseSize * 0.67
            case 2:
                if !isFirst { style.paragraphSpacingBefore = baseSize }
                style.paragraphSpacing = 16
            case 3:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.8 }
                style.paragraphSpacing = 12
            case 4:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.6 }
                style.paragraphSpacing = 10
            case 5:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.5 }
                style.paragraphSpacing = 8
            default:
                if !isFirst { style.paragraphSpacingBefore = baseSize * 0.4 }
                style.paragraphSpacing = 6
            }

        case .paragraph:
            style.paragraphSpacing = 12

        case .codeBlock:
            style.lineSpacing = 0
            style.paragraphSpacing = 16
            style.paragraphSpacingBefore = 0

        case .blankLine:
            break

        case .list, .blockquote, .horizontalRule:
            // Structural block types that aren't yet supported by the
            // new editing pipeline. Basic spacing for read-only display.
            style.paragraphSpacing = 16
        }

        return style
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
        case .list(let items):
            return ListRenderer.render(items: items, bodyFont: bodyFont)
        case .blockquote(let lines):
            return BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont)
        case .horizontalRule:
            return HorizontalRuleRenderer.render(bodyFont: bodyFont)
        case .blankLine:
            // A blank line has no rendered content — it is represented
            // purely by the inter-block "\n" separators on either side.
            // The block's span will be empty (length 0).
            return NSAttributedString(string: "", attributes: [:])
        }
    }
}
