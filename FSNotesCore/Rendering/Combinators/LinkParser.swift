//
//  LinkParser.swift
//  FSNotesCore
//
//  Phase 12.C.3 — Inline tokenizer chain port: inline links and images.
//
//  CommonMark §6.3 / §6.5 — `[text](dest)` and `![alt](dest)`. The
//  link grammar is the most stateful in the inline tokenizer: link
//  text supports nested brackets and code-span boundaries, and the
//  destination has three sub-grammars (empty, angle-bracketed, bare
//  with balanced parens) plus an optional title.
//
//  Replaces `MarkdownParser.tryMatchLink` and `tryMatchImage`. Spec
//  buckets: Links 76/90 (84%), Images 21/22 (95%). Both are
//  pre-existing-floor regressions tracked in REFACTOR_PLAN — this
//  port must hold the floor, not improve it (improvements live in
//  Phase 12.C.6).
//
//  Why an imperative scan rather than a pure combinator chain for
//  the link-text bracket match: the caller passes `codeSpanRanges`
//  (positions of already-discovered `` `…` `` spans) so that
//  `[a `]` b](c)` is recognised as a single link rather than ending
//  early at the literal `]` inside the code span. Threading this
//  through `Parser<…>` would require either a state monad or
//  closure-captured context; an imperative `Int` walk is clearer at
//  this size.
//

import Foundation

public enum LinkParser {

    public struct Match {
        public let text: String
        public let dest: String
        public let endIndex: Int
    }

    /// Run on `chars[start...]` where `chars[start] == '['`. Returns
    /// nil if the link body / destination / title fails any of the
    /// CommonMark grammar rules.
    public static func match(
        _ chars: [Character],
        from start: Int,
        codeSpanRanges: [(start: Int, end: Int)] = []
    ) -> Match? {
        guard start < chars.count, chars[start] == "[" else { return nil }

        // 1. Find matching `]`, handling bracket nesting, backslash
        //    escapes, code-span boundaries (brackets inside a code
        //    span do not count as link delimiters), and raw HTML
        //    tag/autolink boundaries (CommonMark §6.4 spec #524, #526:
        //    brackets inside an HTML attribute value or autolink URL
        //    are protected from link-text scanning).
        var bracketDepth = 1
        var j = start + 1
        while j < chars.count && bracketDepth > 0 {
            if chars[j] == "\\" && j + 1 < chars.count {
                j += 2
                continue
            }
            var inCodeSpan = false
            for cs in codeSpanRanges {
                if j >= cs.start && j < cs.end {
                    j = cs.end
                    inCodeSpan = true
                    break
                }
            }
            if inCodeSpan { continue }
            if chars[j] == "<" {
                if let auto = AutolinkParser.match(chars, from: j) {
                    j = auto.endIndex
                    continue
                }
                if let html = RawHTMLParser.match(chars, from: j) {
                    j = html.endIndex
                    continue
                }
            }
            if chars[j] == "[" {
                bracketDepth += 1
            } else if chars[j] == "]" {
                bracketDepth -= 1
            }
            j += 1
        }
        guard bracketDepth == 0 else { return nil }
        let textEnd = j - 1

        // 2. `(` must follow immediately.
        guard j < chars.count, chars[j] == "(" else { return nil }
        let parenOpen = j
        var k = j + 1

        // 3. Skip optional whitespace (spaces, tabs, newlines).
        skipWhitespace(chars, &k)

        // 4. Empty destination: closing `)` immediately.
        if k < chars.count && chars[k] == ")" {
            return Match(
                text: String(chars[(start + 1)..<textEnd]),
                dest: String(chars[(parenOpen + 1)..<k]),
                endIndex: k + 1
            )
        }

        // 5. Parse destination — angle-bracketed or bare with balanced
        //    parens.
        if k < chars.count && chars[k] == "<" {
            k += 1
            while k < chars.count {
                if chars[k] == "\\" && k + 1 < chars.count { k += 2; continue }
                if chars[k] == ">" { break }
                if chars[k] == "<" || chars[k] == "\n" { return nil }
                k += 1
            }
            guard k < chars.count, chars[k] == ">" else { return nil }
            k += 1
        } else {
            var parenDepth = 0
            while k < chars.count {
                if chars[k] == "\\" && k + 1 < chars.count { k += 2; continue }
                if chars[k] == " " || chars[k] == "\t" || chars[k] == "\n" { break }
                if chars[k] == "(" {
                    parenDepth += 1
                } else if chars[k] == ")" {
                    if parenDepth == 0 { break }
                    parenDepth -= 1
                }
                k += 1
            }
            if parenDepth != 0 { return nil }
        }

        // 6. Skip whitespace before title or `)`.
        skipWhitespace(chars, &k)

        // 7. Optional title in `"…"`, `'…'`, or `(…)`.
        if k < chars.count {
            let opener = chars[k]
            if opener == "\"" || opener == "'" || opener == "(" {
                let closer: Character = opener == "(" ? ")" : opener
                k += 1
                while k < chars.count {
                    if chars[k] == "\\" && k + 1 < chars.count { k += 2; continue }
                    if chars[k] == closer { k += 1; break }
                    k += 1
                }
                skipWhitespace(chars, &k)
            }
        }

        // 8. Closing `)` must follow.
        guard k < chars.count, chars[k] == ")" else { return nil }

        return Match(
            text: String(chars[(start + 1)..<textEnd]),
            dest: String(chars[(parenOpen + 1)..<k]),
            endIndex: k + 1
        )
    }

    private static func skipWhitespace(_ chars: [Character], _ k: inout Int) {
        while k < chars.count, chars[k] == " " || chars[k] == "\t" || chars[k] == "\n" {
            k += 1
        }
    }
}

public enum ImageParser {

    public typealias Match = LinkParser.Match

    /// Run on `chars[start...]` where `chars[start] == '!'` and
    /// `chars[start+1] == '['`. Delegates to `LinkParser.match`
    /// starting at the `[`; the `text` field of the returned
    /// `LinkParser.Match` is reused as the image alt.
    public static func match(
        _ chars: [Character],
        from start: Int,
        codeSpanRanges: [(start: Int, end: Int)] = []
    ) -> Match? {
        guard start + 1 < chars.count,
              chars[start] == "!", chars[start + 1] == "[" else { return nil }
        return LinkParser.match(chars, from: start + 1, codeSpanRanges: codeSpanRanges)
    }
}
