//
//  MarkdownSerializer.swift
//  FSNotesCore
//
//  Document -> markdown text. The inverse of MarkdownParser.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: Document (block model).
//  - Output: raw markdown string suitable for writing to a .md file.
//  - Round-trip: serialize(parse(x)) == x, byte-equal.
//

import Foundation

public enum MarkdownSerializer {

    /// Serialize a Document to markdown text. Round-trips with
    /// MarkdownParser.parse: serialize(parse(x)) == x.
    public static func serialize(_ document: Document) -> String {
        // Each block serializes to a string with NO trailing newline.
        // We join with "\n" to insert the separator between blocks.
        // A trailing blankLine block becomes an empty string, and the
        // join places a "\n" before it, producing the final newline.
        let parts = document.blocks.map { serialize(block: $0) }
        let joined = parts.joined(separator: "\n")
        return document.trailingNewline ? joined + "\n" : joined
    }

    private static func serialize(block: Block) -> String {
        switch block {
        case .codeBlock(_, let content, let fence):
            let fenceChar: Character = fence.character == .backtick ? "`" : "~"
            let fenceString = String(repeating: String(fenceChar), count: fence.length)
            let openLine = fenceString + fence.infoRaw
            // Content is stored with no trailing newline; the closing
            // fence sits on its own line, joined to content by "\n".
            if content.isEmpty {
                return openLine + "\n" + fenceString
            }
            return openLine + "\n" + content + "\n" + fenceString

        case .heading(let level, let suffix):
            // Suffix already carries the leading space (or is empty for
            // "###" with no content) — emit markers + suffix verbatim.
            return String(repeating: "#", count: level) + suffix

        case .paragraph(let inline):
            return serializeInlines(inline)

        case .list(let items, _):
            // Use per-item blankLineBefore for round-trip fidelity:
            // items that followed blank lines in the source get "\n\n"
            // separator; others get "\n".
            var result = ""
            for (idx, item) in items.enumerated() {
                if idx > 0 {
                    result += item.blankLineBefore ? "\n\n" : "\n"
                }
                result += serializeItem(item)
            }
            return result

        case .blockquote(let qLines):
            return qLines
                .map { $0.prefix + serializeInlines($0.inline) }
                .joined(separator: "\n")

        case .horizontalRule(let character, let length):
            return String(repeating: character, count: length)

        case .htmlBlock(let raw):
            return raw

        case .table(_, _, _, let raw):
            // Round-trip: emit the exact source text that was parsed.
            return raw

        case .blankLine:
            return ""
        }
    }

    /// Serialize a list item and its nested children. Each item
    /// reproduces its original source prefix exactly: indent +
    /// marker + afterMarker + inline content. Children are emitted
    /// on subsequent lines, joined by "\n".
    private static func serializeItem(_ item: ListItem) -> String {
        let cbPart: String
        if let cb = item.checkbox {
            cbPart = cb.text + cb.afterText
        } else {
            cbPart = ""
        }
        let firstLine = item.indent + item.marker + item.afterMarker
            + cbPart + serializeInlines(item.inline)
        if item.children.isEmpty { return firstLine }
        let childLines = item.children.map { serializeItem($0) }
            .joined(separator: "\n")
        return firstLine + "\n" + childLines
    }

    /// Serialize an inline tree back to markdown source. Re-emits the
    /// exact marker characters the parser consumed so round-trip is
    /// byte-equal.
    static func serializeInlines(_ inlines: [Inline]) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case .text(let s):
                out += s
            case .bold(let children, let marker):
                let m = marker == .underscore ? "__" : "**"
                out += m + serializeInlines(children) + m
            case .italic(let children, let marker):
                let m = marker == .underscore ? "_" : "*"
                out += m + serializeInlines(children) + m
            case .strikethrough(let children):
                out += "~~" + serializeInlines(children) + "~~"
            case .code(let s):
                out += "`" + s + "`"
            case .link(let text, let rawDest):
                out += "[" + serializeInlines(text) + "](" + rawDest + ")"
            case .image(let alt, let rawDest):
                out += "![" + serializeInlines(alt) + "](" + rawDest + ")"
            case .autolink(let text, _):
                out += "<" + text + ">"
            case .escapedChar(let ch):
                out += "\\" + String(ch)
            case .lineBreak(let raw):
                out += raw
            case .rawHTML(let html):
                out += html
            case .entity(let raw):
                out += raw
            case .underline(let children):
                out += "<u>" + serializeInlines(children) + "</u>"
            case .highlight(let children):
                out += "<mark>" + serializeInlines(children) + "</mark>"
            }
        }
        return out
    }
}
