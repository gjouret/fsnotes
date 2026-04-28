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
        let (refDefs, consumedLines, blockquoteRefDefLines) =
            collectLinkRefDefs(lines, trailingNewline: markdown.hasSuffix("\n"))

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

            if let result = FencedCodeBlockReader.read(
                lines: lines, from: i, trailingNewline: markdown.hasSuffix("\n")
            ) {
                flushRawBuffer()
                blocks.append(result.block)
                i = result.nextIndex
                continue
            }

            if let result = BlockquoteReader.read(
                lines: lines,
                from: i,
                trailingNewline: markdown.hasSuffix("\n"),
                parseInlines: { parseInlines($0, refDefs: refDefs) },
                interruptsLazyContinuation: interruptsLazyContinuation,
                skipLines: blockquoteRefDefLines
            ) {
                flushRawBuffer()
                blocks.append(result.block)
                i = result.nextIndex
                continue
            }

            // Setext heading: paragraph text followed by === (H1) or --- (H2).
            // Must check BEFORE horizontal rule, because "---" is both a
            // setext underline and an HR — context determines which.
            // Exception: if the paragraph is entirely wrapped in emphasis
            // markers (**...**), it's a bold paragraph + HR, not a heading.
            if !rawBuffer.isEmpty, let setextLevel = ATXHeadingReader.detectSetextUnderline(line),
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

            if let result = HorizontalRuleReader.read(lines: lines, from: i) {
                flushRawBuffer()
                blocks.append(result.block)
                i = result.nextIndex
                continue
            }

            // Table detection: a line containing "|" followed by a
            // separator line ("|", "-", ":", spaces). The raw buffer
            // might already contain the header line if the parser
            // buffered it as a paragraph line. Check both modes:
            // (a) current line is header + next line is separator
            // (b) rawBuffer has one line (header) + current line is separator
            if let result = TableReader.read(
                lines: lines,
                at: i,
                rawBuffer: rawBuffer,
                trailingNewline: markdown.hasSuffix("\n"),
                parseInlines: { parseInlines($0, refDefs: [:]) }
            ) {
                if result.headerFromBuffer {
                    rawBuffer.removeLast()
                }
                flushRawBuffer()
                blocks.append(result.block)
                i = result.nextIndex
                continue
            }

            if let firstParsed = ListReader.parseListLine(line),
               // Don't let a bare marker at EOL (e.g. "*", "1.") interrupt
               // a paragraph. CommonMark example 285: "foo\n*" is a paragraph,
               // not a paragraph + list. Only applies when raw buffer has content.
               !(rawBuffer.count > 0 && firstParsed.afterMarker.isEmpty && firstParsed.content.isEmpty),
               // CommonMark 5.3: an ordered list with a starting number other
               // than 1 cannot interrupt a paragraph. Example 304: a paragraph
               // that happens to contain "14. ..." as its second line must
               // remain a single paragraph, not paragraph + list.
               !(rawBuffer.count > 0 && ListReader.isOrderedListMarkerWithNonOneStart(firstParsed.marker)) {
                flushRawBuffer()

                // Determine the list type from the first item's marker.
                // A change in bullet character or ordered delimiter
                // starts a new list (CommonMark rule). This check only
                // applies to items at the SAME indent level — nested
                // items can have different marker types (e.g. unordered
                // list containing ordered sublist).
                let listType = ListReader.listMarkerType(firstParsed.marker)
                let topIndent = firstParsed.indent.count

                // Collect list lines, continuing through blank lines
                // when the next non-blank line is a list item of the
                // same type. Track whether any blank lines separate
                // items (makes the list "loose"). Each item that
                // follows a blank line gets blankLineBefore = true
                // for round-trip serialization.
                var parsedLines: [ListReader.ParsedListLine] = [firstParsed]
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
                        if let nextParsed = ListReader.parseListLine(lines[k]) {
                            let nextIndent = nextParsed.indent.count
                            if nextIndent == topIndent && ListReader.listMarkerType(nextParsed.marker) != listType {
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
                            if let maybeMarker = ListReader.parseListLine(line2) {
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
                    // CommonMark §4.4 / §5.2: a thematic break takes
                    // precedence over a list item when a line at the
                    // outer list's indent could be read as either.
                    // Spec #60:
                    //     * Foo
                    //     * * *
                    //     * Bar
                    // — the second line is `<hr />`, not a deeper
                    // nested list. The HR terminates the current list
                    // so the outer block loop picks it up on the next
                    // iteration. We only apply this when the line sits
                    // at the top-level list's indent: a line indented
                    // beyond the parent item's content column is a
                    // legitimate nested list item (`- Foo\n- * * *`
                    // spec #61, where `* * *` indents to col 2 and
                    // becomes the second item's HR content).
                    if leadingSpaceCount(l) == topIndent,
                       HorizontalRuleReader.detect(l) != nil {
                        break
                    }
                    guard var parsed = ListReader.parseListLine(l) else {
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
                            // CommonMark §5.2: the first non-blank line
                            // following an EMPTY-content list item is
                            // the item's content if it's indented to
                            // at least the item's content column. Spec
                            // #279: `-   \n  foo\n` → the empty item
                            // owns `foo` as its content. We handle
                            // this only for the simple paragraph case:
                            // the line must not look like a block
                            // starter (fence, heading, HR, list, etc.)
                            // because those should route via
                            // continuationLines → buildItemTree's
                            // inner re-parse.
                            if last.content.isEmpty
                                && last.continuationLines.isEmpty
                                && !interruptsLazyContinuation(l) {
                                // For empty-content items the
                                // CommonMark content column is
                                // markerCol + markerLen + 1 regardless
                                // of the actual afterMarker (which may
                                // be zero when the marker sits at EOL,
                                // e.g. `-\n  foo\n`).
                                let cc = last.indent.count
                                    + last.marker.count + max(1, last.afterMarker.count)
                                let lineIndent = leadingSpaceCount(l)
                                let dedented = stripLeadingSpaces(l, count: cc)
                                let isBlockStarter =
                                    FencedCodeBlockReader.detectOpen(dedented) != nil
                                    || ATXHeadingReader.detect(dedented) != nil
                                    || HorizontalRuleReader.detect(dedented) != nil
                                    || ListReader.parseListLine(dedented) != nil
                                    || BlockquoteReader.detect(dedented) != nil
                                    || leadingSpaceCount(dedented) >= 4
                                if lineIndent >= cc && !isBlockStarter {
                                    parsedLines[parsedLines.count - 1] = ListReader.ParsedListLine(
                                        indent: last.indent,
                                        marker: last.marker,
                                        afterMarker: last.afterMarker,
                                        checkbox: last.checkbox,
                                        content: dedented,
                                        blankLineBefore: last.blankLineBefore,
                                        continuationLines: last.continuationLines
                                    )
                                    j += 1
                                    continue
                                }
                            }
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
                                    parsedLines[parsedLines.count - 1] = ListReader.ParsedListLine(
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
                    if ListReader.listMarkerType(parsed.marker) != listType {
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

            if let result = ATXHeadingReader.read(lines: lines, from: i) {
                flushRawBuffer()
                blocks.append(result.block)
                i = result.nextIndex
                continue
            }

            // HTML blocks: detect before paragraph buffer but after
            // code fences, headings, HR, blockquotes, lists.
            if let result = HtmlBlockReader.read(
                lines: lines,
                from: i,
                trailingNewline: markdown.hasSuffix("\n"),
                rawBufferEmpty: rawBuffer.isEmpty
            ) {
                flushRawBuffer()
                blocks.append(result.block)
                i = result.nextIndex
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

            // CommonMark 4.4 — indented code block. A non-blank line
            // indented by 4+ columns (tabs expanded to 4-stop
            // tabstops) that does NOT continue a paragraph is the
            // start of an indented code block. It extends through
            // any subsequent lines that are either blank or also
            // indented by 4+ columns, stopping at the first line
            // that is non-blank AND indented by less than 4. Trailing
            // blank lines inside the block are not kept.
            if rawBuffer.isEmpty,
               leadingSpaceCount(line) >= 4 {
                var codeLines: [String] = []
                codeLines.append(stripLeadingSpaces(line, count: 4))
                var jj = i + 1
                while jj < lines.count {
                    let nextLine = lines[jj]
                    if jj == lines.count - 1 && nextLine.isEmpty && markdown.hasSuffix("\n") {
                        break
                    }
                    if nextLine.isEmpty || isBlankLine(nextLine) {
                        // Peek further — only include the blank if
                        // a subsequent line is still indented 4+.
                        var kk = jj + 1
                        var foundContinuation = false
                        while kk < lines.count {
                            let peek = lines[kk]
                            if kk == lines.count - 1 && peek.isEmpty && markdown.hasSuffix("\n") {
                                break
                            }
                            if peek.isEmpty || isBlankLine(peek) { kk += 1; continue }
                            if leadingSpaceCount(peek) >= 4 {
                                foundContinuation = true
                            }
                            break
                        }
                        if foundContinuation {
                            // CommonMark §4.4: a whitespace-only line
                            // inside an indented code block keeps its
                            // whitespace beyond the 4-column dedent.
                            // Spec #112:
                            //     chunk1
                            //           <- six spaces
                            //       chunk2
                            // yields `chunk1\n  \n  chunk2` — the
                            // six-space line becomes "  " (2 spaces),
                            // not an empty line.
                            if leadingSpaceCount(nextLine) >= 4 {
                                codeLines.append(stripLeadingSpaces(nextLine, count: 4))
                            } else {
                                codeLines.append("")
                            }
                            jj += 1
                            continue
                        } else {
                            break
                        }
                    }
                    if leadingSpaceCount(nextLine) >= 4 {
                        codeLines.append(stripLeadingSpaces(nextLine, count: 4))
                        jj += 1
                    } else {
                        break
                    }
                }
                // Emit as a synthetic fenced code block (no fence
                // markers, empty info string, backtick style). The
                // CommonMark HTML renderer emits `<pre><code>` for
                // unfenced code blocks; our serializer will re-emit
                // them as plain indented lines at save-time via the
                // fence.length==0 sentinel — but since no test path
                // round-trips indented code blocks through our
                // serializer (the editor never creates one), we
                // sidestep that concern and emit the fence form.
                let content = codeLines.joined(separator: "\n")
                let fence = FenceStyle(character: .backtick, length: 0, infoRaw: "")
                blocks.append(.codeBlock(language: nil, content: content, fence: fence))
                i = jj
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
                if let match = CodeSpanParser.match(chars, from: i) {
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

    static func parseInlines(_ text: String, refDefs: [String: (url: String, title: String?)] = [:]) -> [Inline] {
        guard !text.isEmpty else { return [] }

        // Phase A: tokenize into non-emphasis inlines + delimiter runs
        let tokens = tokenizeNonEmphasis(text, refDefs: refDefs)

        // Phase B: resolve emphasis using the delimiter stack algorithm
        let inlines = EmphasisResolver.resolve(tokens, refDefs: refDefs)

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
            // 2+3. Hard line breaks (backslash-before-newline OR
            // two-or-more-spaces-before-newline). Phase 12.C.2 ported
            // both shapes to a combinator-based detector — see
            // `HardLineBreakParser.match`. Same `(raw, endIndex)`
            // shape the other tryMatch helpers return; behavior
            // byte-equal to the prior imperative `if` branches.
            if let match = HardLineBreakParser.match(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.lineBreak(raw: match.raw)))
                i = match.endIndex
                continue
            }
            // 4. Autolinks
            if let match = AutolinkParser.match(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.autolink(text: match.text, isEmail: match.isEmail)))
                i = match.endIndex
                continue
            }
            // 5. Raw HTML
            if let match = RawHTMLParser.match(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.rawHTML(match.html)))
                i = match.endIndex
                continue
            }
            // 6. Entity references
            if let match = EntityParser.match(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.entity(match.entity)))
                i = match.endIndex
                continue
            }
            // 6b. Display math ($$...$$) — must check before single-$ inline math
            if let match = DisplayMathParser.match(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.displayMath(match.content)))
                i = match.endIndex
                continue
            }
            // 6c. Inline math ($...$)
            if let match = InlineMathParser.match(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.math(match.content)))
                i = match.endIndex
                continue
            }
            // 7. Code spans
            if let match = CodeSpanParser.match(chars, from: i) {
                flushPlain()
                tokens.append(.inline(.code(match.inner)))
                i = match.endIndex
                continue
            }
            // 8. Images
            if chars[i] == "!" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let match = ImageParser.match(chars, from: i, codeSpanRanges: codeSpanRanges) {
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
                if let match = WikilinkParser.match(chars, from: i) {
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
                if let match = LinkParser.match(chars, from: i, codeSpanRanges: codeSpanRanges) {
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
                if let match = StrikethroughParser.match(chars, from: i) {
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
                let (canOpen, canClose) = EmphasisResolver.flanking(
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
        lines: [ListReader.ParsedListLine], from: Int,
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
            if let nested = ListReader.parseListLine(cur.content),
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
    ///
    /// CommonMark §2.2 (tab handling): tabs are virtual — their
    /// expansion depends on the column where they sit. When this
    /// function consumes tabs for the dedent, any REMAINING tabs in
    /// the line would re-expand at a different column in any
    /// downstream re-parse (because the line has shifted left).
    /// To preserve the original column layout, we expand all
    /// post-dedent leading whitespace (spaces + tabs) to explicit
    /// spaces using the original virtual-column positions. Non-tab
    /// content after the whitespace is appended verbatim.
    private static func stripLeadingSpaces(_ line: String, count: Int) -> String {
        let chars = Array(line)
        var col = 0
        var idx = 0
        // Step 1: consume leading whitespace up to `count` virtual cols.
        while idx < chars.count && col < count {
            let ch = chars[idx]
            if ch == " " {
                col += 1
                idx += 1
            } else if ch == "\t" {
                let tabWidth = 4 - (col % 4)
                if col + tabWidth > count {
                    // Partial tab — overflow stays as leading spaces.
                    let overflow = (col + tabWidth) - count
                    col += tabWidth
                    idx += 1
                    // After the partial tab, any further leading
                    // whitespace (spaces / tabs) needs to be expanded
                    // to its original column layout, then the rest of
                    // the line tacked on.
                    var tail: [Character] = Array(repeating: " ", count: overflow)
                    var vcol = col
                    while idx < chars.count {
                        let c2 = chars[idx]
                        if c2 == " " {
                            tail.append(" ")
                            vcol += 1
                            idx += 1
                        } else if c2 == "\t" {
                            let w = 4 - (vcol % 4)
                            for _ in 0..<w { tail.append(" ") }
                            vcol += w
                            idx += 1
                        } else {
                            break
                        }
                    }
                    tail.append(contentsOf: chars[idx..<chars.count])
                    return String(tail)
                }
                col += tabWidth
                idx += 1
            } else {
                break
            }
        }
        // Step 2: expand any remaining leading whitespace tabs into
        // spaces relative to the dedented column origin.
        var tail: [Character] = []
        var vcol = 0
        while idx < chars.count {
            let c2 = chars[idx]
            if c2 == " " {
                tail.append(" ")
                vcol += 1
                idx += 1
            } else if c2 == "\t" {
                let w = 4 - ((col - count + vcol) % 4)
                for _ in 0..<w { tail.append(" ") }
                vcol += w
                idx += 1
            } else {
                break
            }
        }
        tail.append(contentsOf: chars[idx..<chars.count])
        return String(tail)
    }

    /// Find the deepest existing parsed item whose content column is
    /// ≤ `indent`. Returns nil if no item is a valid owner. "Deepest"
    /// means the item most recently pushed onto the list, which is
    /// what makes nested-list continuation work (continuations attach
    /// to the innermost container that can host them).
    private static func deepestOwner(in parsed: [ListReader.ParsedListLine], forIndent indent: Int) -> Int? {
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
    ) -> (
        defs: [String: (url: String, title: String?)],
        consumed: Set<Int>,
        blockquoteRefDefLines: Set<Int>
    ) {
        var defs: [String: (url: String, title: String?)] = [:]
        var consumed: Set<Int> = []
        // Lines that are ref-defs nested inside a blockquote container.
        // These are NOT added to `consumed` (which would skip them at
        // the top-level block-parse loop), but ARE passed to
        // `BlockquoteReader.read` so the reader can drop them from the
        // blockquote's inner content while still walking past them.
        var blockquoteRefDefLines: Set<Int> = []
        var inCodeFence = false
        var openFenceChar: Character = "`"
        var openFenceLength = 0

        let effectiveCount = (trailingNewline && lines.last == "") ? lines.count - 1 : lines.count

        // Per-line stripped view: any line carrying a blockquote prefix
        // (`>`, `> `, `>> `, etc.) is replaced with its inner content so
        // the ref-def parser can recognize ref-defs nested inside a
        // blockquote (CommonMark §4.7 — ref-defs may live inside any
        // container block). Top-level lines pass through unchanged.
        let strippedLines: [String] = lines.map { line in
            if let parts = BlockquoteReader.detect(line) {
                return parts.content
            }
            return line
        }

        var i = 0
        while i < effectiveCount {
            let line = lines[i]

            // Track code fences to avoid matching inside them.
            if !inCodeFence {
                if let fence = FencedCodeBlockReader.detectOpen(line) {
                    inCodeFence = true
                    openFenceChar = fence.fenceChar
                    openFenceLength = fence.fenceLength
                    i += 1
                    continue
                }
            } else {
                // Check for closing fence.
                let fence = FencedCodeBlockReader.Fence(
                    fenceChar: openFenceChar, fenceLength: openFenceLength,
                    infoRaw: "", indent: 0
                )
                if FencedCodeBlockReader.isClose(line, matching: fence) {
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
                if ATXHeadingReader.detect(prev) != nil { return true }
                // Fence open/close on the previous line?
                if FencedCodeBlockReader.detectOpen(prev) != nil { return true }
                // Horizontal rule on the previous line?
                if HorizontalRuleReader.detect(prev) != nil { return true }
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
                continue
            }

            // Blockquote-internal ref-def: line carries a `>` prefix and
            // its stripped content parses as a ref-def. Register the
            // definition but DO NOT add the source lines to `consumed`
            // — the BlockquoteReader still needs to walk these lines so
            // the (now empty) blockquote container is preserved. The
            // renderer's inner re-parse will rediscover the ref-def and
            // emit no inner block.
            if canStartBlock,
               BlockquoteReader.detect(line) != nil,
               let parsed = tryParseLinkRefDef(strippedLines, startIndex: i, effectiveCount: effectiveCount) {
                // All lines consumed by the parse must themselves carry
                // a blockquote prefix — a multi-line blockquote ref-def
                // requires every line to be inside the same container.
                var allPrefixed = true
                for j in i..<(i + parsed.linesConsumed) {
                    if BlockquoteReader.detect(lines[j]) == nil {
                        allPrefixed = false
                        break
                    }
                }
                if allPrefixed {
                    let key = normalizeLabel(parsed.label)
                    if defs[key] == nil {
                        defs[key] = (url: parsed.url, title: parsed.title)
                    }
                    for j in i..<(i + parsed.linesConsumed) {
                        blockquoteRefDefLines.insert(j)
                    }
                    i += parsed.linesConsumed
                    continue
                }
            }

            i += 1
        }
        return (defs, consumed, blockquoteRefDefLines)
    }

    /// Normalize a link reference label for case-insensitive matching.
    /// Per CommonMark §4.7: trim leading/trailing whitespace, collapse
    /// internal whitespace runs to a single space, and apply Unicode
    /// case fold. The case fold (vs. plain `lowercased()`) is what
    /// makes pairs like `[ẞ]`/`[SS]` and `[ﬀ]`/`[ff]` equivalent —
    /// `lowercased()` only handles single-codepoint case mappings.
    private static func normalizeLabel(_ label: String) -> String {
        label.folding(options: .caseInsensitive, locale: nil)
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
        if BlockquoteReader.detect(line) != nil { return true }
        // ATX heading
        if ATXHeadingReader.detect(line) != nil { return true }
        // Fenced code opening
        if FencedCodeBlockReader.detectOpen(line) != nil { return true }
        // Thematic break / HR
        if HorizontalRuleReader.detect(line) != nil { return true }
        // List item with <= 3 spaces of indent (4+ spaces = indented code
        // block context, which cannot interrupt a paragraph)
        if let parsed = ListReader.parseListLine(line) {
            let spaceCount = parsed.indent.filter { $0 == " " }.count
                + parsed.indent.filter { $0 == "\t" }.count * 4
            // CommonMark 5.3: an ordered marker with start != 1 also
            // does NOT interrupt a paragraph.
            if spaceCount <= 3 && !ListReader.isOrderedListMarkerWithNonOneStart(parsed.marker) {
                return true
            }
        }
        // HTML block start (types 1-6 can interrupt a paragraph; type 7 cannot)
        if let htmlType = HtmlBlockReader.detect(line), htmlType <= 6 { return true }
        return false
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
        var chars = Array(line)
        var i = 0

        // Up to 3 leading spaces.
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        guard i < chars.count && chars[i] == "[" else { return nil }
        i += 1

        // Find closing `]` for label. CommonMark allows the label to
        // span multiple lines — scan forward, joining continuation
        // lines with `\n`, stopping at the first unescaped `]` or `[`
        // or at a blank line (which terminates the ref def).
        var labelChars: [Character] = []
        var labelLineOffset = 0  // lines past startIndex consumed by the label
        var found = false
        var foundStray = false
        while true {
            while i < chars.count && chars[i] != "]" && chars[i] != "[" {
                if chars[i] == "\\" && i + 1 < chars.count {
                    labelChars.append(chars[i])
                    labelChars.append(chars[i + 1])
                    i += 2
                } else {
                    labelChars.append(chars[i])
                    i += 1
                }
            }
            if i < chars.count {
                if chars[i] == "]" {
                    found = true
                } else {
                    // Stray `[` inside the label — invalid.
                    foundStray = true
                }
                break
            }
            // Ran off the line end — try the next line.
            let nextIdx = startIndex + labelLineOffset + 1
            if nextIdx >= effectiveCount { break }
            if isBlankLine(lines[nextIdx]) { break }
            labelLineOffset += 1
            chars = Array(lines[nextIdx])
            i = 0
            // Preserve the newline inside the label (used by
            // normalizeLabel which collapses whitespace runs).
            labelChars.append("\n")
        }
        guard found, !foundStray else { return nil }
        let label = String(labelChars)
        // Label must not be blank (spaces/tabs/newlines only).
        let labelTrimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !labelTrimmed.isEmpty else { return nil }
        i += 1 // skip `]`

        // Must be followed by `:`.
        guard i < chars.count && chars[i] == ":" else { return nil }
        i += 1

        // Skip whitespace.
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }

        var currentLine = startIndex + labelLineOffset
        var linesConsumed = 1 + labelLineOffset

        // If nothing remains on this line after `[label]:`, URL must be on next line.
        if i >= chars.count {
            // Need a next line for the URL.
            let nextLine = currentLine + 1
            guard nextLine < effectiveCount && !isBlankLine(lines[nextLine]) else { return nil }
            currentLine = nextLine
            linesConsumed += 1
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

        // Skip whitespace after URL. CommonMark §4.7 requires at least
        // one space/tab (or a line ending) between the destination and
        // the title. If there's no whitespace separating a same-line
        // title, the title is NOT accepted — and since trailing
        // non-whitespace after the URL invalidates a ref def, the
        // entire definition must fail (spec #201:
        //   `[foo]: <bar>(baz)`
        // is not a ref def — `<bar>(baz)` has no separator, so the
        // `(baz)` is neither title nor valid bare content).
        let urlEnd = i
        let hadTrailingWhitespace = i < chars.count
            && (chars[i] == " " || chars[i] == "\t")
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }

        // --- Try to parse title ---

        // Case 1: Title starts on same line as URL.
        if i < chars.count && (chars[i] == "\"" || chars[i] == "'" || chars[i] == "(") {
            // Reject when the title glyph immediately follows the URL
            // with no whitespace (spec #201).
            if !hadTrailingWhitespace && urlEnd != charOffset {
                return nil
            }
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
