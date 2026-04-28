//
//  BlockquoteReader.swift
//  FSNotesCore
//
//  Phase 12.C.5 — Block parsing port: blockquotes.
//
//  CommonMark §5.1 — a `>` marker (with optional 0–3 leading spaces and
//  an optional trailing space/tab) opens a blockquote. The blockquote
//  continues as long as subsequent lines either carry their own `>`
//  prefix OR are valid lazy continuations of the last paragraph inside
//  the quote.
//
//  Spec bucket: Block quotes 24/25 (96%).
//
//  This reader owns:
//    - per-line marker detection (`detect`),
//    - the multi-line walk (`read`),
//    - the lazy-continuation eligibility helper
//      (`innerAllowsLazyContinuation`).
//
//  The walk needs `parseInlines` and `interruptsLazyContinuation` from
//  the caller because both depend on parser state (link-ref-def table,
//  list-marker rules) the reader doesn't own. They're injected as
//  closures to keep the reader self-contained.
//

import Foundation

public enum BlockquoteReader {

    public struct ReadResult {
        public let block: Block
        public let nextIndex: Int
    }

    /// Try to read a blockquote starting at `lines[start]`. Returns nil
    /// if `lines[start]` does not begin with a blockquote marker.
    ///
    /// `parseInlines` is called per line to convert the post-marker
    /// content into the inline tree carried by `BlockquoteLine`.
    /// `interruptsLazyContinuation` guards lazy-continuation lines
    /// (no `>` prefix) — it must return true for any line that opens a
    /// new block, so the walk stops at the right boundary.
    public static func read(
        lines: [String],
        from start: Int,
        trailingNewline: Bool,
        parseInlines: (String) -> [Inline],
        interruptsLazyContinuation: (String) -> Bool
    ) -> ReadResult? {
        guard start < lines.count, detect(lines[start]) != nil else { return nil }

        var qLines: [BlockquoteLine] = []
        // Track the inner content lines (post-prefix) so the lazy-
        // continuation eligibility helper can inspect the running state.
        var innerContentLines: [String] = []
        var j = start
        while j < lines.count {
            let l = lines[j]
            if j == lines.count - 1 && l.isEmpty && trailingNewline { break }

            if let parts = detect(l) {
                qLines.append(BlockquoteLine(
                    prefix: parts.prefix,
                    inline: parseInlines(parts.content)
                ))
                innerContentLines.append(parts.content)
                j += 1
            } else if !interruptsLazyContinuation(l)
                        && innerAllowsLazyContinuation(innerContentLines) {
                // Lazy continuation: the line lacks a `>` marker but
                // still extends the last paragraph inside the quote.
                qLines.append(BlockquoteLine(
                    prefix: "",
                    inline: parseInlines(l)
                ))
                innerContentLines.append(l)
                j += 1
            } else {
                break
            }
        }

        return ReadResult(block: .blockquote(lines: qLines), nextIndex: j)
    }

    /// Detect whether `line` starts with a blockquote marker. The
    /// prefix is captured VERBATIM (needed for byte-equal round-trip)
    /// and the content is the remainder of the line.
    ///
    /// Rule: ≤ 3 leading spaces, then a run of one or more `>`, each
    /// optionally followed by a single space or tab (so styles like
    /// `> `, `>> `, `> > `, `>` all parse). Tabs immediately after `>`
    /// follow the partial-consumption rule (CommonMark §5.1, spec
    /// example #6) — exactly one virtual column of the tab is consumed
    /// as the optional post-marker space; any remainder belongs to the
    /// content's leading whitespace.
    ///
    ///   "> hello"     → prefix="> ",   content="hello"
    ///   ">> hello"    → prefix=">> ",  content="hello"
    ///   "> > hello"   → prefix="> > ", content="hello"
    ///   ">no space"   → prefix=">",    content="no space"
    ///   ">"           → prefix=">",    content=""
    ///   ">  two"      → prefix="> ",   content=" two"
    public static func detect(_ line: String) -> (prefix: String, content: String)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == ">" else { return nil }

        var col = 0
        var prefixBuilder: [Character] = []
        var leftoverCols = 0  // cols from prefix tab(s) that belong to content
        while i < chars.count, chars[i] == ">" {
            prefixBuilder.append(">")
            col += 1
            i += 1
            if i < chars.count, chars[i] == " " {
                prefixBuilder.append(" ")
                col += 1
                i += 1
            } else if i < chars.count, chars[i] == "\t" {
                let tabWidth = 4 - (col % 4)
                prefixBuilder.append("\t")
                col += tabWidth
                i += 1
                // 1 of the tab's cols was consumed as the optional
                // post-marker space; the rest belongs to content.
                leftoverCols += (tabWidth - 1)
            }
        }
        let prefix = String(prefixBuilder)

        // If the prefix consumed a tab (leftoverCols > 0), expand the
        // tab-shifted column layout into explicit spaces so the
        // downstream inner-parse (which re-expands tabs from column 0)
        // sees the correct indent width.
        if leftoverCols > 0 {
            var expanded: [Character] = []
            var vcol = col
            while i < chars.count {
                let ch = chars[i]
                if ch == " " {
                    expanded.append(" ")
                    vcol += 1
                    i += 1
                } else if ch == "\t" {
                    let w = 4 - (vcol % 4)
                    for _ in 0..<w { expanded.append(" ") }
                    vcol += w
                    i += 1
                } else {
                    break
                }
            }
            let leftoverSpaces = String(repeating: " ", count: leftoverCols)
            let restOfLine = String(chars[i..<chars.count])
            let content = leftoverSpaces + String(expanded) + restOfLine
            return (prefix, content)
        }
        let content = String(chars[i..<chars.count])
        return (prefix, content)
    }

    /// Whether the inner content of a (partially-collected) blockquote
    /// allows the next no-`>` line to extend it as a lazy paragraph
    /// continuation. CommonMark §5.1: lazy continuation is permitted
    /// only when the inner block ends in an open paragraph context —
    /// not inside an open code fence, not after an indented-code line,
    /// not after a blank line.
    public static func innerAllowsLazyContinuation(_ contentLines: [String]) -> Bool {
        guard !contentLines.isEmpty else { return false }

        // Open (unclosed) code fence inside the quote: lazy continuation
        // would be code, not paragraph text.
        var openFence: FencedCodeBlockReader.Fence? = nil
        for inner in contentLines {
            if let fence = openFence {
                if FencedCodeBlockReader.isClose(inner, matching: fence) {
                    openFence = nil
                }
            } else if let fence = FencedCodeBlockReader.detectOpen(inner) {
                openFence = fence
            }
        }
        if openFence != nil { return false }

        // Last non-blank inner line is an indented code block
        // (4+ leading spaces): no lazy continuation.
        if let lastNonBlank = contentLines.last(where: { !isBlank($0) && !$0.isEmpty }) {
            let leadingSpaces = lastNonBlank.prefix(while: { $0 == " " }).count
            if leadingSpaces >= 4 { return false }
        }

        // Last line is blank (e.g. a bare `>` line): the inner paragraph
        // has closed.
        if let lastInner = contentLines.last, isBlank(lastInner) || lastInner.isEmpty {
            return false
        }

        return true
    }

    private static func isBlank(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" }
    }
}
