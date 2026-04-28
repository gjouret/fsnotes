//
//  RawHTMLParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: raw HTML.
//
//  CommonMark §6.6 — five disjoint sub-grammars dispatched by what
//  follows the opening `<`:
//
//    `<!--` …                  → comment (special-cased empty forms)
//    `<?` …                    → processing instruction
//    `<![CDATA[` …             → CDATA section
//    `<!LETTER` …              → declaration
//    `<TAG` / `</TAG`          → open / closing tag with attributes
//
//  Replaces `MarkdownParser.tryMatchRawHTML` (~165 LoC). Spec bucket
//  Raw HTML 20/20 (100%) — pure-regression-detection.
//

import Foundation

public enum RawHTMLParser {

    public struct Match {
        public let html: String
        public let endIndex: Int
    }

    // MARK: - Comment forms

    /// `<!-- … -->` plus the v0.31.2 short forms `<!-->` and `<!--->`.
    /// The bridge has already consumed `<` so this parser starts on
    /// `!--`.
    private static let comment: Parser<String> = Parser { input in
        // Expect `!--` immediately (caller has already validated the
        // lookahead in the bridge).
        guard input.hasPrefix("!--") else {
            return .failure(message: "expected !--", remainder: input)
        }
        let afterOpen = input.dropFirst(3)
        // Short form `<!-->` — single `>` after `<!--`.
        if afterOpen.first == ">" {
            return .success(value: "<!-->", remainder: afterOpen.dropFirst())
        }
        // Short form `<!--->` — `->` after `<!--`.
        if afterOpen.hasPrefix("->") {
            return .success(value: "<!--->", remainder: afterOpen.dropFirst(2))
        }
        // Long form: scan until `-->`. Content must not contain `-->`.
        var current = afterOpen
        var content = "<!--"
        while !current.isEmpty {
            if current.hasPrefix("-->") {
                content.append("-->")
                return .success(value: content, remainder: current.dropFirst(3))
            }
            content.append(current.first!)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated HTML comment", remainder: input)
    }

    // MARK: - Processing instruction `<? … ?>`

    private static let processingInstruction: Parser<String> = Parser { input in
        guard input.first == "?" else {
            return .failure(message: "expected ?", remainder: input)
        }
        var current = input.dropFirst()
        var content = "<?"
        while !current.isEmpty {
            if current.hasPrefix("?>") {
                content.append("?>")
                return .success(value: content, remainder: current.dropFirst(2))
            }
            content.append(current.first!)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated PI", remainder: input)
    }

    // MARK: - CDATA `<![CDATA[ … ]]>`

    private static let cdata: Parser<String> = Parser { input in
        guard input.hasPrefix("![CDATA[") else {
            return .failure(message: "expected ![CDATA[", remainder: input)
        }
        var current = input.dropFirst(8)
        var content = "<![CDATA["
        while !current.isEmpty {
            if current.hasPrefix("]]>") {
                content.append("]]>")
                return .success(value: content, remainder: current.dropFirst(3))
            }
            content.append(current.first!)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated CDATA", remainder: input)
    }

    // MARK: - Declaration `<!LETTER … >`

    private static let declaration: Parser<String> = Parser { input in
        guard input.first == "!" else {
            return .failure(message: "expected !", remainder: input)
        }
        let afterBang = input.dropFirst()
        guard let head = afterBang.first, head.isLetter else {
            return .failure(message: "declaration body must start with letter", remainder: input)
        }
        var current = afterBang
        var content = "<!"
        while !current.isEmpty {
            if current.first == ">" {
                content.append(">")
                return .success(value: content, remainder: current.dropFirst())
            }
            content.append(current.first!)
            current = current.dropFirst()
        }
        return .failure(message: "unterminated declaration", remainder: input)
    }

    // MARK: - Tags

    /// Open or closing tag with optional attribute list. Caller has
    /// consumed `<`; this parser accepts `[/]TAGNAME …` and emits
    /// the full source `<TAG…>`.
    private static let tag: Parser<String> = Parser { input in
        var current = input
        var raw = "<"
        let isClosing = current.first == "/"
        if isClosing {
            raw.append("/")
            current = current.dropFirst()
        }
        // Tag name: ASCII letter then ASCII letters / digits / `-`.
        guard let first = current.first, first.isASCII, first.isLetter else {
            return .failure(message: "tag must start with ASCII letter", remainder: input)
        }
        raw.append(first)
        current = current.dropFirst()
        while let c = current.first,
              c.isASCII && (c.isLetter || c.isNumber || c == "-") {
            raw.append(c)
            current = current.dropFirst()
        }

        if isClosing {
            // Closing tag: optional whitespace then `>`. NO attributes.
            while let c = current.first, c == " " || c == "\t" || c == "\n" {
                raw.append(c)
                current = current.dropFirst()
            }
            guard current.first == ">" else {
                return .failure(message: "unterminated closing tag", remainder: input)
            }
            raw.append(">")
            return .success(value: raw, remainder: current.dropFirst())
        }

        // Open tag: walk attribute list until `>` or `/>`.
        while !current.isEmpty {
            // Skip whitespace separating tag-name / attributes.
            let beforeWS = current
            while let c = current.first, c == " " || c == "\t" || c == "\n" {
                raw.append(c)
                current = current.dropFirst()
            }

            guard !current.isEmpty else {
                return .failure(message: "unterminated open tag", remainder: input)
            }

            // Self-closing `/>` or terminator `>`.
            if current.first == "/" {
                if current.dropFirst().first == ">" {
                    raw.append("/>")
                    return .success(value: raw, remainder: current.dropFirst(2))
                }
                return .failure(message: "stray slash in open tag", remainder: input)
            }
            if current.first == ">" {
                raw.append(">")
                return .success(value: raw, remainder: current.dropFirst())
            }

            // Otherwise we MUST have advanced over whitespace before
            // an attribute name (CommonMark spec rule).
            if current.startIndex == beforeWS.startIndex {
                return .failure(message: "missing whitespace before attribute", remainder: input)
            }

            // Attribute name: [a-zA-Z_:][a-zA-Z0-9_.:-]*
            guard let nameHead = current.first,
                  nameHead.isASCII && (nameHead.isLetter || nameHead == "_" || nameHead == ":") else {
                return .failure(message: "bad attribute name", remainder: input)
            }
            raw.append(nameHead)
            current = current.dropFirst()
            while let c = current.first,
                  c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == ":" || c == "-") {
                raw.append(c)
                current = current.dropFirst()
            }

            // Optional `= value` with whitespace around `=`. We track a
            // separate `valueScan` cursor so that a missing value
            // leaves `current` pointing where the next loop iteration
            // expects (post-name).
            var valueScan = current
            var preEqualsTrail = ""
            while let c = valueScan.first, c == " " || c == "\t" || c == "\n" {
                preEqualsTrail.append(c)
                valueScan = valueScan.dropFirst()
            }
            guard valueScan.first == "=" else { continue }  // no value, next attr

            // Commit the whitespace + `=`.
            raw.append(preEqualsTrail)
            raw.append("=")
            valueScan = valueScan.dropFirst()
            while let c = valueScan.first, c == " " || c == "\t" || c == "\n" {
                raw.append(c)
                valueScan = valueScan.dropFirst()
            }
            guard let valueStart = valueScan.first else {
                return .failure(message: "value missing after =", remainder: input)
            }

            if valueStart == "\"" {
                raw.append("\"")
                valueScan = valueScan.dropFirst()
                while let c = valueScan.first, c != "\"" {
                    raw.append(c)
                    valueScan = valueScan.dropFirst()
                }
                guard valueScan.first == "\"" else {
                    return .failure(message: "unterminated double-quoted value", remainder: input)
                }
                raw.append("\"")
                valueScan = valueScan.dropFirst()
            } else if valueStart == "'" {
                raw.append("'")
                valueScan = valueScan.dropFirst()
                while let c = valueScan.first, c != "'" {
                    raw.append(c)
                    valueScan = valueScan.dropFirst()
                }
                guard valueScan.first == "'" else {
                    return .failure(message: "unterminated single-quoted value", remainder: input)
                }
                raw.append("'")
                valueScan = valueScan.dropFirst()
            } else {
                // Unquoted: must have at least one char, banned chars
                // disallowed (space, tab, newline, quotes, =, <, >, `).
                if isUnquotedBan(valueStart) {
                    return .failure(message: "bad unquoted value", remainder: input)
                }
                while let c = valueScan.first, !isUnquotedBan(c) {
                    raw.append(c)
                    valueScan = valueScan.dropFirst()
                }
            }
            current = valueScan
        }
        return .failure(message: "unterminated open tag", remainder: input)
    }

    private static func isUnquotedBan(_ c: Character) -> Bool {
        switch c {
        case " ", "\t", "\n", "\"", "'", "=", "<", ">", "`":
            return true
        default:
            return false
        }
    }

    /// Run the combinator. Dispatches by the second character (the
    /// one immediately after `<`) to the appropriate sub-grammar.
    public static func match(_ chars: [Character], from start: Int) -> Match? {
        guard start < chars.count, chars[start] == "<" else { return nil }
        guard start + 1 < chars.count else { return nil }

        let slice = String(chars[start..<chars.count])
        let afterAngle = Substring(slice).dropFirst()  // drop `<`

        // Comment lookahead: `!--`.
        let parser: Parser<String>
        if afterAngle.hasPrefix("!--") {
            parser = comment
        } else if afterAngle.first == "?" {
            parser = processingInstruction
        } else if afterAngle.hasPrefix("![CDATA[") {
            parser = cdata
        } else if afterAngle.first == "!" {
            // Declaration `<!LETTER…>`. Caller's lookahead also rules
            // out CDATA before we get here.
            parser = declaration
        } else {
            // Tag forms: `</TAG` (closing) or `<TAG` (open).
            parser = tag
        }

        switch parser.parse(afterAngle) {
        case .success(let html, let remainder):
            let consumed = slice.count - remainder.count
            return Match(html: html, endIndex: start + consumed)
        case .failure:
            return nil
        }
    }
}
