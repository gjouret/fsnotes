//
//  ListReader.swift
//  FSNotesCore
//
//  Phase 12.C.5.f + 12.C.5.g — Block parsing port: list reader.
//
//  CommonMark §5.2 — bullet (`-`, `*`, `+`) and ordered (digits +
//  `.` or `)`) list markers, with optional leading indentation, an
//  optional checkbox extension (`[ ]`, `[x]`, `[X]`), and content.
//
//  Surfaces:
//    Per-line classifier (12.C.5.f, 2026-04-2x):
//      `ParsedListLine`, `parseListLine`, `listMarkerType`,
//      `isOrderedListMarkerWithNonOneStart`.
//    Multi-line collection + item-tree builder (12.C.5.g, 2026-04-28):
//      `read(lines:from:rawBuffer:trailingNewline:parseInlines:
//      interruptsLazyContinuation:parseRecursive:refDefs:)` returns
//      a fully-built `[ListItem]` plus the loose-list flag and the
//      next line index. `buildItemTree` is also public so callers
//      that own `[ParsedListLine]` directly (only `read` itself today)
//      can drive item-tree construction. The reader owns
//      `leadingSpaceCount`, `stripLeadingSpaces`, `canAppendListMarker`,
//      `deepestOwner`, and `isEmphasisOnlyParagraph`. These five
//      helpers are public because the indented-code-block and setext
//      branches in `MarkdownParser.parse` call into the first two; the
//      rest are public for symmetry and unit-test access.
//
//  This slice is a non-regression port: per-line and multi-line
//  behaviour are byte-equal to the legacy implementation. Closure
//  surface for `read`: `parseInlines`, `interruptsLazyContinuation`,
//  `parseRecursive` (callback to `MarkdownParser.parse` for inner
//  re-parses), `refDefs` (passed through to inline parsing).
//

import Foundation

public enum ListReader {

    /// A single line parsed as a list item: split into leading
    /// indentation, the marker itself, the whitespace after the
    /// marker, an optional checkbox, and the line's content.
    public struct ParsedListLine {
        public let indent: String        // leading whitespace (spaces/tabs)
        public let marker: String        // "-", "*", "+", or "<digits>.", "<digits>)"
        public let afterMarker: String   // whitespace between marker and content/checkbox
        public let checkbox: Checkbox?   // "[ ]", "[x]", "[X]" for todo items
        public let content: String       // remainder of the line after checkbox/afterMarker
        public var blankLineBefore: Bool // true if blank line(s) preceded this item
        /// Raw continuation lines attached to this item BEFORE any of
        /// the item's children appeared in the parsedLines stream —
        /// already dedented by the item's content column, with
        /// blank-line separators preserved as empty strings. Parsed at
        /// buildItemTree time into the leading entries of the item's
        /// `body`. For most items children come AFTER continuation, so
        /// the post slot stays empty; the split exists for spec #325
        /// (`* foo\n  * bar\n\n  baz\n`) where a paragraph follows the
        /// sublist and must render between the sublist and the item end.
        public var continuationLines: [String]
        /// Continuation lines collected AFTER at least one child of this
        /// item has been appended to parsedLines. Re-parsed at
        /// buildItemTree time and appended to `body` after the sublist.
        public var continuationLinesPost: [String]

        public init(
            indent: String,
            marker: String,
            afterMarker: String,
            checkbox: Checkbox?,
            content: String,
            blankLineBefore: Bool = false,
            continuationLines: [String] = [],
            continuationLinesPost: [String] = []
        ) {
            self.indent = indent
            self.marker = marker
            self.afterMarker = afterMarker
            self.checkbox = checkbox
            self.content = content
            self.blankLineBefore = blankLineBefore
            self.continuationLines = continuationLines
            self.continuationLinesPost = continuationLinesPost
        }
    }

    /// Whether `marker` is an ordered-list marker (e.g. "2.", "10)")
    /// whose starting number is not 1. CommonMark 5.3: such a marker
    /// cannot interrupt a paragraph.
    public static func isOrderedListMarkerWithNonOneStart(_ marker: String) -> Bool {
        guard marker.last == "." || marker.last == ")" else { return false }
        let digits = String(marker.dropLast())
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return false }
        return Int(digits) != 1
    }

    /// Classify a list marker into its "family" for the same-list
    /// continuation check. CommonMark rule: a change in bullet
    /// character (`-`, `*`, `+`) or ordered delimiter (`.` vs `)`)
    /// starts a new list. Returns the bullet character for unordered,
    /// or the delimiter character for ordered (e.g. `.` or `)`).
    public static func listMarkerType(_ marker: String) -> String {
        if marker == "-" || marker == "*" || marker == "+" {
            return marker
        }
        if let last = marker.last {
            return String(last)
        }
        return marker
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
    /// just `***` is also rejected.
    public static func parseListLine(_ line: String) -> ParsedListLine? {
        let chars = Array(line)
        var i = 0

        // Leading indent: spaces or tabs.
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        // CommonMark §2.2: tabs expand to the next multiple-of-4 stop.
        // Normalize the indent string to its expanded-to-spaces form so
        // downstream arithmetic that uses `.indent.count` measures
        // virtual columns (spec #9: `\t - baz` → tab is 4 cols + space
        // = 5 virtual cols, must compare against parent items'
        // virtual content columns).
        let indent = expandTabsToSpaces(String(chars[0..<i]), startingAt: 0)

        guard i < chars.count else { return nil }
        let markerStart = i

        // Unordered marker: single `-`, `*`, or `+`.
        if chars[i] == "-" || chars[i] == "*" || chars[i] == "+" {
            // A RUN of the same char ("---", "***", "+++") is HR-like,
            // not a list. Require the next char to differ.
            let markerCh = chars[i]
            if i + 1 < chars.count, chars[i + 1] == markerCh {
                return nil
            }
            i += 1
        } else if chars[i].isNumber {
            // Ordered marker: digits + `.` or `)`.
            // CommonMark 5.2 caps the digit run at 9.
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

        // afterMarker: at least one space/tab, OR the marker is at
        // end of line (empty item, e.g. "-\n", "1.\n").
        let afterStart = i
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        if i == afterStart {
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
        let rawAfterMarker = String(chars[afterStart..<i])
        // The afterMarker may contain tabs whose virtual width depends on
        // the column they sit at. `indent` is already tab-expanded above,
        // so its `.count` is the marker's virtual column directly.
        let markerCol = indent.count + marker.count
        let afterMarker = expandTabsToSpaces(rawAfterMarker, startingAt: markerCol)
        let afterWidth = afterMarker.count

        // CommonMark §5.2 indented-code-in-list-item rule: if the
        // whitespace between marker and content expands to ≥ 5 virtual
        // columns, the content is an indented code block inside the
        // item. The "afterMarker" collapses to exactly 1 virtual
        // column; the remaining cols become the code block's indent.
        // Spec #7: `-\t\tfoo` → `<li><pre><code>  foo</code></pre></li>`.
        if afterWidth >= 5 {
            let leftoverCols = afterWidth - 1
            let contentIndent = String(repeating: " ", count: leftoverCols)
            let content = String(chars[i..<chars.count])
            // The continuation line is at content-col-2 relative indent;
            // since buildItemTree's re-parse uses MarkdownParser.parse
            // directly (no dedent), provide the full indent string so
            // the inner parse recognises indented code (≥ 4 cols).
            var parsed = ParsedListLine(
                indent: indent, marker: marker,
                afterMarker: " ", checkbox: nil,
                content: ""
            )
            parsed.continuationLines = [contentIndent + content]
            return parsed
        }

        // Detect checkbox: "[ ]", "[x]", "[X]" at start of content.
        // Only for unordered markers ("-", "*", "+").
        let remaining = chars[i..<chars.count]
        let checkbox: Checkbox?
        let contentStart: Int
        if (marker == "-" || marker == "*" || marker == "+"),
           remaining.count >= 4,
           chars[i] == "[",
           (chars[i+1] == " " || chars[i+1] == "x" || chars[i+1] == "X"),
           chars[i+2] == "]" {
            let cbText = String(chars[i..<(i+3)])  // "[ ]", "[x]", "[X]"
            var afterCB = i + 3
            let afterCBStart = afterCB
            while afterCB < chars.count, chars[afterCB] == " " || chars[afterCB] == "\t" {
                afterCB += 1
            }
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
        // CommonMark §5.2 #279: if the content of the first line is
        // blank, the item's content column is markerCol + marker.count
        // + 1 — the afterMarker defaults to a single virtual column
        // regardless of its source width. Collapse afterMarker to " "
        // in that case so the downstream content-column arithmetic
        // (continuation, nesting, lazy continuation) uses the
        // canonical value.
        let contentIsBlank = content.isEmpty
            || content.allSatisfy({ $0 == " " || $0 == "\t" })
        let normalizedAfter = (contentIsBlank && !afterMarker.isEmpty)
            ? " "
            : afterMarker
        return ParsedListLine(
            indent: indent, marker: marker,
            afterMarker: normalizedAfter, checkbox: checkbox,
            content: content
        )
    }

    /// Expand tab characters in `s` to spaces using CommonMark §2.2
    /// 4-stop tabstop semantics, with the run starting at virtual
    /// column `startCol`. Spaces are kept as-is. Non-whitespace input is
    /// not expected (callers pass leading-whitespace runs only).
    private static func expandTabsToSpaces(_ s: String, startingAt startCol: Int) -> String {
        if s.isEmpty || !s.contains("\t") { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var col = startCol
        for ch in s {
            if ch == "\t" {
                let w = 4 - (col % 4)
                for _ in 0..<w { out.append(" ") }
                col += w
            } else {
                out.append(ch)
                col += 1
            }
        }
        return out
    }

    // MARK: - 12.C.5.g multi-line collection helpers

    /// Count of leading space characters (tabs expanded to 4-stop tabstops).
    /// Used to determine whether a continuation line is indented enough
    /// to belong to an enclosing list item.
    public static func leadingSpaceCount(_ line: String) -> Int {
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
    public static func stripLeadingSpaces(_ line: String, count: Int) -> String {
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

    /// Whether `parsed` is a valid list marker to append to an open
    /// list with `parsedLines` collected so far and outermost marker
    /// indent `topIndent`. CommonMark §5.2: a marker line opens a new
    /// item iff
    ///   • its marker indent satisfies [topIndent, topIndent+3]
    ///     (sibling at the outermost level), OR
    ///   • its marker indent ≥ the most recently appended item's
    ///     content column (nested under the deepest open item).
    /// A marker that fails both is NOT a marker for this list —
    /// callers fall through to lazy continuation (no preceding blank,
    /// spec #312) or terminate the list (preceding blank, spec #313).
    public static func canAppendListMarker(
        _ parsed: ParsedListLine,
        parsedLines: [ParsedListLine],
        topIndent: Int
    ) -> Bool {
        let markerIndent = parsed.indent.count
        // Top-level sibling slot: marker indent within K∈[0,3] of the
        // outermost list edge.
        if markerIndent <= topIndent + 3 { return true }
        // Nested under the most recently appended item.
        if let last = parsedLines.last {
            let lastCC = last.indent.count + last.marker.count + last.afterMarker.count
            if markerIndent >= lastCC { return true }
        }
        return false
    }

    /// Find the deepest existing parsed item whose content column is
    /// ≤ `indent`. Returns nil if no item is a valid owner. "Deepest"
    /// means the item most recently pushed onto the list, which is
    /// what makes nested-list continuation work (continuations attach
    /// to the innermost container that can host them).
    public static func deepestOwner(in parsed: [ParsedListLine], forIndent indent: Int) -> Int? {
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

    /// Whether `buffer` (the rawBuffer line accumulator from the block
    /// loop) is a single line whose content is wholly wrapped in
    /// emphasis markers (e.g., `**Bold text**`, `*italic*`, `__bold__`,
    /// `_italic_`). Such paragraphs should NOT be promoted to setext
    /// headings when followed by `---`. Used by both the outer block
    /// loop's setext detection and `buildItemTree`'s first-continuation
    /// setext detection (spec #300).
    public static func isEmphasisOnlyParagraph(_ buffer: [String]) -> Bool {
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

    /// Local equivalent of the parser's `isBlankLine` — duplicated
    /// rather than imported to avoid plumbing yet another closure
    /// through `read`. Trivial 3-line implementation.
    private static func isBlank(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - buildItemTree

    /// Recursively build a list item tree from a flat array of parsed
    /// list lines. Items at the same indent column become siblings;
    /// items at a deeper indent are collected as children of the
    /// immediately preceding sibling.
    ///
    /// `parentContentColumn` is the indent-column of the enclosing scope
    /// (or -1 at the top level). Items whose indent falls below
    /// `parentContentColumn` pop the recursion back to the caller.
    ///
    /// Closure surface:
    ///   - `parseInlines`: `(String) -> [Inline]` — inline tokenizer for
    ///     the item's content text.
    ///   - `parseRecursive`: `(String) -> Document` — recursive callback
    ///     to `MarkdownParser.parse` for inner re-parses (block-starter
    ///     first lines, continuation re-parse, nested-marker re-parse).
    ///   - `refDefs`: link reference definitions for inline parsing.
    public static func buildItemTree(
        lines: [ParsedListLine], from: Int,
        parentContentColumn: Int,
        parseInlines: (String) -> [Inline],
        parseRecursive: (String) -> Document,
        refDefs: [String: (url: String, title: String?)]
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
            let curContentColumn = curIndent + cur.marker.count + cur.afterMarker.count
            let (children, nextI) = buildItemTree(
                lines: lines, from: i + 1,
                parentContentColumn: curContentColumn,
                parseInlines: parseInlines,
                parseRecursive: parseRecursive,
                refDefs: refDefs
            )
            // CommonMark §5.2: when the item's first-line content starts
            // a non-paragraph block (fenced code, blockquote, heading,
            // HR, HTML block) we MUST re-parse cur.content together with
            // any continuationLines as a single block sequence — the
            // first-line lazy-merge that the line-collection phase may
            // have performed (e.g. spec #318: `- ```\n  b` lazy-merges
            // "b" into the item's content) would otherwise leave the
            // fenced block half-open with the body stranded as inline
            // text. For paragraph-only content the existing path stands
            // — it preserves doc-level refDef resolution via parseInlines.
            //
            // Blank lines emitted by the inner parse are retained on
            // `continuationBlocks` so the renderer's looseness signal
            // (CommonMark §5.4: blank line between blocks → loose) can
            // see them; the renderer skips them when iterating.
            let firstLineEnd = cur.content.firstIndex(of: "\n")
                .map { cur.content.distance(from: cur.content.startIndex, to: $0) }
                ?? cur.content.count
            let firstLine = String(cur.content.prefix(firstLineEnd))
            // Spec #300: when the first continuation line is a setext
            // underline (`===` / `---`) and cur.content is a paragraph,
            // the item's content is a setext heading whose text spans
            // cur.content. Detecting this case routes through the
            // combined-reparse path so the inner parse sees the
            // paragraph + underline as one input — otherwise the
            // standalone underline becomes an HR (or stray paragraph)
            // because rawBuffer is empty when the inner parse starts.
            let firstContIsSetext: Bool = {
                guard !cur.content.isEmpty,
                      let firstCont = cur.continuationLines.first,
                      ATXHeadingReader.detectSetextUnderline(firstCont) != nil,
                      !isEmphasisOnlyParagraph([cur.content]) else {
                    return false
                }
                return true
            }()
            let firstLineIsBlockStarter =
                FencedCodeBlockReader.detectOpen(firstLine) != nil
                || ATXHeadingReader.detect(firstLine) != nil
                || HorizontalRuleReader.detect(firstLine) != nil
                || BlockquoteReader.detect(firstLine) != nil
                || HtmlBlockReader.detect(firstLine) != nil
                || firstContIsSetext

            let inline: [Inline]
            var continuationBlocks: [Block]
            if firstLineIsBlockStarter {
                let combined = ([cur.content] + cur.continuationLines)
                    .joined(separator: "\n") + "\n"
                let innerDoc = parseRecursive(combined)
                inline = []
                continuationBlocks = innerDoc.blocks
            } else {
                inline = parseInlines(cur.content)
                if cur.continuationLines.isEmpty {
                    continuationBlocks = []
                } else {
                    let inner = cur.continuationLines.joined(separator: "\n") + "\n"
                    let innerDoc = parseRecursive(inner)
                    continuationBlocks = innerDoc.blocks
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
            //
            // Skip when `firstLineIsBlockStarter` — the combined-parse
            // branch above already handled the content (e.g. spec #61
            // `- * * *` parses cur.content="* * *" as an HR; running
            // the nested-marker re-parse on top would double-emit).
            var outerInline = inline
            if !firstLineIsBlockStarter,
               let nested = parseListLine(cur.content),
               nested.indent.isEmpty || nested.indent.allSatisfy({ $0 == " " }) {
                // Re-emit the nested content as its own list in the
                // outer item's continuationBlocks. Keep any pre-existing
                // continuationBlocks behind it.
                let nestedDoc = parseRecursive(cur.content + "\n")
                let nestedBlocks = nestedDoc.blocks.filter {
                    if case .blankLine = $0 { return false }
                    return true
                }
                continuationBlocks = nestedBlocks + continuationBlocks
                outerInline = []
            }

            // Compose the item's body in CommonMark source order
            // (spec #325): pre-children continuation blocks, then the
            // sublist of recursed children, then any post-children
            // continuation blocks. Pre-redesign these were stored as
            // separate `children: [ListItem]` and
            // `continuationBlocks: [Block]` fields, with the renderer
            // emitting continuation FIRST and children LAST regardless
            // of source order — wrong for `* foo\n  * bar\n\n  baz`,
            // where `baz` follows the sublist.
            var body: [Block] = continuationBlocks
            if !children.isEmpty {
                // Sublist looseness is a property of the rendered
                // output (CommonMark §5.4 — inter-item blanks at the
                // sublist's level), so the parser leaves it false here
                // and lets the renderer compute it from `blankLineBefore`
                // and per-item signals.
                body.append(.list(items: children, loose: false))
            }
            if !cur.continuationLinesPost.isEmpty {
                let postInner = cur.continuationLinesPost
                    .joined(separator: "\n") + "\n"
                let postDoc = parseRecursive(postInner)
                body.append(contentsOf: postDoc.blocks)
            }

            items.append(ListItem(
                indent: cur.indent,
                marker: cur.marker,
                afterMarker: cur.afterMarker,
                checkbox: cur.checkbox,
                inline: outerInline,
                body: body,
                blankLineBefore: cur.blankLineBefore
            ))
            i = nextI
        }
        return (items, i)
    }

    // MARK: - read (multi-line collection)

    /// Outcome of `read` — a fully-built `[ListItem]` plus the
    /// loose-list flag and the next line index after the list.
    public struct ReadResult {
        public let items: [ListItem]
        public let loose: Bool
        public let nextIndex: Int
    }

    /// Detect and consume a list block starting at `lines[from]`.
    /// Returns nil if the line is not a list opener for this context
    /// (no marker, marker would interrupt a paragraph, or marker is
    /// 4+ space-indented at top level — see CommonMark §5.2 rule 1).
    /// On success returns the built items, the loose flag, and the
    /// next index after the consumed list block.
    ///
    /// The caller flushes its raw paragraph buffer before consuming
    /// the result, mirroring the legacy block-loop branch.
    ///
    /// Closure surface:
    ///   - `parseInlines`: inline tokenizer for item content.
    ///   - `interruptsLazyContinuation`: true when a line would
    ///     interrupt an open paragraph (blank, blockquote, heading,
    ///     fence, HR, list, HTML block 1-6).
    ///   - `parseRecursive`: callback to `MarkdownParser.parse` for
    ///     inner re-parse of item bodies.
    ///   - `refDefs`: link reference definitions, threaded through.
    public static func read(
        lines: [String],
        from: Int,
        rawBuffer: [String],
        trailingNewline: Bool,
        parseInlines: (String) -> [Inline],
        interruptsLazyContinuation: (String) -> Bool,
        parseRecursive: (String) -> Document,
        refDefs: [String: (url: String, title: String?)]
    ) -> ReadResult? {
        guard from < lines.count else { return nil }
        let line = lines[from]

        guard let firstParsed = parseListLine(line),
              // Don't let a bare marker at EOL (e.g. "*", "1.") interrupt
              // a paragraph. CommonMark example 285: "foo\n*" is a paragraph,
              // not a paragraph + list. Only applies when raw buffer has content.
              !(rawBuffer.count > 0 && firstParsed.afterMarker.isEmpty && firstParsed.content.isEmpty),
              // CommonMark 5.3: an ordered list with a starting number other
              // than 1 cannot interrupt a paragraph. Example 304: a paragraph
              // that happens to contain "14. ..." as its second line must
              // remain a single paragraph, not paragraph + list.
              !(rawBuffer.count > 0 && isOrderedListMarkerWithNonOneStart(firstParsed.marker)),
              // CommonMark §5.2 rule 1: K (preceding indent) must be in
              // [0, 3] for a list marker to open a list item. K ≥ 4 is
              // outside the rule, so the line is treated as either
              // paragraph lazy continuation (if rawBuffer is non-empty,
              // spec #238: `> foo\n    - bar`) or as the start of an
              // indented code block (if rawBuffer is empty, spec #289:
              // `    1.  A paragraph` opens an indented code block,
              // not a list).
              !(leadingSpaceCount(firstParsed.indent) >= 4)
        else { return nil }

        // Determine the list type from the first item's marker.
        // A change in bullet character or ordered delimiter
        // starts a new list (CommonMark rule). This check only
        // applies to items at the SAME indent level — nested
        // items can have different marker types (e.g. unordered
        // list containing ordered sublist).
        let listType = listMarkerType(firstParsed.marker)
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
        var j = from + 1
        while j < lines.count {
            let l = lines[j]
            if j == lines.count - 1 && l.isEmpty && trailingNewline {
                break
            }
            if l.isEmpty {
                // Blank line: peek ahead.
                var k = j + 1
                while k < lines.count && lines[k].isEmpty { k += 1 }
                // End of input or trailing-newline synthetic empty.
                if k >= lines.count
                    || (k == lines.count - 1 && lines[k].isEmpty && trailingNewline)
                {
                    break
                }
                if let nextParsed = parseListLine(lines[k]) {
                    let nextIndent = nextParsed.indent.count
                    if nextIndent == topIndent && listMarkerType(nextParsed.marker) != listType {
                        // Top-level item with different marker type — new list.
                        break
                    }
                    // CommonMark §5.2: a marker indent that is
                    // not a valid top-level sibling AND not
                    // valid as a nested item under the most
                    // recently appended item terminates the
                    // list. After a blank, the line falls
                    // through to the outer loop where the
                    // top-level indented-code-block detector
                    // picks it up. Spec #313:
                    //     1. a
                    //
                    //       2. b
                    //
                    //         3. c
                    // — `3. c` at marker col 4 is past the
                    // top-level cap [0,3] AND below b's content
                    // col 5, so it is neither a sibling nor a
                    // child. The list closes after b; `3. c`
                    // becomes top-level indented code.
                    if !canAppendListMarker(nextParsed, parsedLines: parsedLines, topIndent: topIndent) {
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
                    && ownerItem.continuationLines.isEmpty
                    && ownerItem.continuationLinesPost.isEmpty {
                    break
                }
                let contentCol = ownerItem.indent.count
                    + ownerItem.marker.count + ownerItem.afterMarker.count
                // CommonMark §5.2 source-order preservation
                // (spec #325): if any child of `ownerItem` has
                // already been appended to parsedLines, this
                // continuation segment fills the POST slot —
                // re-parsed at buildItemTree time and emitted
                // after the sublist in the item's body. With no
                // children seen yet, fill the standard
                // (pre-sublist) continuationLines.
                let collectingPost = parsedLines
                    .indices[(ownerIdx! + 1)...]
                    .contains { parsedLines[$0].indent.count >= contentCol }
                // Record the blank-line gap, then consume indented
                // (or blank) lines. Stop at the first line whose
                // indent is less than contentCol AND is non-blank
                // AND is not a list marker of this list (list
                // markers are handled by the outer loop).
                // Preserve the blanks between the item and the
                // continuation to distinguish tight vs loose.
                var continuation = collectingPost
                    ? parsedLines[ownerIdx!].continuationLinesPost
                    : parsedLines[ownerIdx!].continuationLines
                // Prepend blank gap
                for _ in j..<k { continuation.append("") }
                var m = k
                while m < lines.count {
                    let line2 = lines[m]
                    if m == lines.count - 1 && line2.isEmpty && trailingNewline {
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
                // item.  Track whether any were trimmed: that
                // tells us a blank actually sits BETWEEN this
                // item's continuation and whatever comes next,
                // versus blanks that sit INSIDE the continuation
                // (e.g. spec #318 fence-body blanks).
                var trimmedTrailingBlank = false
                while let last = continuation.last, last.isEmpty {
                    continuation.removeLast()
                    trimmedTrailingBlank = true
                }
                if collectingPost {
                    parsedLines[ownerIdx!].continuationLinesPost = continuation
                } else {
                    parsedLines[ownerIdx!].continuationLines = continuation
                }
                // Looseness signal at the list level only fires
                // when the next item actually follows a blank
                // line (trimmed-trailing-blank).  Per-item
                // looseness (blank between blocks within the
                // item) is detected by the renderer reading
                // `.blankLine` markers inside `continuationBlocks`,
                // so we don't conflate the two here.  Spec #318:
                // a fence body containing blanks is one block —
                // the list stays tight.  Spec #324: a fence
                // followed by a blank then a paragraph is
                // two blocks separated by a blank, but THAT
                // is detected per-item.
                if ownerItem.indent.count == topIndent
                    && trimmedTrailingBlank
                {
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
            // CommonMark §5.2: a parsed marker is only a real
            // marker in this list when its indent satisfies
            // [topIndent, topIndent+3] (top-level sibling) OR is
            // ≥ the most recently appended item's content
            // column (nested under last). Otherwise the line is
            // NOT a marker for this list — fall through to the
            // lazy-continuation logic below. Spec #312:
            //     - a
            //      - b
            //       - c
            //        - d
            //         - e
            // — `- e` at marker col 4 is past [0,3] AND below
            // d's content col 5, so it is neither sibling nor
            // child. With no preceding blank, the narrow
            // lazy-continuation rule merges it into d's
            // paragraph as `d\n- e`.
            let validMarker = parseListLine(l).flatMap { p -> ParsedListLine? in
                canAppendListMarker(p, parsedLines: parsedLines, topIndent: topIndent) ? p : nil
            }
            guard var parsed = validMarker else {
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
                        let dedentedIs4Indent = leadingSpaceCount(dedented) >= 4
                        let isBlockStarter =
                            FencedCodeBlockReader.detectOpen(dedented) != nil
                            || ATXHeadingReader.detect(dedented) != nil
                            || HorizontalRuleReader.detect(dedented) != nil
                            || parseListLine(dedented) != nil
                            || BlockquoteReader.detect(dedented) != nil
                            || dedentedIs4Indent
                        if lineIndent >= cc && !isBlockStarter {
                            parsedLines[parsedLines.count - 1] = ParsedListLine(
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
                        // Spec #278: empty-marker item followed by a
                        // 4-space-indented line (relative to cc)
                        // owns that line as an indented code block
                        // in its continuationBlocks. The line
                        // doesn't trigger interruptsLazyContinuation
                        // (it's just text), so the block-starter-as-
                        // continuation branch below won't fire; we
                        // route it ourselves. Walk forward and
                        // collect every indented-enough line into
                        // the item's continuationLines, mirroring
                        // the block-starter walk's stop conditions.
                        if lineIndent >= cc && dedentedIs4Indent {
                            var continuation: [String] = [dedented]
                            var m = j + 1
                            while m < lines.count {
                                let line2 = lines[m]
                                if m == lines.count - 1
                                    && line2.isEmpty
                                    && trailingNewline
                                {
                                    break
                                }
                                if line2.isEmpty {
                                    continuation.append("")
                                    m += 1
                                    continue
                                }
                                let lineIndentCount = leadingSpaceCount(line2)
                                if let maybeMarker = parseListLine(line2) {
                                    if maybeMarker.indent.count < cc {
                                        break
                                    }
                                }
                                if lineIndentCount < cc {
                                    break
                                }
                                continuation.append(stripLeadingSpaces(line2, count: cc))
                                m += 1
                            }
                            while let trailLast = continuation.last,
                                  trailLast.isEmpty
                            {
                                continuation.removeLast()
                            }
                            parsedLines[parsedLines.count - 1].continuationLines = continuation
                            j = m
                            continue
                        }
                    }
                    let hasOpenParagraph = !last.content.isEmpty
                        && last.continuationLines.isEmpty
                    if hasOpenParagraph {
                        let cc = last.indent.count
                            + last.marker.count + last.afterMarker.count
                        let lineIndent = leadingSpaceCount(l)
                        // Narrow lazy continuation: merge when
                        // the incoming line is indented MORE
                        // than the list item's opening column.
                        // Covers the well-formed spec cases
                        // where the continuation is at least
                        // partially indented (#254, #286-#289,
                        // #291).
                        let narrowMerge =
                            lineIndent > last.indent.count
                            && !interruptsLazyContinuation(l)
                        // Multi-block evidence (spec #290):
                        // strict CommonMark §5.1 lazy
                        // continuation merges unindented text
                        // too, but the editor layer produces
                        // `[list, paragraph]` Documents that
                        // serialize without an explicit
                        // `.blankLine` separator — making the
                        // parser fully strict would re-merge
                        // those at load time. Compromise: also
                        // merge when a subsequent line proves
                        // this item has multi-block content
                        // (a line indented to ≥ cc after
                        // skipping consecutive lazy candidates
                        // and any blank gap). Spec #290's
                        // `1.  A paragraph\nwith two lines.\n
                        // \n          indented code` matches
                        // this — the deeply-indented code line
                        // is the multi-block evidence that
                        // licenses lazy-continuing
                        // `with two lines.`. Editor-produced
                        // `- foo\nbar` (no deep follower)
                        // continues to parse as
                        // `[list, paragraph]`.
                        let multiBlockEvidence: Bool = {
                            if narrowMerge { return false }
                            if interruptsLazyContinuation(l) { return false }
                            var k = j
                            while k < lines.count {
                                let lk = lines[k]
                                if lk.isEmpty || isBlank(lk) { break }
                                if interruptsLazyContinuation(lk) { break }
                                if parseListLine(lk) != nil { break }
                                k += 1
                            }
                            while k < lines.count {
                                let lk = lines[k]
                                if k == lines.count - 1
                                    && lk.isEmpty
                                    && trailingNewline
                                {
                                    return false
                                }
                                if lk.isEmpty || isBlank(lk) {
                                    k += 1
                                    continue
                                }
                                return leadingSpaceCount(lk) >= cc
                            }
                            return false
                        }()
                        if (narrowMerge || multiBlockEvidence)
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
                    // Block-starter as continuation: when an
                    // indented line that interrupts a paragraph
                    // appears at the current item's content column
                    // or deeper without a preceding blank, it
                    // becomes the start of a continuation block
                    // for the current item rather than terminating
                    // the list.  Spec #320, #321: `* a\n  > b` —
                    // the blockquote at the item's content column
                    // is item 1's continuation, not a sibling.
                    // Mirrors the blank-line-then-content branch
                    // above (lines 234-300) without the blank gap.
                    let cc = last.indent.count
                        + last.marker.count + last.afterMarker.count
                    let lineIndent = leadingSpaceCount(l)
                    if lineIndent >= cc && interruptsLazyContinuation(l) {
                        var continuation = parsedLines[parsedLines.count - 1].continuationLines
                        var m = j
                        while m < lines.count {
                            let line2 = lines[m]
                            if m == lines.count - 1
                                && line2.isEmpty
                                && trailingNewline
                            {
                                break
                            }
                            if line2.isEmpty {
                                continuation.append("")
                                m += 1
                                continue
                            }
                            let lineIndentCount = leadingSpaceCount(line2)
                            if let maybeMarker = parseListLine(line2) {
                                if maybeMarker.indent.count < cc {
                                    break
                                }
                            }
                            if lineIndentCount < cc {
                                break
                            }
                            continuation.append(stripLeadingSpaces(line2, count: cc))
                            m += 1
                        }
                        var trimmedTrailingBlank = false
                        while let trailLast = continuation.last,
                              trailLast.isEmpty
                        {
                            continuation.removeLast()
                            trimmedTrailingBlank = true
                        }
                        parsedLines[parsedLines.count - 1].continuationLines = continuation
                        // Mirror the blank-prefix path: only flag
                        // looseness when the continuation actually
                        // ended with trailing blanks (next item
                        // follows a blank).  Per-item looseness
                        // is handled by the renderer.
                        if last.indent.count == topIndent
                            && trimmedTrailingBlank
                        {
                            hasBlankLines = true
                            nextItemFollowsBlank = true
                        }
                        j = m
                        continue
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
            if listMarkerType(parsed.marker) != listType {
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
            lines: parsedLines, from: 0, parentContentColumn: -1,
            parseInlines: parseInlines,
            parseRecursive: parseRecursive,
            refDefs: refDefs
        )
        return ReadResult(items: items, loose: hasBlankLines, nextIndex: j)
    }
}
