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
//  Block coverage (skeleton):
//    * `.paragraph` — inline content with inline markers
//      (`**bold**`, `_italic_`, `` `code` ``, etc.) re-injected around
//      the `InlineRenderer` output and tagged.
//    * `.heading(level:, suffix:)` — `# `…`###### ` prefix tagged.
//    * `.codeBlock(language:, content:, fence:)` — fence lines tagged;
//      content rendered in the code font untagged.
//    * `.blockquote(lines:)` — `> ` prefix per line tagged; inline
//      content rendered with inline markers re-injected.
//    * `.horizontalRule` — whole `---` line tagged as marker.
//
//  Remaining block kinds (`.list`, `.table`, `.htmlBlock`, `.blankLine`)
//  fall through to a visible placeholder marker so a dogfood run with
//  the flag on surfaces the gap immediately. Phase 4.4 adds them.
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
        _ = theme  // reserved for Phase 4.4 wire-up
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
            out.append(markerString(prefix, font: bodyFont))
            // The parser preserves the heading suffix verbatim,
            // including the leading space. The space itself is part of
            // the ATX-heading marker surface, but it's also the
            // separator between marker and content — we tag the single
            // leading space character as a marker and leave the rest as
            // content. If suffix is empty (e.g. "###" with nothing
            // after), there is no leading space to tag.
            if suffix.hasPrefix(" ") {
                out.append(markerString(" ", font: bodyFont))
                let rest = String(suffix.dropFirst())
                // Heading content may carry inline markers
                // (`# **bold**`) — re-inject them.
                let inlineContent = MarkdownParser.parseInlines(rest, refDefs: [:])
                out.append(
                    reinjectInlineMarkers(
                        inlineContent,
                        baseAttrs: [.font: bodyFont]
                    )
                )
            } else {
                // No leading space — still parse suffix as inline.
                let inlineContent = MarkdownParser.parseInlines(suffix, refDefs: [:])
                out.append(
                    reinjectInlineMarkers(
                        inlineContent,
                        baseAttrs: [.font: bodyFont]
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

        case .list, .table, .htmlBlock:
            // Phase 4.1 skeleton — not yet implemented. Emit a visible
            // placeholder tagged fully as a marker so a dogfood run
            // with `FeatureFlag.useSourceRendererV2 = true` surfaces
            // the gap on-screen instead of silently dropping content.
            // Phase 4.4 adds full coverage.
            let kind: String
            switch block {
            case .list: kind = "list"
            case .table: kind = "table"
            case .htmlBlock: kind = "htmlBlock"
            default: kind = "unknown"
            }
            return markerString(
                "⟨4.1-skeleton: unsupported block type \(kind)⟩",
                font: bodyFont
            )
        }
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
