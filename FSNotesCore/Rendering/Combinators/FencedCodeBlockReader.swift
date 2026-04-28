//
//  FencedCodeBlockReader.swift
//  FSNotesCore
//
//  Phase 12.C.5 — Block parsing port: fenced code blocks.
//
//  CommonMark §4.5 — `` ``` `` or `~~~` fence open / matching close.
//
//  Self-contained block reader extracted from the inline branch in
//  `MarkdownParser.parse`. Returns the parsed block + the next line
//  index to resume from, OR nil if the line at `start` doesn't open
//  a fence. The caller (`MarkdownParser.parse`) flushes its paragraph
//  buffer before this reader runs, so this file owns no shared state.
//
//  Why this lives in `Combinators/` even though it isn't a `Parser<…>`:
//  the inline tokenizer ports (12.C.3) and emphasis resolver (12.C.4)
//  set the precedent — block-level parsing logic moves out of the
//  monolithic `parse()` for the same structural reasons. A literal
//  `Parser<…>` over a line-stream is awkward when block readers
//  consume multi-line ranges and need cross-cutting context (here,
//  whether the document ends with a newline).
//

import Foundation

public enum FencedCodeBlockReader {

    public struct ReadResult {
        public let block: Block
        public let nextIndex: Int
    }

    /// Information captured from a fence-open line. The fence string
    /// is stored so the close fence can be validated against it
    /// (CommonMark: close length must be ≥ open length AND use the
    /// same fence character).
    ///
    /// Public so other readers (list continuation, link-ref-def
    /// collection) can detect fences and skip over their bodies
    /// without re-implementing the rules.
    public struct Fence {
        public let fenceChar: Character
        public let fenceLength: Int
        public let infoRaw: String
        public let indent: Int

        public init(fenceChar: Character, fenceLength: Int, infoRaw: String, indent: Int) {
            self.fenceChar = fenceChar
            self.fenceLength = fenceLength
            self.infoRaw = infoRaw
            self.indent = indent
        }
    }

    /// Try to read a fenced code block starting at `lines[start]`.
    /// Returns nil if `lines[start]` doesn't open a fence.
    /// `trailingNewline` lets the reader skip the synthetic trailing
    /// empty line that `splitPreservingTrailingEmpty` introduces for
    /// inputs ending with `\n`.
    public static func read(
        lines: [String],
        from start: Int,
        trailingNewline: Bool
    ) -> ReadResult? {
        guard start < lines.count,
              let fence = Self.detectOpen(lines[start]) else { return nil }

        var contentLines: [String] = []
        var j = start + 1
        var foundClose = false

        while j < lines.count {
            let l = lines[j]
            if j == lines.count - 1 && l.isEmpty && trailingNewline { break }
            if isClose(l, matching: fence) {
                foundClose = true
                break
            }
            contentLines.append(l)
            j += 1
        }

        // CommonMark: strip up to `fence.indent` leading spaces from
        // every content line so the displayed code aligns with column 0.
        if fence.indent > 0 {
            contentLines = contentLines.map { contentLine in
                let lineChars = Array(contentLine)
                var strip = 0
                while strip < fence.indent &&
                      strip < lineChars.count &&
                      lineChars[strip] == " " {
                    strip += 1
                }
                return String(lineChars[strip...])
            }
        }

        let content = contentLines.joined(separator: "\n")
        // Unterminated fence: code block extends to end of document
        // (CommonMark rule); no closing fence line consumed.
        let nextIndex = foundClose ? j + 1 : j

        let infoTrimmed = fence.infoRaw.trimmingCharacters(in: .whitespaces)
        let language = infoTrimmed.isEmpty ? nil : infoTrimmed
        let fenceStyle = FenceStyle(
            character: fence.fenceChar == "`" ? .backtick : .tilde,
            length: fence.fenceLength,
            infoRaw: fence.infoRaw
        )

        return ReadResult(
            block: .codeBlock(language: language, content: content, fence: fenceStyle),
            nextIndex: nextIndex
        )
    }

    // MARK: - Detection helpers

    /// Detect whether `line` opens a fenced code block. Rule: ≤ 3
    /// leading spaces, then ≥ 3 backticks or tildes, optionally
    /// followed by an info string. Backtick fences cannot contain
    /// backticks in their info string.
    public static func detectOpen(_ line: String) -> Fence? {
        let chars = Array(line)
        var i = 0
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }
        let indent = i

        guard i < chars.count else { return nil }
        let fenceChar = chars[i]
        guard fenceChar == "`" || fenceChar == "~" else { return nil }

        var count = 0
        while i < chars.count && chars[i] == fenceChar { i += 1; count += 1 }
        guard count >= 3 else { return nil }

        let rest = String(chars[i...])
        if fenceChar == "`" && rest.contains("`") { return nil }

        return Fence(fenceChar: fenceChar, fenceLength: count, infoRaw: rest, indent: indent)
    }

    /// Check whether `line` is a valid close fence for the given open.
    /// Close fence: ≤ 3 leading spaces, then ≥ open-length fence chars,
    /// then optional trailing whitespace only, no info string.
    public static func isClose(_ line: String, matching open: Fence) -> Bool {
        let chars = Array(line)
        var i = 0
        while i < chars.count && i < 3 && chars[i] == " " { i += 1 }

        var count = 0
        while i < chars.count && chars[i] == open.fenceChar { i += 1; count += 1 }
        guard count >= open.fenceLength else { return false }

        let trailing = chars[i...]
        return trailing.allSatisfy { $0 == " " || $0 == "\t" }
    }
}
