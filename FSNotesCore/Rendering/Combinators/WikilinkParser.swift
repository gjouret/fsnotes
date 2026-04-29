//
//  WikilinkParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: wikilinks `[[target]]`
//  and `[[target|display]]`.
//
//  FSNotes++ extension to CommonMark. Narrow grammar by design — the
//  target/display fields cannot contain `[`, `]`, `|`, or newline so
//  the wikilink path doesn't collide with regular link / reference-link
//  syntax. The caller (`parseInlines`) tries the wikilink path BEFORE
//  the regular `[…]` link to avoid `[[foo]]` being parsed as a
//  reference-link `[foo]` wrapped in literal brackets.
//

import Foundation

public enum WikilinkParser {

    public struct Match {
        public let target: String
        public let display: String?
        public let endIndex: Int
    }

    /// Body characters: anything except `]`, `[`, or `\n`. The pipe
    /// `|` is allowed (it's the target/display separator) but is
    /// post-processed in the bridge after parsing.
    private static let bodyChar: Parser<Character> = noneOf("[]\n")

    /// Combinator: `[[` → body chars (≥ 1) → `]]`. Returns the
    /// concatenated body (may contain `|` for target/display split).
    private static let parser: Parser<String> =
        between(string("[["), string("]]"), many1(bodyChar))
        .map { String($0) }

    /// Run the combinator. Returns nil if the cursor is not at `[[`,
    /// no closing `]]` exists, or the content (split on `|` into
    /// target/display) is invalid.
    ///
    /// Bracket-integrity rules — a wikilink also fails when:
    ///
    ///   1. An EXTRA `[` immediately precedes the opening `[[`, or an
    ///      EXTRA `]` immediately follows the closing `]]`. CommonMark
    ///      spec #548 (`[[[foo]]]`) treats those bracket triples as
    ///      plain text — we don't let the wikilink path consume the
    ///      middle `[[foo]]` and leave stray brackets behind.
    ///
    ///   2. The opening `[[` is immediately preceded by `!`. The
    ///      `!` would otherwise be treated as a literal-text run with
    ///      a wikilink glued onto it, but per CommonMark spec #590
    ///      `![[foo]]` is the (failed) image-opener form and the
    ///      whole run must stay as literal text. Wikilinks are an
    ///      FSNotes++ extension; suppressing them after `!` keeps the
    ///      image opener's failure mode intact.
    ///
    ///   3. The closing `]]` is immediately followed by `:`. CommonMark
    ///      spec #590's second line — `[[foo]]: /url "title"` — is
    ///      meant to be a malformed link-reference-definition, not a
    ///      wikilink at all. Letting the wikilink fire would split the
    ///      line into `<wikilink>foo</wikilink>: /url "title"` instead
    ///      of preserving it as literal paragraph text. A wikilink
    ///      glued to a `:` is overwhelmingly more likely to be a typo
    ///      / failed ref-def than a real wikilink (real wikilinks
    ///      don't carry trailing `:` in any FSNotes++ usage).
    public static func match(_ chars: [Character], from start: Int) -> Match? {
        guard start + 1 < chars.count,
              chars[start] == "[", chars[start + 1] == "[" else { return nil }
        if start > 0 && chars[start - 1] == "[" { return nil }
        if start > 0 && chars[start - 1] == "!" { return nil }

        let slice = String(chars[start..<chars.count])
        let result = parser.parse(Substring(slice))
        guard case .success(let inner, let remainder) = result else { return nil }
        let consumed = slice.count - remainder.count
        let endIndex = start + consumed

        if endIndex < chars.count && chars[endIndex] == "]" { return nil }
        if endIndex < chars.count && chars[endIndex] == ":" { return nil }

        // Split on the first `|`. Empty target rejects the match
        // (`[[|x]]` is not a valid wikilink).
        if let pipeIdx = inner.firstIndex(of: "|") {
            let target = String(inner[..<pipeIdx])
            let display = String(inner[inner.index(after: pipeIdx)...])
            guard !target.isEmpty else { return nil }
            return Match(
                target: target,
                display: display.isEmpty ? nil : display,
                endIndex: endIndex
            )
        }
        return Match(target: inner, display: nil, endIndex: endIndex)
    }
}
