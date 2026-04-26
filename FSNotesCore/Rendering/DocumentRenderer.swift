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
    
    private static let logFilePath = NSHomeDirectory() + "/log/render-debug.log"
    
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

    // MARK: - Paragraph Spacing
    //
    // Phase 7.2: paragraph-spacing values are now read from the active
    // `Theme` instead of being file-local constants. `theme.spacing.*`
    // carries the multipliers applied against the body font size, and
    // `theme.headingSpacingBefore` / `theme.headingSpacingAfter` (flat
    // fields on `BlockStyleTheme`) carry the per-heading-level values.
    // Defaults match the pre-theme hardcoded values byte-for-byte, so
    // `theme: .shared` (today's default theme) is a visual no-op.

    /// Render a document to an attributed string + per-block span map.
    ///
    /// - Parameters:
    ///   - document: the block-model document to render.
    ///   - bodyFont: the body font for paragraph / heading text.
    ///   - codeFont: the code font for code blocks.
    ///   - note: optional note context threaded through to
    ///     InlineRenderer for resolving relative image/PDF paths.
    ///     Defaults to nil so tests without a note stay source-compatible.
    ///   - theme: the active theme. Defaults to `Theme.shared` so
    ///     existing callers don't need updating. Renderer-level tests
    ///     pass a custom theme to assert theme-driven values.
    ///   - editingCodeBlocks: the set of `BlockRef`s whose code blocks
    ///     should render in EDITING form — raw fenced source in plain
    ///     code font, no syntax highlighting, no mermaid/math
    ///     attachment. Blocks not in the set render in today's DEFAULT
    ///     form (syntax-highlighted or bitmap-rendered). Default empty
    ///     set preserves the byte-for-byte existing behaviour so every
    ///     existing caller stays unchanged. See
    ///     `CODEBLOCK_EDIT_TOGGLE_PLAN.md` slice 1.
    public static func render(
        _ document: Document,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        note: Note? = nil,
        theme: Theme = .shared,
        editingCodeBlocks: Set<BlockRef> = []
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
            let blockRendered = renderBlock(
                block,
                bodyFont: bodyFont,
                codeFont: codeFont,
                note: note,
                theme: theme,
                editingCodeBlocks: editingCodeBlocks
            )
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
                baseSize: bodyFont.pointSize, lineSpacing: lineSpacing,
                theme: theme
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
                    lineSpacing: lineSpacing,
                    theme: theme
                )

                // Phase 2b: tag the block's range with its
                // `BlockModelKind`. The TK2 content-storage delegate
                // reads this attribute to dispatch on `NSTextParagraph`
                // subclass (see `BlockModelElements.swift`). Tables
                // are tagged separately by `TableTextRenderer`
                // (which emits a single flat attributed string per table
                // and tags it `.blockModelKind = .table`), so they are
                // intentionally omitted from this pass.
                if let kind = blockModelKind(for: block, editingCodeBlocks: editingCodeBlocks) {
                    // Phase 2d: upgrade `.paragraph` to `.paragraphWithKbd`
                    // when the rendered paragraph contains any `.kbdTag`
                    // runs. `InlineRenderer` emits `.kbdTag = true` on
                    // the inner content of each `Inline.kbd`. The upgrade
                    // routes this paragraph to `KbdBoxParagraphLayoutFragment`
                    // via the content-storage delegate, which draws the
                    // rounded kbd boxes behind each tagged run. Paragraphs
                    // with no kbd tags stay on the default fragment.
                    let effectiveKind: BlockModelKind
                    if kind == .paragraph,
                       paragraphContainsKbdTag(in: out, range: blockRange) {
                        effectiveKind = .paragraphWithKbd
                    } else {
                        effectiveKind = kind
                    }
                    out.addAttribute(
                        .blockModelKind,
                        value: effectiveKind.rawValue,
                        range: blockRange
                    )
                    // Phase 2c: for headings, also tag the level so
                    // `HeadingLayoutFragment` can decide whether to
                    // paint the H1/H2 bottom hairline. Keeping the
                    // level on the attributed-string range (not only
                    // in the block model) lets the TK2 fragment read
                    // it off `NSTextParagraph.attributedString` at
                    // draw time without needing a back-reference to
                    // the Document.
                    if case .heading(let level, _) = block {
                        out.addAttribute(
                            .headingLevel,
                            value: level,
                            range: blockRange
                        )
                    }
                    // Phase 2c: for mermaid/math code blocks, tag the
                    // block range with the raw source text so the
                    // MermaidLayoutFragment / MathLayoutFragment can
                    // read it via a single attribute lookup at draw
                    // time without reaching back into the Document.
                    if (kind == .mermaid || kind == .math),
                       case .codeBlock(_, let content, _) = block {
                        out.addAttribute(
                            .renderedBlockSource,
                            value: content,
                            range: blockRange
                        )
                    }
                    // Display math: tag the paragraph range with the
                    // raw LaTeX source from the sole `.displayMath`
                    // inline so `DisplayMathLayoutFragment` can read
                    // it via a single attribute lookup at draw time.
                    // Structurally parallel to the fenced-math branch
                    // above — the only difference is where the source
                    // string comes from (inline payload vs. code-block
                    // content).
                    if kind == .displayMath,
                       case .paragraph(let inline) = block,
                       inline.count == 1,
                       case .displayMath(let content) = inline[0] {
                        out.addAttribute(
                            .renderedBlockSource,
                            value: content,
                            range: blockRange
                        )
                    }
                }
            }

            // Inter-block separator: a single "\n" between consecutive
            // blocks. NOT included in the block's span.
            if i < document.blocks.count - 1 {
                let nextBlock = document.blocks[i + 1]
                // When the NEXT block renders to zero content (blank line
                // or empty paragraph produced by exit-list / delete-line),
                // NSTextView draws the cursor on that empty line using
                // the style of whatever character precedes it. If we
                // leave the separator styled with THIS block's paragraph
                // style, the cursor on the empty line inherits (e.g.)
                // the list's hanging indent or heading's font/spacing.
                // Apply a plain paragraph style to the separator in that
                // case so the empty line renders as a body-text line.
                if case .blankLine = nextBlock {
                    let paraStyle = paragraphStyle(
                        for: .paragraph(inline: []), isFirst: false,
                        baseSize: bodyFont.pointSize, lineSpacing: lineSpacing,
                        theme: theme
                    )
                    var blankLineSepAttrs = separatorAttrs
                    blankLineSepAttrs[.paragraphStyle] = paraStyle
                    out.append(NSAttributedString(string: "\n", attributes: blankLineSepAttrs))
                } else if isEmptyParagraph(nextBlock) {
                    // Empty paragraph (e.g. the block produced when the
                    // user exits a list via Delete-at-home, or enters a
                    // new paragraph between two existing paragraphs).
                    // Style the separator with the empty paragraph's
                    // own paragraph style so the cursor lands at the
                    // body-text left margin with correct line spacing.
                    let paraStyle = paragraphStyle(
                        for: nextBlock, isFirst: (i + 1 == 0),
                        baseSize: bodyFont.pointSize, lineSpacing: lineSpacing,
                        theme: theme
                    )
                    var emptyParaSepAttrs = separatorAttrs
                    emptyParaSepAttrs[.paragraphStyle] = paraStyle
                    out.append(NSAttributedString(string: "\n", attributes: emptyParaSepAttrs))
                } else {
                    // For other blocks, apply the block's paragraph style to the separator.
                    let blockStyle = paragraphStyle(
                        for: block, isFirst: (i == 0),
                        baseSize: bodyFont.pointSize, lineSpacing: lineSpacing,
                        theme: theme
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
                baseSize: bodyFont.pointSize, lineSpacing: lineSpacing,
                theme: theme
            )
            var lastAttrs = separatorAttrs
            lastAttrs[.paragraphStyle] = lastStyle
            out.append(NSAttributedString(string: "\n", attributes: lastAttrs))
        }

        // Post-processing: auto-link bare URLs in paragraph/heading text.
        // This doesn't modify the Document model — bare URLs stay as
        // plain text and serialize back without [text](url) wrapping.
        applyAutoLinks(to: out, theme: theme)

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
    static func applyAutoLinks(
        to attrStr: NSMutableAttributedString,
        theme: Theme = .shared
    ) {
        let string = attrStr.string
        let fullRange = NSRange(location: 0, length: attrStr.length)

        // Phase 7.2: link color now reads from the active theme's
        // `colors.link` entry. The default theme ships with
        // `{ "asset": "linkColor" }` so the previous `NSColor(named: "link")`
        // behaviour is preserved; themes without an asset fall back to
        // a per-theme hex, and finally to the platform system-blue.
        #if os(OSX)
        let linkColor = theme.colors.link
            .resolvedForCurrentAppearance(fallback: NSColor.systemBlue)
        #else
        let linkColor = theme.colors.link
            .resolvedForCurrentAppearance(fallback: UIColor.systemBlue)
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
    ///
    /// Phase 7.2: spacing multipliers are read from `theme.spacing.*`
    /// (paragraph + structural-block) and from the flat
    /// `theme.headingSpacingBefore` / `theme.headingSpacingAfter` arrays
    /// (per-heading-level values). The default theme carries values that
    /// match the prior hardcoded constants so the default render is
    /// byte-identical.
    static func paragraphStyle(
        for block: Block,
        isFirst: Bool,
        baseSize: CGFloat,
        lineSpacing: CGFloat,
        theme: Theme = .shared
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.alignment = .left

        let paragraphMult = theme.spacing.paragraphSpacingMultiplier
        let structuralMult = theme.spacing.structuralBlockSpacingMultiplier

        switch block {
        case .heading(let level, _):
            // Spacing proportional to heading level for clear visual
            // hierarchy. Values are indexed off the theme's flat
            // `headingSpacingBefore` / `headingSpacingAfter` arrays via
            // the clamped `headingSpacingBeforeMultiplier(for:)` /
            // `headingSpacingAfterMultiplier(for:)` helpers so invalid
            // levels (0, 7+) never index out of bounds.
            if !isFirst {
                style.paragraphSpacingBefore =
                    baseSize * theme.headingSpacingBeforeMultiplier(for: level)
            }
            style.paragraphSpacing =
                baseSize * theme.headingSpacingAfterMultiplier(for: level)

        case .paragraph(let inline):
            // Use proportional spacing based on actual font size
            style.paragraphSpacing = baseSize * paragraphMult
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
            style.paragraphSpacing = baseSize * structuralMult
            style.paragraphSpacingBefore = 0

        case .blankLine:
            // Blank lines should have same spacing as empty paragraphs
            // to prevent visual jumps when they convert to paragraphs
            style.paragraphSpacing = baseSize * paragraphMult

        case .list, .blockquote, .horizontalRule, .table:
            // Structural block types. Basic spacing for read-only display.
            style.paragraphSpacing = baseSize * structuralMult

        case .htmlBlock:
            style.lineSpacing = 0
            style.paragraphSpacing = baseSize * structuralMult
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
        lineSpacing: CGFloat,
        theme: Theme = .shared
    ) {
        switch block {
        case .blockquote, .list:
            let blockSpacing = paragraphStyle(
                for: block, isFirst: isFirst,
                baseSize: baseSize, lineSpacing: lineSpacing,
                theme: theme
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
                baseSize: baseSize, lineSpacing: lineSpacing,
                theme: theme
            )
            attrStr.addAttribute(.paragraphStyle, value: paraStyle, range: range)
        }
    }

    /// Render a single block. Dispatches to the per-block renderer.
    /// Output contains NO trailing newline — the caller owns separators.
    ///
    /// Phase 7.2: the `theme` parameter is threaded into the inline
    /// renderer for blocks that flow through it (paragraph, heading,
    /// list item, blockquote line). Per-block renderers that do NOT
    /// consume `InlineRenderer` directly (code, table, HR) stay
    /// theme-agnostic for now — those are Phase 7.3 scope.
    public static func renderBlock(
        _ block: Block,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        note: Note? = nil,
        theme: Theme = .shared,
        editingCodeBlocks: Set<BlockRef> = []
    ) -> NSAttributedString {
        switch block {
        case .paragraph(let inline):
            return ParagraphRenderer.render(inline: inline, bodyFont: bodyFont, note: note, theme: theme)
        case .heading(let level, let suffix):
            return HeadingRenderer.render(level: level, suffix: suffix, bodyFont: bodyFont, theme: theme)
        case .codeBlock(let language, let content, let fence):
            // Code-Block Edit Toggle (slice 1): when this block's ref
            // is in `editingCodeBlocks`, emit the RAW fenced source as
            // plain code font. Otherwise today's syntax-highlighted /
            // attachment behaviour is preserved.
            let editingForm = editingCodeBlocks.contains(BlockRef(block))
            return CodeBlockRenderer.render(
                language: language,
                content: content,
                codeFont: codeFont,
                fence: fence,
                editingForm: editingForm
            )
        case .list(let items, _):
            return ListRenderer.render(items: items, bodyFont: bodyFont, note: note, theme: theme)
        case .blockquote(let lines):
            return BlockquoteRenderer.render(lines: lines, bodyFont: bodyFont, note: note, theme: theme)
        case .horizontalRule:
            return HorizontalRuleRenderer.render(bodyFont: bodyFont)
        case .htmlBlock(let raw):
            // Render HTML blocks as plain text with code font.
            return CodeBlockRenderer.render(language: nil, content: raw, codeFont: codeFont)
        case .table(let header, let alignments, let rows, let widths):
            let raw = EditingOps.rebuildTableRaw(
                header: header, alignments: alignments, rows: rows
            )
            return TableTextRenderer.render(
                header: header,
                rows: rows,
                alignments: alignments,
                rawMarkdown: raw,
                bodyFont: bodyFont,
                columnWidths: widths
            )
        case .blankLine:
            // A blank line has no rendered content — it is represented
            // purely by the inter-block "\n" separators on either side.
            // The block's span will be empty (length 0).
            // Note: No paragraph style is applied to the separator for
            // blank lines to avoid visual jumps when they become paragraphs.
            return NSAttributedString(string: "", attributes: [:])
        }
    }

    /// Phase 2d: does the paragraph's rendered attributed string
    /// contain any `.kbdTag` runs? Used to upgrade `.blockModelKind`
    /// from `.paragraph` to `.paragraphWithKbd` so the content-storage
    /// delegate routes the element to `KbdBoxParagraphLayoutFragment`.
    /// One enumerate over the paragraph range — O(runs). Short-circuits
    /// on the first match.
    fileprivate static func paragraphContainsKbdTag(
        in attributed: NSAttributedString,
        range: NSRange
    ) -> Bool {
        let clampedLength = min(range.length, attributed.length - range.location)
        guard clampedLength > 0 else { return false }
        let scanRange = NSRange(location: range.location, length: clampedLength)
        var found = false
        attributed.enumerateAttribute(
            .kbdTag,
            in: scanRange,
            options: []
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Detect whether a block renders to zero content length.
    /// Used to style the separator before an empty block so the
    /// cursor lands with the right paragraph attributes on the empty line.
    fileprivate static func isEmptyParagraph(_ block: Block) -> Bool {
        guard case .paragraph(let inline) = block else { return false }
        if inline.isEmpty { return true }
        // A single empty text node also counts as empty.
        if inline.count == 1, case .text(let s) = inline[0], s.isEmpty {
            return true
        }
        return false
    }

    /// Map a `Block` case to the `BlockModelKind` used for TK2 element
    /// dispatch. Returns nil for blocks that stay on the NSTextAttachment
    /// path (tables — Phase 2e) or render to zero content (blank lines).
    /// `htmlBlock` is grouped with `codeBlock` because both render via
    /// the code-block renderer and layout identically.
    fileprivate static func blockModelKind(
        for block: Block,
        editingCodeBlocks: Set<BlockRef> = []
    ) -> BlockModelKind? {
        switch block {
        case .paragraph(let inline):
            // A paragraph whose sole inline is `.displayMath` is
            // rendered as a centered pseudo-block equation via
            // `DisplayMathLayoutFragment`. Paragraphs containing
            // display math PLUS other content fall through to
            // `.paragraph` (the display-math attachment path is
            // retained for mixed-content paragraphs).
            if inline.count == 1, case .displayMath = inline[0] {
                return .displayMath
            }
            return .paragraph  // upgraded to .paragraphWithKbd in tagging pass if needed
        case .heading: return .heading
        case .list: return .list
        case .blockquote: return .blockquote
        case .codeBlock(let language, _, _):
            // Code-Block Edit Toggle (slice 1): when this block is in
            // editing form, downgrade mermaid/math → regular .codeBlock
            // so `CodeBlockLayoutFragment` (not `MermaidLayoutFragment`
            // / `MathLayoutFragment`) handles display. This is the
            // entire mermaid/math editing-form routing — no attachment
            // mutation, no fragment branching.
            if editingCodeBlocks.contains(BlockRef(block)) {
                return .codeBlock
            }
            switch language?.lowercased() {
            case "mermaid": return .mermaid
            case "math", "latex": return .math
            default: return .codeBlock
            }
        case .htmlBlock: return .codeBlock
        case .horizontalRule: return .horizontalRule
        case .table: return nil
        case .blankLine: return nil
        }
    }
}
