//
//  StrikethroughParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: GFM strikethrough `~~…~~`.
//
//  GitHub-Flavored-Markdown strikethrough (not part of the CommonMark
//  core spec). Rules:
//    - Open is `~~` not followed by another `~` (rejects `~~~`).
//    - The character immediately after `~~` must NOT be ASCII
//      whitespace (` `, `\t`, `\n`).
//    - Close is `~~` not part of a longer tilde run.
//    - The character immediately before the closing `~~` must NOT be
//      ASCII whitespace.
//
//  Replaces `MarkdownParser.tryMatchStrikethrough` (~35 LoC) — same
//  `(inner, endIndex)` return shape, drop-in.
//

import Foundation

public enum StrikethroughParser {

    public struct Match {
        public let inner: String
        public let endIndex: Int
    }

    /// Combinator: open `~~` (not part of `~~~`) → body → close `~~`
    /// (not part of `~~~`). The flanking-whitespace constraints are
    /// inside the body parser because they depend on the body content.
    private static let parser: Parser<String> = string("~~").flatMap { _ in
        body
    }

    /// Scan body characters until a closing `~~` not part of a longer
    /// tilde run is found, with the spec's no-leading / no-trailing
    /// ASCII whitespace constraint enforced inline.
    private static let body: Parser<String> = Parser { input in
        // Reject open-then-whitespace.
        guard let first = input.first else {
            return .failure(message: "empty body", remainder: input)
        }
        if first == " " || first == "\t" || first == "\n" {
            return .failure(message: "whitespace after open ~~", remainder: input)
        }
        var content = ""
        var current = input
        while !current.isEmpty {
            if current.first == "~", current.dropFirst().first == "~" {
                // Reject `~~~` close — keep scanning.
                if current.dropFirst(2).first == "~" {
                    content.append("~")
                    current = current.dropFirst()
                    continue
                }
                // Char before close (= last appended to `content`)
                // must not be whitespace.
                guard let last = content.last,
                      last != " " && last != "\t" && last != "\n" else {
                    content.append("~")
                    current = current.dropFirst()
                    continue
                }
                return .success(value: content, remainder: current.dropFirst(2))
            }
            content.append(current.first!)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated strikethrough", remainder: input)
    }

    /// Run the combinator against `chars[start...]`. Returns nil if
    /// the cursor is not at `~~`, the open is part of `~~~`, or the
    /// flanking-whitespace rules reject the candidate.
    public static func match(_ chars: [Character], from start: Int) -> Match? {
        // Need at least `~~X~~` = 5 characters.
        guard start + 4 < chars.count,
              chars[start] == "~", chars[start + 1] == "~" else { return nil }
        // Reject triple-tilde open.
        if start + 2 < chars.count, chars[start + 2] == "~" { return nil }

        let slice = String(chars[start..<chars.count])
        let result = parser.parse(Substring(slice))
        guard case .success(let inner, let remainder) = result else { return nil }
        let consumed = slice.count - remainder.count
        return Match(inner: inner, endIndex: start + consumed)
    }
}
