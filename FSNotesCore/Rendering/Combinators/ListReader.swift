//
//  ListReader.swift
//  FSNotesCore
//
//  Phase 12.C.5 — Block parsing port: per-line list classifier.
//
//  CommonMark §5.2 — bullet (`-`, `*`, `+`) and ordered (digits +
//  `.` or `)`) list markers, with optional leading indentation, an
//  optional checkbox extension (`[ ]`, `[x]`, `[X]`), and content.
//
//  This slice ports the SINGLE-LINE classifier surface — the
//  `ParsedListLine` value, the `parseListLine` detector, and the
//  marker-family helpers `listMarkerType` /
//  `isOrderedListMarkerWithNonOneStart`. The multi-line collection
//  code (the ~320-line block-loop branch in `MarkdownParser.parse`),
//  `buildItemTree`, `deepestOwner`, `leadingSpaceCount`, and
//  `stripLeadingSpaces` STAY in `MarkdownParser` for now because they
//  weave through container-block continuation rules, blank-line
//  semantics, and the recursive call back into `MarkdownParser.parse`
//  for item-content re-parsing — porting that surface cleanly is its
//  own slice (potentially `12.C.5.g`).
//
//  Spec buckets touched: List items 42/48 (88%), Lists 19/26 (73%) —
//  but those numbers depend mostly on the multi-line collection logic,
//  not the per-line classifier. This slice is a non-regression port:
//  per-line behaviour is byte-equal to the legacy implementation.
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
        /// Raw continuation lines attached to this item after a blank
        /// line — already dedented by the item's content column, with
        /// blank-line separators preserved as empty strings. Parsed at
        /// buildItemTree time into `ListItem.continuationBlocks`.
        public var continuationLines: [String]

        public init(
            indent: String,
            marker: String,
            afterMarker: String,
            checkbox: Checkbox?,
            content: String,
            blankLineBefore: Bool = false,
            continuationLines: [String] = []
        ) {
            self.indent = indent
            self.marker = marker
            self.afterMarker = afterMarker
            self.checkbox = checkbox
            self.content = content
            self.blankLineBefore = blankLineBefore
            self.continuationLines = continuationLines
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
        let indent = String(chars[0..<i])

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
        let afterMarker = String(chars[afterStart..<i])

        // CommonMark §5.2 indented-code-in-list-item rule: if the
        // whitespace between marker and content expands to ≥ 5 virtual
        // columns, the content is an indented code block inside the
        // item. The "afterMarker" collapses to exactly 1 virtual
        // column; the remaining cols become the code block's indent.
        // Spec #7: `-\t\tfoo` → `<li><pre><code>  foo</code></pre></li>`.
        let markerCol = indent.count + marker.count
        var afterWidth = 0
        do {
            var vcol = markerCol
            for ch in afterMarker {
                if ch == " " { afterWidth += 1; vcol += 1 }
                else if ch == "\t" {
                    let w = 4 - (vcol % 4)
                    afterWidth += w
                    vcol += w
                }
            }
        }
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
}
