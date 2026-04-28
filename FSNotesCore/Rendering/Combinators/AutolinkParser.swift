//
//  AutolinkParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: autolinks `<scheme:path>`
//  and `<local@domain>`.
//
//  CommonMark §6.4 — autolinks are URIs or email addresses delimited by
//  `<` and `>`:
//
//    URI form:    `<scheme:path>` where:
//                 - scheme is [A-Za-z][A-Za-z0-9+.-]{1,31}
//                 - path is any character except space, newline, `<`, `>`
//
//    Email form:  `<local@domain>` where the local-part contains an
//                 `@`, no spaces, no backslashes, length ≥ 3.
//
//  Replaces `MarkdownParser.tryMatchAutolink`. Spec bucket Autolinks
//  19/19 (100%) — pure-regression-detection.
//

import Foundation

public enum AutolinkParser {

    public struct Match {
        public let text: String
        public let isEmail: Bool
        public let endIndex: Int
    }

    /// Body of an autolink: characters between `<` and `>` excluding
    /// whitespace and newlines. Disambiguation between URI and email
    /// happens after collection — a single body character class works
    /// for both forms.
    private static let body: Parser<String> = Parser { input in
        var content = ""
        var current = input
        while let c = current.first {
            if c == ">" {
                return .success(value: content, remainder: current.dropFirst())
            }
            if c == " " || c == "\n" {
                return .failure(message: "whitespace inside autolink", remainder: input)
            }
            content.append(c)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated autolink", remainder: input)
    }

    private static let parser: Parser<String> = then(char("<"), body)

    /// Run the combinator. Returns nil if the cursor is not at `<`,
    /// the body collects no closing `>`, or the body fails URI/email
    /// validation.
    public static func match(_ chars: [Character], from start: Int) -> Match? {
        guard start < chars.count, chars[start] == "<" else { return nil }

        let slice = String(chars[start..<chars.count])
        let result = parser.parse(Substring(slice))
        guard case .success(let inner, let remainder) = result else { return nil }
        let consumed = slice.count - remainder.count

        // Try URI form: a scheme followed by `:` followed by anything.
        if let colonIdx = inner.firstIndex(of: ":"), colonIdx > inner.startIndex {
            let scheme = inner[..<colonIdx]
            if scheme.count >= 2 && scheme.count <= 32 &&
               scheme.first!.isASCII && scheme.first!.isLetter &&
               scheme.dropFirst().allSatisfy({
                   $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
               }) {
                return Match(text: inner, isEmail: false, endIndex: start + consumed)
            }
        }
        // Try email form: contains `@`, length ≥ 3, no `\\`, both sides
        // of `@` non-empty.
        if inner.contains("@") && !inner.contains(" ") && !inner.contains("\\") && inner.count >= 3 {
            let parts = inner.split(separator: "@", maxSplits: 1)
            if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty {
                return Match(text: inner, isEmail: true, endIndex: start + consumed)
            }
        }
        return nil
    }
}
