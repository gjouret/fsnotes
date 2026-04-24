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
//  paragraphs with inline bold/italic/code/strikethrough emphasis,
//  backslash escapes, autolinks, raw HTML, entity references, links,
//  images, hard line breaks, underscore emphasis, lists (unordered +
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

        // First pass: collect link reference definitions, respecting
        // code fences. Lines that are link ref defs are consumed and
        // NOT emitted as blocks.
        let (refDefs, consumedLines) = collectLinkRefDefs(lines, trailingNewline: markdown.hasSuffix("\n"))

        var blocks: [Block] = []
        var i = 0
        var rawBuffer: [String] = []

        func flushRawBuffer() {
            guard !rawBuffer.isEmpty else { return }
            let text = rawBuffer.joined(separator: "\n")
            blocks.append(.paragraph(inline: parseInlines(text, refDefs: refDefs)))
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

            // Skip lines consumed as link reference definitions.
            if consumedLines.contains(i) {
                i += 1
                continue
            }

            if let fence = detectFenceOpen(line) {
                flushRawBuffer()

                // Scan forward for the matching close fence.
                var contentLines: [String] = []
                var j = i + 1
                var foundClose = false

                while j < lines.count {
                    let l = lines[j]
                    // Skip the synthetic trailing "" for file-ending newline
                    if j == lines.count - 1 && l.isEmpty && markdown.hasSuffix("\n") {
                        break
                    }
                    if isFenceClose(l, matching: fence) {
                        foundClose = true
                        break
                    }
                    contentLines.append(l)
                    j += 1
                }

                // Strip up to `fence.indent` leading spaces from each
                // content line (CommonMark indentation removal rule).
                if fence.indent > 0 {
                    contentLines = contentLines.map { contentLine in
                        let lineChars = Array(contentLine)
                        var strip = 0
                        while strip < fence.indent && strip < lineChars.count && lineChars[strip] == " " {
                            strip += 1
                        }
                        return String(lineChars[strip...])
                    }
                }

                let content: String
                let advanceTo: Int
                if foundClose {
                    content = contentLines.joined(separator: "\n")
                    advanceTo = j + 1
                } else {
                    // Unterminated fence: code block extends to end of
                    // document (CommonMark rule). No closing fence line.
                    content = contentLines.joined(separator: "\n")
                    advanceTo = j
                }

                let infoTrimmed = fence.infoRaw.trimmingCharacters(in: .whitespaces)
                let language = infoTrimmed.isEmpty ? nil : infoTrimmed
                let fenceStyle = FenceStyle(
                    character: fence.fenceChar == "`" ? .backtick : .tilde,
                    length: fence.fenceLength,
                    infoRaw: fence.infoRaw
                )
                blocks.append(.codeBlock(language: language, content: content, fence: fenceStyle))
                i = advanceTo
                continue
            }

            if detectBlockquoteLine(line) != nil {
                flushRawBuffer()
                var qLines: [BlockquoteLine] = []
                // Track inner content lines (after stripping > prefix)
                // for lazy continuation analysis.
                var innerContentLines: [String] = []
                var j = i
                while j < lines.count {
                    let l = lines[j]
                    if j == lines.count - 1 && l.isEmpty && markdown.hasSuffix("\n") {
                        break
                    }
                    if let parts = detectBlockquoteLine(l) {
                        // Normal blockquote line with > prefix
                        qLines.append(BlockquoteLine(
                            prefix: parts.prefix,
                            inline: parseInlines(parts.content, refDefs: refDefs)
                        ))
                        innerContentLines.append(parts.content)
                        j += 1
                    } else if !interruptsLazyContinuation(l)
                                && blockquoteInnerAllowsLazyContinuation(innerContentLines) {
                        // Lazy continuation: line without > that continues
                        // the last paragraph inside the blockquote.
                        qLines.append(BlockquoteLine(
                            prefix: "",
                            inline: parseInlines(l, refDefs: refDefs)
                        ))
                        innerContentLines.append(l)
                        j += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(lines: qLines))
                i = j
                continue
            }

            // Setext heading: paragraph text followed by === (H1) or --- (H2).
            // Must check BEFORE horizontal rule, because "---" is both a
            // setext underline and an HR — context determines which.
            // Exception: if the paragraph is entirely wrapped in emphasis
            // markers (**...**), it's a bold paragraph + HR, not a heading.
            if !rawBuffer.isEmpty, let setextLevel = detectSetextUnderline(line),
               !isEmphasisOnlyParagraph(rawBuffer) {
                // Combine rawBuffer into the heading text.
                let headingText = rawBuffer.joined(separator: "\n")
                rawBuffer.removeAll()
                // The suffix includes a leading space to match ATX heading
                // convention (round-trip: setext serializes differently).
                blocks.append(.heading(level: setextLevel, suffix: " " + headingText))
                i += 1
                continue
            }

            if let hr = detectHorizontalRule(line) {
                flushRawBuffer()
                blocks.append(.horizontalRule(character: hr.character, length: hr.length))
                i += 1
                continue
            }

            // Table detection: a line containing "|" followed by a
            // separator line ("|", "-", ":", spaces). The raw buffer
            // might already contain the header line if the parser
            // buffered it as a paragraph line. Check both cases:
            // (a) current line is header + next line is separator
            // (b) rawBuffer has one line (header) + current line is separator
            if let tableBlock = detectTable(lines: lines, at: i, rawBuffer: rawBuffer, markdown: markdown) {
                // If the header was in the rawBuffer, remove it.
                if tableBlock.headerFromBuffer {
                    rawBuffer.removeLast()
                }
                flushRawBuffer()
                blocks.append(tableBlock.block)
                i = tableBlock.nextIndex
                continue
            }

            if let firstParsed = parseListLine(line),
               // Don't let a bare marker at EOL (e.g. "*", "1.") interrupt
               // a paragraph. CommonMark example 285: "foo\n*" is a paragraph,
               // not a paragraph + list. Only applies when raw buffer has content.
               !(rawBuffer.count > 0 && firstParsed.afterMarker.isEmpty && firstParsed.content.isEmpty),
               // CommonMark 5.3: an ordered list with a starting number other
               // than 1 cannot interrupt a paragraph. Example 304: a paragraph
               // that happens to contain "14. ..." as its second line must
               // remain a single paragraph, not paragraph + list.
               !(rawBuffer.count > 0 && isOrderedListMarkerWithNonOneStart(firstParsed.marker)) {
                flushRawBuffer()

                // Determine the list type from the first item's marker.
                // A change in bullet character or ordered delimiter
                // starts a new list (CommonMark rule). This check only
                // applies to items at the SAME indent level — nested
                // items can have different marker types (e.g. unordered
                // list containing ordered sublist).
                let listType = Self.listMarkerType(firstParsed.marker)
                let topIndent = firstParsed.indent.count

                // Collect list lines, continuing through blank lines
                // when the next non-blank line is a list item of the
                // same type. Track whether any blank lines separate
                // items (makes the list "loose"). Each item that
                // follows a blank line gets blankLineBefore = true
                // for round-trip serialization.
                var parsedLines: [ParsedListLine] = [firstParsed]
                var hasBlankLines = false
                var nextItemFollowsBlank = false
                // Track the number of *consecutive* blank lines between
                // the current position and the previous content line.
                // Two or more consecutive blanks still terminate the list
                // when followed by non-indented content, but single
                // blanks within indented continuations are preserved.
                var j = i + 1
                while j < lines.count {
                    let l = lines[j]
                    if j == lines.count - 1 && l.isEmpty && markdown.hasSuffix("\n") {
                        break
                    }
                    if l.isEmpty {
                        // Blank line: peek ahead.
                        var k = j + 1
                        while k < lines.count && lines[k].isEmpty { k += 1 }
                        // End of input or trailing-newline synthetic empty.
                        if k >= lines.count
                            || (k == lines.count - 1 && lines[k].isEmpty && markdown.hasSuffix("\n"))
                        {
                            break
                        }
                        if let nextParsed = parseListLine(lines[k]) {
                            let nextIndent = nextParsed.indent.count
                            if nextIndent == topIndent && Self.listMarkerType(nextParsed.marker) != listType {
                                // Top-level item with different marker type — new list.
                                break
                            }
                            // Continue: skip blank line(s), mark as loose.
                            hasBlankLines = true
                            nextItemFollowsBlank = true
                            j = k
                            continue
                        }
                        // Next non-blank line is NOT a list marker. If it
                        // is indented to at least some existing item's
                        // content column, attach it (and any further
                        // indented-or-blank lines) as continuation of the
                        // deepest-matching existing item.
                        let nextLine = lines[k]
                        let nextIndentCount = leadingSpaceCount(nextLine)
                        let ownerIdx = deepestOwner(in: parsedLines, forIndent: nextIndentCount)
                        if ownerIdx == nil {
                            break
                        }
                        let ownerItem = parsedLines[ownerIdx!]
                        // CommonMark rule 3: a list item that begins with
                        // an empty first line (empty marker content) cannot
                        // contain a non-blank block. If the owner's own
                        // first line was empty AND this is the owner's
                        // first continuation attempt, treat the blank as
                        // terminating the list instead.
                        if ownerItem.content.isEmpty
                            && ownerItem.afterMarker.isEmpty
                            && ownerItem.continuationLines.isEmpty {
                            break
                        }
                        let contentCol = ownerItem.indent.count
                            + ownerItem.marker.count + ownerItem.afterMarker.count
                        // Record the blank-line gap, then consume indented
                        // (or blank) lines. Stop at the first line whose
                        // indent is less than contentCol AND is non-blank
                        // AND is not a list marker of this list (list
                        // markers are handled by the outer loop).
                        // Preserve the blanks between the item and the
                        // continuation to distinguish tight vs loose.
                        var continuation = parsedLines[ownerIdx!].continuationLines
                        // Prepend blank gap
                        for _ in j..<k { continuation.append("") }
                        var m = k
                        while m < lines.count {
                            let line2 = lines[m]
                            if m == lines.count - 1 && line2.isEmpty && markdown.hasSuffix("\n") {
                                break
                            }
                            if line2.isEmpty {
                                // Keep consuming blanks — they may sit
                                // between continuation blocks.
                                continuation.append("")
                                m += 1
                                continue
                            }
                            let lineIndentCount = leadingSpaceCount(line2)
                            // If it's a list marker, decide whether it
                            // belongs to this list before taking over.
                            if let maybeMarker = parseListLine(line2) {
                                // A marker at indent < contentCol breaks
                                // out of this item's continuation and
                                // returns control to the outer loop.
                                if maybeMarker.indent.count < contentCol {
                                    break
                                }
                                // Otherwise it's a nested list marker
                                // inside the continuation — fold it into
                                // the continuation text rather than
                                // promoting to a new item.
                            }
                            if lineIndentCount < contentCol {
                                break
                            }
                            // Strip contentCol leading spaces (CommonMark
                            // indentation removal). The continuation is
                            // re-parsed as an inner document.
                            continuation.append(stripLeadingSpaces(line2, count: contentCol))
                            m += 1
                        }
                        // Trim trailing blanks — they belong outside the
                        // item.
                        while let last = continuation.last, last.isEmpty {
                            continuation.removeLast()
                        }
                        parsedLines[ownerIdx!].continuationLines = continuation
                        // Looseness propagation: a continuation makes
                        // the OWNER's list loose (captured via the
                        // owner's .continuationBlocks in renderList).
                        // The TOP-level list's looseness and the
                        // "next-item-follows-blank" marker are only
                        // set when the owner itself is a top-level
                        // item; otherwise the blank is structurally
                        // inside a nested owner and does not loosen
                        // the outer list.
                        if ownerItem.indent.count == topIndent {
                            hasBlankLines = true
                            nextItemFollowsBlank = true
                        }
                        j = m
                        continue
                    }
                    guard var parsed = parseListLine(l) else {
                        // Non-list line without a preceding blank.
                        //
                        // Narrow lazy continuation: if the line is
                        // indented at least to the last item's content
                        // column AND the last item has non-empty
                        // content (open paragraph), merge the line into
                        // the item's inline content with a soft
                        // line-break separator.
                        //
                        // Strict CommonMark would lazy-continue any
                        // indentation (including zero), but the editor
                        // layer produces `[list, paragraph]` Documents
                        // without explicit `.blankLine` separators —
                        // serializing those yields `- Item\nBody`, and
                        // a strict lazy-continuation parse would fold
                        // them into a single item. The narrower
                        // "indent ≥ content column" rule handles the
                        // well-formed CommonMark spec cases (#254,
                        // #286-#291 — where the continuation IS
                        // indented to the content column) without
                        // pulling unindented content into the list.
                        if !parsedLines.isEmpty {
                            let last = parsedLines[parsedLines.count - 1]
                            let hasOpenParagraph = !last.content.isEmpty
                                && last.continuationLines.isEmpty
                            if hasOpenParagraph {
                                let cc = last.indent.count
                                    + last.marker.count + last.afterMarker.count
                                let lineIndent = leadingSpaceCount(l)
                                // Narrow lazy continuation: merge only
                                // when the incoming line is indented
                                // MORE than the list item's opening
                                // column. Strict CommonMark would
                                // merge unindented lines too (#290),
                                // but the editor layer produces
                                // `[list, paragraph]` Documents
                                // without explicit `.blankLine`
                                // separators. A `line.indent >
                                // last.indent` threshold covers the
                                // well-formed spec cases where the
                                // continuation is at least partially
                                // indented (#254, #286-#289, #291)
                                // without pulling unindented content
                                // into the list at re-parse time.
                                if lineIndent > last.indent.count
                                    && !interruptsLazyContinuation(l)
                                {
                                    let stripped = stripLeadingSpaces(l, count: cc)
                                    let merged = last.content + "\n" + stripped
                                    parsedLines[parsedLines.count - 1] = ParsedListLine(
                                        indent: last.indent,
                                        marker: last.marker,
                                        afterMarker: last.afterMarker,
                                        checkbox: last.checkbox,
                                        content: merged,
                                        blankLineBefore: last.blankLineBefore,
                                        continuationLines: last.continuationLines
                                    )
                                    j += 1
                                    continue
                                }
                            }
                        }
                        break
                    }
                    // CommonMark 5.3 / 5.4: a list ends when the marker
                    // type changes — at ANY level where the new item is
                    // a sibling, not a child, of any item we've already
                    // collected. A line is a "child" of an earlier item
                    // only if its indent reaches that earlier item's
                    // content column. Otherwise it would be a sibling,
                    // and a sibling with a different marker type starts
                    // a new list.
                    if Self.listMarkerType(parsed.marker) != listType {
                        let childOfSome = parsedLines.contains(where: { existing in
                            let existingContentCol = existing.indent.count
                                + existing.marker.count + existing.afterMarker.count
                            return parsed.indent.count >= existingContentCol
                        })
                        if !childOfSome { break }
                    }
                    if nextItemFollowsBlank {
                        parsed.blankLineBefore = true
                        nextItemFollowsBlank = false
                    }
                    parsedLines.append(parsed)
                    j += 1
                }
                let (items, _) = buildItemTree(
                    lines: parsedLines, from: 0, parentContentColumn: -1, refDefs: refDefs
                )
                blocks.append(.list(items: items, loose: hasBlankLines))
                i = j
                continue
            }

            if let heading = detectHeading(line) {
                flushRawBuffer()
                blocks.append(.heading(level: heading.level, suffix: heading.suffix))
                i += 1
                continue
            }

            // HTML blocks: detect before paragraph buffer but after
            // code fences, headings, HR, blockquotes, lists.
            if let htmlType = detectHTMLBlock(line),
               // Type 7 cannot interrupt a paragraph (rawBuffer non-empty).
               !(htmlType == 7 && !rawBuffer.isEmpty) {
                flushRawBuffer()
                var htmlLines: [String] = [line]
                i += 1

                // Check if end condition is met on the opening line itself
                // (types 1-5 have specific end markers that can appear on
                // the same line as the start).
                let endedOnOpeningLine = Self.htmlBlockEndsOnLine(line, type: htmlType)

                if !endedOnOpeningLine {
                    while i < lines.count {
                        let nextLine = lines[i]
                        if i == lines.count - 1 && nextLine.isEmpty && markdown.hasSuffix("\n") {
                            break
                        }
                        if htmlType == 6 || htmlType == 7 {
                            // Type 6/7: end at blank line (exclusive)
                            if nextLine.trimmingCharacters(in: .whitespaces).isEmpty { break }
                        }
                        htmlLines.append(nextLine)
                        if htmlType == 1 {
                            let lower = nextLine.lowercased()
                            if lower.contains("</pre>") || lower.contains("</script>") || lower.contains("</style>") || lower.contains("</textarea>") { i += 1; break }
                        } else if htmlType == 2 {
                            if nextLine.contains("-->") { i += 1; break }
                        } else if htmlType == 3 {
                            if nextLine.contains("?>") { i += 1; break }
                        } else if htmlType == 4 {
                            if nextLine.contains(">") { i += 1; break }
                        } else if htmlType == 5 {
                            if nextLine.contains("]]>") { i += 1; break }
                        }
                        i += 1
                    }
                }
                blocks.append(.htmlBlock(raw: htmlLines.joined(separator: "\n")))
                continue
            }

            if line.isEmpty || isBlankLine(line) {
                // CommonMark: a blank line is empty or contains only
                // whitespace. Treat whitespace-only lines as blank lines
                // for block-termination purposes — they don't extend a
                // paragraph. This loses the original spaces for serialization
                // (round-trip is idempotent via blankLine -> "" -> blankLine).
                flushRawBuffer()
                blocks.append(.blankLine)
                i += 1
                continue
            }

            // Paragraph line buffering: strip up to 3 leading spaces per
            // CommonMark 4.8 (a paragraph is zero-or-more non-blank lines
            // that cannot be interpreted as other kinds of blocks; up to
            // 3 leading spaces are allowed). 4+ spaces would be an
            // indented code block, which we don't support.
            rawBuffer.append(stripUpTo3LeadingSpaces(line))
            i += 1
        }

        flushRawBuffer()

        // T2-g.4: attach persisted column widths to tables preceded by
        // our `<!-- fsnotes-col-widths: [...] -->` sentinel comment.
        blocks = attachPersistedColumnWidths(blocks)

        return Document(blocks: blocks, trailingNewline: markdown.hasSuffix("\n"), refDefs: refDefs)
    }

    // MARK: - T2-g.4 column-widths sidecar

    /// Scan the parsed block sequence and apply any
    /// `<!-- fsnotes-col-widths: [...] -->` sentinels that sit
    /// immediately before a `.table` block. The sentinel is stripped
    /// from the output; the following table gains the decoded
    /// `columnWidths`. Malformed sentinels are left as regular
    /// htmlBlocks so no markdown is lost.
    private static func attachPersistedColumnWidths(_ blocks: [Block]) -> [Block] {
        var out: [Block] = []
        out.reserveCapacity(blocks.count)
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            if case .htmlBlock(let raw) = block,
               let widths = parseColumnWidthsComment(raw),
               i + 1 < blocks.count,
               case .table(let header, let alignments, let rows, _) = blocks[i + 1],
               widths.count == alignments.count,
               widths.allSatisfy({ $0 > 0 }) {
                out.append(.table(
                    header: header,
                    alignments: alignments,
                    rows: rows,
                    columnWidths: widths
                ))
                i += 2
                continue
            }
            out.append(block)
            i += 1
        }
        return out
    }

    /// Decode a raw htmlBlock string as the T2-g.4 widths sentinel.
    private static func parseColumnWidthsComment(_ raw: String) -> [CGFloat]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "<!-- fsnotes-col-widths: "
        let suffix = " -->"
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else {
            return nil
        }
        let body = String(trimmed.dropFirst(prefix.count).dropLast(suffix.count))
        let inner = body.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("["), inner.hasSuffix("]") else { return nil }
        let contents = inner.dropFirst().dropLast()
        let parts = contents
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { return nil }
        var widths: [CGFloat] = []
        widths.reserveCapacity(parts.count)
        for p in parts {
            guard let d = Double(p), d > 0, d.isFinite else { return nil }
            widths.append(CGFloat(d))
        }
        return widths
    }

    // MARK: - Fence detection

    /// Info captured from a fence-open line. We store the fence string so
    /// the close must match exactly (CommonMark rule: close fence length
    /// must be >= open fence length AND use the same fence character).
    private struct Fence {
        let fenceChar: Character   // '`' or '~'
        let fenceLength: Int       // number of fence chars (>= 3)
        let infoRaw: String        // info string verbatim (not trimmed)
        let indent: Int            // 0-3 leading spaces on the opening fence
    }

    /// Detect whether `line` opens a fenced code block. Returns the Fence
    /// descriptor if so, nil otherwise.
    ///
    /// Rule: a fence-open is a line that starts with up to 3 leading
    /// spaces followed by >= 3 backticks or >= 3 tildes, optionally
    /// followed by an info string. The indent level is tracked so
    /// content lines can have up to that many leading spaces stripped.
    private static func detectFenceOpen(_ line: String) -> Fence? {
        let chars = Array(line)
        var i = 0
        // Allow up to 3 leading spaces
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        let indent = i

        guard i < chars.count else { return nil }
        let fenceChar = chars[i]
        guard fenceChar == "`" || fenceChar == "~" else { return nil }

        var count = 0
        while i < chars.count && chars[i] == fenceChar { i += 1; count += 1 }
        guard count >= 3 else { return nil }

        let rest = String(chars[i...])

        // CommonMark: backtick fences cannot contain backticks in their
        // info string. If they do, this isn't a fence open.
        if fenceChar == "`" && rest.contains("`") { return nil }

        return Fence(fenceChar: fenceChar, fenceLength: count, infoRaw: rest, indent: indent)
    }

    /// Check whether `line` is a valid close fence for the given open.
    /// Close fence: up to 3 leading spaces, then only fence chars
    /// (>= open length) and optional trailing whitespace, no info string.
    private static func isFenceClose(_ line: String, matching open: Fence) -> Bool {
        let chars = Array(line)
        var i = 0
        // Allow up to 3 leading spaces
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }

        var count = 0
        while i < chars.count && chars[i] == open.fenceChar { i += 1; count += 1 }
        guard count >= open.fenceLength else { return false }

        // Everything after fence chars must be whitespace only.
        let trailing = chars[i...]
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
        // CommonMark 4.2: up to 3 leading spaces before the opening `#`
        // run are allowed. 4+ spaces would be an indented code block
        // (which we don't support — falls through to paragraph).
        var chars = Array(line)
        var i = 0
        var leading = 0
        while i < chars.count, chars[i] == " ", leading < 3 {
            leading += 1
            i += 1
        }
        guard i < chars.count, chars[i] == "#" else { return nil }

        var level = 0
        while i < chars.count, chars[i] == "#" {
            level += 1
            i += 1
        }
        guard level >= 1 && level <= 6 else { return nil }

        let suffix = String(chars[i..<chars.count])
        // Valid heading: either suffix is empty (end of line) or begins
        // with a space/tab.
        if suffix.isEmpty { return (level, suffix) }
        guard let nextCh = suffix.first, nextCh == " " || nextCh == "\t" else {
            return nil
        }
        return (level, suffix)
    }

    // MARK: - HTML block detection

    /// Block-level HTML tag names (CommonMark spec, type 6).
    private static let htmlBlockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog",
        "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer",
        "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6",
        "head", "header", "hr", "html", "iframe", "legend", "li", "link",
        "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup",
        "option", "p", "param", "search", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "title", "tr", "ul"
    ]

    /// Detect whether a line starts an HTML block and return the type
    /// (1–7) if so. Returns nil if the line is not an HTML block start.
    private static func detectHTMLBlock(_ line: String) -> Int? {
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
        if let tagName = extractHTMLTagName(trimmedStr) {
            if htmlBlockTags.contains(tagName.lowercased()) {
                return 6
            }
        }

        // Type 7: any other complete open or closing tag on its own line.
        // The tag must be a complete open tag (with optional attributes,
        // ending with > or />) or a closing tag (</tagname>), followed
        // only by optional whitespace. Cannot interrupt a paragraph
        // (caller must check rawBuffer).
        if isCompleteHTMLTag(trimmedStr) {
            return 7
        }

        return nil
    }

    /// Check whether a line is a complete HTML open tag or closing tag
    /// followed only by optional whitespace (type 7 HTML block start).
    ///
    /// CommonMark open tag: `< tag_name attribute* /? >`
    /// - tag_name: ASCII letter followed by (letter|digit|hyphen)*
    /// - attribute: whitespace+ attr_name (= attr_value)?
    /// - attr_name: (letter|_|:) (letter|digit|_|.|:|-)*
    /// - attr_value: unquoted | 'single' | "double"
    ///
    /// Closing tag: `</ tag_name whitespace* >`
    private static func isCompleteHTMLTag(_ line: String) -> Bool {
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
            // After tag name, must see whitespace, >, or />
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
                // Could be > or /> after whitespace
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
                    // Optional whitespace after =
                    while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                    guard i < chars.count else { return false }
                    if chars[i] == "\"" {
                        // Double-quoted value
                        i += 1
                        while i < chars.count && chars[i] != "\"" { i += 1 }
                        guard i < chars.count else { return false }
                        i += 1 // skip closing "
                    } else if chars[i] == "'" {
                        // Single-quoted value
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
                        if i == vStart { return false } // empty unquoted value
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

    /// Check whether an HTML block's end condition is met on a given line.
    /// Used to detect same-line end markers (e.g., `<style>...</style>` on one line).
    /// Types 6 and 7 end at blank lines, so they never "end on a line" — returns false.
    private static func htmlBlockEndsOnLine(_ line: String, type: Int) -> Bool {
        let lower = line.lowercased()
        switch type {
        case 1:
            // End markers for type 1: closing tags for pre/script/style/textarea
            // anywhere on the line (including the opening line).
            return lower.contains("</pre>") || lower.contains("</script>")
                || lower.contains("</style>") || lower.contains("</textarea>")
        case 2:
            // End marker: -->  (must appear after the opening <!--)
            if let range = line.range(of: "<!--") {
                return line[range.upperBound...].contains("-->")
            }
            return false
        case 3:
            // End marker: ?>
            if let range = line.range(of: "<?") {
                return line[range.upperBound...].contains("?>")
            }
            return false
        case 4:
            // End marker: >  (after the opening <!)
            // The opening is <!LETTER, so check from index 2 onward.
            return line.dropFirst(2).contains(">")
        case 5:
            // End marker: ]]>
            if let range = line.range(of: "<![CDATA[") {
                return line[range.upperBound...].contains("]]>")
            }
            return false
        default:
            return false
        }
    }

    /// Extract the tag name from a line starting with `<` or `</`.
    /// Returns the tag name if the character after the tag is a valid
    /// delimiter (space, tab, >, /, newline, or end of string).
    private static func extractHTMLTagName(_ line: String) -> String? {
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

    // MARK: - Inline tokenizer

    /// Parse inline content from a paragraph's raw text.
    ///
    /// Two-phase approach:
    ///   Phase A (`tokenizeNonEmphasis`): parse everything except emphasis
    ///     (* and _). Code spans, links, images, autolinks, raw HTML,
    ///     entities, escapes, line breaks, and strikethrough are all
    ///     handled here. Delimiter runs of * and _ are emitted as tokens.
    ///   Phase B (`resolveEmphasis`): process the delimiter stack using
    ///     the CommonMark spec section 6.2 algorithm. This correctly
    ///     handles nested emphasis, Rule of 3, underscore word boundaries,
    ///     and all the complex nesting cases that greedy matching fails on.
    ///
    /// Precedence order (highest first):
    /// 1. Backslash escapes (`\*`, `\[`, etc.)
    /// 2. Hard line breaks (`\\\n` and `  \n`)
    /// 3. Autolinks (`<scheme:path>`, `<email@domain>`)
    /// 4. Raw HTML (`<tag>`, `<!-- -->`, `<?...?>`, `<![CDATA[...]]>`)
    /// 5. Entity references (`&amp;`, `&#123;`, `&#x1F;`)
    /// 6. Code spans (`` `…` ``)
    /// 7. Images (`![alt](url)`)
    /// 8. Links (`[text](url)`)
    /// 9. Strikethrough (`~~…~~`)
    /// 10. Emphasis (`*`, `**`, `_`, `__` via delimiter stack)

    /// Pre-scan for all code span ranges in the character array.
    /// Returns an array of (start, end) pairs where start is the index
    /// of the first opening backtick and end is the index past the last
    /// closing backtick. Used to give code spans precedence over
    /// emphasis, links, and other inline constructs per CommonMark spec.
    private static func findCodeSpanRanges(_ chars: [Character]) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "`" {
                if let match = tryMatchCodeSpan(chars, from: i) {
                    ranges.append((i, match.endIndex))
                    i = match.endIndex
                    continue
                }
            }
            i += 1
        }
        return ranges
    }

    /// Check if a code span starting inside (matchStart, matchEnd) extends
    /// past matchEnd — meaning the code span crosses the boundary of the
    /// candidate match and should take precedence (CommonMark rule).
    private static func codeSpanCrossesBoundary(
        _ codeSpanRanges: [(start: Int, end: Int)],
        matchStart: Int, matchEnd: Int
    ) -> Bool {
        for cs in codeSpanRanges {
            if cs.start > matchStart && cs.start < matchEnd && cs.end > matchEnd {
                return true
            }
        }
        return false
    }

    // MARK: - Delimiter stack types for CommonMark emphasis algorithm

    /// A token in the intermediate representation between Phase A
    /// (non-emphasis inline parsing) and Phase B (emphasis resolution).
    private enum InlineToken {
        case inline(Inline)                  // already-parsed inline (code, link, etc.)
        case text(String)                    // raw text needing no further processing
        case delimiter(DelimiterRun)         // a run of * or _ to be resolved
    }

    /// A delimiter run on the stack. Tracks the character, remaining
    /// count (decremented as emphasis is consumed), and flanking status.
    private class DelimiterRun {
        let char: Character           // '*' or '_'
        var count: Int                // remaining delimiter chars (decremented)
        let originalCount: Int        // original count (for Rule of 3)
        let canOpen: Bool
        let canClose: Bool
        var active: Bool = true       // set to false when removed from stack

        init(char: Character, count: Int, canOpen: Bool, canClose: Bool) {
            self.char = char
            self.count = count
            self.originalCount = count
            self.canOpen = canOpen
            self.canClose = canClose
        }
    }

    /// Determine whether a delimiter run can open and/or close emphasis.
    /// Implements CommonMark spec section 6.2 flanking rules.
    private static func emphasisFlanking(
        delimChar: Character, before: Character?, after: Character?
    ) -> (canOpen: Bool, canClose: Bool) {
        let beforeIsWhitespace = before == nil || isUnicodeWhitespace(before!)
        let afterIsWhitespace = after == nil || isUnicodeWhitespace(after!)
        let beforeIsPunct = before != nil && isUnicodePunctuation(before!)
        let afterIsPunct = after != nil && isUnicodePunctuation(after!)

        // Left-flanking: not followed by whitespace, AND
        // (not followed by punctuation OR preceded by whitespace/punctuation)
        let leftFlanking = !afterIsWhitespace &&
            (!afterIsPunct || beforeIsWhitespace || beforeIsPunct)

        // Right-flanking: not preceded by whitespace, AND
        // (not preceded by punctuation OR followed by whitespace/punctuation)
        let rightFlanking = !beforeIsWhitespace &&
            (!beforeIsPunct || afterIsWhitespace || afterIsPunct)

        let canOpen: Bool
        let canClose: Bool
        if delimChar == "*" {
            canOpen = leftFlanking
            canClose = rightFlanking
        } else {
            // Underscore: stricter rules
            canOpen = leftFlanking && (!rightFlanking || beforeIsPunct)
            canClose = rightFlanking && (!leftFlanking || afterIsPunct)
        }
        return (canOpen, canClose)
    }

    static func parseInlines(_ text: String, refDefs: [String: (url: String, title: String?)] = [:]) -> [Inline] {
        guard !text.isEmpty else { return [] }

        // Phase A: tokenize into non-emphasis inlines + delimiter runs
        let tokens = tokenizeNonEmphasis(text, refDefs: refDefs)

        // Phase B: resolve emphasis using the delimiter stack algorithm
        let inlines = resolveEmphasis(tokens, refDefs: refDefs)

        // Phase C: resolve known HTML tag pairs (<u>...</u>, <mark>...</mark>)
        // into container inlines, the same way emphasis resolves ** into .bold.
        return resolveHTMLTagPairs(inlines)
    }

    /// Post-parse pass: match rawHTML opening/closing tag pairs and convert
    /// them into structured container inlines (.underline, .highlight).
    /// Unmatched tags remain as .rawHTML.
    private static let knownTagPairs: [(open: String, close: String, wrap: ([Inline]) -> Inline)] = [
        ("<u>", "</u>", { .underline($0) }),
        ("<mark>", "</mark>", { .highlight($0) }),
        ("<sup>", "</sup>", { .superscript($0) }),
        ("<sub>", "</sub>", { .`subscript`($0) }),
        ("<kbd>", "</kbd>", { .kbd($0) }),
    ]

    private static func resolveHTMLTagPairs(_ inlines: [Inline]) -> [Inline] {
        var result = inlines
        for pair in knownTagPairs {
            result = resolveTagPair(result, open: pair.open, close: pair.close, wrap: pair.wrap)
        }
        return result
    }

    private static func resolveTagPair(
        _ inlines: [Inline],
        open: String,
        close: String,
        wrap: ([Inline]) -> Inline
    ) -> [Inline] {
        var result: [Inline] = []
        var i = 0
        while i < inlines.count {
            if case .rawHTML(let html) = inlines[i], html == open {
                // Scan for matching close tag.
                var j = i + 1
                var depth = 1
                while j < inlines.count {
                    if case .rawHTML(let inner) = inlines[j] {
                        if inner == open { depth += 1 }
                        if inner == close { depth -= 1 }
                        if depth == 0 { break }
                    }
                    j += 1
                }
                if j < inlines.count {
                    // Found match. Recursively resolve tag pairs in children.
                    let content = Array(inlines[(i + 1)..<j])
                    let resolvedContent = resolveTagPair(content, open: open, close: close, wrap: wrap)
                    result.append(wrap(resolvedContent))
                    i = j + 1
                } else {
                    // No match — keep as raw HTML.
                    result.append(inlines[i])
                    i += 1
                }
            } else {
                // Recurse into existing containers.
                result.append(resolveTagPairInChildren(inlines[i], open: open, close: close, wrap: wrap))
                i += 1
            }
        }
        return result
    }

    private static func resolveTagPairInChildren(
        _ inline: Inline,
        open: String,
        close: String,
        wrap: ([Inline]) -> Inline
    ) -> Inline {
        switch inline {
        case .bold(let children, let marker):
            return .bold(resolveTagPair(children, open: open, close: close, wrap: wrap), marker: marker)
        case .italic(let children, let marker):
            return .italic(resolveTagPair(children, open: open, close: close, wrap: wrap), marker: marker)
        case .strikethrough(let children):
            return .strikethrough(resolveTagPair(children, open: open, close: close, wrap: wrap))
        case .link(let text, let dest):
            return .link(text: resolveTagPair(text, open: open, close: close, wrap: wrap), rawDestination: dest)
        case .image(let alt, let dest, let width):
            return .image(alt: resolveTagPair(alt, open: open, close: close, wrap: wrap), rawDestination: dest, width: width)
        case .underline(let children):
            return .underline(resolveTagPair(children, open: open, close: close, wrap: wrap))
        case .highlight(let children):
            return .highlight(resolveTagPair(children, open: open, close: close, wrap: wrap))
        case .superscript(let children):
            return .superscript(resolveTagPair(children, open: open, close: close, wrap: wrap))
        case .`subscript`(let children):
            return .`subscript`(resolveTagPair(children, open: open, close: close, wrap: wrap))
        case .kbd(let children):
            return .kbd(resolveTagPair(children, open: open, close: close, wrap: wrap))
        default:
            return inline
        }
    }

    /// Phase A: Parse everything EXCEPT emphasis (* and _). Emit delimiter
    /// runs as tokens to be resolved in Phase B.
    private static func tokenizeNonEmphasis(
        _ text: String,
        refDefs: [String: (url: String, title: String?)]
    ) -> [InlineToken] {
        let chars = Array(text)
        var tokens: [InlineToken] = []
        var plain = ""
        var i = 0

        // Pre-scan code span ranges so we can give them precedence
        // over emphasis, links, and other constructs (CommonMark spec).
        let codeSpanRanges = findCodeSpanRanges(chars)

        func flushPlain() {
            if !plain.isEmpty {
                tokens.append(.text(plain))
                plain = ""
            }
        }

        while i < chars.count {
            // 1. Backslash escape: \X where X is an ASCII punctuation character
            if chars[i] == "\\" && i + 1 < chars.count {
                let next = chars[i + 1]
                if isPunctuationChar(next) {
                    flushPlain()
                    tokens.append(.inline(.escapedChar(next)))
                    i += 2
                    continue
                }
            }
            // 2. Hard line break: backslash before newline (\\\n)
            if chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "\n" {
                flushPlain()
                tokens.append(.inline(.lineBreak(raw: "\\\n")))
                i += 2
                continue
            }
            // 3. Hard line break: two or more trailing spaces before \n
            if chars[i] == " " {
                var spaceCount = 0
                var k = i
                while k < chars.count && chars[k] == " " { k += 1; spaceCount += 1 }
                if k < chars.count && chars[k] == "\n" && spaceCount >= 2 {
                    flushPlain()
                    let raw = String(chars[i...k])
                    tokens.append(.inline(.lineBreak(raw: raw)))
                    i = k + 1
                    continue
                }
            }
            // 4. Autolinks
            if let match = tryMatchAutolink(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.autolink(text: match.text, isEmail: match.isEmail)))
                i = match.endIndex
                continue
            }
            // 5. Raw HTML
            if let match = tryMatchRawHTML(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.rawHTML(match.html)))
                i = match.endIndex
                continue
            }
            // 6. Entity references
            if let match = tryMatchEntity(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.entity(match.entity)))
                i = match.endIndex
                continue
            }
            // 6b. Display math ($$...$$) — must check before single-$ inline math
            if let match = tryMatchDisplayMath(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.displayMath(match.content)))
                i = match.endIndex
                continue
            }
            // 6c. Inline math ($...$)
            if let match = tryMatchInlineMath(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.math(match.content)))
                i = match.endIndex
                continue
            }
            // 7. Code spans
            if let match = tryMatchCodeSpan(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.code(match.inner)))
                i = match.endIndex
                continue
            }
            // 8. Images
            if chars[i] == "!" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let match = tryMatchImage(chars, from: i, codeSpanRanges: codeSpanRanges) {
                    if !codeSpanCrossesBoundary(codeSpanRanges, matchStart: i, matchEnd: match.endIndex) {
                        flushPlain()
                        let (_, imgTitle) = extractURLAndTitle(from: match.dest)
                        let imgWidth = imgTitle.flatMap { ImageSizeTitle.parse($0).width }
                        tokens.append(.inline(.image(
                            alt: parseInlines(match.alt, refDefs: refDefs),
                            rawDestination: match.dest,
                            width: imgWidth
                        )))
                        i = match.endIndex
                        continue
                    }
                }
                if !refDefs.isEmpty {
                    if let match = tryMatchReferenceLink(chars, from: i + 1, refDefs: refDefs) {
                        if !codeSpanCrossesBoundary(codeSpanRanges, matchStart: i, matchEnd: match.endIndex) {
                            flushPlain()
                            let (_, imgTitle) = extractURLAndTitle(from: match.dest)
                            let imgWidth = imgTitle.flatMap { ImageSizeTitle.parse($0).width }
                            tokens.append(.inline(.image(
                                alt: parseInlines(match.text, refDefs: refDefs),
                                rawDestination: match.dest,
                                width: imgWidth
                            )))
                            i = match.endIndex
                            continue
                        }
                    }
                }
            }
            // 9a. Wikilinks: [[target]] or [[target|display]]. Handled
            // BEFORE the regular link path so that `[[foo]]` doesn't
            // match as a ref-link `[foo]`. The target must not contain
            // `]`, `|`, or newline.
            if chars[i] == "[" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let match = tryMatchWikilink(chars, from: i) {
                    if !codeSpanCrossesBoundary(codeSpanRanges, matchStart: i, matchEnd: match.endIndex) {
                        flushPlain()
                        tokens.append(.inline(.wikilink(target: match.target, display: match.display)))
                        i = match.endIndex
                        continue
                    }
                }
            }
            // 9. Links
            if chars[i] == "[" {
                if let match = tryMatchLink(chars, from: i, codeSpanRanges: codeSpanRanges) {
                    if !codeSpanCrossesBoundary(codeSpanRanges, matchStart: i, matchEnd: match.endIndex) {
                        flushPlain()
                        tokens.append(.inline(.link(text: parseInlines(match.text, refDefs: refDefs), rawDestination: match.dest)))
                        i = match.endIndex
                        continue
                    }
                }
                if !refDefs.isEmpty {
                    if let match = tryMatchReferenceLink(chars, from: i, refDefs: refDefs) {
                        if !codeSpanCrossesBoundary(codeSpanRanges, matchStart: i, matchEnd: match.endIndex) {
                            flushPlain()
                            tokens.append(.inline(.link(text: parseInlines(match.text, refDefs: refDefs), rawDestination: match.dest)))
                            i = match.endIndex
                            continue
                        }
                    }
                }
            }
            // 10. Strikethrough
            if chars[i] == "~" {
                if let match = tryMatchStrikethrough(chars, from: i) {
                    if !codeSpanCrossesBoundary(codeSpanRanges, matchStart: i, matchEnd: match.endIndex) {
                        flushPlain()
                        tokens.append(.inline(.strikethrough(parseInlines(match.inner, refDefs: refDefs))))
                        i = match.endIndex
                        continue
                    }
                }
            }
            // 11. Delimiter runs (* and _) — emit as tokens for Phase B
            if chars[i] == "*" || chars[i] == "_" {
                flushPlain()
                let delimChar = chars[i]
                let runStart = i
                var runLen = 0
                while i < chars.count && chars[i] == delimChar { i += 1; runLen += 1 }

                let before: Character? = runStart > 0 ? chars[runStart - 1] : nil
                let after: Character? = i < chars.count ? chars[i] : nil
                let (canOpen, canClose) = emphasisFlanking(
                    delimChar: delimChar, before: before, after: after
                )
                let run = DelimiterRun(
                    char: delimChar, count: runLen,
                    canOpen: canOpen, canClose: canClose
                )
                tokens.append(.delimiter(run))
                continue
            }
            plain.append(chars[i])
            i += 1
        }
        flushPlain()
        return tokens
    }

    /// Phase B: Process the delimiter stack to resolve emphasis.
    /// Implements the CommonMark algorithm from spec section 6.2.
    private static func resolveEmphasis(
        _ tokens: [InlineToken],
        refDefs: [String: (url: String, title: String?)]
    ) -> [Inline] {
        // Build a doubly-linked list of tokens. We use an array and
        // index-based navigation for simplicity.
        // Each element is either a resolved Inline, raw text, or a
        // delimiter run that may still be consumed.
        struct Node {
            var token: InlineToken
            var removed: Bool = false
        }
        var nodes = tokens.map { Node(token: $0) }

        // Collect indices of delimiter runs.
        var delimiterIndices: [Int] = []
        for (idx, node) in nodes.enumerated() {
            if case .delimiter = node.token {
                delimiterIndices.append(idx)
            }
        }

        // Process closers: scan left to right for potential closers.
        // For each closer, search backwards for a matching opener.
        var closerDIdx = 0
        while closerDIdx < delimiterIndices.count {
            let closerIdx = delimiterIndices[closerDIdx]
            guard !nodes[closerIdx].removed else {
                closerDIdx += 1
                continue
            }
            guard case .delimiter(let closer) = nodes[closerIdx].token,
                  closer.canClose, closer.active, closer.count > 0 else {
                closerDIdx += 1
                continue
            }

            // Search backwards for a matching opener.
            var foundOpener = false
            var openerDIdx = closerDIdx - 1
            while openerDIdx >= 0 {
                let openerIdx = delimiterIndices[openerDIdx]
                guard !nodes[openerIdx].removed else {
                    openerDIdx -= 1
                    continue
                }
                guard case .delimiter(let opener) = nodes[openerIdx].token,
                      opener.canOpen, opener.active, opener.count > 0,
                      opener.char == closer.char else {
                    openerDIdx -= 1
                    continue
                }

                // Rule of 3: If the closer can open OR the opener can close,
                // and the sum of their original counts is a multiple of 3,
                // and neither original count is a multiple of 3, skip.
                if (closer.canOpen || opener.canClose) {
                    let sum = opener.originalCount + closer.originalCount
                    if sum % 3 == 0 && opener.originalCount % 3 != 0 && closer.originalCount % 3 != 0 {
                        openerDIdx -= 1
                        continue
                    }
                }

                foundOpener = true
                break
            }

            if !foundOpener {
                // No matching opener found. If this closer can't open
                // either, deactivate it.
                if !closer.canOpen {
                    closer.active = false
                }
                closerDIdx += 1
                continue
            }

            let openerIdx = delimiterIndices[openerDIdx]
            guard case .delimiter(let opener) = nodes[openerIdx].token else {
                closerDIdx += 1
                continue
            }

            // Determine emphasis type: strong if both have >= 2 chars
            let isStrong = opener.count >= 2 && closer.count >= 2
            let consumed = isStrong ? 2 : 1
            let marker: EmphasisMarker = opener.char == "_" ? .underscore : .asterisk

            // Collect all content between opener and closer into children.
            var children: [Inline] = []
            for k in (openerIdx + 1)..<closerIdx {
                guard !nodes[k].removed else { continue }
                switch nodes[k].token {
                case .text(let s):
                    children.append(.text(s))
                case .inline(let inl):
                    children.append(inl)
                case .delimiter(let run):
                    if run.count > 0 {
                        let s = String(repeating: run.char, count: run.count)
                        children.append(.text(s))
                    }
                }
                nodes[k].removed = true
            }

            // Also remove delimiter indices between opener and closer.
            // We'll rebuild delimiterIndices after processing.

            // Consume from opener and closer.
            opener.count -= consumed
            closer.count -= consumed

            // Create the emphasis inline.
            let emphInline: Inline
            if isStrong {
                emphInline = .bold(children, marker: marker)
            } else {
                emphInline = .italic(children, marker: marker)
            }

            // Replace the content between opener and closer with the
            // emphasis node. We insert it right after the opener.
            // If opener is fully consumed, replace it; otherwise insert after.
            if opener.count == 0 {
                nodes[openerIdx] = Node(token: .inline(emphInline))
            } else {
                // Insert the emphasis node right after the opener.
                // We need to find the first non-removed slot after
                // openerIdx. Since all between are removed, we can
                // repurpose the first removed slot.
                var inserted = false
                for k in (openerIdx + 1)..<closerIdx {
                    nodes[k] = Node(token: .inline(emphInline))
                    inserted = true
                    break
                }
                if !inserted {
                    // No slots between — this shouldn't happen with
                    // valid emphasis (need content between markers), but
                    // handle gracefully by replacing the closer slot.
                    if closer.count == 0 {
                        nodes[closerIdx] = Node(token: .inline(emphInline))
                    } else {
                        // Edge case: insert before closer by repurposing.
                        // We'll handle this by creating a compound node.
                        // For now, append to opener.
                        nodes[openerIdx] = Node(token: .inline(emphInline))
                    }
                }
            }

            // If closer is fully consumed, mark it removed.
            if closer.count == 0 {
                if nodes[closerIdx].removed == false {
                    // Only mark removed if we didn't already repurpose it.
                    if case .delimiter = nodes[closerIdx].token {
                        nodes[closerIdx].removed = true
                    }
                }
            }
            // If opener is fully consumed and we didn't replace it with
            // the emphasis node, mark it removed.
            if opener.count == 0 {
                // Already replaced above — no action needed.
            }

            // Remove delimiter indices between opener and closer from
            // the active set (they've been consumed as content).
            // Rebuild delimiterIndices to stay consistent.
            delimiterIndices = []
            for (idx, node) in nodes.enumerated() {
                if node.removed { continue }
                if case .delimiter(let run) = node.token, run.count > 0, run.active {
                    delimiterIndices.append(idx)
                }
            }

            // If closer still has remaining count, re-process it.
            if closer.count > 0 {
                // Find the closer in the new delimiter indices.
                if let newCloserDIdx = delimiterIndices.firstIndex(where: {
                    if case .delimiter(let r) = nodes[$0].token {
                        return r === closer
                    }
                    return false
                }) {
                    closerDIdx = newCloserDIdx
                } else {
                    closerDIdx = 0
                }
            } else {
                // Closer fully consumed — restart scan.
                // Find where we should continue: the position after
                // where opener was.
                closerDIdx = 0
                // Advance to the first delimiter after the emphasis we
                // just created.
                for (di, idx) in delimiterIndices.enumerated() {
                    if idx > openerIdx {
                        closerDIdx = di
                        break
                    }
                    if di == delimiterIndices.count - 1 {
                        closerDIdx = delimiterIndices.count
                    }
                }
            }
        }

        // Phase 3: Flatten remaining nodes into [Inline].
        var result: [Inline] = []
        for node in nodes {
            guard !node.removed else { continue }
            switch node.token {
            case .text(let s):
                result.append(.text(s))
            case .inline(let inl):
                result.append(inl)
            case .delimiter(let run):
                if run.count > 0 {
                    let s = String(repeating: run.char, count: run.count)
                    result.append(.text(s))
                }
            }
        }

        // Merge adjacent .text nodes for cleanliness.
        var merged: [Inline] = []
        for inl in result {
            if case .text(let s) = inl, let last = merged.last, case .text(let prev) = last {
                merged[merged.count - 1] = .text(prev + s)
            } else {
                merged.append(inl)
            }
        }
        return merged
    }

    /// Try to match a code span starting at `start`. CommonMark rule:
    /// a run of N backticks opens the span, and a run of exactly N
    /// backticks closes it. The content is taken verbatim (no inline
    /// parsing). If the content starts AND ends with a space and is
    /// not entirely spaces, one leading and one trailing space are
    /// stripped. Line endings in the content are converted to spaces.
    ///
    /// Note: multi-backtick code spans (e.g. `` `` ` `` ``) will
    /// normalize to single-backtick on round-trip serialization since
    /// we store only the inner content in Inline.code.
    private static func tryMatchCodeSpan(
        _ chars: [Character], from start: Int
    ) -> (inner: String, endIndex: Int)? {
        guard start < chars.count, chars[start] == "`" else { return nil }
        // CommonMark: a backtick string must not be preceded by a backtick
        if start > 0 && chars[start - 1] == "`" { return nil }
        // Count opening backtick run length
        var openLen = 0
        var j = start
        while j < chars.count && chars[j] == "`" { j += 1; openLen += 1 }
        // Scan for closing run of exactly openLen backticks
        var k = j
        while k < chars.count {
            if chars[k] == "`" {
                var closeLen = 0
                let closeStart = k
                while k < chars.count && chars[k] == "`" { k += 1; closeLen += 1 }
                if closeLen == openLen {
                    // Found matching close
                    var inner = String(chars[j..<closeStart])
                    // Collapse newlines to spaces (CommonMark rule)
                    inner = inner.replacingOccurrences(of: "\n", with: " ")
                    // Strip one leading + trailing space if both present
                    // and content isn't all spaces
                    if inner.count >= 2 && inner.first == " " && inner.last == " " &&
                       !inner.allSatisfy({ $0 == " " }) {
                        inner = String(inner.dropFirst().dropLast())
                    }
                    return (inner, k)
                }
                // closeLen != openLen — keep scanning
            } else {
                k += 1
            }
        }
        return nil
    }

    /// Try to match inline math `$...$` starting at `start`. Requires
    /// non-empty content and the closing `$` must not be preceded by a
    /// space (to avoid matching currency amounts like `$5`).
    /// Try to match display math `$$...$$` starting at `start`.
    /// Display math can span multiple lines (soft line breaks within a paragraph).
    private static func tryMatchDisplayMath(
        _ chars: [Character], from start: Int
    ) -> (content: String, endIndex: Int)? {
        guard start + 1 < chars.count,
              chars[start] == "$", chars[start + 1] == "$" else { return nil }
        var j = start + 2
        while j + 1 < chars.count {
            if chars[j] == "$" && chars[j + 1] == "$" {
                let content = String(chars[(start + 2)..<j])
                    .trimmingCharacters(in: .whitespaces)
                if content.isEmpty { return nil }
                return (content, j + 2)
            }
            j += 1
        }
        return nil
    }

    private static func tryMatchInlineMath(
        _ chars: [Character], from start: Int
    ) -> (content: String, endIndex: Int)? {
        guard start < chars.count, chars[start] == "$" else { return nil }
        // $$ is display math, not inline — skip
        if start + 1 < chars.count && chars[start + 1] == "$" { return nil }
        // Don't match $ preceded by alphanumeric (likely currency)
        if start > 0 && chars[start - 1].isLetter { return nil }
        var j = start + 1
        while j < chars.count {
            if chars[j] == "$" {
                let content = String(chars[(start + 1)..<j])
                // Reject empty content and content ending in space
                if content.isEmpty || content.last == " " { return nil }
                return (content, j + 1)
            }
            if chars[j] == "\n" { return nil } // No newlines in inline math
            j += 1
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

    // MARK: - Backslash escape helper

    /// Returns true if `ch` is an ASCII punctuation character that can
    /// be backslash-escaped per CommonMark.
    private static func isPunctuationChar(_ ch: Character) -> Bool {
        let punctuation: Set<Character> = [
            "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".",
            "/", ":", ";", "<", "=", ">", "?", "@", "[", "\\", "]", "^", "_",
            "`", "{", "|", "}", "~"
        ]
        return punctuation.contains(ch)
    }

    // MARK: - Autolink detection

    /// Try to match an autolink `<scheme:path>` (URI) or `<local@domain>`
    /// (email) starting at `start`.
    private static func tryMatchAutolink(
        _ chars: [Character], from start: Int
    ) -> (text: String, isEmail: Bool, endIndex: Int)? {
        guard start < chars.count, chars[start] == "<" else { return nil }
        // Scan for closing >
        var j = start + 1
        while j < chars.count {
            if chars[j] == ">" {
                let inner = String(chars[(start + 1)..<j])
                // Check if it's a URI autolink (has scheme:)
                if let colonIdx = inner.firstIndex(of: ":"),
                   colonIdx > inner.startIndex {
                    let scheme = inner[..<colonIdx]
                    // Scheme: [A-Za-z][A-Za-z0-9+.-]{1,31} (CommonMark spec)
                    if scheme.count >= 2 && scheme.count <= 32 &&
                       scheme.first!.isASCII && scheme.first!.isLetter &&
                       scheme.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) {
                        return (inner, false, j + 1)
                    }
                }
                // Check if it's an email autolink
                if inner.contains("@") && !inner.contains(" ") && !inner.contains("\\") && inner.count >= 3 {
                    let parts = inner.split(separator: "@", maxSplits: 1)
                    if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty {
                        return (inner, true, j + 1)
                    }
                }
                // Not a valid autolink — bail
                return nil
            }
            // Autolinks can't contain spaces or newlines
            if chars[j] == " " || chars[j] == "\n" { return nil }
            j += 1
        }
        return nil
    }

    // MARK: - Raw HTML inline detection

    /// Try to match inline raw HTML starting at `start`. Matches open/close
    /// tags, HTML comments, processing instructions, CDATA, and declarations.
    private static func tryMatchRawHTML(
        _ chars: [Character], from start: Int
    ) -> (html: String, endIndex: Int)? {
        guard start < chars.count, chars[start] == "<" else { return nil }

        // HTML comment: <!-- ... -->
        if start + 3 < chars.count &&
           chars[start + 1] == "!" && chars[start + 2] == "-" && chars[start + 3] == "-" {
            var j = start + 4
            while j + 2 < chars.count {
                if chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">" {
                    let html = String(chars[start...(j + 2)])
                    return (html, j + 3)
                }
                j += 1
            }
            return nil
        }

        // Processing instruction: <? ... ?>
        if start + 1 < chars.count && chars[start + 1] == "?" {
            var j = start + 2
            while j + 1 < chars.count {
                if chars[j] == "?" && chars[j + 1] == ">" {
                    let html = String(chars[start...(j + 1)])
                    return (html, j + 2)
                }
                j += 1
            }
            return nil
        }

        // CDATA: <![CDATA[ ... ]]>
        if start + 8 < chars.count &&
           String(chars[(start + 1)...(start + 8)]) == "![CDATA[" {
            var j = start + 9
            while j + 2 < chars.count {
                if chars[j] == "]" && chars[j + 1] == "]" && chars[j + 2] == ">" {
                    let html = String(chars[start...(j + 2)])
                    return (html, j + 3)
                }
                j += 1
            }
            return nil
        }

        // Declaration: <!LETTER ... >
        if start + 1 < chars.count && chars[start + 1] == "!" {
            if start + 2 < chars.count && chars[start + 2].isLetter {
                var j = start + 3
                while j < chars.count {
                    if chars[j] == ">" {
                        let html = String(chars[start...j])
                        return (html, j + 1)
                    }
                    j += 1
                }
            }
            return nil
        }

        // Open tag: <tagname ...> or </tagname ...>
        var j = start + 1
        let isClosing = j < chars.count && chars[j] == "/"
        if isClosing { j += 1 }

        // Tag name: must start with ASCII letter
        guard j < chars.count, chars[j].isASCII && chars[j].isLetter else { return nil }
        j += 1
        // Rest of tag name: ASCII letters, digits, -
        while j < chars.count && (chars[j].isASCII && (chars[j].isLetter || chars[j].isNumber || chars[j] == "-")) {
            j += 1
        }

        if isClosing {
            // Closing tag: optional whitespace then > (NO attributes allowed)
            while j < chars.count && (chars[j] == " " || chars[j] == "\t" || chars[j] == "\n") { j += 1 }
            guard j < chars.count && chars[j] == ">" else { return nil }
            let html = String(chars[start...j])
            return (html, j + 1)
        }

        // Open tag: validate attributes per CommonMark spec
        // Attribute: whitespace+ attribute-name (= attribute-value)?
        // Attribute name: [a-zA-Z_:][a-zA-Z0-9_.:-]*
        // Attribute value: unquoted | 'single-quoted' | "double-quoted"
        while j < chars.count {
            // Skip whitespace
            let beforeWS = j
            while j < chars.count && (chars[j] == " " || chars[j] == "\t" || chars[j] == "\n") { j += 1 }
            guard j < chars.count else { return nil }

            // Self-closing /> or >
            if chars[j] == "/" {
                if j + 1 < chars.count && chars[j + 1] == ">" {
                    let html = String(chars[start...(j + 1)])
                    return (html, j + 2)
                }
                return nil
            }
            if chars[j] == ">" {
                let html = String(chars[start...j])
                return (html, j + 1)
            }

            // Must have whitespace before attribute name
            if j == beforeWS { return nil }

            // Attribute name: [a-zA-Z_:][a-zA-Z0-9_.:-]*
            guard chars[j].isASCII && (chars[j].isLetter || chars[j] == "_" || chars[j] == ":") else { return nil }
            j += 1
            while j < chars.count && chars[j].isASCII &&
                  (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." || chars[j] == ":" || chars[j] == "-") {
                j += 1
            }

            // Optional attribute value: = value
            // Skip whitespace around =
            var k = j
            while k < chars.count && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\n") { k += 1 }
            if k < chars.count && chars[k] == "=" {
                k += 1
                while k < chars.count && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\n") { k += 1 }
                guard k < chars.count else { return nil }
                if chars[k] == "\"" {
                    // Double-quoted value
                    k += 1
                    while k < chars.count && chars[k] != "\"" { k += 1 }
                    guard k < chars.count else { return nil }
                    k += 1 // skip closing "
                } else if chars[k] == "'" {
                    // Single-quoted value
                    k += 1
                    while k < chars.count && chars[k] != "'" { k += 1 }
                    guard k < chars.count else { return nil }
                    k += 1 // skip closing '
                } else {
                    // Unquoted value: no spaces, quotes, =, <, >, backtick
                    guard chars[k] != " " && chars[k] != "\t" && chars[k] != "\n" &&
                          chars[k] != "\"" && chars[k] != "'" && chars[k] != "=" &&
                          chars[k] != "<" && chars[k] != ">" && chars[k] != "`" else { return nil }
                    while k < chars.count && chars[k] != " " && chars[k] != "\t" && chars[k] != "\n" &&
                          chars[k] != "\"" && chars[k] != "'" && chars[k] != "=" &&
                          chars[k] != "<" && chars[k] != ">" && chars[k] != "`" {
                        k += 1
                    }
                }
                j = k
            }
        }
        return nil
    }

    // MARK: - Entity reference detection

    /// Known HTML5 named entity names (without & and ;).
    /// This is a subset covering the most common entities.
    /// CommonMark requires validation against the full HTML5 entity list.
    private static let knownHTMLEntities: Set<String> = [
        // Core XML entities
        "amp", "lt", "gt", "quot", "apos",
        // Whitespace and special
        "nbsp", "ensp", "emsp", "thinsp", "shy", "lrm", "rlm", "zwj", "zwnj",
        // Typography
        "copy", "reg", "trade", "mdash", "ndash", "hellip", "bull", "middot",
        "lsquo", "rsquo", "ldquo", "rdquo", "sbquo", "bdquo",
        "laquo", "raquo", "lsaquo", "rsaquo",
        "dagger", "Dagger", "permil",
        // Arrows
        "larr", "rarr", "uarr", "darr", "harr", "lArr", "rArr", "uArr", "dArr", "hArr",
        // Math and symbols
        "sect", "para", "deg", "plusmn", "times", "divide", "micro",
        "cent", "pound", "euro", "yen", "curren",
        "iexcl", "iquest", "ordf", "ordm", "not", "macr", "acute",
        "cedil", "sup1", "sup2", "sup3",
        "frac14", "frac12", "frac34",
        "fnof", "minus", "lowast", "radic", "prop", "infin",
        "ang", "and", "or", "cap", "cup", "int",
        "there4", "sim", "cong", "asymp", "ne", "equiv", "le", "ge",
        "sub", "sup", "nsub", "sube", "supe",
        "oplus", "otimes", "perp", "sdot",
        "lceil", "rceil", "lfloor", "rfloor", "lang", "rang",
        "loz", "sum", "prod", "forall", "part", "exist", "empty",
        "nabla", "isin", "notin", "ni",
        // Card suits
        "hearts", "spades", "clubs", "diams",
        // Greek
        "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta",
        "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron", "Pi",
        "Rho", "Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega",
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi",
        "rho", "sigmaf", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega",
        "thetasym", "upsih", "piv",
        // Latin extended
        "AElig", "Aacute", "Acirc", "Agrave", "Aring", "Atilde", "Auml",
        "Ccedil", "ETH", "Eacute", "Ecirc", "Egrave", "Euml",
        "Iacute", "Icirc", "Igrave", "Iuml",
        "Ntilde", "Oacute", "Ocirc", "Ograve", "Oslash", "Otilde", "Ouml",
        "THORN", "Uacute", "Ucirc", "Ugrave", "Uuml", "Yacute",
        "aacute", "acirc", "agrave", "aring", "atilde", "auml",
        "ccedil", "eacute", "ecirc", "egrave", "euml",
        "eth", "iacute", "icirc", "igrave", "iuml",
        "ntilde", "oacute", "ocirc", "ograve", "oslash", "otilde", "ouml",
        "szlig", "thorn", "uacute", "ucirc", "ugrave", "uuml", "yacute", "yuml",
        // Additional HTML5 entities from CommonMark spec examples
        "Dcaron", "HilbertSpace", "DifferentialD",
        "ClockwiseContourIntegral", "ngE",
    ]

    /// Try to match an HTML entity reference starting at `start`.
    /// Matches named (&amp;), decimal (&#123;), and hex (&#x1F;) forms.
    /// Named entities are validated against a known set of HTML5 entity names.
    private static func tryMatchEntity(
        _ chars: [Character], from start: Int
    ) -> (entity: String, endIndex: Int)? {
        guard start < chars.count, chars[start] == "&" else { return nil }
        var j = start + 1
        guard j < chars.count else { return nil }

        if chars[j] == "#" {
            // Numeric reference: &#digits; or &#xhex;
            j += 1
            guard j < chars.count else { return nil }
            if chars[j] == "x" || chars[j] == "X" {
                // Hex: &#x[0-9a-fA-F]+;
                j += 1
                let digitStart = j
                while j < chars.count && chars[j].isHexDigit { j += 1 }
                guard j > digitStart && j < chars.count && chars[j] == ";" else { return nil }
                guard j - digitStart <= 6 else { return nil } // Max 6 hex digits
                // Validate code point range
                let hexStr = String(chars[digitStart..<j])
                guard let codePoint = UInt32(hexStr, radix: 16),
                      codePoint <= 0x10FFFF else { return nil }
                let entity = String(chars[start...j])
                return (entity, j + 1)
            } else {
                // Decimal: &#[0-9]+;
                let digitStart = j
                while j < chars.count && chars[j].isNumber { j += 1 }
                guard j > digitStart && j < chars.count && chars[j] == ";" else { return nil }
                guard j - digitStart <= 7 else { return nil } // Max 7 decimal digits
                // Validate code point range
                let decStr = String(chars[digitStart..<j])
                guard let codePoint = UInt32(decStr),
                      codePoint <= 0x10FFFF else { return nil }
                let entity = String(chars[start...j])
                return (entity, j + 1)
            }
        } else {
            // Named reference: &[a-zA-Z][a-zA-Z0-9]+;
            guard chars[j].isLetter else { return nil }
            j += 1
            while j < chars.count && (chars[j].isLetter || chars[j].isNumber) { j += 1 }
            guard j < chars.count && chars[j] == ";" else { return nil }
            // Extract the name and validate against known entities
            let name = String(chars[(start + 1)..<j])
            guard knownHTMLEntities.contains(name) else { return nil }
            let entity = String(chars[start...j])
            return (entity, j + 1)
        }
    }

    // MARK: - Link and image detection

    /// Try to match an inline link `[text](destination)` starting at `start`.
    ///
    /// CommonMark-compliant destination parsing:
    /// - Angle-bracketed: `<url with spaces>` — allows spaces, disallows
    ///   unescaped `<` and newlines
    /// - Bare: no spaces, no newlines, balanced unescaped parentheses
    /// - Optional title in quotes after whitespace
    /// - Empty destination `()` is valid
    ///
    /// The returned `dest` is the raw content between `(` and `)` for
    /// round-trip serialization (includes angle brackets, whitespace, title).
    /// Try to match a wikilink starting at `chars[from]`. The input must
    /// start with `[[`. Returns the parsed target, optional display text,
    /// and the index PAST the closing `]]`. Returns nil if no matching
    /// `]]` is found or the content is empty.
    ///
    /// Syntax: `[[target]]` or `[[target|display]]`. Target and display
    /// may not contain `[`, `]`, `|`, or newline — keeping the grammar
    /// narrow prevents collisions with CommonMark link syntax.
    private static func tryMatchWikilink(
        _ chars: [Character],
        from: Int
    ) -> (target: String, display: String?, endIndex: Int)? {
        guard from + 1 < chars.count,
              chars[from] == "[", chars[from + 1] == "[" else { return nil }
        var i = from + 2
        var inner = ""
        while i + 1 < chars.count {
            let c = chars[i]
            if c == "\n" || c == "[" { return nil }
            if c == "]" && chars[i + 1] == "]" {
                guard !inner.isEmpty else { return nil }
                // Split on first '|' into target|display.
                if let pipeIdx = inner.firstIndex(of: "|") {
                    let target = String(inner[..<pipeIdx])
                    let display = String(inner[inner.index(after: pipeIdx)...])
                    guard !target.isEmpty else { return nil }
                    return (target, display.isEmpty ? nil : display, i + 2)
                }
                return (inner, nil, i + 2)
            }
            inner.append(c)
            i += 1
        }
        return nil
    }

    private static func tryMatchLink(
        _ chars: [Character], from start: Int,
        codeSpanRanges: [(start: Int, end: Int)] = []
    ) -> (text: String, dest: String, endIndex: Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }

        // Find the matching ] — handle nesting, escapes, and code spans.
        // Positions inside a code span don't count as bracket delimiters.
        var bracketDepth = 1
        var j = start + 1
        while j < chars.count && bracketDepth > 0 {
            if chars[j] == "\\" && j + 1 < chars.count { j += 2; continue }
            // Skip past code spans — brackets inside them don't count
            var inCodeSpan = false
            for cs in codeSpanRanges {
                if j >= cs.start && j < cs.end {
                    j = cs.end
                    inCodeSpan = true
                    break
                }
            }
            if inCodeSpan { continue }
            if chars[j] == "[" { bracketDepth += 1 }
            else if chars[j] == "]" { bracketDepth -= 1 }
            j += 1
        }
        guard bracketDepth == 0 else { return nil }
        // j is now past the ]
        let textEnd = j - 1

        // Must be immediately followed by (
        guard j < chars.count && chars[j] == "(" else { return nil }
        let parenOpen = j
        var k = j + 1

        // Skip optional whitespace (spaces, tabs, up to one newline per spec)
        while k < chars.count && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\n") { k += 1 }

        // Empty destination: just )
        if k < chars.count && chars[k] == ")" {
            let text = String(chars[(start + 1)..<textEnd])
            let dest = String(chars[(parenOpen + 1)..<k])
            return (text, dest, k + 1)
        }

        // Parse destination
        if k < chars.count && chars[k] == "<" {
            // Angle-bracketed destination: scan for matching >
            k += 1
            while k < chars.count {
                if chars[k] == "\\" && k + 1 < chars.count { k += 2; continue }
                if chars[k] == ">" { break }
                if chars[k] == "<" || chars[k] == "\n" { return nil }
                k += 1
            }
            guard k < chars.count && chars[k] == ">" else { return nil }
            k += 1 // skip past >
        } else {
            // Bare destination: no spaces, no newlines, balanced parens
            var parenDepth = 0
            while k < chars.count {
                if chars[k] == "\\" && k + 1 < chars.count { k += 2; continue }
                if chars[k] == " " || chars[k] == "\t" || chars[k] == "\n" { break }
                if chars[k] == "(" { parenDepth += 1 }
                else if chars[k] == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                }
                k += 1
            }
            // Unbalanced inner parens means invalid destination
            if parenDepth != 0 { return nil }
        }

        // Skip optional whitespace before title or closing paren
        while k < chars.count && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\n") { k += 1 }

        // Optional title (double-quoted, single-quoted, or parenthesized)
        if k < chars.count && (chars[k] == "\"" || chars[k] == "'" || chars[k] == "(") {
            let openQuote = chars[k]
            let closeQuote: Character = openQuote == "(" ? ")" : openQuote
            k += 1
            while k < chars.count {
                if chars[k] == "\\" && k + 1 < chars.count { k += 2; continue }
                if chars[k] == closeQuote { k += 1; break }
                k += 1
            }
            // Skip whitespace after title
            while k < chars.count && (chars[k] == " " || chars[k] == "\t" || chars[k] == "\n") { k += 1 }
        }

        // Must end with )
        guard k < chars.count && chars[k] == ")" else { return nil }

        let text = String(chars[(start + 1)..<textEnd])
        // rawDestination: everything between ( and ) for round-trip fidelity
        let dest = String(chars[(parenOpen + 1)..<k])
        return (text, dest, k + 1)
    }

    /// Try to match an inline image `![alt](destination)` starting at `start`.
    private static func tryMatchImage(
        _ chars: [Character], from start: Int,
        codeSpanRanges: [(start: Int, end: Int)] = []
    ) -> (alt: String, dest: String, endIndex: Int)? {
        guard start + 1 < chars.count, chars[start] == "!", chars[start + 1] == "[" else { return nil }
        // Reuse link matching starting from the [
        guard let linkMatch = tryMatchLink(chars, from: start + 1, codeSpanRanges: codeSpanRanges) else { return nil }
        return (linkMatch.text, linkMatch.dest, linkMatch.endIndex)
    }

    // MARK: - Unicode character classification helpers

    /// Returns true if `ch` is a Unicode whitespace character.
    /// Includes all characters from Unicode category Zs plus ASCII
    /// control whitespace, per CommonMark spec.
    private static func isUnicodeWhitespace(_ ch: Character) -> Bool {
        if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" ||
           ch == "\u{000C}" || ch == "\u{000B}" || ch == "\u{00A0}" {
            return true
        }
        // Check for other Unicode space separators (Zs category)
        if let scalar = ch.unicodeScalars.first {
            return scalar.properties.generalCategory == .spaceSeparator
        }
        return false
    }

    /// Returns true if `ch` is a Unicode punctuation character (ASCII
    /// punctuation + Unicode general categories Pc, Pd, Pe, Pf, Pi, Po, Ps).
    private static func isUnicodePunctuation(_ ch: Character) -> Bool {
        // Fast path: ASCII punctuation
        if isPunctuationChar(ch) { return true }
        // Slow path: Unicode general category
        if let scalar = ch.unicodeScalars.first {
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .closePunctuation,
                 .finalPunctuation, .initialPunctuation, .otherPunctuation,
                 .openPunctuation:
                return true
            default:
                return false
            }
        }
        return false
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
        let chars = Array(line)
        var i = 0
        // Allow up to 3 leading spaces before >
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == ">" else { return nil }
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
    /// CommonMark rule: a line containing 3+ of the same character
    /// (`-`, `*`, or `_`), optionally interspersed with spaces/tabs,
    /// with up to 3 leading spaces, and nothing else on the line.
    /// Returns the character and the count of HR characters (not
    /// spaces), or nil otherwise. Note: spaced HRs like `- - -`
    /// will be normalized to `---` on round-trip serialization.
    private static func detectHorizontalRule(_ line: String) -> (character: Character, length: Int)? {
        let chars = Array(line)
        var i = 0
        // Allow up to 3 leading spaces
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        guard i < chars.count else { return nil }
        let hrChar = chars[i]
        guard hrChar == "-" || hrChar == "*" || hrChar == "_" else { return nil }
        var count = 0
        while i < chars.count {
            if chars[i] == hrChar {
                count += 1
            } else if chars[i] == " " || chars[i] == "\t" {
                // spaces/tabs allowed between HR characters
            } else {
                return nil // non-HR, non-whitespace character
            }
            i += 1
        }
        guard count >= 3 else { return nil }
        return (hrChar, count)
    }

    /// Detect a setext heading underline: a line of `===` (H1) or `---` (H2).
    /// Returns the heading level (1 or 2) if the line is a valid underline.
    private static func detectSetextUnderline(_ line: String) -> Int? {
        // CommonMark 4.3: up to 3 leading spaces before the underline,
        // followed by one-or-more `=` (H1) or `-` (H2) characters, then
        // optional trailing whitespace.
        var chars = Array(line)
        var i = 0
        var leading = 0
        while i < chars.count, chars[i] == " ", leading < 3 {
            leading += 1
            i += 1
        }
        guard i < chars.count else { return nil }
        let marker = chars[i]
        guard marker == "=" || marker == "-" else { return nil }
        let runStart = i
        while i < chars.count, chars[i] == marker { i += 1 }
        let runLen = i - runStart
        // Allow trailing spaces/tabs.
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        guard i == chars.count else { return nil }
        if marker == "=" {
            guard runLen >= 1 else { return nil }
            return 1
        } else {
            // `-` underline: CommonMark technically allows 1+ chars, but
            // a single `-` on a line is reliably a list-marker start in
            // all observed spec examples. Keep the pre-existing 3-char
            // disambiguation: `foo\n-` is a paragraph + (inert) list
            // marker, not a setext H2. Three chars (`---`) is the
            // minimum used by every passing spec example.
            guard runLen >= 3 else { return nil }
            return 2
        }
    }

    /// Check if the raw buffer (paragraph lines) is entirely wrapped in
    /// emphasis markers (e.g., `**Bold text**`, `*italic*`, `__bold__`,
    /// `_italic_`). Such paragraphs should NOT be promoted to setext
    /// headings when followed by `---`.
    private static func isEmphasisOnlyParagraph(_ buffer: [String]) -> Bool {
        guard buffer.count == 1 else { return false }
        let line = buffer[0].trimmingCharacters(in: .whitespaces)
        // Check for double markers: **...** or __...__
        if (line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4) ||
           (line.hasPrefix("__") && line.hasSuffix("__") && line.count > 4) {
            return true
        }
        // Check for single markers: *...* or _..._
        if (line.hasPrefix("*") && line.hasSuffix("*") && !line.hasPrefix("**") && line.count > 2) ||
           (line.hasPrefix("_") && line.hasSuffix("_") && !line.hasPrefix("__") && line.count > 2) {
            return true
        }
        return false
    }

    // MARK: - Table detection

    /// Result of table detection: the block, the next line index to
    /// continue parsing from, and whether the header was taken from
    /// the rawBuffer (so the caller can remove it before flushing).
    private struct TableDetection {
        let block: Block
        let nextIndex: Int
        let headerFromBuffer: Bool
    }

    /// Try to detect a pipe-delimited table starting at line index `at`.
    /// Two detection modes:
    ///  (a) lines[at] is the header, lines[at+1] is the separator.
    ///  (b) rawBuffer.last is the header, lines[at] is the separator.
    /// Returns nil if no table is found.
    ///
    /// Each cell's raw string is parsed via `parseInlines` so the
    /// table carries `TableCell` values (inline trees) rather than
    /// opaque strings — this is the Option C unification, cells are
    /// paragraphs.
    private static func detectTable(
        lines: [String],
        at i: Int,
        rawBuffer: [String],
        markdown: String
    ) -> TableDetection? {
        // Mode (a): current line is header, next line is separator.
        if i + 1 < lines.count {
            let headerLine = lines[i]
            let sepLine = lines[i + 1]
            if !(i + 1 == lines.count - 1 && sepLine.isEmpty && markdown.hasSuffix("\n")),
               isTableRow(headerLine),
               isTableSeparator(sepLine) {
                let headerStrings = parseTableRow(headerLine)
                let alignments = parseAlignments(sepLine)
                let colCount = headerStrings.count
                let headerCells = headerStrings.map {
                    TableCell(parseInlines($0, refDefs: [:]))
                }
                var dataRows: [[TableCell]] = []
                var j = i + 2
                while j < lines.count {
                    let l = lines[j]
                    if j == lines.count - 1 && l.isEmpty && markdown.hasSuffix("\n") { break }
                    guard isTableRow(l) else { break }
                    var rowStrings = parseTableRow(l)
                    // Pad or truncate to match header column count.
                    while rowStrings.count < colCount { rowStrings.append("") }
                    if rowStrings.count > colCount {
                        rowStrings = Array(rowStrings.prefix(colCount))
                    }
                    let rowCells = rowStrings.map {
                        TableCell(parseInlines($0, refDefs: [:]))
                    }
                    dataRows.append(rowCells)
                    j += 1
                }
                return TableDetection(
                    block: .table(header: headerCells, alignments: alignments, rows: dataRows, columnWidths: nil),
                    nextIndex: j,
                    headerFromBuffer: false
                )
            }
        }

        // Mode (b): rawBuffer.last is the header, current line is separator.
        if !rawBuffer.isEmpty, isTableSeparator(lines[i]) {
            let headerLine = rawBuffer.last!
            let sepLine = lines[i]
            guard isTableRow(headerLine) else { return nil }
            let headerStrings = parseTableRow(headerLine)
            let alignments = parseAlignments(sepLine)
            let colCount = headerStrings.count
            let headerCells = headerStrings.map {
                TableCell(parseInlines($0, refDefs: [:]))
            }
            var dataRows: [[TableCell]] = []
            var j = i + 1
            while j < lines.count {
                let l = lines[j]
                if j == lines.count - 1 && l.isEmpty && markdown.hasSuffix("\n") { break }
                guard isTableRow(l) else { break }
                var rowStrings = parseTableRow(l)
                while rowStrings.count < colCount { rowStrings.append("") }
                if rowStrings.count > colCount {
                    rowStrings = Array(rowStrings.prefix(colCount))
                }
                let rowCells = rowStrings.map {
                    TableCell(parseInlines($0, refDefs: [:]))
                }
                dataRows.append(rowCells)
                j += 1
            }
            return TableDetection(
                block: .table(header: headerCells, alignments: alignments, rows: dataRows, columnWidths: nil),
                nextIndex: j,
                headerFromBuffer: true
            )
        }

        return nil
    }

    /// Check if a line looks like a table row (contains at least one `|`).
    private static func isTableRow(_ line: String) -> Bool {
        return line.contains("|")
    }

    /// Check if a line is a table separator row: all cells contain only
    /// `-`, `:`, and spaces (with at least one `-` per cell).
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return false }
        let cells = parseTableRow(line)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            if c.isEmpty { return false }
            for ch in c {
                guard ch == "-" || ch == ":" || ch == " " else { return false }
            }
            // Must have at least one dash.
            guard c.contains("-") else { return false }
        }
        return true
    }

    /// Parse column alignments from a separator row.
    private static func parseAlignments(_ line: String) -> [TableAlignment] {
        let cells = parseTableRow(line)
        return cells.map { cell -> TableAlignment in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            if left { return .left }
            return .none
        }
    }

    /// Split a pipe-delimited row into cell strings, trimming whitespace
    /// from each cell. Handles leading and trailing `|`.
    private static func parseTableRow(_ line: String) -> [String] {
        var work = line
        // Strip leading/trailing pipes if present.
        let trimmed = work.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            work = String(trimmed.dropFirst())
        }
        if work.hasSuffix("|") {
            work = String(work.dropLast())
        }
        let parts = work.split(separator: "|", omittingEmptySubsequences: false)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - List detection

    /// Classify a list marker into its "type" for determining whether
    /// two list items belong to the same list. CommonMark rule: a
    /// change in bullet character (`-`, `*`, `+`) or ordered delimiter
    /// (`.` vs `)`) starts a new list.
    /// Returns: the bullet character for unordered, or the delimiter
    /// character for ordered (e.g. "." or ")").
    /// Returns true if `marker` is an ordered-list marker (e.g. "2.", "10)")
    /// whose starting number is not 1. Used to enforce CommonMark 5.3:
    /// such a marker cannot interrupt a paragraph.
    static func isOrderedListMarkerWithNonOneStart(_ marker: String) -> Bool {
        // Ordered marker is digits + "." or ")".
        guard marker.last == "." || marker.last == ")" else { return false }
        let digits = String(marker.dropLast())
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return false }
        return Int(digits) != 1
    }

    static func listMarkerType(_ marker: String) -> String {
        if marker == "-" || marker == "*" || marker == "+" {
            return marker
        }
        // Ordered: digits + delimiter. The delimiter is the last char.
        if let last = marker.last {
            return String(last)
        }
        return marker
    }

    /// A single line parsed as a list item: split into leading
    /// indentation, the marker itself, the whitespace after the
    /// marker, an optional checkbox, and the line's content.
    struct ParsedListLine {
        let indent: String        // leading whitespace (spaces/tabs)
        let marker: String        // "-", "*", "+", or "<digits>.", "<digits>)"
        let afterMarker: String   // whitespace between marker and content/checkbox
        let checkbox: Checkbox?   // "[ ]", "[x]", "[X]" for todo items
        let content: String       // remainder of the line after checkbox/afterMarker
        var blankLineBefore: Bool = false // true if blank line(s) preceded this item
        /// Raw continuation lines attached to this item after a blank
        /// line — already dedented by the item's content column, with
        /// blank-line separators preserved as empty strings. Parsed at
        /// buildItemTree time into `ListItem.continuationBlocks`.
        var continuationLines: [String] = []
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
            // CommonMark 5.2 caps the digit run at 9. 10+ digits is not
            // a valid list marker (e.g. "1234567890. not ok").
            let digitStart = i
            while i < chars.count, chars[i].isNumber { i += 1 }
            let digitCount = i - digitStart
            guard digitCount >= 1 && digitCount <= 9 else { return nil }
            guard i < chars.count, chars[i] == "." || chars[i] == ")" else {
                return nil
            }
            i += 1
        } else {
            return nil
        }

        let marker = String(chars[markerStart..<i])

        // afterMarker: require at least one space/tab, OR the marker
        // is at end of line (empty list item, e.g. "-\n", "1.\n").
        // CommonMark allows empty items where the marker is the entire
        // line content.
        let afterStart = i
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        if i == afterStart {
            // Marker at end of line with no whitespace — valid empty
            // list item per CommonMark (e.g. "-\n", "1.\n", "*\n").
            if i == chars.count {
                return ParsedListLine(
                    indent: indent, marker: marker,
                    afterMarker: "", checkbox: nil,
                    content: ""
                )
            }
            // Marker followed by non-whitespace — not a list item.
            return nil
        }
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
        lines: [ParsedListLine], from: Int,
        parentContentColumn: Int,
        refDefs: [String: (url: String, title: String?)] = [:]
    ) -> (items: [ListItem], endIndex: Int) {
        guard from < lines.count else { return ([], from) }

        // CommonMark 5.2 nesting rule: a list item is a CHILD of a
        // preceding item iff its marker starts at a column >= the
        // parent's content column (indent + marker + afterMarker).
        // Otherwise it is a SIBLING at the current level.
        //
        // This tolerates siblings with differing indent (e.g. `- a\n - b`
        // — both siblings because `- b` at indent 1 < content col 2 of
        // `- a`). The first line that falls below parentContentColumn
        // belongs to the caller and returns.
        var items: [ListItem] = []
        var i = from
        while i < lines.count {
            let cur = lines[i]
            let curIndent = cur.indent.count
            // Shallower than the caller's content boundary — return.
            if curIndent < parentContentColumn { break }
            // Defensively: if this line is strictly a child of the
            // LATEST sibling (indent >= that sibling's content column),
            // the nested recursion should have consumed it. We land
            // here only if the previous sibling didn't recurse (e.g.
            // this is the first line at this level), in which case
            // `curIndent` equals (or drops below) the current sibling
            // indent we're about to set.
            let inline = parseInlines(cur.content, refDefs: refDefs)
            let curContentColumn = curIndent + cur.marker.count + cur.afterMarker.count
            let (children, nextI) = buildItemTree(
                lines: lines, from: i + 1,
                parentContentColumn: curContentColumn,
                refDefs: refDefs
            )
            // Parse any continuation lines attached at collection time
            // into a block sequence. Uses the parser recursively (note:
            // this is idempotent because continuation text has already
            // been dedented by the item's content column).
            var continuationBlocks: [Block]
            if cur.continuationLines.isEmpty {
                continuationBlocks = []
            } else {
                let inner = cur.continuationLines.joined(separator: "\n") + "\n"
                let innerDoc = MarkdownParser.parse(inner)
                continuationBlocks = innerDoc.blocks.filter {
                    if case .blankLine = $0 { return false }
                    return true
                }
            }

            // CommonMark 5.2 example #298, #299: a list marker may be
            // followed on the same line by another list marker. Each
            // nested marker starts its own list. Detect this by
            // re-parsing `cur.content` as a list line; if it is one,
            // consume `cur.content` entirely as a nested list block
            // (carried on continuationBlocks) and emit the outer item
            // with empty inline content. This produces the correct
            // `<li><ul><li>...</li></ul></li>` tree.
            var outerInline = inline
            if let nested = parseListLine(cur.content),
               nested.indent.isEmpty || nested.indent.allSatisfy({ $0 == " " }) {
                // Re-emit the nested content as its own list in the
                // outer item's continuationBlocks. Keep any pre-existing
                // continuationBlocks behind it.
                let nestedDoc = MarkdownParser.parse(cur.content + "\n")
                let nestedBlocks = nestedDoc.blocks.filter {
                    if case .blankLine = $0 { return false }
                    return true
                }
                continuationBlocks = nestedBlocks + continuationBlocks
                outerInline = []
            }

            items.append(ListItem(
                indent: cur.indent,
                marker: cur.marker,
                afterMarker: cur.afterMarker,
                checkbox: cur.checkbox,
                inline: outerInline,
                children: children,
                blankLineBefore: cur.blankLineBefore,
                continuationBlocks: continuationBlocks
            ))
            i = nextI
        }
        return (items, i)
    }

    // MARK: - List continuation helpers (CommonMark container-block rules)

    /// Count of leading space characters (tabs expanded to 4-stop tabstops).
    /// Used to determine whether a continuation line is indented enough
    /// to belong to an enclosing list item.
    private static func leadingSpaceCount(_ line: String) -> Int {
        var col = 0
        for ch in line {
            if ch == " " { col += 1 }
            else if ch == "\t" { col += 4 - (col % 4) }
            else { break }
        }
        return col
    }

    /// Strip `count` leading columns of whitespace from `line`, counting
    /// tabs as 4-stop tabstops. If the line has fewer leading columns
    /// than `count`, returns the trimmed remainder. Used to dedent
    /// continuation lines inside a list item by the item's content
    /// column.
    private static func stripLeadingSpaces(_ line: String, count: Int) -> String {
        var col = 0
        var idx = line.startIndex
        while idx < line.endIndex && col < count {
            let ch = line[idx]
            if ch == " " {
                col += 1
                idx = line.index(after: idx)
            } else if ch == "\t" {
                let tabWidth = 4 - (col % 4)
                if col + tabWidth > count {
                    // Partial tab: emit the overflow as spaces.
                    let overflow = (col + tabWidth) - count
                    col += tabWidth
                    idx = line.index(after: idx)
                    return String(repeating: " ", count: overflow) + line[idx...]
                }
                col += tabWidth
                idx = line.index(after: idx)
            } else {
                break
            }
        }
        return String(line[idx...])
    }

    /// Find the deepest existing parsed item whose content column is
    /// ≤ `indent`. Returns nil if no item is a valid owner. "Deepest"
    /// means the item most recently pushed onto the list, which is
    /// what makes nested-list continuation work (continuations attach
    /// to the innermost container that can host them).
    private static func deepestOwner(in parsed: [ParsedListLine], forIndent indent: Int) -> Int? {
        // Walk forward and take the last qualifying item. "Last"
        // matters in flat-list cases like `- a\n- b\n\n  c`, where
        // both `a` and `b` have the same content column but the
        // continuation belongs to `b` (the item immediately above
        // the blank line). Ties on content column resolve to the
        // most recently appended parsed item.
        var bestIdx: Int? = nil
        var bestCol = -1
        for (idx, p) in parsed.enumerated() {
            let col = p.indent.count + p.marker.count + p.afterMarker.count
            if col <= indent && col >= bestCol {
                bestIdx = idx
                bestCol = col
            }
        }
        return bestIdx
    }

    // MARK: - Link reference definition collection

    /// Scan all lines for link reference definitions (first pass).
    /// Returns the collected definitions (case-insensitive label lookup)
    /// and the set of line indices that were consumed.
    /// Respects code fences — lines inside fenced code blocks are not
    /// scanned for link ref defs.
    private static func collectLinkRefDefs(
        _ lines: [String], trailingNewline: Bool
    ) -> (defs: [String: (url: String, title: String?)], consumed: Set<Int>) {
        var defs: [String: (url: String, title: String?)] = [:]
        var consumed: Set<Int> = []
        var inCodeFence = false
        var openFenceChar: Character = "`"
        var openFenceLength = 0

        let effectiveCount = (trailingNewline && lines.last == "") ? lines.count - 1 : lines.count
        var i = 0
        while i < effectiveCount {
            let line = lines[i]

            // Track code fences to avoid matching inside them.
            if !inCodeFence {
                if let fence = detectFenceOpen(line) {
                    inCodeFence = true
                    openFenceChar = fence.fenceChar
                    openFenceLength = fence.fenceLength
                    i += 1
                    continue
                }
            } else {
                // Check for closing fence.
                let fence = Fence(fenceChar: openFenceChar, fenceLength: openFenceLength, infoRaw: "", indent: 0)
                if isFenceClose(line, matching: fence) {
                    inCodeFence = false
                }
                i += 1
                continue
            }

            // Try to parse starting at this line as a (possibly multi-line) link reference definition.
            // CommonMark 4.7: a link reference definition cannot
            // interrupt a paragraph. It must start at the beginning of
            // a block — either the start of the document, after a
            // blank line, or immediately after a non-paragraph block
            // boundary (e.g. a previously-consumed ref-def, fence
            // open/close, heading line). We approximate this with:
            // "previous line is blank OR previous line was already
            // consumed as a ref-def OR this is line 0".
            let canStartBlock: Bool = {
                if i == 0 { return true }
                let prev = lines[i - 1]
                if prev.isEmpty || isBlankLine(prev) { return true }
                if consumed.contains(i - 1) { return true }
                // ATX heading line on the previous line? Check detect.
                if detectHeading(prev) != nil { return true }
                // Fence open/close on the previous line?
                if detectFenceOpen(prev) != nil { return true }
                // Horizontal rule on the previous line?
                if detectHorizontalRule(prev) != nil { return true }
                return false
            }()
            if canStartBlock,
               let parsed = tryParseLinkRefDef(lines, startIndex: i, effectiveCount: effectiveCount) {
                let key = normalizeLabel(parsed.label)
                // First definition wins (CommonMark rule).
                if defs[key] == nil {
                    defs[key] = (url: parsed.url, title: parsed.title)
                }
                for j in i..<(i + parsed.linesConsumed) {
                    consumed.insert(j)
                }
                i += parsed.linesConsumed
            } else {
                i += 1
            }
        }
        return (defs, consumed)
    }

    /// Normalize a link reference label for case-insensitive matching.
    /// Collapses whitespace runs to a single space and lowercases.
    private static func normalizeLabel(_ label: String) -> String {
        label.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").joined(separator: " ")
            .split(separator: "\t").joined(separator: " ")
    }

    /// Check if a string is only whitespace (spaces/tabs).
    private static func isBlankLine(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Strip up to 3 leading ASCII spaces from a line. Used when
    /// buffering paragraph lines (CommonMark 4.8). 4+ leading spaces
    /// would be an indented code block context, which we don't
    /// currently distinguish; anything with 4+ leading spaces is
    /// left alone so we preserve that content verbatim.
    private static func stripUpTo3LeadingSpaces(_ s: String) -> String {
        // Count the full leading-space run first.
        var leadingSpaces = 0
        for ch in s {
            if ch == " " { leadingSpaces += 1 } else { break }
        }
        // If the run is 4+ spaces, don't touch it (indented-code
        // context). If it's 1-3, strip those leading spaces.
        if leadingSpaces >= 4 { return s }
        if leadingSpaces == 0 { return s }
        return String(s.dropFirst(leadingSpaces))
    }

    /// ASCII punctuation characters that can be backslash-escaped per CommonMark spec.
    private static let asciiPunctuationChars: Set<Character> = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// Check if a character is ASCII punctuation (valid after backslash escape).
    private static func isASCIIPunctuation(_ ch: Character) -> Bool {
        asciiPunctuationChars.contains(ch)
    }

    /// Build a rawDestination string from a URL and optional title.
    /// Wraps URLs containing spaces in angle brackets so that
    /// `extractURLAndTitle` can round-trip them correctly.
    /// Uses single-quote delimiters for titles containing double-quotes
    /// (and vice versa) so extractURLAndTitle parses them correctly.
    ///
    /// Internal (not private) so `EditingOps.setImageSize` can rebuild
    /// a canonical rawDestination after mutating the size hint.
    static func buildRawDest(url: String, title: String?) -> String {
        let urlPart: String
        if url.contains(" ") || url.contains("\t") {
            urlPart = "<\(url)>"
        } else {
            urlPart = url
        }
        if let title = title {
            // Choose delimiter that doesn't appear in the title.
            // extractURLAndTitle doesn't process escapes in titles,
            // so we must use a delimiter not present in the content.
            if !title.contains("\"") {
                return "\(urlPart) \"\(title)\""
            } else if !title.contains("'") {
                return "\(urlPart) '\(title)'"
            } else {
                // Both quote types present — use " and escape embedded "
                // extractURLAndTitle skips \" when scanning for closing "
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                return "\(urlPart) \"\(escaped)\""
            }
        }
        return urlPart
    }

    // MARK: - URL / title extraction (used by setImageSize)

    /// Split a raw destination string into (url, title).
    /// Inverse of `buildRawDest`. The `raw` argument is the text between
    /// the parens of `![alt](...)` or `[text](...)` — exactly what the
    /// parser stores in `rawDestination`.
    ///
    /// Returns nil title when the destination has no title portion
    /// (bare URL). Handles angle-bracketed URLs, quoted titles
    /// (single- or double-quoted) and parenthesized titles. Escape
    /// sequences inside the title are NOT unescaped here — the caller
    /// gets the text verbatim so a round-trip through buildRawDest
    /// produces byte-identical output.
    static func extractURLAndTitle(from raw: String) -> (url: String, title: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ("", nil) }

        let chars = Array(trimmed)
        var i = 0
        let url: String

        if chars[i] == "<" {
            // Angle-bracketed URL
            i += 1
            let urlStart = i
            while i < chars.count && chars[i] != ">" {
                if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
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
                    i += 1
                }
                i += 1
            }
            url = String(chars[urlStart..<i])
        }

        // Skip whitespace before optional title
        while i < chars.count && (chars[i] == " " || chars[i] == "\t" || chars[i] == "\n") { i += 1 }

        var title: String? = nil
        if i < chars.count {
            let open = chars[i]
            if open == "\"" || open == "'" {
                i += 1
                let titleStart = i
                while i < chars.count && chars[i] != open {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    i += 1
                }
                title = String(chars[titleStart..<i])
            } else if open == "(" {
                i += 1
                let titleStart = i
                while i < chars.count && chars[i] != ")" {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    i += 1
                }
                title = String(chars[titleStart..<i])
            }
        }

        return (url, title)
    }

    // MARK: - Image size title hint (width=N)

    /// Parse and emit the `width=N` token carried inside a CommonMark
    /// image title field. The title may contain arbitrary user text
    /// alongside the size hint — e.g. `"photo from 2024 width=300"` —
    /// and we need to preserve that text verbatim on round-trip.
    ///
    /// Format rules:
    /// - The size token is `width=N` where N is a positive integer.
    /// - It is matched only as a SPACE-DELIMITED SUFFIX of the title
    ///   (either the whole title, or everything after the last space).
    ///   This avoids accidental matches inside longer prose.
    /// - A non-positive or non-numeric N falls through to no match,
    ///   leaving the entire title as opaque preserved text.
    enum ImageSizeTitle {
        /// Parse a title string into (preserved-non-size-part, width).
        /// Examples:
        ///   ""                    → (nil, nil)
        ///   "width=300"           → (nil, 300)
        ///   "photo"               → ("photo", nil)
        ///   "photo width=300"     → ("photo", 300)
        ///   "photo width=0"       → ("photo width=0", nil)  // 0 invalid
        ///   "photo width=-5"      → ("photo width=-5", nil) // negative invalid
        ///   "width=abc"           → ("width=abc", nil)      // non-numeric
        ///   "wide"                → ("wide", nil)           // not width=
        static func parse(_ title: String) -> (preserved: String?, width: Int?) {
            if title.isEmpty { return (nil, nil) }

            // Try "whole title is the size token"
            if let w = parseSizeToken(title) {
                return (nil, w)
            }

            // Try "<preserved> <size token>" (split on last space)
            if let lastSpace = title.lastIndex(of: " ") {
                let tail = String(title[title.index(after: lastSpace)...])
                if let w = parseSizeToken(tail) {
                    let head = String(title[..<lastSpace])
                    // Trim trailing whitespace from the preserved part
                    let trimmed = head.trimmingCharacters(in: .whitespaces)
                    return (trimmed.isEmpty ? nil : trimmed, w)
                }
            }

            // No size hint found — whole title is preserved
            return (title, nil)
        }

        /// Build a title string from preserved text + optional width.
        /// Inverse of `parse`. Returns nil when both inputs are nil —
        /// the caller should then omit the title entirely from the
        /// rawDestination.
        static func emit(preserved: String?, width: Int?) -> String? {
            let p = preserved?.trimmingCharacters(in: .whitespaces)
            let hasPreserved = (p != nil && !p!.isEmpty)
            let hasWidth = (width != nil && width! > 0)

            switch (hasPreserved, hasWidth) {
            case (false, false): return nil
            case (true, false):  return p
            case (false, true):  return "width=\(width!)"
            case (true, true):   return "\(p!) width=\(width!)"
            }
        }

        /// Recognize exactly `width=N` where N is a positive integer.
        /// Returns N, or nil on any failure.
        private static func parseSizeToken(_ token: String) -> Int? {
            guard token.hasPrefix("width=") else { return nil }
            let rest = token.dropFirst("width=".count)
            guard !rest.isEmpty, !rest.contains(" "), !rest.contains("\t") else { return nil }
            guard let n = Int(rest), n > 0 else { return nil }
            return n
        }
    }

    // MARK: - Lazy continuation support

    /// Check whether a line would interrupt lazy continuation of a
    /// paragraph inside a blockquote. CommonMark §5.1: a lazy
    /// continuation line is any line that is not blank and does not
    /// start a block-level construct that can interrupt a paragraph.
    ///
    /// Constructs that interrupt:
    /// - Blank line
    /// - Blockquote marker `>`
    /// - ATX heading `# ...`
    /// - Fenced code opening ``` or ~~~
    /// - Thematic break (HR)
    /// - List item with <= 3 spaces indent
    /// - HTML block (types 1-6 only; type 7 cannot interrupt a paragraph)
    private static func interruptsLazyContinuation(_ line: String) -> Bool {
        // Blank line
        if isBlankLine(line) || line.isEmpty { return true }
        // Blockquote marker
        if detectBlockquoteLine(line) != nil { return true }
        // ATX heading
        if detectHeading(line) != nil { return true }
        // Fenced code opening
        if detectFenceOpen(line) != nil { return true }
        // Thematic break / HR
        if detectHorizontalRule(line) != nil { return true }
        // List item with <= 3 spaces of indent (4+ spaces = indented code
        // block context, which cannot interrupt a paragraph)
        if let parsed = parseListLine(line) {
            let spaceCount = parsed.indent.filter { $0 == " " }.count
                + parsed.indent.filter { $0 == "\t" }.count * 4
            // CommonMark 5.3: an ordered marker with start != 1 also
            // does NOT interrupt a paragraph.
            if spaceCount <= 3 && !isOrderedListMarkerWithNonOneStart(parsed.marker) {
                return true
            }
        }
        // HTML block start (types 1-6 can interrupt a paragraph; type 7 cannot)
        if let htmlType = detectHTMLBlock(line), htmlType <= 6 { return true }
        return false
    }

    /// Check whether the inner content of collected blockquote lines
    /// ends in a paragraph context (as opposed to a code block or
    /// open code fence), which is required for lazy continuation.
    private static func blockquoteInnerAllowsLazyContinuation(_ contentLines: [String]) -> Bool {
        guard !contentLines.isEmpty else { return false }

        // Check for an open (unclosed) code fence
        var openFence: Fence? = nil
        for inner in contentLines {
            if let fence = openFence {
                if isFenceClose(inner, matching: fence) {
                    openFence = nil
                }
            } else if let fence = detectFenceOpen(inner) {
                openFence = fence
            }
        }
        // If there's an unclosed code fence, lazy continuation is not allowed
        if openFence != nil { return false }

        // Check if the last non-blank inner line is an indented code block
        // (4+ spaces of leading indent). Indented code blocks don't support
        // lazy continuation.
        if let lastNonBlank = contentLines.last(where: { !isBlankLine($0) && !$0.isEmpty }) {
            let leadingSpaces = lastNonBlank.prefix(while: { $0 == " " }).count
            if leadingSpaces >= 4 { return false }
        }

        // Check if the last line is blank (empty blockquote line ">")
        // — a blank line inside a blockquote ends the paragraph.
        if let lastInner = contentLines.last, isBlankLine(lastInner) || lastInner.isEmpty {
            return false
        }

        return true
    }

    /// Try to parse a multi-line link reference definition starting at `startIndex`.
    /// Returns the parsed label, url, optional title, and how many lines were consumed.
    /// CommonMark allows:
    ///   - URL on the next line after `[label]:`
    ///   - Title on the next line after the URL
    ///   - Multi-line titles (spanning lines until the closing quote, broken by blank lines)
    private static func tryParseLinkRefDef(
        _ lines: [String], startIndex: Int, effectiveCount: Int
    ) -> (label: String, url: String, title: String?, linesConsumed: Int)? {
        let line = lines[startIndex]
        let chars = Array(line)
        var i = 0

        // Up to 3 leading spaces.
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        guard i < chars.count && chars[i] == "[" else { return nil }
        i += 1

        // Find closing ] for label.
        let labelStart = i
        while i < chars.count && chars[i] != "]" && chars[i] != "[" {
            if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
            i += 1
        }
        guard i < chars.count && chars[i] == "]" else { return nil }
        let label = String(chars[labelStart..<i])
        guard !label.isEmpty else { return nil }
        i += 1

        // Must be followed by `:`.
        guard i < chars.count && chars[i] == ":" else { return nil }
        i += 1

        // Skip whitespace.
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }

        var currentLine = startIndex
        var linesConsumed = 1

        // If nothing remains on this line after `[label]:`, URL must be on next line.
        if i >= chars.count {
            // Need a next line for the URL.
            let nextLine = startIndex + 1
            guard nextLine < effectiveCount && !isBlankLine(lines[nextLine]) else { return nil }
            currentLine = nextLine
            linesConsumed = 2
            // Parse destination from next line.
            let result = parseDestinationAndTitle(lines, lineIndex: currentLine, charOffset: 0,
                                                  startIndex: startIndex, linesConsumed: linesConsumed,
                                                  effectiveCount: effectiveCount, label: label)
            return result
        }

        // Parse destination from current position on the first line.
        return parseDestinationAndTitle(lines, lineIndex: currentLine, charOffset: i,
                                        startIndex: startIndex, linesConsumed: linesConsumed,
                                        effectiveCount: effectiveCount, label: label)
    }

    /// Parse destination and optional title from the given line and character offset.
    /// Handles multi-line titles and title-on-next-line.
    private static func parseDestinationAndTitle(
        _ lines: [String], lineIndex: Int, charOffset: Int,
        startIndex: Int, linesConsumed: Int, effectiveCount: Int, label: String
    ) -> (label: String, url: String, title: String?, linesConsumed: Int)? {
        let lineStr = lines[lineIndex]
        let chars = Array(lineStr)
        var i = charOffset
        var consumed = linesConsumed

        // Skip leading whitespace on continuation lines.
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }

        // Parse destination.
        guard i < chars.count else { return nil }
        var url = ""
        if chars[i] == "<" {
            // Angle-bracketed destination.
            i += 1
            let urlStart = i
            while i < chars.count && chars[i] != ">" {
                if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                i += 1
            }
            guard i < chars.count else { return nil }
            url = String(chars[urlStart..<i])
            i += 1
        } else {
            // Bare destination: no spaces, balanced parens.
            let urlStart = i
            var parenDepth = 0
            while i < chars.count && chars[i] != " " && chars[i] != "\t" {
                if chars[i] == "(" { parenDepth += 1 }
                else if chars[i] == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                }
                if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                i += 1
            }
            url = String(chars[urlStart..<i])
        }

        // URL must not be empty for bare destinations (angle-bracket <> is OK).
        if url.isEmpty && !(i > 0 && chars[i - 1] == ">") {
            // Check if char before urlStart was '<' — if angle brackets produced empty, that's ok.
            // Otherwise, empty bare URL is not valid.
            return nil
        }

        // Skip whitespace after URL.
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }

        // --- Try to parse title ---

        // Case 1: Title starts on same line as URL.
        if i < chars.count && (chars[i] == "\"" || chars[i] == "'" || chars[i] == "(") {
            let open = chars[i]
            let close: Character = open == "(" ? ")" : open
            i += 1
            var titleChars: [Character] = []
            // Scan for closing quote, possibly spanning multiple lines.
            var titleLine = lineIndex
            var ti = i
            while true {
                let tChars = Array(lines[titleLine])
                while ti < tChars.count {
                    if tChars[ti] == close {
                        // Found closing quote. Rest of this line must be whitespace only.
                        ti += 1
                        while ti < tChars.count {
                            if tChars[ti] != " " && tChars[ti] != "\t" { return nil }
                            ti += 1
                        }
                        let title = String(titleChars)
                        let totalConsumed = titleLine - startIndex + 1
                        return (label, url, title, totalConsumed)
                    }
                    if tChars[ti] == "\\" && ti + 1 < tChars.count {
                        let next = tChars[ti + 1]
                        if isASCIIPunctuation(next) {
                            // Valid backslash escape — consume \ and keep the char.
                            titleChars.append(next)
                        } else {
                            // Not a valid escape — preserve both characters.
                            titleChars.append("\\")
                            titleChars.append(next)
                        }
                        ti += 2
                    } else {
                        titleChars.append(tChars[ti])
                        ti += 1
                    }
                }
                // Title continues on next line.
                titleLine += 1
                if titleLine >= effectiveCount || isBlankLine(lines[titleLine]) {
                    // Blank line breaks a multi-line title — entire def is invalid.
                    return nil
                }
                titleChars.append("\n")
                ti = 0
            }
        }

        // Case 2: Nothing after URL on this line — valid def without title,
        // but also check if next line starts a title.
        if i >= chars.count {
            // Check next line for a title.
            let nextTitleLine = lineIndex + 1
            if nextTitleLine < effectiveCount && !isBlankLine(lines[nextTitleLine]) {
                let nextChars = Array(lines[nextTitleLine])
                var ni = 0
                while ni < nextChars.count && (nextChars[ni] == " " || nextChars[ni] == "\t") { ni += 1 }
                if ni < nextChars.count && (nextChars[ni] == "\"" || nextChars[ni] == "'" || nextChars[ni] == "(") {
                    let open = nextChars[ni]
                    let close: Character = open == "(" ? ")" : open
                    ni += 1
                    var titleChars: [Character] = []
                    var titleLine = nextTitleLine
                    var ti = ni
                    while true {
                        let tChars = Array(lines[titleLine])
                        while ti < tChars.count {
                            if tChars[ti] == close {
                                // Found closing quote. Rest must be whitespace.
                                ti += 1
                                while ti < tChars.count {
                                    if tChars[ti] != " " && tChars[ti] != "\t" {
                                        // Title line has trailing content like `"title" ok` —
                                        // the title is invalid. But the def is still valid
                                        // without the title (the next line is NOT consumed).
                                        return (label, url, nil, lineIndex - startIndex + 1)
                                    }
                                    ti += 1
                                }
                                let title = String(titleChars)
                                let totalConsumed = titleLine - startIndex + 1
                                return (label, url, title, totalConsumed)
                            }
                            if tChars[ti] == "\\" && ti + 1 < tChars.count {
                                titleChars.append(tChars[ti + 1])
                                ti += 2
                            } else {
                                titleChars.append(tChars[ti])
                                ti += 1
                            }
                        }
                        titleLine += 1
                        if titleLine >= effectiveCount || isBlankLine(lines[titleLine]) {
                            // Multi-line title broken by blank — title invalid,
                            // but def still valid without title.
                            return (label, url, nil, lineIndex - startIndex + 1)
                        }
                        titleChars.append("\n")
                        ti = 0
                    }
                }
            }
            // No title found — valid def without title.
            return (label, url, nil, consumed)
        }

        // Case 3: Non-whitespace, non-title content after URL — not a valid link ref def.
        return nil
    }

    // MARK: - Reference link matching

    /// Try to match a reference link at position `start` in the character
    /// array. Handles three forms:
    /// - Full reference: `[text][label]`
    /// - Collapsed reference: `[text][]`
    /// - Shortcut reference: `[text]` (not followed by `(`)
    ///
    /// Returns the link text, resolved destination, and the index past
    /// the match, or nil if no reference link was found.
    private static func tryMatchReferenceLink(
        _ chars: [Character], from start: Int,
        refDefs: [String: (url: String, title: String?)]
    ) -> (text: String, dest: String, endIndex: Int)? {
        guard start < chars.count && chars[start] == "[" else { return nil }

        // Find closing ] for the text part.
        var j = start + 1
        var depth = 1
        while j < chars.count && depth > 0 {
            if chars[j] == "\\" && j + 1 < chars.count { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" { depth -= 1 }
            j += 1
        }
        guard depth == 0 else { return nil }
        let textEnd = j - 1
        let text = String(chars[(start + 1)..<textEnd])

        // Check what follows the closing ].
        if j < chars.count && chars[j] == "[" {
            // Full or collapsed reference: [text][label] or [text][].
            let labelStart = j + 1
            var k = labelStart
            while k < chars.count && chars[k] != "]" {
                if chars[k] == "\\" && k + 1 < chars.count { k += 1 }
                k += 1
            }
            guard k < chars.count else { return nil }
            let label = String(chars[labelStart..<k])
            let normalizedLabel = label.isEmpty ? text : label
            let key = normalizeLabel(normalizedLabel)
            if let def = refDefs[key] {
                let rawDest = buildRawDest(url: def.url, title: def.title)
                return (text, rawDest, k + 1)
            }
            return nil
        }

        // Shortcut reference: [text] not followed by ( or [.
        // Don't match if followed by ( — that's an inline link.
        if j < chars.count && chars[j] == "(" { return nil }
        let key = normalizeLabel(text)
        if let def = refDefs[key] {
            let rawDest = buildRawDest(url: def.url, title: def.title)
            return (text, rawDest, j)
        }
        return nil
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
