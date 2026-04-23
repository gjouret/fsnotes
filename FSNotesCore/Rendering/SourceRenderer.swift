//
//  SourceRenderer.swift
//  FSNotesCore
//
//  Phase 4.1 (dormant additive slice) — sibling of `DocumentRenderer`
//  that renders a `Document` to an attributed string WITH visible
//  markdown markers (e.g. `#`, `**`, backticks, `>`, `---`) tagged via
//  the `.markerRange` attribute. Marker color is not set here;
//  `SourceLayoutFragment` paints those runs in
//  `Theme.shared.chrome.sourceMarker` at draw time without mutating the
//  storage's `.foregroundColor`.
//
//  WYSIWYG vs. source mode — the split:
//    * `DocumentRenderer` (existing) is the WYSIWYG path: renders
//      `Document` to attributed text with NO markers. The block model
//      stays fully parsed and the user sees bold/italic/headings as
//      visual formatting.
//    * `SourceRenderer` (this file) is the source-mode path: renders
//      `Document` to attributed text WITH every marker the parser
//      consumed, so the user sees the raw markdown with syntax
//      highlighting. Marker runs are tagged with `.markerRange`; the
//      fragment paints them in a distinct color.
//
//  This file is DORMANT in Phase 4.1 — no call site reads
//  `FeatureFlag.useSourceRendererV2` yet. Phase 4.4 wires the flag on,
//  deletes the `NotesTextProcessor.highlight*` path, and makes this
//  renderer the live source-mode path.
//
//  Block coverage (Phase 4.4 — complete):
//    * `.paragraph` — inline content with inline markers
//      (`**bold**`, `_italic_`, `` `code` ``, etc.) re-injected around
//      the `InlineRenderer` output and tagged.
//    * `.heading(level:, suffix:)` — `# `…`###### ` prefix tagged.
//    * `.codeBlock(language:, content:, fence:)` — fence lines tagged;
//      content rendered in the code font untagged.
//    * `.blockquote(lines:)` — `> ` prefix per line tagged; inline
//      content rendered with inline markers re-injected.
//    * `.horizontalRule` — whole `---` line tagged as marker.
//    * `.list(items:, loose:)` — each item's indent + marker + optional
//      checkbox tagged; inline content re-injected; nested children
//      recurse with deeper indentation preserved.
//    * `.table(header:, alignments:, rows:, columnWidths:)` — pipes
//      and alignment-row markers (`:---:`) tagged; cell inline content
//      re-injected between tags.
//    * `.htmlBlock(raw:)` — whole raw HTML content tagged as marker
//      (source mode shows raw HTML, not rendered).
//    * `.blankLine` — emits empty string; block-join layer supplies
//      the separator newlines.
//
//  Rule 7 conscience:
//    * No marker-hiding via zero-size fonts or `.clear` foreground.
//    * No regex-based inline re-parsing — inline content flows through
//      `InlineRenderer.render` (WYSIWYG-side) plus a pure marker-re-
//      injection helper that walks the `[Inline]` tree directly.
//    * No view-reads-into-model — this file is a pure function on
//      `Document` values.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum SourceRenderer {

    /// Render a `Document` with visible markdown markers.
    ///
    /// - Parameter document: the parsed block model to render.
    /// - Parameter bodyFont: base font applied to paragraph / heading /
    ///   blockquote text.
    /// - Parameter codeFont: monospace font applied to fenced-code block
    ///   bodies (NOT to inline code spans — those use their own derived
    ///   font via the inline marker helper).
    /// - Parameter theme: active theme. Unused in this skeleton slice
    ///   (all marker coloring is deferred to `SourceLayoutFragment`),
    ///   threaded through so Phase 4.4 can pull typography multipliers
    ///   for inline code / kbd / etc. when it goes live.
    /// - Returns: an `NSAttributedString` containing the full source
    ///   text of `document`, block-joined by the CommonMark blank-line
    ///   separator. Every marker run carries `.markerRange = NSNull()`.
    public static func render(
        _ document: Document,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        theme: Theme = .shared
    ) -> NSAttributedString {
        _ = theme  // reserved for richer per-block theming
        let out = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 {
                out.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [.font: bodyFont]
                    )
                )
            }
            out.append(render(block: block, bodyFont: bodyFont, codeFont: codeFont))
        }

        // Preserve the document's trailing newline for byte-exact
        // round-trip with the source string. Without this, re-rendering
        // a document whose source ends with "\n" produces a shorter
        // attributed string and `reapplySourceRendererAttributes`
        // would mis-align with live storage.
        if document.trailingNewline {
            out.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [.font: bodyFont]
                )
            )
        }

        // Phase 4.4: tag the full rendered range with
        // `.blockModelKind = .sourceMarkdown` so the TK2 content-storage
        // delegate dispatches every paragraph to `SourceMarkdownElement`
        // → `SourceLayoutFragment` (marker-colour overpaint). Tables
        // / code blocks / mermaid / math in SOURCE mode stay as
        // plain-paragraph source text — the user is looking at raw
        // markdown, not the rendered widget. This differs from
        // `DocumentRenderer` which emits per-block kinds (`.heading`,
        // `.codeBlock`, `.table`, etc.) for WYSIWYG block dispatch.
        let fullRange = NSRange(location: 0, length: out.length)
        if fullRange.length > 0 {
            out.addAttribute(
                .blockModelKind,
                value: BlockModelKind.sourceMarkdown.rawValue,
                range: fullRange
            )
        }
        return out
    }

    // MARK: - Per-block dispatch

    private static func render(
        block: Block,
        bodyFont: PlatformFont,
        codeFont: PlatformFont
    ) -> NSAttributedString {
        switch block {
        case .paragraph(let inline):
            return reinjectInlineMarkers(inline, baseAttrs: [.font: bodyFont])

        case .heading(let level, let suffix):
            let out = NSMutableAttributedString()
            let prefix = String(repeating: "#", count: level)
            // Heading body font: scaled + bold per level. Source mode
            // shows the raw markdown but still renders with the header
            // font so the heading visually stands out. The prefix
            // marker and its trailing space carry the SAME header font
            // so the `#` characters don't look shrunken next to the
            // heading content.
            let headerFont = NotesTextProcessor.getHeaderFont(
                level: level,
                baseFont: bodyFont,
                baseFontSize: bodyFont.pointSize
            )
            out.append(markerString(prefix, font: headerFont))
            // The parser preserves the heading suffix verbatim,
            // including the leading space. The space itself is part of
            // the ATX-heading marker surface, but it's also the
            // separator between marker and content — we tag the single
            // leading space character as a marker and leave the rest as
            // content. If suffix is empty (e.g. "###" with nothing
            // after), there is no leading space to tag.
            if suffix.hasPrefix(" ") {
                out.append(markerString(" ", font: headerFont))
                let rest = String(suffix.dropFirst())
                // Heading content may carry inline markers
                // (`# **bold**`) — re-inject them.
                let inlineContent = MarkdownParser.parseInlines(rest, refDefs: [:])
                out.append(
                    reinjectInlineMarkers(
                        inlineContent,
                        baseAttrs: [.font: headerFont]
                    )
                )
            } else {
                // No leading space — still parse suffix as inline.
                let inlineContent = MarkdownParser.parseInlines(suffix, refDefs: [:])
                out.append(
                    reinjectInlineMarkers(
                        inlineContent,
                        baseAttrs: [.font: headerFont]
                    )
                )
            }
            return out

        case .codeBlock(_, let content, let fence):
            let out = NSMutableAttributedString()
            let fenceChar: String = fence.character == .backtick ? "`" : "~"
            let fenceString = String(repeating: fenceChar, count: fence.length)
            // Opening fence + info-string on its own line. The info
            // string is part of the fence syntax — tag the whole
            // opening line as a marker.
            out.append(markerString(fenceString + fence.infoRaw, font: codeFont))
            out.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [.font: codeFont]
                )
            )
            if !content.isEmpty {
                out.append(
                    NSAttributedString(
                        string: content,
                        attributes: [.font: codeFont]
                    )
                )
                out.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [.font: codeFont]
                    )
                )
            }
            out.append(markerString(fenceString, font: codeFont))
            return out

        case .blockquote(let lines):
            let out = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    out.append(
                        NSAttributedString(
                            string: "\n",
                            attributes: [.font: bodyFont]
                        )
                    )
                }
                // The blockquote line prefix is literal `>` characters
                // and spaces captured verbatim from the source. Tag
                // the whole prefix as a marker.
                if !line.prefix.isEmpty {
                    out.append(markerString(line.prefix, font: bodyFont))
                }
                out.append(
                    reinjectInlineMarkers(
                        line.inline,
                        baseAttrs: [.font: bodyFont]
                    )
                )
            }
            return out

        case .horizontalRule(let character, let length):
            // Canonical representation — a run of the source character
            // on its own line. Whole line is marker.
            let rule = String(repeating: String(character), count: max(length, 3))
            return markerString(rule, font: bodyFont)

        case .blankLine:
            // The block-join layer inserts a "\n" before this block,
            // which — combined with the preceding block's trailing
            // newline behavior — produces a blank line. Emit nothing
            // further.
            return NSAttributedString(
                string: "",
                attributes: [.font: bodyFont]
            )

        case .list(let items, _):
            return renderList(items: items, bodyFont: bodyFont)

        case .table(let header, let alignments, let rows, _):
            return renderTable(
                header: header,
                alignments: alignments,
                rows: rows,
                bodyFont: bodyFont
            )

        case .htmlBlock(let raw):
            // Source mode shows raw HTML. Tag the entire raw content
            // as marker — every character is syntax surface from the
            // user's point of view.
            return markerString(raw, font: bodyFont)
        }
    }

    // MARK: - List rendering

    /// Render a list as source text. Each item emits its exact source
    /// prefix (`indent` + `marker` + `afterMarker` + optional checkbox)
    /// tagged as marker, followed by the item's inline content with
    /// inline markers re-injected, followed by any nested children on
    /// subsequent lines.
    private static func renderList(
        items: [ListItem],
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (idx, item) in items.enumerated() {
            if idx > 0 {
                // Per-item `blankLineBefore` drives tight/loose spacing
                // in the source — mirror the serializer's logic so
                // source-mode output round-trips byte-identically with
                // `MarkdownSerializer.serialize`.
                let sep = item.blankLineBefore ? "\n\n" : "\n"
                out.append(
                    NSAttributedString(
                        string: sep,
                        attributes: [.font: bodyFont]
                    )
                )
            }
            out.append(renderListItem(item, bodyFont: bodyFont))
        }
        return out
    }

    private static func renderListItem(
        _ item: ListItem,
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // Leading indent — whitespace only, safe to emit as a plain
        // (non-marker) run. It's the marker that carries the syntax;
        // indentation is layout.
        if !item.indent.isEmpty {
            out.append(
                NSAttributedString(
                    string: item.indent,
                    attributes: [.font: bodyFont]
                )
            )
        }

        // Marker + separator whitespace (e.g. "- ", "1. ") — marker.
        out.append(markerString(item.marker + item.afterMarker, font: bodyFont))

        // Optional checkbox (e.g. "[ ] ", "[x] ") — marker.
        if let cb = item.checkbox {
            out.append(markerString(cb.text + cb.afterText, font: bodyFont))
        }

        // Item inline content.
        out.append(
            reinjectInlineMarkers(
                item.inline,
                baseAttrs: [.font: bodyFont]
            )
        )

        // Nested children on subsequent lines, separator "\n" per child
        // (children use their own `blankLineBefore` at the child-list
        // level, but at the item level we mirror the serializer which
        // joins children with "\n").
        if !item.children.isEmpty {
            for child in item.children {
                out.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [.font: bodyFont]
                    )
                )
                out.append(renderListItem(child, bodyFont: bodyFont))
            }
        }
        return out
    }

    // MARK: - Table rendering

    /// Render a table as canonical pipe-delimited source text. Pipes
    /// and alignment-row separators are tagged as marker; cell inline
    /// content between pipes is re-rendered via `reinjectInlineMarkers`
    /// so inline formatting markers (`**bold**`, `*italic*`, etc.)
    /// inside cells also appear tagged.
    ///
    /// The output matches `EditingOps.rebuildTableRaw` byte-for-byte
    /// modulo the embedded inline markers (which the raw serializer
    /// emits as plain text): each cell is padded with a single space
    /// on each side of its inline content, separated by `|`, with the
    /// canonical alignment row between header and body.
    private static func renderTable(
        header: [TableCell],
        alignments: [TableAlignment],
        rows: [[TableCell]],
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headerColCount = header.count

        // Render a single row matching `rebuildTableRaw.renderRow`:
        //   "|" + cells.joined(separator: "|") + "|"
        // where each cell is padded with a leading + trailing space
        // around its inline content. Pipes are marker-tagged; cell
        // content is re-injected via the inline helper so inline
        // formatting markers inside cells also appear tagged.
        func appendRow(_ cells: [TableCell]) {
            if cells.isEmpty {
                out.append(markerString("|", font: bodyFont))
                return
            }
            out.append(markerString("|", font: bodyFont))
            for cell in cells {
                out.append(
                    NSAttributedString(
                        string: " ",
                        attributes: [.font: bodyFont]
                    )
                )
                out.append(
                    reinjectInlineMarkers(
                        cell.inline,
                        baseAttrs: [.font: bodyFont]
                    )
                )
                out.append(
                    NSAttributedString(
                        string: " ",
                        attributes: [.font: bodyFont]
                    )
                )
                out.append(markerString("|", font: bodyFont))
            }
        }

        // Header row.
        appendRow(header)
        out.append(
            NSAttributedString(
                string: "\n",
                attributes: [.font: bodyFont]
            )
        )

        // Alignment row: whole line is marker syntax. Matches the
        // exact shape `rebuildTableRaw.renderSeparator` produces
        // (`---`, `:---`, `---:`, `:---:` per column, `|`-separated).
        var effective = alignments
        while effective.count < headerColCount { effective.append(.none) }
        if effective.count > headerColCount {
            effective = Array(effective.prefix(headerColCount))
        }
        let separatorCells = effective.map { alignment -> String in
            switch alignment {
            case .none:   return "---"
            case .left:   return ":---"
            case .right:  return "---:"
            case .center: return ":---:"
            }
        }
        let separatorRow: String
        if separatorCells.isEmpty {
            separatorRow = "|"
        } else {
            separatorRow = "|" + separatorCells.joined(separator: "|") + "|"
        }
        out.append(markerString(separatorRow, font: bodyFont))

        // Body rows. `rebuildTableRaw` pads/truncates each row to the
        // header's column count — mirror that for byte-exact match.
        for row in rows {
            out.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [.font: bodyFont]
                )
            )
            var padded = row
            while padded.count < headerColCount {
                padded.append(TableCell([]))
            }
            if padded.count > headerColCount {
                padded = Array(padded.prefix(headerColCount))
            }
            appendRow(padded)
        }
        return out
    }

    // MARK: - Inline marker re-injection

    /// Walk the `[Inline]` tree and emit the source text with every
    /// marker (`**`, `_`, `` ` ``, `~~`, `[`, `]`, `(`, `)`, `<tag>`,
    /// `$`, `$$`, etc.) tagged via `.markerRange`. Content characters
    /// between markers carry `baseAttrs` only.
    ///
    /// This is the pure inverse of the parser's inline consumption step
    /// for the marker surface. It is NOT a full `InlineRenderer`
    /// replacement — link destinations, autolinks, rawHTML, entities,
    /// escape characters, hard breaks, and math carry their source
    /// text literally with the whole run tagged as a marker (since the
    /// user sees those as syntax in source mode).
    ///
    /// Nested structure (`**_bold italic_**`) works via recursion.
    public static func reinjectInlineMarkers(
        _ inlines: [Inline],
        baseAttrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for inline in inlines {
            out.append(reinjectMarker(inline, baseAttrs: baseAttrs))
        }
        return out
    }

    private static func reinjectMarker(
        _ inline: Inline,
        baseAttrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        switch inline {
        case .text(let s):
            out.append(NSAttributedString(string: s, attributes: baseAttrs))

        case .bold(let children, let marker):
            let m = marker == .underscore ? "__" : "**"
            out.append(markerString(m, attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString(m, attrs: baseAttrs))

        case .italic(let children, let marker):
            let m = marker == .underscore ? "_" : "*"
            out.append(markerString(m, attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString(m, attrs: baseAttrs))

        case .strikethrough(let children):
            out.append(markerString("~~", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString("~~", attrs: baseAttrs))

        case .code(let content):
            out.append(markerString("`", attrs: baseAttrs))
            out.append(NSAttributedString(string: content, attributes: baseAttrs))
            out.append(markerString("`", attrs: baseAttrs))

        case .link(let text, let rawDest):
            out.append(markerString("[", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(text, baseAttrs: baseAttrs))
            out.append(markerString("](" + rawDest + ")", attrs: baseAttrs))

        case .image(let alt, let rawDest, _):
            out.append(markerString("![", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(alt, baseAttrs: baseAttrs))
            out.append(markerString("](" + rawDest + ")", attrs: baseAttrs))

        case .autolink(let text, _):
            out.append(markerString("<" + text + ">", attrs: baseAttrs))

        case .escapedChar(let ch):
            out.append(markerString("\\" + String(ch), attrs: baseAttrs))

        case .lineBreak(let raw):
            // Hard line breaks look like "  \n" or "\\\n" — whole run
            // is marker syntax.
            out.append(markerString(raw, attrs: baseAttrs))

        case .rawHTML(let html):
            out.append(markerString(html, attrs: baseAttrs))

        case .entity(let raw):
            out.append(markerString(raw, attrs: baseAttrs))

        case .underline(let children):
            out.append(markerString("<u>", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString("</u>", attrs: baseAttrs))

        case .highlight(let children):
            out.append(markerString("<mark>", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString("</mark>", attrs: baseAttrs))

        case .superscript(let children):
            out.append(markerString("<sup>", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString("</sup>", attrs: baseAttrs))

        case .`subscript`(let children):
            out.append(markerString("<sub>", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString("</sub>", attrs: baseAttrs))

        case .kbd(let children):
            out.append(markerString("<kbd>", attrs: baseAttrs))
            out.append(reinjectInlineMarkers(children, baseAttrs: baseAttrs))
            out.append(markerString("</kbd>", attrs: baseAttrs))

        case .math(let content):
            out.append(markerString("$", attrs: baseAttrs))
            out.append(NSAttributedString(string: content, attributes: baseAttrs))
            out.append(markerString("$", attrs: baseAttrs))

        case .displayMath(let content):
            out.append(markerString("$$", attrs: baseAttrs))
            out.append(NSAttributedString(string: content, attributes: baseAttrs))
            out.append(markerString("$$", attrs: baseAttrs))

        case .wikilink(let target, let display):
            out.append(markerString("[[", attrs: baseAttrs))
            if let display = display {
                out.append(NSAttributedString(string: target, attributes: baseAttrs))
                out.append(markerString("|", attrs: baseAttrs))
                out.append(NSAttributedString(string: display, attributes: baseAttrs))
            } else {
                out.append(NSAttributedString(string: target, attributes: baseAttrs))
            }
            out.append(markerString("]]", attrs: baseAttrs))
        }
        return out
    }

    // MARK: - Marker attribute helpers

    /// Build an attributed string whose every character carries
    /// `.markerRange = NSNull()` plus the supplied base attributes.
    private static func markerString(
        _ text: String,
        font: PlatformFont
    ) -> NSAttributedString {
        return markerString(text, attrs: [.font: font])
    }

    private static func markerString(
        _ text: String,
        attrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var merged = attrs
        merged[.markerRange] = NSNull()
        return NSAttributedString(string: text, attributes: merged)
    }
}
