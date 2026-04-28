//
//  HtmlBlockReader.swift
//  FSNotesCore
//
//  Phase 12.C.5 — Block parsing port: HTML blocks.
//
//  CommonMark §4.6 — seven sub-types of HTML block, each with its own
//  open / close conditions:
//
//    1. <pre, <script, <style, <textarea  — close at </pre>, </script>,
//       </style>, </textarea> on any line (including the open line).
//    2. <!--                               — close at -->.
//    3. <?                                 — close at ?>.
//    4. <!LETTER                           — close at >.
//    5. <![CDATA[                          — close at ]]>.
//    6. block-level HTML tag               — close at blank line.
//    7. any other complete open or close   — close at blank line; cannot
//       tag on its own line                  interrupt a paragraph.
//
//  Spec bucket: HTML blocks 43/44 (98%).
//
//  Self-contained: the reader owns the type tag set, tag-name parsing,
//  attribute scanning, and the line-stream walk. The caller (the
//  MarkdownParser block loop) flushes its paragraph buffer before this
//  reader runs and must pass `rawBufferEmpty` so type-7 (which cannot
//  interrupt a paragraph) is gated correctly.
//
//  `detect(_:)` is the public type discriminator — both the block loop
//  and the lazy-continuation interrupt check read it.
//

import Foundation

public enum HtmlBlockReader {

    public struct ReadResult {
        public let block: Block
        public let nextIndex: Int
    }

    /// Try to read an HTML block starting at `lines[start]`. Returns nil
    /// if `lines[start]` doesn't open one OR if the open is type 7 while
    /// `rawBufferEmpty == false` (type 7 cannot interrupt a paragraph).
    /// `trailingNewline` lets the reader skip the synthetic empty line
    /// that line-splitting introduces for inputs ending with `\n`.
    public static func read(
        lines: [String],
        from start: Int,
        trailingNewline: Bool,
        rawBufferEmpty: Bool
    ) -> ReadResult? {
        guard start < lines.count else { return nil }
        let openLine = lines[start]
        guard let type = detect(openLine) else { return nil }
        if type == 7 && !rawBufferEmpty { return nil }

        var collected: [String] = [openLine]
        var i = start + 1

        // Types 1–5 may close on their opening line (e.g.
        // `<style>foo</style>`).
        if !endsOnLine(openLine, type: type) {
            while i < lines.count {
                let nextLine = lines[i]
                if i == lines.count - 1 && nextLine.isEmpty && trailingNewline { break }

                if type == 6 || type == 7 {
                    // Types 6 and 7 close at a blank line (exclusive).
                    if nextLine.trimmingCharacters(in: .whitespaces).isEmpty { break }
                }

                collected.append(nextLine)

                switch type {
                case 1:
                    let lower = nextLine.lowercased()
                    if lower.contains("</pre>") || lower.contains("</script>")
                        || lower.contains("</style>") || lower.contains("</textarea>") {
                        i += 1; return ReadResult(
                            block: .htmlBlock(raw: collected.joined(separator: "\n")),
                            nextIndex: i
                        )
                    }
                case 2:
                    if nextLine.contains("-->") {
                        i += 1; return ReadResult(
                            block: .htmlBlock(raw: collected.joined(separator: "\n")),
                            nextIndex: i
                        )
                    }
                case 3:
                    if nextLine.contains("?>") {
                        i += 1; return ReadResult(
                            block: .htmlBlock(raw: collected.joined(separator: "\n")),
                            nextIndex: i
                        )
                    }
                case 4:
                    if nextLine.contains(">") {
                        i += 1; return ReadResult(
                            block: .htmlBlock(raw: collected.joined(separator: "\n")),
                            nextIndex: i
                        )
                    }
                case 5:
                    if nextLine.contains("]]>") {
                        i += 1; return ReadResult(
                            block: .htmlBlock(raw: collected.joined(separator: "\n")),
                            nextIndex: i
                        )
                    }
                default:
                    break
                }
                i += 1
            }
        }

        return ReadResult(
            block: .htmlBlock(raw: collected.joined(separator: "\n")),
            nextIndex: i
        )
    }

    /// Detect whether `line` starts an HTML block and return its type
    /// (1–7), or nil if it isn't a block start. Public so callers (the
    /// block loop, the lazy-continuation interrupt check) can branch on
    /// the type without owning the detection rules.
    public static func detect(_ line: String) -> Int? {
        // CommonMark §4.6: an HTML block may have up to 3 leading spaces
        // of indentation. A line with 4+ leading columns of whitespace
        // is an indented code block context (when no paragraph is open),
        // not an HTML block.
        var leadingSpaces = 0
        for ch in line {
            if ch == " " { leadingSpaces += 1 } else { break }
        }
        guard leadingSpaces <= 3 else { return nil }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix("<") else { return nil }
        let trimmedStr = String(trimmed)

        // Type 1: <pre, <script, <style, <textarea (case insensitive)
        let lower = trimmedStr.lowercased()
        for tag in ["pre", "script", "style", "textarea"] {
            if lower.hasPrefix("<\(tag)") {
                let afterTag = lower.dropFirst(tag.count + 1)
                if afterTag.isEmpty || afterTag.first == " " || afterTag.first == ">"
                    || afterTag.first == "\t" || afterTag.hasPrefix("\n") {
                    return 1
                }
            }
        }

        // Type 2: <!--
        if trimmedStr.hasPrefix("<!--") { return 2 }

        // Type 3: <?
        if trimmedStr.hasPrefix("<?") { return 3 }

        // Type 4: <!LETTER
        if trimmedStr.hasPrefix("<!") && trimmedStr.count > 2 {
            let thirdChar = trimmedStr[trimmedStr.index(trimmedStr.startIndex, offsetBy: 2)]
            if thirdChar.isLetter && thirdChar.isUppercase { return 4 }
        }

        // Type 5: <![CDATA[
        if trimmedStr.hasPrefix("<![CDATA[") { return 5 }

        // Type 6: block-level HTML tag
        if let tagName = extractTagName(trimmedStr) {
            if blockLevelTags.contains(tagName.lowercased()) {
                return 6
            }
        }

        // Type 7: any other complete open or closing tag on its own
        // line. The tag must be a complete open tag (with optional
        // attributes, ending with > or />) or a closing tag
        // (</tagname>), followed only by optional whitespace. Cannot
        // interrupt a paragraph (caller must check rawBufferEmpty).
        if isCompleteTag(trimmedStr) {
            return 7
        }

        return nil
    }

    /// Whether the type's end condition is met somewhere on `line`.
    /// Used to detect same-line ends (e.g., `<style>...</style>` on
    /// one line). Types 6 and 7 end at blank lines, so they never
    /// "end on a line" — return false.
    public static func endsOnLine(_ line: String, type: Int) -> Bool {
        let lower = line.lowercased()
        switch type {
        case 1:
            return lower.contains("</pre>") || lower.contains("</script>")
                || lower.contains("</style>") || lower.contains("</textarea>")
        case 2:
            if let range = line.range(of: "<!--") {
                return line[range.upperBound...].contains("-->")
            }
            return false
        case 3:
            if let range = line.range(of: "<?") {
                return line[range.upperBound...].contains("?>")
            }
            return false
        case 4:
            // Opening is <!LETTER, so check from index 2 onward.
            return line.dropFirst(2).contains(">")
        case 5:
            if let range = line.range(of: "<![CDATA[") {
                return line[range.upperBound...].contains("]]>")
            }
            return false
        default:
            return false
        }
    }

    // MARK: - Internals

    /// Block-level HTML tag names (CommonMark spec, type 6).
    private static let blockLevelTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog",
        "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer",
        "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6",
        "head", "header", "hr", "html", "iframe", "legend", "li", "link",
        "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup",
        "option", "p", "param", "search", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "title", "tr", "ul"
    ]

    /// Extract the tag name from a string starting with `<` or `</`.
    /// Returns the tag name if the character after the tag is a valid
    /// delimiter (space, tab, >, /, newline, or end of string).
    private static func extractTagName(_ line: String) -> String? {
        let chars = Array(line)
        guard chars.count >= 2, chars[0] == "<" else { return nil }
        var i = 1
        if i < chars.count && chars[i] == "/" { i += 1 }
        guard i < chars.count, chars[i].isLetter else { return nil }
        let start = i
        while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "-") { i += 1 }
        guard i <= chars.count else { return nil }
        if i == chars.count { return String(chars[start..<i]) }
        let next = chars[i]
        if next == " " || next == "\t" || next == ">" || next == "/" || next == "\n" {
            return String(chars[start..<i])
        }
        return nil
    }

    /// Whether `line` is a complete HTML open tag or closing tag
    /// followed only by optional whitespace (type 7 HTML block start).
    ///
    /// CommonMark open tag: `< tag_name attribute* /? >`
    /// - tag_name: ASCII letter followed by (letter|digit|hyphen)*
    /// - attribute: whitespace+ attr_name (= attr_value)?
    /// - attr_name: (letter|_|:) (letter|digit|_|.|:|-)*
    /// - attr_value: unquoted | 'single' | "double"
    ///
    /// Closing tag: `</ tag_name whitespace* >`
    private static func isCompleteTag(_ line: String) -> Bool {
        let chars = Array(line)
        guard chars.count >= 3, chars[0] == "<" else { return false }
        var i = 1

        let isClosing = chars[i] == "/"
        if isClosing { i += 1 }

        // Tag name: starts with ASCII letter
        guard i < chars.count, chars[i].isASCII, chars[i].isLetter else { return false }
        i += 1
        while i < chars.count && (chars[i].isASCII && (chars[i].isLetter || chars[i].isNumber) || chars[i] == "-") { i += 1 }

        if isClosing {
            // Closing tag: optional whitespace then >
            while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
            guard i < chars.count, chars[i] == ">" else { return false }
            i += 1
        } else {
            // Open tag: parse zero or more attributes, then optional /, then >
            while i < chars.count {
                let ch = chars[i]
                if ch == ">" { i += 1; break }
                if ch == "/" {
                    if i + 1 < chars.count && chars[i + 1] == ">" { i += 2; break }
                    return false // bare / not followed by >
                }
                // Must have whitespace before attribute
                guard ch == " " || ch == "\t" else { return false }
                // Skip whitespace
                while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                guard i < chars.count else { return false }
                if chars[i] == ">" { i += 1; break }
                if chars[i] == "/" {
                    if i + 1 < chars.count && chars[i + 1] == ">" { i += 2; break }
                    return false
                }
                // Attribute name: starts with letter, _, or :
                let ac = chars[i]
                guard ac.isASCII && ac.isLetter || ac == "_" || ac == ":" else { return false }
                i += 1
                while i < chars.count {
                    let c = chars[i]
                    if c.isASCII && (c.isLetter || c.isNumber) || c == "_" || c == "." || c == ":" || c == "-" {
                        i += 1
                    } else { break }
                }
                // Optional whitespace
                while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                guard i < chars.count else { return false }
                // Optional = value
                if chars[i] == "=" {
                    i += 1
                    while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                    guard i < chars.count else { return false }
                    if chars[i] == "\"" {
                        i += 1
                        while i < chars.count && chars[i] != "\"" { i += 1 }
                        guard i < chars.count else { return false }
                        i += 1 // skip closing "
                    } else if chars[i] == "'" {
                        i += 1
                        while i < chars.count && chars[i] != "'" { i += 1 }
                        guard i < chars.count else { return false }
                        i += 1 // skip closing '
                    } else {
                        // Unquoted value: non-empty, no spaces/quotes/=/</>
                        let vStart = i
                        while i < chars.count && chars[i] != " " && chars[i] != "\t"
                                && chars[i] != "\"" && chars[i] != "'" && chars[i] != "="
                                && chars[i] != "<" && chars[i] != ">" && chars[i] != "`" {
                            i += 1
                        }
                        if i == vStart { return false }
                    }
                }
            }
            // Must have ended with >
            guard i > 0 && chars[i - 1] == ">" else { return false }
        }

        // Rest of line must be only whitespace
        while i < chars.count {
            guard chars[i] == " " || chars[i] == "\t" else { return false }
            i += 1
        }
        return true
    }
}
