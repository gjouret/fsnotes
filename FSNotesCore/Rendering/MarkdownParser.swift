//
//  MarkdownParser.swift
//  FSNotesCore
//
//  Markdown text -> Document (block model).
//
//  ARCHITECTURAL CONTRACT:
//  - Input: raw markdown string (contents of a .md file).
//  - Output: Document with blocks. Fence characters are CONSUMED — they
//    exist in the input string but NOT in the output Document's payloads.
//  - Round-trip: MarkdownSerializer.serialize(parse(x)) == x, byte-equal,
//    for every valid markdown input.
//
//  Supported constructs: fenced code blocks, ATX headings, blank lines,
//  paragraphs with inline bold/italic/code emphasis, lists (unordered +
//  ordered with nesting), blockquotes, horizontal rules.
//

import Foundation

public enum MarkdownParser {

    /// Parse markdown source into a Document.
    ///
    /// The parse is LINE-ORIENTED. We scan line by line, identify fence
    /// opens / fence closes, headings, and blank lines, and emit blocks.
    /// Runs of non-empty lines that are not a fence or heading become a
    /// single .paragraph block whose inline tree is produced by the
    /// inline tokenizer.
    public static func parse(_ markdown: String) -> Document {
        // Split preserving a trailing empty element if the input ends
        // with a newline. This is required for byte-equal round-trip:
        // "a\n" has two parts ("a", "") while "a" has one ("a").
        let lines = splitPreservingTrailingEmpty(markdown)

        var blocks: [Block] = []
        var i = 0
        var rawBuffer: [String] = []

        func flushRawBuffer() {
            guard !rawBuffer.isEmpty else { return }
            let text = rawBuffer.joined(separator: "\n")
            blocks.append(.paragraph(inline: parseInlines(text)))
            rawBuffer.removeAll(keepingCapacity: true)
        }

        while i < lines.count {
            let line = lines[i]

            // Last element after split is the synthetic trailing "" if the
            // original string ended with '\n'. We handle trailing newline
            // at serialize time, so drop that synthetic final element.
            if i == lines.count - 1 && line.isEmpty && markdown.hasSuffix("\n") {
                break
            }

            if let fence = detectFenceOpen(line) {
                flushRawBuffer()

                // Scan forward for the matching close fence.
                var contentLines: [String] = []
                var j = i + 1
                var foundClose = false

                while j < lines.count {
                    if isFenceClose(lines[j], matching: fence) {
                        foundClose = true
                        break
                    }
                    contentLines.append(lines[j])
                    j += 1
                }

                guard foundClose else {
                    // Unterminated fence: treat the open line as a plain
                    // paragraph line to preserve byte-equal round-trip.
                    rawBuffer.append(line)
                    i += 1
                    continue
                }

                let content = contentLines.joined(separator: "\n")
                let infoTrimmed = fence.infoRaw.trimmingCharacters(in: .whitespaces)
                let language = infoTrimmed.isEmpty ? nil : infoTrimmed
                let fenceStyle = FenceStyle(
                    character: fence.fenceChar == "`" ? .backtick : .tilde,
                    length: fence.fenceLength,
                    infoRaw: fence.infoRaw
                )
                blocks.append(.codeBlock(language: language, content: content, fence: fenceStyle))
                i = j + 1
                continue
            }

            if detectBlockquoteLine(line) != nil {
                flushRawBuffer()
                var qLines: [BlockquoteLine] = []
                var j = i
                while j < lines.count {
                    let l = lines[j]
                    if j == lines.count - 1 && l.isEmpty && markdown.hasSuffix("\n") {
                        break
                    }
                    guard let parts = detectBlockquoteLine(l) else { break }
                    qLines.append(BlockquoteLine(
                        prefix: parts.prefix,
                        inline: parseInlines(parts.content)
                    ))
                    j += 1
                }
                blocks.append(.blockquote(lines: qLines))
                i = j
                continue
            }

            if let hr = detectHorizontalRule(line) {
                flushRawBuffer()
                blocks.append(.horizontalRule(character: hr.character, length: hr.length))
                i += 1
                continue
            }

            if parseListLine(line) != nil {
                flushRawBuffer()

                // Collect a contiguous run of list lines. The run stops
                // at a blank line, a non-list line, or the synthetic
                // trailing "" for a file-ending newline.
                var parsedLines: [ParsedListLine] = []
                var j = i
                while j < lines.count {
                    let l = lines[j]
                    if j == lines.count - 1 && l.isEmpty && markdown.hasSuffix("\n") {
                        break
                    }
                    if l.isEmpty { break }
                    guard let parsed = parseListLine(l) else { break }
                    parsedLines.append(parsed)
                    j += 1
                }
                let (items, _) = buildItemTree(
                    lines: parsedLines, from: 0, parentIndent: -1
                )
                blocks.append(.list(items: items))
                i = j
                continue
            }

            if let heading = detectHeading(line) {
                flushRawBuffer()
                blocks.append(.heading(level: heading.level, suffix: heading.suffix))
                i += 1
                continue
            }

            if line.isEmpty {
                flushRawBuffer()
                blocks.append(.blankLine)
                i += 1
                continue
            }

            rawBuffer.append(line)
            i += 1
        }

        flushRawBuffer()
        return Document(blocks: blocks, trailingNewline: markdown.hasSuffix("\n"))
    }

    // MARK: - Fence detection

    /// Info captured from a fence-open line. We store the fence string so
    /// the close must match exactly (CommonMark rule: close fence length
    /// must be >= open fence length AND use the same fence character).
    private struct Fence {
        let fenceChar: Character   // '`' or '~'
        let fenceLength: Int       // number of fence chars (>= 3)
        let infoRaw: String        // info string verbatim (not trimmed)
    }

    /// Detect whether `line` opens a fenced code block. Returns the Fence
    /// descriptor if so, nil otherwise.
    ///
    /// Rule: a fence-open is a line that starts with >= 3
    /// backticks or >= 3 tildes, optionally followed by an info string.
    /// Indented fences are NOT matched (we only handle unindented for now).
    private static func detectFenceOpen(_ line: String) -> Fence? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }

        var count = 0
        for ch in line {
            if ch == first { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }

        let rest = String(line.dropFirst(count))

        // CommonMark: backtick fences cannot contain backticks in their
        // info string. If they do, this isn't a fence open.
        if first == "`" && rest.contains("`") { return nil }

        return Fence(fenceChar: first, fenceLength: count, infoRaw: rest)
    }

    /// Check whether `line` is a valid close fence for the given open.
    /// Close fence: only fence chars (>= open length) and optional trailing
    /// whitespace, no info string.
    private static func isFenceClose(_ line: String, matching open: Fence) -> Bool {
        var count = 0
        for ch in line {
            if ch == open.fenceChar { count += 1 } else { break }
        }
        guard count >= open.fenceLength else { return false }

        // Everything after fence chars must be whitespace only.
        let trailing = line.dropFirst(count)
        return trailing.allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Heading detection

    /// Detect an ATX heading on `line`. CommonMark rule: 1–6 leading `#`
    /// characters followed by either a space/tab OR end of line. The
    /// opening sequence cannot be indented (we do not yet support the
    /// up-to-3-space indentation allowance). Returns the level and the
    /// verbatim suffix (everything after the `#` markers) if matched.
    ///
    /// Examples (preserving exact whitespace for byte-equal round-trip):
    ///   "# Hello"     → level 1, suffix " Hello"
    ///   "##  Spaced"  → level 2, suffix "  Spaced"
    ///   "###"         → level 3, suffix ""
    ///   "#### "       → level 4, suffix " "
    ///   "#Hello"      → nil  (missing required space after markers)
    ///   "####### too" → nil  (7 markers exceeds max of 6)
    private static func detectHeading(_ line: String) -> (level: Int, suffix: String)? {
        guard let first = line.first, first == "#" else { return nil }

        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 else { return nil }

        let suffix = String(line.dropFirst(level))
        // Valid heading: either suffix is empty (end of line) or begins
        // with a space/tab.
        if suffix.isEmpty { return (level, suffix) }
        guard let nextCh = suffix.first, nextCh == " " || nextCh == "\t" else {
            return nil
        }
        return (level, suffix)
    }

    // MARK: - Inline tokenizer

    /// Parse inline content from a paragraph's raw text. Standard
    /// scope: consumes `**…**` (bold) and `*…*` (italic) markers. All
    /// other characters (including `_`, `` ` ``, `[…](…)`) are treated
    /// as plain text and round-trip verbatim.
    ///
    /// Simplified CommonMark flanking rules:
    /// - An opening `**` or `*` must NOT be followed by whitespace.
    /// - A closing `**` or `*` must NOT be preceded by whitespace.
    /// - `**` is matched greedily before `*` to avoid `**x**` parsing
    ///   as two italic runs.
    /// - Emphasis may not span across a paragraph boundary (input here
    ///   is already a single paragraph's text).
    /// - Unmatched markers stay as literal text.
    ///
    /// Byte-equal round-trip: the serializer re-emits the exact marker
    /// characters that the parser consumed.
    static func parseInlines(_ text: String) -> [Inline] {
        guard !text.isEmpty else { return [] }
        let chars = Array(text)
        var result: [Inline] = []
        var plain = ""
        var i = 0

        func flushPlain() {
            if !plain.isEmpty {
                result.append(.text(plain))
                plain = ""
            }
        }

        while i < chars.count {
            // Code spans have higher precedence than emphasis per
            // CommonMark: `**` inside backticks stays as literal text.
            if let match = tryMatchCodeSpan(chars, from: i) {
                flushPlain()
                result.append(.code(match.inner))
                i = match.endIndex
                continue
            }
            // Try `~~…~~` (strikethrough) before bold — both use double
            // markers but different characters.
            if let match = tryMatchStrikethrough(chars, from: i) {
                flushPlain()
                result.append(.strikethrough(parseInlines(match.inner)))
                i = match.endIndex
                continue
            }
            // Try `**…**` (bold) — double marker takes precedence over `*`.
            if let match = tryMatchEmphasis(chars, from: i, markerLength: 2) {
                flushPlain()
                result.append(.bold(parseInlines(match.inner)))
                i = match.endIndex
                continue
            }
            // Then try `*…*` (italic).
            if let match = tryMatchEmphasis(chars, from: i, markerLength: 1) {
                flushPlain()
                result.append(.italic(parseInlines(match.inner)))
                i = match.endIndex
                continue
            }
            plain.append(chars[i])
            i += 1
        }
        flushPlain()
        return result
    }

    /// Try to match a code span starting at `start`. Rule:
    /// a single `` ` `` opens the span; the next single `` ` `` closes
    /// it; the inner content contains no backticks. Byte-equal round-trip
    /// is preserved by NOT stripping leading/trailing whitespace (unlike
    /// CommonMark's cosmetic strip rule).
    ///
    /// Double-backtick spans (for content containing a backtick) are
    /// future work; for now, a `` ` `` followed by more backticks yields
    /// no match (treated as literal text).
    private static func tryMatchCodeSpan(
        _ chars: [Character], from start: Int
    ) -> (inner: String, endIndex: Int)? {
        guard start < chars.count, chars[start] == "`" else { return nil }
        // Reject multi-backtick runs (not yet supported).
        if start + 1 < chars.count, chars[start + 1] == "`" { return nil }
        // Scan for the next single backtick.
        var j = start + 1
        while j < chars.count {
            if chars[j] == "`" {
                // Reject if this backtick is part of a longer run.
                if j + 1 < chars.count, chars[j + 1] == "`" {
                    // Longer run encountered — skip past it entirely;
                    // cannot close against it.
                    var k = j
                    while k < chars.count, chars[k] == "`" { k += 1 }
                    j = k
                    continue
                }
                let inner = String(chars[(start + 1)..<j])
                return (inner, j + 1)
            }
            j += 1
        }
        return nil
    }

    /// Try to match an emphasis run starting at `start` using a run of
    /// `markerLength` asterisks. Returns the inner text and the index
    /// past the closing marker, or nil if no valid run matches.
    private static func tryMatchEmphasis(
        _ chars: [Character], from start: Int, markerLength: Int
    ) -> (inner: String, endIndex: Int)? {
        // Need at least: open(markerLength) + 1 char + close(markerLength).
        guard start + markerLength * 2 + 1 <= chars.count else { return nil }

        // Verify exactly `markerLength` asterisks at `start`, and the
        // char before and after the run is the right kind.
        for k in 0..<markerLength {
            if chars[start + k] != "*" { return nil }
        }
        // Must not be part of a LONGER asterisk run (else `**` would
        // match inside `***`, mis-parsing nested emphasis).
        if start + markerLength < chars.count,
           chars[start + markerLength] == "*" {
            // If this is a `**` run but the next char is also `*`,
            // treat the whole run as literal (we don't support `***`).
            if markerLength == 2 { return nil }
            // For single `*`, the next char being `*` means we actually
            // have `**` which should be handled by the caller — defer.
            if markerLength == 1 { return nil }
        }
        // Flanking: char after the opening marker must not be whitespace.
        let afterOpen = chars[start + markerLength]
        if afterOpen == " " || afterOpen == "\t" || afterOpen == "\n" {
            return nil
        }

        // Scan forward for a matching close marker.
        var j = start + markerLength
        while j + markerLength <= chars.count {
            // Close candidate at j: `markerLength` asterisks, preceded
            // by non-whitespace, not part of a longer asterisk run.
            var allStars = true
            for k in 0..<markerLength {
                if chars[j + k] != "*" { allStars = false; break }
            }
            if !allStars {
                j += 1
                continue
            }
            // Not part of a longer run.
            if j + markerLength < chars.count, chars[j + markerLength] == "*" {
                // Skip this position — it's inside a longer asterisk run.
                j += 1
                continue
            }
            // Char before close must not be whitespace.
            let beforeClose = chars[j - 1]
            if beforeClose == " " || beforeClose == "\t" || beforeClose == "\n" {
                j += 1
                continue
            }
            // Valid match.
            let inner = String(chars[(start + markerLength)..<j])
            return (inner, j + markerLength)
        }
        return nil
    }

    /// Try to match a strikethrough span `~~…~~` starting at `start`.
    private static func tryMatchStrikethrough(
        _ chars: [Character], from start: Int
    ) -> (inner: String, endIndex: Int)? {
        // Need at least `~~X~~` = 5 characters.
        guard start + 4 < chars.count,
              chars[start] == "~", chars[start + 1] == "~" else { return nil }
        // Reject triple-tilde (not strikethrough).
        if start + 2 < chars.count, chars[start + 2] == "~" { return nil }
        // Flanking: char after `~~` must not be whitespace.
        let afterOpen = chars[start + 2]
        if afterOpen == " " || afterOpen == "\t" || afterOpen == "\n" {
            return nil
        }
        // Scan for closing `~~`.
        var j = start + 2
        while j + 1 < chars.count {
            if chars[j] == "~" && chars[j + 1] == "~" {
                // Not part of a longer tilde run.
                if j + 2 < chars.count, chars[j + 2] == "~" {
                    j += 1
                    continue
                }
                // Char before close must not be whitespace.
                let beforeClose = chars[j - 1]
                if beforeClose == " " || beforeClose == "\t" || beforeClose == "\n" {
                    j += 1
                    continue
                }
                let inner = String(chars[(start + 2)..<j])
                return (inner, j + 2)
            }
            j += 1
        }
        return nil
    }

    // MARK: - Blockquote detection

    /// Detect whether `line` starts with a blockquote marker. The
    /// prefix is captured VERBATIM (needed for byte-equal round-trip)
    /// and the content is the remainder of the line.
    ///
    /// Rule: the prefix is a run of one or more `>`,
    /// each optionally followed by a single space or tab (to permit
    /// styles like "> ", ">> ", "> > ", ">"). Leading whitespace
    /// before the first `>` is NOT allowed.
    ///
    ///   "> hello"     → prefix="> ",   content="hello"
    ///   ">> hello"    → prefix=">> ",  content="hello"
    ///   "> > hello"   → prefix="> > ", content="hello"
    ///   ">no space"   → prefix=">",    content="no space"
    ///   ">"           → prefix=">",    content=""
    ///   ">  two"      → prefix="> ",   content=" two"
    static func detectBlockquoteLine(_ line: String) -> (prefix: String, content: String)? {
        guard line.first == ">" else { return nil }
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == ">" {
            i += 1
            // Optionally consume ONE space/tab after this `>`.
            if i < chars.count, chars[i] == " " || chars[i] == "\t" {
                i += 1
            }
        }
        let prefix = String(chars[0..<i])
        let content = String(chars[i..<chars.count])
        return (prefix, content)
    }

    // MARK: - Horizontal rule detection

    /// Detect whether `line` is a thematic break (horizontal rule).
    /// Rule: the line consists of EXACTLY a run of
    /// three-or-more identical `-`, `_`, or `*` characters, with no
    /// intervening whitespace and no other characters. Returns the
    /// character and count (needed for byte-equal round-trip), or
    /// nil otherwise.
    ///
    /// Intentionally stricter than CommonMark (which allows spaces
    /// between markers and up to 3 leading spaces) — this keeps the
    /// detector unambiguous and preserves the list/HR boundary.
    private static func detectHorizontalRule(_ line: String) -> (character: Character, length: Int)? {
        guard let first = line.first,
              first == "-" || first == "_" || first == "*" else { return nil }
        var count = 0
        for ch in line {
            if ch == first { count += 1 } else { return nil }
        }
        guard count >= 3 else { return nil }
        return (first, count)
    }

    // MARK: - List detection

    /// A single line parsed as a list item: split into leading
    /// indentation, the marker itself, the whitespace after the
    /// marker, an optional checkbox, and the line's content.
    struct ParsedListLine {
        let indent: String        // leading whitespace (spaces/tabs)
        let marker: String        // "-", "*", "+", or "<digits>.", "<digits>)"
        let afterMarker: String   // whitespace between marker and content/checkbox
        let checkbox: Checkbox?   // "[ ]", "[x]", "[X]" for todo items
        let content: String       // remainder of the line after checkbox/afterMarker
    }

    /// Detect whether `line` is a list item. Rules:
    /// - Leading indentation: any run of spaces/tabs (may be empty).
    /// - Marker: `-`, `*`, `+`, or one-or-more digits followed by `.`
    ///   or `)`.
    /// - At least ONE space/tab must follow the marker (afterMarker).
    ///   Content may be empty (the "empty item" case "- ").
    ///
    /// Ambiguities with emphasis-or-HR: a lone `*` line without a
    /// following space is NOT a list item (returns nil). A line of
    /// just `***` is also rejected (future HR handling).
    static func parseListLine(_ line: String) -> ParsedListLine? {
        let chars = Array(line)
        var i = 0

        // Leading indent: spaces or tabs.
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let indent = String(chars[0..<i])

        guard i < chars.count else { return nil }
        let markerStart = i

        // Unordered marker: single `-`, `*`, or `+`.
        if chars[i] == "-" || chars[i] == "*" || chars[i] == "+" {
            // Disambiguate: a RUN of the same char ("---", "***", "+++")
            // is not a list item (it's HR-like). Require the next
            // character to NOT be the same marker.
            let markerCh = chars[i]
            if i + 1 < chars.count, chars[i + 1] == markerCh {
                return nil
            }
            i += 1
        } else if chars[i].isNumber {
            // Ordered marker: digits followed by `.` or `)`.
            while i < chars.count, chars[i].isNumber { i += 1 }
            guard i < chars.count, chars[i] == "." || chars[i] == ")" else {
                return nil
            }
            i += 1
        } else {
            return nil
        }

        let marker = String(chars[markerStart..<i])

        // afterMarker: require at least one space/tab UNLESS we're
        // at end of line (allow "-" with no content — rejected above
        // as "-" alone has no whitespace, so we only accept "- " or
        // marker followed by whitespace).
        let afterStart = i
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        // Special case: marker at end of line with no whitespace
        // ("-" alone) — not a list item.
        if i == afterStart { return nil }
        let afterMarker = String(chars[afterStart..<i])

        // Detect checkbox: "[ ] ", "[x] ", "[X] " at the start of
        // content. Only for unordered markers ("-", "*", "+").
        let remaining = chars[i..<chars.count]
        let checkbox: Checkbox?
        let contentStart: Int
        if (marker == "-" || marker == "*" || marker == "+"),
           remaining.count >= 4,
           chars[i] == "[",
           (chars[i+1] == " " || chars[i+1] == "x" || chars[i+1] == "X"),
           chars[i+2] == "]" {
            let cbText = String(chars[i..<(i+3)])  // "[ ]", "[x]", "[X]"
            // Consume whitespace after checkbox.
            var afterCB = i + 3
            let afterCBStart = afterCB
            while afterCB < chars.count, chars[afterCB] == " " || chars[afterCB] == "\t" {
                afterCB += 1
            }
            // Require at least one space after the checkbox.
            if afterCB > afterCBStart {
                checkbox = Checkbox(text: cbText, afterText: String(chars[afterCBStart..<afterCB]))
                contentStart = afterCB
            } else if afterCB == chars.count {
                // Checkbox at end of line with no content (empty todo).
                checkbox = Checkbox(text: cbText, afterText: "")
                contentStart = afterCB
            } else {
                checkbox = nil
                contentStart = i
            }
        } else {
            checkbox = nil
            contentStart = i
        }

        let content = String(chars[contentStart..<chars.count])
        return ParsedListLine(
            indent: indent, marker: marker,
            afterMarker: afterMarker, checkbox: checkbox,
            content: content
        )
    }

    /// Recursively build a list item tree from a flat array of parsed
    /// list lines. Items at the same indent column become siblings;
    /// items at a deeper indent are collected as children of the
    /// immediately preceding sibling.
    ///
    /// `parentIndent` is the indent-column of the enclosing scope
    /// (or -1 at the top level). We take as "sibling indent" the
    /// indent of the first item at or before index `from` that is
    /// strictly greater than `parentIndent`. Items whose indent falls
    /// below `siblingIndent` pop the recursion back to the caller.
    static func buildItemTree(
        lines: [ParsedListLine], from: Int, parentIndent: Int
    ) -> (items: [ListItem], endIndex: Int) {
        guard from < lines.count else { return ([], from) }
        let siblingIndent = lines[from].indent.count
        // Must be strictly deeper than the parent scope; otherwise
        // these lines belong to the caller.
        guard siblingIndent > parentIndent else { return ([], from) }

        var items: [ListItem] = []
        var i = from
        while i < lines.count {
            let cur = lines[i]
            let curIndent = cur.indent.count
            if curIndent < siblingIndent { break }
            if curIndent > siblingIndent {
                // Should never happen — the previous iteration should
                // have consumed deeper-indented lines as children. If
                // it does (e.g. the very first line is deeper than a
                // subsequent sibling at shallower indent), stop here.
                break
            }
            let inline = parseInlines(cur.content)
            // Try to collect children at a deeper indent immediately
            // following this item.
            let (children, nextI) = buildItemTree(
                lines: lines, from: i + 1, parentIndent: siblingIndent
            )
            items.append(ListItem(
                indent: cur.indent,
                marker: cur.marker,
                afterMarker: cur.afterMarker,
                checkbox: cur.checkbox,
                inline: inline,
                children: children
            ))
            i = nextI
        }
        return (items, i)
    }

    // MARK: - Line splitting

    /// Split on '\n' but preserve a synthetic trailing empty string if the
    /// input ends with '\n'. We need this because:
    ///   "a"    -> ["a"]
    ///   "a\n"  -> ["a", ""]   (the trailing "" marks the final newline)
    ///   "a\nb" -> ["a", "b"]
    /// This lets round-trip serialization decide whether to add a final \n.
    private static func splitPreservingTrailingEmpty(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var parts: [String] = []
        var current = ""
        for ch in s {
            if ch == "\n" {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        // After loop, `current` holds text after the last newline. If the
        // string ended with '\n', `current` is "" and we still append to
        // record the trailing newline.
        parts.append(current)
        return parts
    }
}
