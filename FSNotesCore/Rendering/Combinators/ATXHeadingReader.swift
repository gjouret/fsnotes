//
//  ATXHeadingReader.swift
//  FSNotesCore
//
//  Phase 12.C.5 — Block parsing port: ATX heading + setext underline.
//
//  CommonMark §4.2 (ATX) — 1–6 leading `#` characters, optionally up
//  to 3 leading spaces, followed by either a space/tab OR end-of-line.
//
//  CommonMark §4.3 (setext) — `===` (H1) or `---` (H2) on a line by
//  itself underneath a paragraph promotes the paragraph to a heading.
//  Detection is exposed here; the actual setext promotion lives in
//  `MarkdownParser.parse` because it depends on the paragraph buffer
//  state and is not a self-contained line read.
//
//  Spec buckets: ATX headings 18/18 (100%), Setext headings 27/27 (100%).
//

import Foundation

public enum ATXHeadingReader {

    public struct ReadResult {
        public let block: Block
        public let nextIndex: Int
    }

    /// Detect an ATX heading on `line`. Returns the level (1–6) and
    /// the verbatim suffix (everything after the marker run) for byte-
    /// equal round-trip. Returns nil for `#Hello` (missing required
    /// space after markers) or `####### too` (7 markers exceeds max).
    public static func detect(_ line: String) -> (level: Int, suffix: String)? {
        let chars = Array(line)
        var i = 0
        var leading = 0
        // CommonMark 4.2: up to 3 leading spaces before the opening `#`.
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

    /// Read a single-line ATX heading starting at `lines[start]`.
    public static func read(lines: [String], from start: Int) -> ReadResult? {
        guard start < lines.count,
              let heading = detect(lines[start]) else { return nil }
        return ReadResult(
            block: .heading(level: heading.level, suffix: heading.suffix),
            nextIndex: start + 1
        )
    }

    /// Detect a setext heading underline: a line of `===` (H1) or
    /// `---` (H2). Returns the heading level (1 or 2) if the line is
    /// a valid underline. `-` underlines require ≥ 3 chars to
    /// disambiguate from a list-marker start (CommonMark technically
    /// allows 1+, but the FSNotes++ heuristic prevents `foo\n-` from
    /// being misread as a setext H2 instead of a paragraph + bare
    /// list marker).
    public static func detectSetextUnderline(_ line: String) -> Int? {
        let chars = Array(line)
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
            guard runLen >= 3 else { return nil }
            return 2
        }
    }
}
