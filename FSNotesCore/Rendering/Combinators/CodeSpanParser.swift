//
//  CodeSpanParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: code spans (`` `…` ``).
//
//  CommonMark §6.1: a code span is opened by a string of ≥1 backtick
//  characters and closed by a string of EXACTLY the same length later
//  in the input. Inside the span:
//    1. A single leading and trailing space are stripped IFF the inner
//       content begins AND ends with a space and is not all-spaces
//       (preserves intentional `` ` `text` `` ``).
//    2. Newlines collapse to single spaces (line folding).
//
//  Replaces `MarkdownParser.tryMatchCodeSpan` (~35 LoC of position-
//  tracking) with a combinator composition:
//
//      open  = many1(char("`"))                         -- length n
//      body  = scanInner(closeLen: n)                   -- consumes
//                                                          characters
//                                                          and absorbs
//                                                          backtick
//                                                          runs ≠ n
//      span  = open.flatMap { open in body }
//
//  CommonMark spec bucket: Code spans 22/22 (100%). This port is
//  pure-regression-detection — any drop in the bucket is a clear bug.
//

import Foundation

/// Combinator-based detector for CommonMark code spans. Returns nil
/// if the cursor isn't at a span open (or no matching close run
/// exists in the remaining input). Designed to drop into
/// `MarkdownParser.parseInlines` (and `findCodeSpanRanges`) as a
/// drop-in replacement for the imperative `tryMatchCodeSpan`.
public enum CodeSpanParser {

    public struct Match {
        /// Inner content AFTER CommonMark §6.1 post-processing
        /// (newline-to-space + optional one-leading + one-trailing
        /// space strip). Stored on `Inline.code(...)` verbatim.
        public let inner: String
        /// New cursor position in the caller's `chars` array. Equal to
        /// the original `start` plus the count of consumed Character
        /// elements through the closing backtick run.
        public let endIndex: Int
    }

    /// Combinator: opening backtick run → matching close run, returning
    /// the verbatim inner content (pre-post-processing). The flatMap
    /// is the only place where the open length feeds the close
    /// constraint — replaces the imperative `openLen`/`closeLen`
    /// counter pair.
    private static let parser: Parser<String> =
        many1(char("`")).flatMap { open in scanInner(closeLen: open.count) }

    /// Scan body characters until a backtick run of EXACTLY `closeLen`
    /// is found. Backtick runs of any other length are absorbed into
    /// the body verbatim (they're literal characters in the span).
    /// Failure if the input is exhausted without a matching close.
    private static func scanInner(closeLen: Int) -> Parser<String> {
        return Parser { input in
            var body = ""
            var current = input
            while !current.isEmpty {
                if current.first == "`" {
                    var runLen = 0
                    var run = current
                    while run.first == "`" {
                        runLen += 1
                        run = run.dropFirst()
                    }
                    if runLen == closeLen {
                        return .success(value: body, remainder: run)
                    }
                    body.append(String(repeating: "`", count: runLen))
                    current = run
                } else {
                    body.append(current.first!)
                    current = current.dropFirst()
                }
            }
            return .failure(message: "no matching closing backtick run", remainder: input)
        }
    }

    /// Run the combinator against `chars[start...]` and return a
    /// `Match` or nil. Mirrors the shape of the other `tryMatch*`
    /// helpers for drop-in use in `parseInlines` and
    /// `findCodeSpanRanges`.
    public static func match(_ chars: [Character], from start: Int) -> Match? {
        // Precondition (CommonMark §6.1): an opening backtick run must
        // not be immediately preceded by another backtick (otherwise
        // we'd have started inside a longer run that the previous
        // iteration of the caller would already have considered). This
        // check is outside the combinator because the parser only sees
        // input from `start` onward.
        guard start < chars.count, chars[start] == "`" else { return nil }
        if start > 0 && chars[start - 1] == "`" { return nil }

        // Bridge from `[Character]` cursor convention to combinator
        // `Substring`. Code spans are character-aware only on `` ` ``
        // and `\n` (both pure ASCII), so character-count == String-count
        // == cursor delta.
        let slice = String(chars[start..<chars.count])
        let result = parser.parse(Substring(slice))
        guard case .success(let raw, let remainder) = result else { return nil }
        let consumed = slice.count - remainder.count
        return Match(inner: postprocess(raw), endIndex: start + consumed)
    }

    /// CommonMark §6.1 post-processing of code-span content.
    /// 1. Replace newlines with spaces (line folding).
    /// 2. If the content begins AND ends with a single space AND is
    ///    not all-spaces, strip one leading and one trailing space —
    ///    so `` ` text ` `` renders as "text" but `` `  ` `` (two
    ///    spaces) renders as "  ".
    private static func postprocess(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\n", with: " ")
        if s.count >= 2 && s.first == " " && s.last == " " &&
           !s.allSatisfy({ $0 == " " }) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}
