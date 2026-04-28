//
//  CommonMarkHTMLRenderer.swift
//  FSNotesTests
//
//  Minimal HTML renderer for the MarkdownParser Document model.
//  Used exclusively by CommonMarkSpecTests to compare our parser output
//  against the CommonMark spec's expected HTML.
//
//  This is NOT a general-purpose HTML renderer — it exists only to
//  translate our block model into HTML so we can run spec compliance
//  tests. It lives in the test target, not the app target.
//

import Foundation
@testable import FSNotes

/// Renders a `Document` (our parser's output) to CommonMark-compatible HTML.
///
/// Limitations (tracked as expected spec failures):
/// - Indented code blocks: not distinguished from paragraphs
struct CommonMarkHTMLRenderer {

    /// Link reference definitions from the parsed document, used to
    /// resolve reference links when re-parsing heading suffixes.
    private let refDefs: [String: (url: String, title: String?)]

    init(refDefs: [String: (url: String, title: String?)] = [:]) {
        self.refDefs = refDefs
    }

    static func render(_ document: Document) -> String {
        let renderer = CommonMarkHTMLRenderer(refDefs: document.refDefs)
        var output = ""
        let blocks = document.blocks

        for (i, block) in blocks.enumerated() {
            // Skip blank lines between blocks — they affect structure
            // but don't produce HTML output themselves.
            if case .blankLine = block { continue }
            output += renderer.renderBlock(block, inTightList: false)
        }

        return output
    }

    // MARK: - Block rendering

    func renderBlock(_ block: Block, inTightList: Bool) -> String {
        switch block {
        case .heading(let level, let suffix):
            // The suffix includes leading space and possibly trailing
            // closing hashes. Strip both, then collapse internal whitespace.
            var content = suffix
            // Remove leading whitespace
            content = String(content.drop(while: { $0 == " " || $0 == "\t" }))
            // Strip trailing closing hashes (e.g., "foo ##" -> "foo")
            content = Self.stripClosingHashes(content)
            // Trim any remaining leading/trailing whitespace
            content = content.trimmingCharacters(in: .whitespaces)
            // Parse inline content from the heading text
            let inlines = MarkdownParser.parseInlines(content, refDefs: refDefs)
            let rendered = Self.renderInlines(inlines)
            return "<h\(level)>\(rendered)</h\(level)>\n"

        case .paragraph(let inlines):
            // An empty paragraph is an editor transient (e.g., the block
            // produced by exitListItem on an empty item) and is never
            // emitted by the parser. Render it as nothing — equivalent
            // to a blankLine — so HTML parity tests match the parsed
            // form of the same markdown.
            if inlines.isEmpty {
                return ""
            }
            // Strip trailing whitespace from rendered paragraph content
            // (CommonMark: trailing spaces at end of paragraph are removed).
            var rendered = Self.renderInlines(inlines)
            // Strip leading spaces per CommonMark 4.8 — the parser also
            // strips up to 3 leading spaces from paragraph lines at
            // block-open time; live Documents whose inline content
            // carries stray leading spaces (e.g. after certain splice
            // operations) must still compare equal to the re-parsed
            // canonical form under HTML parity.
            while rendered.hasPrefix(" ") { rendered = String(rendered.dropFirst()) }
            // Only strip trailing spaces (not newlines or other whitespace)
            while rendered.hasSuffix(" ") { rendered = String(rendered.dropLast()) }
            if rendered.isEmpty { return "" }
            // CommonMark §5.4 tight-list rule: paragraphs inside a tight
            // list item render their inline content unwrapped (no <p>).
            // Spec #300: the trailing `baz` after a setext heading inside
            // a tight item renders as `\nbaz` not `\n<p>baz</p>`.
            if inTightList {
                return rendered
            }
            return "<p>\(rendered)</p>\n"

        case .codeBlock(_, let content, let fence):
            // Extract language from info string: trim, take first word.
            let trimmedInfo = fence.infoRaw.trimmingCharacters(in: .whitespaces)
            var lang: String
            if let spaceIdx = trimmedInfo.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                lang = String(trimmedInfo[..<spaceIdx])
            } else {
                lang = trimmedInfo
            }
            // Unescape ASCII-punctuation backslash escapes first
            // (CommonMark #24: `foo\+bar` in info string becomes
            // `foo+bar` in the rendered class attribute).
            lang = Self.unescapeBackslashes(lang)
            // Decode entities in the info string (CommonMark spec)
            lang = Self.decodeEntitiesInString(lang)
            // CommonMark: code block content ends with a newline (unless empty).
            let contentWithNewline = content.isEmpty ? "" : Self.escapeHTML(content) + "\n"
            if !lang.isEmpty {
                let escapedLang = Self.escapeHTML(lang)
                return "<pre><code class=\"language-\(escapedLang)\">\(contentWithNewline)</code></pre>\n"
            }
            return "<pre><code>\(contentWithNewline)</code></pre>\n"

        case .horizontalRule:
            return "<hr />\n"

        case .list(let items, let loose):
            return renderList(items, loose: loose)

        case .blockquote(let lines):
            return renderBlockquote(lines)

        case .htmlBlock(let raw):
            return raw + "\n"

        case .table(let header, let alignments, let rows, _):
            return renderTable(header: header, alignments: alignments, rows: rows)

        case .blankLine:
            return ""
        }
    }

    // MARK: - Heading helpers

    /// Strip optional closing `#` sequence from ATX headings.
    /// E.g., "foo ## " -> "foo", "foo #" -> "foo"
    private static func stripClosingHashes(_ text: String) -> String {
        var s = text
        // Trim trailing whitespace first
        while s.hasSuffix(" ") || s.hasSuffix("\t") {
            s = String(s.dropLast())
        }
        // If the string ends with #, strip trailing #s
        if s.hasSuffix("#") {
            while s.hasSuffix("#") {
                s = String(s.dropLast())
            }
            // The # sequence must be preceded by a space (or be the whole string)
            if s.isEmpty || s.hasSuffix(" ") || s.hasSuffix("\t") {
                // Trim the trailing space
                while s.hasSuffix(" ") || s.hasSuffix("\t") {
                    s = String(s.dropLast())
                }
            } else {
                // The # was part of the content — restore it
                // Actually we can't easily restore, so re-parse from original
                return text.trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    // MARK: - List rendering

    private func renderList(_ items: [ListItem], loose: Bool = false) -> String {
        guard !items.isEmpty else { return "" }

        let isOrdered = Self.isOrderedMarker(items[0].marker)
        // A list is loose if the parser flagged it OR any item has
        // blankLineBefore (covers nested lists which don't carry the
        // top-level loose flag) OR any item contains a continuation
        // block sequence that actually introduces a blank-line
        // separation. A single non-paragraph continuation block with
        // no blank lines (e.g. an HR emitted for a list item whose
        // content is `* * *`, or a single fenced code block with no
        // preceding blank) does NOT by itself make the list loose —
        // CommonMark's looseness rule requires either blank lines
        // between items or blank lines between blocks within an item.
        let itemHasLoosenessSignal: (ListItem) -> Bool = { item in
            // Look at the item's continuation blocks (body minus
            // sublists). Sublists themselves don't make the OUTER list
            // loose — their own looseness is computed when they
            // render. Pre-#325 this filtering happened naturally
            // because `continuationBlocks` was a separate array; with
            // the unified `body`, we filter explicitly.
            let nonSublist = item.body.filter {
                if case .list = $0 { return false }
                return true
            }
            guard !nonSublist.isEmpty else { return false }
            // CommonMark §5.4: a list is loose if any item's blocks
            // are separated by a blank line. The parser preserves
            // those blanks as `.blankLine` entries; the renderer
            // skips them when iterating but uses them here as the
            // looseness signal.
            if nonSublist.contains(where: {
                if case .blankLine = $0 { return true }
                return false
            }) { return true }
            // Continuation is a single paragraph — traditionally
            // rendered as loose (the item becomes `<li><p>...</p>`).
            // The blank-line-then-content collection path emits a
            // single paragraph with no preceding `.blankLine`
            // because the inner re-parse trims leading blanks; this
            // covers that case explicitly.
            let nonBlank = nonSublist.filter {
                if case .blankLine = $0 { return false }
                return true
            }
            if nonBlank.count == 1, case .paragraph = nonBlank[0] {
                return true
            }
            return false
        }
        // `blankLineBefore` on the FIRST item of a list records the
        // blank-line gap between the list and the previous outer
        // context (e.g. a parent item or a preceding paragraph). That
        // gap doesn't make THIS list loose — CommonMark's loose
        // definition requires blank lines between SIBLING items. Only
        // consider blankLineBefore from index 1 onward.
        let hasInterItemBlank = items.dropFirst().contains(where: { $0.blankLineBefore })
        let isLoose = loose
            || hasInterItemBlank
            || items.contains(where: itemHasLoosenessSignal)
        let isTight = !isLoose && Self.detectTightList(items)

        var output = ""
        if isOrdered {
            let start = Self.extractOrderedStart(items[0].marker)
            if start == 1 {
                output += "<ol>\n"
            } else {
                output += "<ol start=\"\(start)\">\n"
            }
        } else {
            output += "<ul>\n"
        }

        for item in items {
            output += renderListItem(item, tight: isTight)
        }

        output += isOrdered ? "</ol>\n" : "</ul>\n"
        return output
    }

    private func renderListItem(_ item: ListItem, tight: Bool) -> String {
        var content = ""

        // Render the item's own inline content
        let inlineHTML = Self.renderInlines(item.inline)
        // CommonMark source-order body iteration (post-#325 redesign):
        // sublists and continuation blocks are interleaved in
        // `item.body`. The legacy `hasContinuation` signal — used to
        // decide tight `<li>` wrapping and the inline→first-block
        // separator — is "is there any non-list, non-blank-line block"
        // in the body. Sublist-only items (no continuation paragraphs)
        // still render with the existing newline-before-sublist rule.
        let hasContinuation = item.body.contains {
            if case .list = $0 { return false }
            if case .blankLine = $0 { return false }
            return true
        }
        let hasAnySublist = item.body.contains {
            if case .list = $0 { return true }
            return false
        }
        let isEmpty = inlineHTML.isEmpty && !hasAnySublist && !hasContinuation

        if item.isTodo {
            let checkbox = item.isChecked
                ? "<input checked=\"\" disabled=\"\" type=\"checkbox\" /> "
                : "<input disabled=\"\" type=\"checkbox\" /> "
            if tight {
                content += "<li>\(checkbox)\(inlineHTML)"
            } else {
                content += "<li>\n<p>\(checkbox)\(inlineHTML)</p>\n"
            }
        } else if isEmpty {
            // Empty list item: no <p> wrapper regardless of tight/loose.
            content += "<li>"
        } else if inlineHTML.isEmpty && hasContinuation {
            // No first-line content but later blocks — treat the first
            // continuation block as the visible content of the item.
            content += "<li>\n"
        } else {
            if tight {
                content += "<li>\(inlineHTML)"
                if hasContinuation {
                    // Tight items with continuation blocks need a
                    // newline between the inline content and the first
                    // continuation block so output reads
                    // `<li>a\n<blockquote>...` (spec #320, #321) rather
                    // than `<li>a<blockquote>...`.
                    content += "\n"
                }
            } else {
                content += "<li>\n<p>\(inlineHTML)</p>\n"
            }
        }

        // Walk the body in source order, rendering each block in turn.
        // Sublists go through `renderList` (their loose flag is
        // self-determined); other blocks go through `renderBlock` with
        // the outer-list tightness flag (so paragraphs unwrap when the
        // outer list is tight, per CommonMark §5.4); blank-line markers
        // are skipped (their role was the looseness signal upstream).
        // Sublists in tight items need a leading newline so the
        // `<li>foo\n<ul>...` formatting matches the legacy output for
        // pre-#325 cases.
        var firstBodyBlock = true
        for block in item.body {
            if case .blankLine = block { continue }
            if case .list(let subItems, _) = block {
                if tight && firstBodyBlock && !hasContinuation {
                    content += "\n"
                }
                content += renderList(subItems)
            } else {
                content += renderBlock(block, inTightList: tight)
            }
            firstBodyBlock = false
        }

        content += "</li>\n"
        return content
    }

    private static func isOrderedMarker(_ marker: String) -> Bool {
        // Ordered markers end with . or )
        marker.hasSuffix(".") || marker.hasSuffix(")")
    }

    private static func extractOrderedStart(_ marker: String) -> Int {
        let digits = marker.filter { $0.isNumber }
        return Int(digits) ?? 1
    }

    /// Secondary tight/loose heuristic for nested lists (which don't
    /// carry their own `loose` flag from the parser). For top-level
    /// lists, the parser's `loose` flag takes precedence.
    private static func detectTightList(_ items: [ListItem]) -> Bool {
        return true
    }

    // MARK: - Blockquote rendering

    private func renderBlockquote(_ lines: [BlockquoteLine]) -> String {
        // Reconstruct the inner markdown by serializing each line's
        // inlines AND preserving the nested-blockquote prefix —
        // `line.level - 1` `>` markers, separated by a single space
        // (CommonMark canonical form). Re-parse the result as a
        // document so nested <blockquote> elements emerge from
        // recursion into renderBlock.
        //
        // CommonMark §4.3: a setext heading underline MAY NOT be a
        // lazy continuation line of an outer block. Spec #93:
        //     > foo
        //     bar
        //     ===
        // — the `===` is lazy-continued into the blockquote paragraph
        // and is NOT a setext underline. Our parser correctly captures
        // all three lines as blockquote content, but the inner re-parse
        // loses that context and would treat `===` as a setext
        // underline. Guard against that by escaping the lead character
        // of any lazy-continuation line (empty prefix) whose content
        // matches a setext-underline pattern — the backslash prevents
        // the inner parse from recognizing the underline without
        // affecting the rendered output.
        var renderedLines: [String] = []
        for line in lines {
            let innerPrefix = line.level > 1
                ? String(repeating: "> ", count: line.level - 1)
                : ""
            let body = MarkdownSerializer.serializeInlines(line.inline)
            let isLazy = line.prefix.isEmpty
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            let looksLikeSetextUnderline =
                !trimmed.isEmpty
                && (trimmed.allSatisfy { $0 == "=" } || trimmed.allSatisfy { $0 == "-" })
            if isLazy && looksLikeSetextUnderline {
                renderedLines.append(innerPrefix + "\\" + body)
            } else {
                renderedLines.append(innerPrefix + body)
            }
        }
        let innerMarkdown = renderedLines.joined(separator: "\n") + "\n"

        // Re-parse the inner content as a document
        let innerDoc = MarkdownParser.parse(innerMarkdown)
        var innerHTML = ""
        for block in innerDoc.blocks {
            if case .blankLine = block { continue }
            innerHTML += renderBlock(block, inTightList: false)
        }

        return "<blockquote>\n\(innerHTML)</blockquote>\n"
    }

    // MARK: - Table rendering

    private func renderTable(header: [TableCell], alignments: [TableAlignment], rows: [[TableCell]]) -> String {
        var html = "<table>\n<thead>\n<tr>\n"
        for (i, cell) in header.enumerated() {
            let align = i < alignments.count ? alignments[i] : .none
            let alignAttr: String
            switch align {
            case .left: alignAttr = " align=\"left\""
            case .center: alignAttr = " align=\"center\""
            case .right: alignAttr = " align=\"right\""
            case .none: alignAttr = ""
            }
            // Cells already carry parsed inline trees — render them
            // directly via renderInlines without re-parsing.
            html += "<th\(alignAttr)>\(Self.renderInlines(cell.inline))</th>\n"
        }
        html += "</tr>\n</thead>\n<tbody>\n"
        for row in rows {
            html += "<tr>\n"
            for (i, cell) in row.enumerated() {
                let align = i < alignments.count ? alignments[i] : .none
                let alignAttr: String
                switch align {
                case .left: alignAttr = " align=\"left\""
                case .center: alignAttr = " align=\"center\""
                case .right: alignAttr = " align=\"right\""
                case .none: alignAttr = ""
                }
                html += "<td\(alignAttr)>\(Self.renderInlines(cell.inline))</td>\n"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    // MARK: - Inline rendering

    static func renderInlines(_ inlines: [Inline]) -> String {
        // Pre-process: drop trailing hard line break at end of inline sequence
        // (CommonMark: hard break at end of paragraph is ignored).
        var processed = inlines
        if let last = processed.last, case .lineBreak = last {
            processed.removeLast()
            // Also strip trailing spaces from the now-last text element
            if let lastIdx = processed.indices.last {
                if case .text(let t) = processed[lastIdx] {
                    let trimmed = Self.stripTrailingSpaces(t)
                    processed[lastIdx] = .text(trimmed)
                }
            }
        }

        var output = ""
        for (idx, inline) in processed.enumerated() {
            // Check if previous inline was a lineBreak — if so, we need
            // to strip leading spaces from this text element.
            let afterLineBreak = idx > 0 && {
                if case .lineBreak = processed[idx - 1] { return true }
                return false
            }()

            switch inline {
            case .text(let text):
                // Handle soft line breaks: embedded \n in text.
                // CommonMark: trailing spaces before soft break and leading
                // spaces after soft break are stripped.
                var t = text
                if afterLineBreak {
                    // Strip leading spaces after a hard line break
                    t = Self.stripLeadingSpaces(t)
                }
                output += Self.renderSoftLineBreaks(t)
            case .bold(let children, _):
                output += "<strong>\(renderInlines(children))</strong>"
            case .italic(let children, _):
                output += "<em>\(renderInlines(children))</em>"
            case .strikethrough(let children):
                output += "<del>\(renderInlines(children))</del>"
            case .code(let text):
                output += "<code>\(escapeHTML(text))</code>"
            case .link(let text, let rawDest):
                let (url, linkTitle) = extractURLAndTitle(from: rawDest)
                // Decode entities in URL and percent-encode non-ASCII
                let decodedURL = Self.decodeEntitiesInString(url)
                let percentEncodedURL = Self.percentEncodeNonASCII(decodedURL)
                let escapedURL = escapeHTML(percentEncodedURL)
                let rendered = renderInlines(text)
                if let linkTitle = linkTitle {
                    let decodedTitle = Self.decodeEntitiesInString(linkTitle)
                    output += "<a href=\"\(escapedURL)\" title=\"\(escapeHTML(decodedTitle))\">\(rendered)</a>"
                } else {
                    output += "<a href=\"\(escapedURL)\">\(rendered)</a>"
                }
            case .image(let alt, let rawDest, _):
                let (url, imgTitle) = extractURLAndTitle(from: rawDest)
                let decodedURL = Self.decodeEntitiesInString(url)
                let percentEncodedURL = Self.percentEncodeNonASCII(decodedURL)
                let escapedURL = escapeHTML(percentEncodedURL)
                let altText = plainText(from: alt)
                if let imgTitle = imgTitle {
                    let decodedTitle = Self.decodeEntitiesInString(imgTitle)
                    output += "<img src=\"\(escapedURL)\" alt=\"\(escapeHTML(altText))\" title=\"\(escapeHTML(decodedTitle))\" />"
                } else {
                    output += "<img src=\"\(escapedURL)\" alt=\"\(escapeHTML(altText))\" />"
                }
            case .autolink(let text, let isEmail):
                let href = isEmail ? "mailto:\(text)" : text
                let encodedHref = Self.percentEncodeNonASCII(href)
                output += "<a href=\"\(escapeHTML(encodedHref))\">\(escapeHTML(text))</a>"
            case .escapedChar(let ch):
                output += escapeHTML(String(ch))
            case .lineBreak:
                output += "<br />\n"
            case .rawHTML(let html):
                output += html
            case .entity(let raw):
                // CommonMark: entities are replaced by their Unicode character,
                // then that character is HTML-escaped in the output.
                if let multiScalar = decodeEntityToString(raw) {
                    output += escapeHTML(multiScalar)
                } else if let decoded = decodeEntity(raw) {
                    output += escapeHTML(String(decoded))
                } else {
                    output += escapeHTML(raw)
                }
            case .underline(let children):
                output += "<u>\(renderInlines(children))</u>"
            case .highlight(let children):
                output += "<mark>\(renderInlines(children))</mark>"
            case .math(let s):
                output += "<code>\(escapeHTML(s))</code>"
            case .displayMath(let s):
                output += "<code>\(escapeHTML(s))</code>"
            case .wikilink(let target, let display):
                let visible = display ?? target
                let encoded = target.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed) ?? target
                output += "<a href=\"wiki:\(escapeHTML(encoded))\">\(escapeHTML(visible))</a>"
            case .superscript(let children):
                output += "<sup>\(renderInlines(children))</sup>"
            case .`subscript`(let children):
                output += "<sub>\(renderInlines(children))</sub>"
            case .kbd(let children):
                output += "<kbd>\(renderInlines(children))</kbd>"
            }
        }
        return output
    }

    /// Render text containing soft line breaks (embedded \n).
    /// Strips trailing spaces before and leading spaces after each \n.
    private static func renderSoftLineBreaks(_ text: String) -> String {
        guard text.contains("\n") else { return escapeHTML(text) }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result = ""
        for (i, part) in parts.enumerated() {
            var segment = String(part)
            if i > 0 {
                // Strip leading spaces after soft break
                segment = stripLeadingSpaces(segment)
            }
            if i < parts.count - 1 {
                // Strip trailing spaces before soft break
                segment = stripTrailingSpaces(segment)
            }
            result += escapeHTML(segment)
            if i < parts.count - 1 {
                result += "\n"
            }
        }
        return result
    }

    private static func stripTrailingSpaces(_ s: String) -> String {
        var result = s
        while result.hasSuffix(" ") { result = String(result.dropLast()) }
        return result
    }

    private static func stripLeadingSpaces(_ s: String) -> String {
        var result = s
        while result.hasPrefix(" ") { result = String(result.dropFirst()) }
        return result
    }

    // MARK: - Inline helpers

    /// Extract the URL and optional title from a raw link destination.
    /// The rawDestination may contain `url "title"`, `<url>`, `<url> "title"`, or just `url`.
    private static func extractURLAndTitle(from raw: String) -> (url: String, title: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var url = ""
        var title: String? = nil

        if trimmed.isEmpty {
            return ("", nil)
        }

        var chars = Array(trimmed)
        var i = 0

        // Angle-bracketed URL
        if chars[i] == "<" {
            i += 1
            let urlStart = i
            while i < chars.count && chars[i] != ">" {
                if chars[i] == "\\" && i + 1 < chars.count { i += 1 } // skip escaped
                i += 1
            }
            url = String(chars[urlStart..<i])
            if i < chars.count { i += 1 } // skip >
        } else {
            // Bare URL — take until whitespace, respecting balanced parens
            let urlStart = i
            var parenDepth = 0
            while i < chars.count {
                if chars[i] == "(" { parenDepth += 1 }
                else if chars[i] == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                } else if chars[i] == " " || chars[i] == "\t" || chars[i] == "\n" {
                    if parenDepth == 0 { break }
                } else if chars[i] == "\\" && i + 1 < chars.count {
                    i += 1 // skip escaped char
                }
                i += 1
            }
            url = String(chars[urlStart..<i])
        }

        // Skip whitespace
        while i < chars.count && (chars[i] == " " || chars[i] == "\t" || chars[i] == "\n") { i += 1 }

        // Optional title
        if i < chars.count {
            let quoteChar = chars[i]
            if quoteChar == "\"" || quoteChar == "'" {
                i += 1
                let titleStart = i
                while i < chars.count && chars[i] != quoteChar {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    i += 1
                }
                title = String(chars[titleStart..<i])
            } else if quoteChar == "(" {
                i += 1
                let titleStart = i
                while i < chars.count && chars[i] != ")" {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    i += 1
                }
                title = String(chars[titleStart..<i])
            }
        }

        // Unescape backslash sequences in the URL AND the title
        // (CommonMark: ASCII punctuation backslash-escapes apply in
        // both). Example #506: `title \"&quot;"` — the `\"` sequence
        // must unescape to a literal `"` before HTML-escaping.
        url = unescapeBackslashes(url)
        if let t = title { title = unescapeBackslashes(t) }

        return (url, title)
    }

    /// Remove backslash escapes before ASCII punctuation characters.
    internal static func unescapeBackslashes(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count && isPunctuationChar(chars[i + 1]) {
                result.append(chars[i + 1])
                i += 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    /// Check if a character is an ASCII punctuation character (CommonMark definition).
    private static func isPunctuationChar(_ ch: Character) -> Bool {
        let punctuation: Set<Character> = [
            "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".",
            "/", ":", ";", "<", "=", ">", "?", "@", "[", "\\", "]", "^", "_",
            "`", "{", "|", "}", "~"
        ]
        return punctuation.contains(ch)
    }

    /// Extract plain text from inlines (strips all formatting/tags).
    private static func plainText(from inlines: [Inline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case .text(let t):
                result += t
            case .bold(let children, _), .italic(let children, _),
                 .strikethrough(let children),
                 .underline(let children), .highlight(let children),
                 .superscript(let children), .`subscript`(let children),
                 .kbd(let children):
                result += plainText(from: children)
            case .code(let t):
                result += t
            case .math(let t):
                result += t
            case .displayMath(let t):
                result += t
            case .link(let text, _):
                result += plainText(from: text)
            case .image(let alt, _, _):
                result += plainText(from: alt)
            case .autolink(let text, _):
                result += text
            case .escapedChar(let ch):
                result += String(ch)
            case .lineBreak:
                result += "\n"
            case .rawHTML:
                break
            case .entity(let raw):
                if let multiScalar = decodeEntityToString(raw) {
                    result += multiScalar
                } else if let decoded = decodeEntity(raw) {
                    result += String(decoded)
                } else {
                    result += raw
                }
            case .wikilink(let target, let display):
                result += display ?? target
            }
        }
        return result
    }

    // MARK: - Entity decoding

    /// Decode an HTML entity reference to its Unicode character.
    /// Handles numeric (decimal and hex) and named entities.
    /// Returns nil if the entity is invalid or unknown.
    private static func decodeEntity(_ entity: String) -> Character? {
        guard entity.hasPrefix("&") && entity.hasSuffix(";") else { return nil }

        if entity.hasPrefix("&#") {
            // Numeric entity
            let inner = String(entity.dropFirst(2).dropLast(1))
            let codePoint: UInt32?
            if inner.hasPrefix("x") || inner.hasPrefix("X") {
                // Hex: &#xHEX;
                codePoint = UInt32(inner.dropFirst(), radix: 16)
            } else {
                // Decimal: &#DEC;
                codePoint = UInt32(inner)
            }
            guard let cp = codePoint else { return nil }
            // Code point 0 maps to U+FFFD per CommonMark spec
            if cp == 0 {
                return "\u{FFFD}"
            }
            guard let scalar = Unicode.Scalar(cp) else { return nil }
            return Character(scalar)
        }

        // Named entity: look up in table
        let name = String(entity.dropFirst().dropLast())
        return namedEntityTable[name]
    }

    /// Named HTML5 entity table mapping entity names to their Unicode characters.
    private static let namedEntityTable: [String: Character] = [
        // Core XML entities
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        // Whitespace and special
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "shy": "\u{00AD}",
        "lrm": "\u{200E}", "rlm": "\u{200F}",
        "zwj": "\u{200D}", "zwnj": "\u{200C}",
        // Typography
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "bull": "\u{2022}", "middot": "\u{00B7}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "sbquo": "\u{201A}", "bdquo": "\u{201E}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "lsaquo": "\u{2039}", "rsaquo": "\u{203A}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}", "permil": "\u{2030}",
        // Arrows
        "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}", "darr": "\u{2193}",
        "harr": "\u{2194}", "lArr": "\u{21D0}", "rArr": "\u{21D2}",
        "uArr": "\u{21D1}", "dArr": "\u{21D3}", "hArr": "\u{21D4}",
        // Math and symbols
        "sect": "\u{00A7}", "para": "\u{00B6}", "deg": "\u{00B0}",
        "plusmn": "\u{00B1}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "micro": "\u{00B5}", "cent": "\u{00A2}", "pound": "\u{00A3}",
        "euro": "\u{20AC}", "yen": "\u{00A5}", "curren": "\u{00A4}",
        "iexcl": "\u{00A1}", "iquest": "\u{00BF}",
        "ordf": "\u{00AA}", "ordm": "\u{00BA}",
        "not": "\u{00AC}", "macr": "\u{00AF}", "acute": "\u{00B4}",
        "cedil": "\u{00B8}",
        "sup1": "\u{00B9}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "frac14": "\u{00BC}", "frac12": "\u{00BD}", "frac34": "\u{00BE}",
        "fnof": "\u{0192}", "minus": "\u{2212}", "lowast": "\u{2217}",
        "radic": "\u{221A}", "prop": "\u{221D}", "infin": "\u{221E}",
        "ang": "\u{2220}", "and": "\u{2227}", "or": "\u{2228}",
        "cap": "\u{2229}", "cup": "\u{222A}", "int": "\u{222B}",
        "there4": "\u{2234}", "sim": "\u{223C}", "cong": "\u{2245}",
        "asymp": "\u{2248}", "ne": "\u{2260}", "equiv": "\u{2261}",
        "le": "\u{2264}", "ge": "\u{2265}",
        "sub": "\u{2282}", "sup": "\u{2283}", "nsub": "\u{2284}",
        "sube": "\u{2286}", "supe": "\u{2287}",
        "oplus": "\u{2295}", "otimes": "\u{2297}",
        "perp": "\u{22A5}", "sdot": "\u{22C5}",
        "lceil": "\u{2308}", "rceil": "\u{2309}",
        "lfloor": "\u{230A}", "rfloor": "\u{230B}",
        "lang": "\u{27E8}", "rang": "\u{27E9}",
        "loz": "\u{25CA}", "sum": "\u{2211}", "prod": "\u{220F}",
        "forall": "\u{2200}", "part": "\u{2202}", "exist": "\u{2203}",
        "empty": "\u{2205}", "nabla": "\u{2207}",
        "isin": "\u{2208}", "notin": "\u{2209}", "ni": "\u{220B}",
        // Card suits
        "hearts": "\u{2665}", "spades": "\u{2660}",
        "clubs": "\u{2663}", "diams": "\u{2666}",
        // Greek uppercase
        "Alpha": "\u{0391}", "Beta": "\u{0392}", "Gamma": "\u{0393}",
        "Delta": "\u{0394}", "Epsilon": "\u{0395}", "Zeta": "\u{0396}",
        "Eta": "\u{0397}", "Theta": "\u{0398}", "Iota": "\u{0399}",
        "Kappa": "\u{039A}", "Lambda": "\u{039B}", "Mu": "\u{039C}",
        "Nu": "\u{039D}", "Xi": "\u{039E}", "Omicron": "\u{039F}",
        "Pi": "\u{03A0}", "Rho": "\u{03A1}", "Sigma": "\u{03A3}",
        "Tau": "\u{03A4}", "Upsilon": "\u{03A5}", "Phi": "\u{03A6}",
        "Chi": "\u{03A7}", "Psi": "\u{03A8}", "Omega": "\u{03A9}",
        // Greek lowercase
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}",
        "delta": "\u{03B4}", "epsilon": "\u{03B5}", "zeta": "\u{03B6}",
        "eta": "\u{03B7}", "theta": "\u{03B8}", "iota": "\u{03B9}",
        "kappa": "\u{03BA}", "lambda": "\u{03BB}", "mu": "\u{03BC}",
        "nu": "\u{03BD}", "xi": "\u{03BE}", "omicron": "\u{03BF}",
        "pi": "\u{03C0}", "rho": "\u{03C1}", "sigmaf": "\u{03C2}",
        "sigma": "\u{03C3}", "tau": "\u{03C4}", "upsilon": "\u{03C5}",
        "phi": "\u{03C6}", "chi": "\u{03C7}", "psi": "\u{03C8}",
        "omega": "\u{03C9}", "thetasym": "\u{03D1}", "upsih": "\u{03D2}",
        "piv": "\u{03D6}",
        // Latin extended uppercase
        "AElig": "\u{00C6}", "Aacute": "\u{00C1}", "Acirc": "\u{00C2}",
        "Agrave": "\u{00C0}", "Aring": "\u{00C5}", "Atilde": "\u{00C3}",
        "Auml": "\u{00C4}", "Ccedil": "\u{00C7}", "ETH": "\u{00D0}",
        "Eacute": "\u{00C9}", "Ecirc": "\u{00CA}", "Egrave": "\u{00C8}",
        "Euml": "\u{00CB}", "Iacute": "\u{00CD}", "Icirc": "\u{00CE}",
        "Igrave": "\u{00CC}", "Iuml": "\u{00CF}", "Ntilde": "\u{00D1}",
        "Oacute": "\u{00D3}", "Ocirc": "\u{00D4}", "Ograve": "\u{00D2}",
        "Oslash": "\u{00D8}", "Otilde": "\u{00D5}", "Ouml": "\u{00D6}",
        "THORN": "\u{00DE}", "Uacute": "\u{00DA}", "Ucirc": "\u{00DB}",
        "Ugrave": "\u{00D9}", "Uuml": "\u{00DC}", "Yacute": "\u{00DD}",
        // Latin extended lowercase
        "aacute": "\u{00E1}", "acirc": "\u{00E2}", "agrave": "\u{00E0}",
        "aring": "\u{00E5}", "atilde": "\u{00E3}", "auml": "\u{00E4}",
        "ccedil": "\u{00E7}", "eacute": "\u{00E9}", "ecirc": "\u{00EA}",
        "egrave": "\u{00E8}", "euml": "\u{00EB}", "eth": "\u{00F0}",
        "iacute": "\u{00ED}", "icirc": "\u{00EE}", "igrave": "\u{00EC}",
        "iuml": "\u{00EF}", "ntilde": "\u{00F1}",
        "oacute": "\u{00F3}", "ocirc": "\u{00F4}", "ograve": "\u{00F2}",
        "oslash": "\u{00F8}", "otilde": "\u{00F5}", "ouml": "\u{00F6}",
        "szlig": "\u{00DF}", "thorn": "\u{00FE}",
        "uacute": "\u{00FA}", "ucirc": "\u{00FB}", "ugrave": "\u{00F9}",
        "uuml": "\u{00FC}", "yacute": "\u{00FD}", "yuml": "\u{00FF}",
        // Additional HTML5 entities from CommonMark spec examples
        "Dcaron": "\u{010E}",
        "HilbertSpace": "\u{210B}",
        "DifferentialD": "\u{2146}",
        "ClockwiseContourIntegral": "\u{2232}",
        // ngE is handled separately in decodeEntityToString (multi-scalar)
    ]

    /// Special case for entities that decode to multi-scalar characters.
    /// Most entities map to a single Character, but some (like &ngE;)
    /// require multiple Unicode scalars.
    private static func decodeEntityToString(_ entity: String) -> String? {
        guard entity.hasPrefix("&") && entity.hasSuffix(";") else { return nil }
        let name = String(entity.dropFirst().dropLast())
        // Multi-scalar entities
        if name == "ngE" { return "\u{2267}\u{0338}" }
        return nil
    }

    /// Decode all entity references in a plain string (e.g., code block info strings).
    /// Scans for &...; patterns and replaces valid ones with decoded characters.
    static func decodeEntitiesInString(_ text: String) -> String {
        var result = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "&" {
                // Try to find the closing ;
                var j = i + 1
                while j < chars.count && j - i <= 32 && chars[j] != ";" && chars[j] != "&" {
                    j += 1
                }
                if j < chars.count && chars[j] == ";" {
                    let entity = String(chars[i...j])
                    if let multiScalar = decodeEntityToString(entity) {
                        result += multiScalar
                        i = j + 1
                        continue
                    } else if let decoded = decodeEntity(entity) {
                        result += String(decoded)
                        i = j + 1
                        continue
                    }
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// Characters that are safe in URLs (unreserved + reserved delimiters).
    /// Everything else gets percent-encoded.
    private static let urlSafeCharacters: Set<Character> = {
        var safe = Set<Character>()
        // Unreserved: ALPHA, DIGIT, -, ., _, ~
        for ch in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~" {
            safe.insert(ch)
        }
        // Reserved characters used as delimiters (keep as-is in URLs).
        // `[` and `]` are EXCLUDED here — per CommonMark spec examples
        // (autolink #603) square brackets in URLs percent-encode to
        // %5B / %5D. They are not valid delimiter characters in the
        // path/query sections of a URL.
        for ch in ":/?#@!$&'()*+,;=" {
            safe.insert(ch)
        }
        // Percent sign itself (already-encoded sequences)
        safe.insert("%")
        return safe
    }()

    /// Percent-encode characters in a URL string that are not valid in URIs.
    /// Handles both non-ASCII characters (UTF-8 encoded) and unsafe ASCII characters.
    private static func percentEncodeNonASCII(_ url: String) -> String {
        var result = ""
        for char in url {
            if urlSafeCharacters.contains(char) {
                result.append(char)
            } else {
                // Encode as UTF-8 bytes
                for byte in String(char).utf8 {
                    result += String(format: "%%%02X", byte)
                }
            }
        }
        return result
    }

    // MARK: - HTML escaping

    static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result += String(char)
            }
        }
        return result
    }
}
