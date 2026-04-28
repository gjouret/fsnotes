//
//  HardLineBreakParser.swift
//  FSNotesCore
//
//  Phase 12.C.2 — First combinator port: hard line break detection.
//
//  CommonMark §6.7 hard line break: either
//    (a) a backslash immediately before a newline (`\\\n`), OR
//    (b) two or more trailing spaces immediately before a newline.
//
//  Currently inlined in `MarkdownParser.parseInlines` at a fixed
//  position in the imperative tokenizer chain (steps 2 + 3 of the
//  ~12-step `while i < chars.count` loop). The CommonMark spec
//  corpus's "Hard line breaks" bucket is at 100% (5/5), so porting
//  this is a pure regression-detection exercise — any port that
//  drops a single example is a clear bug.
//
//  Bridge between the existing `[Character]` + `Int` cursor that
//  `parseInlines` uses and the combinator API (which operates on
//  `Substring`): the helper takes the same `(chars, from: i)` shape
//  the other `tryMatch*` functions use and returns a `Match` carrying
//  `raw` (the consumed source) and `endIndex` (the new cursor
//  position) — same shape `tryMatchAutolink`, `tryMatchRawHTML`, etc.
//  return.
//

import Foundation

/// Combinator-based detector for the two CommonMark hard-line-break
/// shapes. Returns nil if the cursor isn't at a hard break. Designed
/// to drop into the existing `parseInlines` chain in
/// `MarkdownParser.swift` as a 5-line replacement for the 20-line
/// imperative steps 2+3.
public enum HardLineBreakParser {

    public struct Match {
        /// The verbatim source consumed (e.g. "\\\n" or "  \n" or
        /// "    \n"). Round-trips through `Inline.lineBreak(raw:)` so
        /// the serializer can emit the same source back.
        public let raw: String
        /// New cursor position in the caller's `chars` array. Equal to
        /// the original `from` plus the count of consumed Character
        /// elements (which equals the UTF-16 / String length here
        /// because we never consume a multi-codepoint grapheme — the
        /// hard-break shapes are pure ASCII).
        public let endIndex: Int
    }

    /// Combinator: backslash followed by newline.
    /// Matches `\\\n`. Returns the literal "\\\n".
    private static let backslashBreak: Parser<String> =
        seq2(char("\\"), char("\n")).map { _ in "\\\n" }

    /// Combinator: two or more spaces followed by newline.
    /// Returns the consumed text (e.g. "  \n" or "    \n").
    /// `many1` ensures ≥ 1 space; the post-condition `spaces.count >= 2`
    /// enforces the spec's "two or more". The condition is expressed
    /// in `flatMap` because Swift combinator libraries don't have a
    /// post-filter primitive — `flatMap` to either `pure(value)` (pass)
    /// or `fail(reason)` (reject) is the canonical pattern.
    private static let spacesBreak: Parser<String> =
        seq2(many1(char(" ")), char("\n")).flatMap { spaces, _ in
            guard spaces.count >= 2 else {
                return fail("hard break needs ≥ 2 trailing spaces, got \(spaces.count)")
            }
            return pure(String(repeating: " ", count: spaces.count) + "\n")
        }

    /// Either form. The two alternatives are disjoint at the first
    /// character (`\\` vs space) so order doesn't matter for
    /// correctness — backslash first matches the imperative version's
    /// step ordering.
    private static let hardBreak: Parser<String> = backslashBreak <|> spacesBreak

    /// Run the combinator against `chars[from...]` and return a `Match`
    /// or nil. Mirrors the shape of `tryMatchAutolink` / `tryMatchRawHTML`
    /// for drop-in use in `parseInlines`.
    public static func match(_ chars: [Character], from i: Int) -> Match? {
        guard i < chars.count else { return nil }
        // Bridge: build a Substring from the slice. Hard-break shapes
        // are pure ASCII so character-count == String-count == cursor
        // delta in the caller's `chars` array.
        let slice = String(chars[i..<chars.count])
        let result = hardBreak.parse(Substring(slice))
        guard case .success(let raw, _) = result else {
            return nil
        }
        return Match(raw: raw, endIndex: i + raw.count)
    }
}
