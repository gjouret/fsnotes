//
//  DocumentHTMLRenderer.swift
//  FSNotes Tests
//
//  Pure deterministic HTML serializer for the block-model Document.
//  Used as a test oracle: corpus files render to HTML and are string-diffed
//  against committed reference HTML. Not for display.
//
//  Rules:
//  - Identical input produces byte-equal output. No dictionary iteration.
//  - Indented output (2-space) for readable diffs.
//  - One block per top-level element.
//  - Pure function; Foundation only.
//

import Foundation
@testable import FSNotes

public enum DocumentHTMLRenderer {
    /// Deterministic HTML serialization of a Document. Not for display —
    /// used as a test-oracle string we diff against reference output.
    public static func render(_ document: Document) -> String {
        var out = ""
        for block in document.blocks {
            renderBlock(block, indent: 0, into: &out)
        }
        return out
    }

    // MARK: - Block rendering

    private static func renderBlock(_ block: Block, indent: Int, into out: inout String) {
        let pad = indentString(indent)
        switch block {
        case .paragraph(let inline):
            out += pad + "<p>" + renderInlines(inline) + "</p>\n"

        case .heading(let level, let suffix):
            // TODO: phase 0 — heading suffix rendered as plain text.
            // Future: parse `suffix` as inline content via MarkdownParser.
            let n = max(1, min(6, level))
            let text = suffix.trimmingCharacters(in: .whitespaces)
            out += pad + "<h\(n)>" + escape(text) + "</h\(n)>\n"

        case .codeBlock(let language, let content, _):
            let langAttr: String
            if let lang = language, !lang.isEmpty {
                langAttr = " class=\"language-\(escapeAttr(lang))\""
            } else {
                langAttr = ""
            }
            out += pad + "<pre><code\(langAttr)>" + escape(content) + "</code></pre>\n"

        case .list(let items, let loose):
            renderList(items: items, loose: loose, indent: indent, into: &out)

        case .blockquote(let lines):
            renderBlockquote(lines: lines, indent: indent, into: &out)

        case .horizontalRule:
            out += pad + "<hr>\n"

        case .htmlBlock(let raw):
            // Verbatim, ensure trailing newline.
            out += raw
            if !raw.hasSuffix("\n") { out += "\n" }

        case .table(let header, let alignments, let rows, _):
            renderTable(header: header, alignments: alignments, rows: rows,
                        indent: indent, into: &out)

        case .blankLine:
            // Blocks are separated by their own newlines; nothing to emit.
            break
        }
    }

    // MARK: - Lists

    private static func renderList(items: [ListItem], loose: Bool, indent: Int,
                                   into out: inout String) {
        guard let first = items.first else { return }
        let isOrdered = isOrderedMarker(first.marker)
        let pad = indentString(indent)
        let tag = isOrdered ? "ol" : "ul"

        var openTag = "<\(tag)"
        if isOrdered, let start = orderedStart(first.marker), start != 1 {
            openTag += " start=\"\(start)\""
        }
        openTag += ">"
        out += pad + openTag + "\n"

        for item in items {
            renderListItem(item, loose: loose, indent: indent + 1, into: &out)
        }

        out += pad + "</\(tag)>\n"
    }

    private static func renderListItem(_ item: ListItem, loose: Bool, indent: Int,
                                       into out: inout String) {
        let pad = indentString(indent)
        let innerPad = indentString(indent + 1)
        let inlineHTML = renderInlines(item.inline)

        // Checkbox prefix if present.
        var bodyHTML = ""
        if let cb = item.checkbox {
            let checkedAttr = cb.isChecked ? " checked" : ""
            bodyHTML += "<input type=\"checkbox\"\(checkedAttr) disabled> "
        }
        bodyHTML += inlineHTML

        let hasChildren = !item.children.isEmpty

        if !hasChildren && !loose {
            // Tight, leaf item: single-line <li>...</li>
            out += pad + "<li>" + bodyHTML + "</li>\n"
            return
        }

        // Multi-line item.
        out += pad + "<li>\n"
        if loose {
            out += innerPad + "<p>" + bodyHTML + "</p>\n"
        } else {
            out += innerPad + bodyHTML + "\n"
        }

        if hasChildren {
            // Group consecutive children by marker kind (ordered vs unordered)
            // so mixed nesting still produces valid HTML. Pure, order-preserving.
            var buffer: [ListItem] = []
            var bufferOrdered: Bool? = nil
            for child in item.children {
                let childOrdered = isOrderedMarker(child.marker)
                if let b = bufferOrdered, b != childOrdered {
                    renderList(items: buffer, loose: loose,
                               indent: indent + 1, into: &out)
                    buffer.removeAll()
                }
                buffer.append(child)
                bufferOrdered = childOrdered
            }
            if !buffer.isEmpty {
                renderList(items: buffer, loose: loose,
                           indent: indent + 1, into: &out)
            }
        }
        out += pad + "</li>\n"
    }

    private static func isOrderedMarker(_ marker: String) -> Bool {
        guard let last = marker.last else { return false }
        return last == "." || last == ")"
    }

    private static func orderedStart(_ marker: String) -> Int? {
        // Strip trailing "." or ")"; parse integer part.
        var digits = marker
        if let last = digits.last, last == "." || last == ")" {
            digits.removeLast()
        }
        return Int(digits)
    }

    // MARK: - Blockquote

    private static func renderBlockquote(lines: [BlockquoteLine], indent: Int,
                                         into out: inout String) {
        let pad = indentString(indent)
        let innerPad = indentString(indent + 1)
        out += pad + "<blockquote>\n"
        if !lines.isEmpty {
            // CommonMark: consecutive lines form one paragraph joined by <br>.
            let parts = lines.map { renderInlines($0.inline) }
            out += innerPad + "<p>" + parts.joined(separator: "<br>") + "</p>\n"
        }
        out += pad + "</blockquote>\n"
    }

    // MARK: - Table

    private static func renderTable(header: [TableCell], alignments: [TableAlignment],
                                    rows: [[TableCell]], indent: Int,
                                    into out: inout String) {
        let pad = indentString(indent)
        let p1 = indentString(indent + 1)
        let p2 = indentString(indent + 2)
        let p3 = indentString(indent + 3)

        out += pad + "<table>\n"
        out += p1 + "<thead>\n"
        out += p2 + "<tr>\n"
        for (i, cell) in header.enumerated() {
            let align = i < alignments.count ? alignments[i] : .none
            let alignAttr = alignAttribute(align)
            out += p3 + "<th\(alignAttr)>" + renderInlines(cell.inline) + "</th>\n"
        }
        out += p2 + "</tr>\n"
        out += p1 + "</thead>\n"
        out += p1 + "<tbody>\n"
        for row in rows {
            out += p2 + "<tr>\n"
            for (i, cell) in row.enumerated() {
                let align = i < alignments.count ? alignments[i] : .none
                let alignAttr = alignAttribute(align)
                out += p3 + "<td\(alignAttr)>" + renderInlines(cell.inline) + "</td>\n"
            }
            out += p2 + "</tr>\n"
        }
        out += p1 + "</tbody>\n"
        out += pad + "</table>\n"
    }

    private static func alignAttribute(_ a: TableAlignment) -> String {
        switch a {
        case .left:   return " align=\"left\""
        case .center: return " align=\"center\""
        case .right:  return " align=\"right\""
        case .none:   return ""
        }
    }

    // MARK: - Inline rendering

    private static func renderInlines(_ inlines: [Inline]) -> String {
        var s = ""
        for inline in inlines {
            s += renderInline(inline)
        }
        return s
    }

    private static func renderInline(_ inline: Inline) -> String {
        switch inline {
        case .text(let t):
            return escape(t)

        case .bold(let children, _):
            return "<strong>" + renderInlines(children) + "</strong>"

        case .italic(let children, _):
            return "<em>" + renderInlines(children) + "</em>"

        case .strikethrough(let children):
            return "<del>" + renderInlines(children) + "</del>"

        case .code(let s):
            return "<code>" + escape(s) + "</code>"

        case .link(let text, let rawDest):
            return "<a href=\"" + escapeAttr(rawDest) + "\">" + renderInlines(text) + "</a>"

        case .image(let alt, let rawDest, let width):
            let altText = flattenToPlainText(alt)
            var tag = "<img src=\"" + escapeAttr(rawDest) + "\" alt=\"" + escapeAttr(altText) + "\""
            if let w = width {
                tag += " width=\"\(w)\""
            }
            tag += ">"
            return tag

        case .autolink(let text, let isEmail):
            let href = isEmail ? "mailto:\(text)" : text
            return "<a href=\"" + escapeAttr(href) + "\">" + escape(text) + "</a>"

        case .escapedChar(let c):
            return escape(String(c))

        case .lineBreak:
            return "<br>"

        case .rawHTML(let s):
            return s

        case .entity(let s):
            return s

        case .underline(let children):
            return "<u>" + renderInlines(children) + "</u>"

        case .highlight(let children):
            return "<mark>" + renderInlines(children) + "</mark>"

        case .superscript(let children):
            return "<sup>" + renderInlines(children) + "</sup>"

        case .subscript(let children):
            return "<sub>" + renderInlines(children) + "</sub>"

        case .kbd(let children):
            return "<kbd>" + renderInlines(children) + "</kbd>"

        case .math(let s):
            return "<span class=\"math-inline\">" + escape(s) + "</span>"

        case .displayMath(let s):
            return "<div class=\"math-display\">" + escape(s) + "</div>"

        case .wikilink(let target, let display):
            let shown = display ?? target
            return "<a class=\"wikilink\" href=\"" + escapeAttr(target) + "\">" + escape(shown) + "</a>"
        }
    }

    /// Flatten an inline tree to plain text (for `<img alt="...">` values).
    private static func flattenToPlainText(_ inlines: [Inline]) -> String {
        var s = ""
        for inline in inlines {
            s += flattenOne(inline)
        }
        return s
    }

    private static func flattenOne(_ inline: Inline) -> String {
        switch inline {
        case .text(let t): return t
        case .bold(let c, _), .italic(let c, _), .strikethrough(let c),
             .underline(let c), .highlight(let c),
             .superscript(let c), .subscript(let c), .kbd(let c):
            return flattenToPlainText(c)
        case .code(let s): return s
        case .link(let text, _): return flattenToPlainText(text)
        case .image(let alt, _, _): return flattenToPlainText(alt)
        case .autolink(let t, _): return t
        case .escapedChar(let c): return String(c)
        case .lineBreak: return " "
        case .rawHTML(let s): return s
        case .entity(let s): return s
        case .math(let s), .displayMath(let s): return s
        case .wikilink(let target, let display): return display ?? target
        }
    }

    // MARK: - Escaping

    /// HTML-escape text content: `&`, `<`, `>` only. Quotes pass through.
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(c)
            }
        }
        return out
    }

    /// HTML-escape attribute values: `&`, `<`, `>`, `"`, `'`.
    private static func escapeAttr(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(c)
            }
        }
        return out
    }

    // MARK: - Indentation

    private static func indentString(_ level: Int) -> String {
        if level <= 0 { return "" }
        return String(repeating: "  ", count: level)
    }
}
