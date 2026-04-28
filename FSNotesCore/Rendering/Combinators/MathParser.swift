//
//  MathParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: inline math (`$…$`) and
//  display math (`$$…$$`).
//
//  Both forms are FSNotes++ extensions to CommonMark; the spec corpus
//  doesn't cover them, so the regression gate is the unit-test layer
//  + integration via existing math-rendering tests.
//
//  Grammar:
//    inline-math  = '$' (!('$' | '\n' | currency-prefix) anyChar)+ '$'
//                   where the closing '$' is not preceded by space.
//    display-math = '$$' (!'$$' anyChar)* '$$'
//                   where content trims whitespace and is non-empty.
//
//  Display must be checked BEFORE inline (caller responsibility) so
//  `$$x$$` doesn't tokenize as two inline maths.
//

import Foundation

/// Combinator-based detector for FSNotes++ inline math `$...$`.
public enum InlineMathParser {

    public struct Match {
        public let content: String
        public let endIndex: Int
    }

    /// Scan body characters until the closing `$`, rejecting newlines,
    /// embedded `$$` (display math has precedence — caller checks
    /// first), and trailing-space content.
    private static let body: Parser<String> = Parser { input in
        var content = ""
        var current = input
        while !current.isEmpty {
            let c = current.first!
            if c == "$" {
                if content.isEmpty || content.last == " " {
                    return .failure(message: "empty content or trailing space", remainder: input)
                }
                return .success(value: content, remainder: current.dropFirst())
            }
            if c == "\n" {
                return .failure(message: "no newlines in inline math", remainder: input)
            }
            content.append(c)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated inline math", remainder: input)
    }

    private static let parser: Parser<String> = then(char("$"), body)

    /// Run the combinator against `chars[start...]`. Returns nil if the
    /// cursor is not at a `$`, the `$` is part of `$$` (display math),
    /// or the content fails the spec rules.
    public static func match(_ chars: [Character], from start: Int) -> Match? {
        guard start < chars.count, chars[start] == "$" else { return nil }
        // `$$` is display math — handled separately. Skip.
        if start + 1 < chars.count && chars[start + 1] == "$" { return nil }
        // Reject `$` immediately after a letter (likely currency, not
        // math). This is a callers-side disambiguation that lives in
        // the bridge because the combinator only sees forward input.
        if start > 0 && chars[start - 1].isLetter { return nil }

        let slice = String(chars[start..<chars.count])
        let result = parser.parse(Substring(slice))
        guard case .success(let content, let remainder) = result else { return nil }
        let consumed = slice.count - remainder.count
        return Match(content: content, endIndex: start + consumed)
    }
}

/// Combinator-based detector for FSNotes++ display math `$$...$$`.
/// Spans multiple lines; content is trimmed of surrounding whitespace
/// and must be non-empty after trimming.
public enum DisplayMathParser {

    public struct Match {
        public let content: String
        public let endIndex: Int
    }

    /// Scan body characters until the closing `$$`. No restrictions on
    /// newlines (display math is multi-line). Content is trimmed; if
    /// the trimmed content is empty, the match fails.
    private static let body: Parser<String> = Parser { input in
        var content = ""
        var current = input
        while !current.isEmpty {
            let c = current.first!
            if c == "$" && current.dropFirst().first == "$" {
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    return .failure(message: "empty display-math content", remainder: input)
                }
                return .success(value: trimmed, remainder: current.dropFirst(2))
            }
            content.append(c)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated display math", remainder: input)
    }

    private static let parser: Parser<String> = then(string("$$"), body)

    public static func match(_ chars: [Character], from start: Int) -> Match? {
        guard start + 1 < chars.count,
              chars[start] == "$", chars[start + 1] == "$" else { return nil }

        let slice = String(chars[start..<chars.count])
        let result = parser.parse(Substring(slice))
        guard case .success(let content, let remainder) = result else { return nil }
        let consumed = slice.count - remainder.count
        return Match(content: content, endIndex: start + consumed)
    }
}
