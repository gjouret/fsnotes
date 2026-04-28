//
//  LinkResolver.swift
//  FSNotesCore
//
//  Phase 12.C.6.h — Link-in-link literalization via the CommonMark §6.4
//  delimiter-stack algorithm.
//
//  Replaces the greedy left-to-right link/image matching previously
//  performed inside `MarkdownParser.tokenizeNonEmphasis` with a
//  pre-pass that walks the inline character stream, tracks `[` /
//  `![` openers on a stack, and resolves each `]` against the most
//  recent active opener. When a `[`-opener resolves successfully, all
//  `[` openers earlier on the stack are deactivated — preventing the
//  outer brackets of `[a [b](u1)](u2)` from re-activating into a
//  spurious nested link.
//
//  Image (`![`) openers are NOT deactivated by inner link resolution
//  per spec §6.4 — `[![alt](img)](url)` correctly produces an image
//  inside a link. Only `[` link openers are subject to the
//  inactivation rule.
//
//  Public surface: `LinkResolver.resolve(...)` returns the sorted list
//  of resolved link/image spans the tokenizer should emit. Spans
//  carry the character offsets into `chars` of the opener, the inner
//  text region, the closer, and the position immediately after the
//  full link body — letting the tokenizer materialise the inline
//  without re-running the §6.4 algorithm.
//
//  Reuses `LinkParser.parseInlineBody` for `(dest title?)` parsing so
//  the body-parse semantics stay byte-identical to the standalone
//  `LinkParser.match` path.
//
//  CommonMark spec buckets affected: Links 85/90 → 90/90 (closes
//  #518, #519, #520, #532, #533); Images 21/22 unchanged (#590 is
//  the documented FSNotes++ wikilink-extension non-conformance).
//

import Foundation

public enum LinkResolver {

    public struct ResolvedLink: Equatable {
        public let openCharIdx: Int      // position of `[` (or `!` for image)
        public let textStart: Int        // first char of link text (after `[` or `![`)
        public let textEnd: Int          // exclusive — position of the closing `]`
        public let endCharIdx: Int       // position immediately after the full body
        public let dest: String          // raw destination (may include `<...>`, title)
        public let isImage: Bool
    }

    /// Run the §6.4 delimiter-stack algorithm over `chars` and return
    /// every resolved link / image span. Spans are sorted by
    /// `openCharIdx` ascending. The tokenizer keys off `openCharIdx`
    /// to decide whether a `[` it has reached is the start of a real
    /// link (emit + jump to `endCharIdx`) or a literal `[` (fall
    /// through).
    ///
    /// `codeSpanRanges` are honoured: characters inside a code span
    /// don't participate in bracket counting, and a span that crosses
    /// an otherwise-resolvable link's boundary cancels the resolution
    /// (matches the existing `codeSpanCrossesBoundary` rule on the
    /// greedy path).
    ///
    /// `refDefs` is consulted for full-ref / collapsed-ref / shortcut
    /// reference links.
    public static func resolve(
        chars: [Character],
        codeSpanRanges: [(start: Int, end: Int)],
        refDefs: [String: (url: String, title: String?)]
    ) -> [ResolvedLink] {
        struct Opener {
            let charIdx: Int
            let textStart: Int
            let kind: Kind
            var active: Bool
            enum Kind { case bracket; case imageBracket }
        }
        var openerStack: [Opener] = []
        var resolved: [ResolvedLink] = []

        var i = 0
        while i < chars.count {
            let ch = chars[i]

            // Backslash escape: skip the escaped char (don't let
            // `\[` or `\]` count as bracket delimiters).
            if ch == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }

            // Code spans: consumed atomically — brackets inside a
            // code span don't participate in link bracket counting.
            var hitCodeSpan = false
            for cs in codeSpanRanges where i >= cs.start && i < cs.end {
                i = cs.end
                hitCodeSpan = true
                break
            }
            if hitCodeSpan { continue }

            // Autolinks and raw HTML: brackets inside an HTML
            // attribute value or autolink URL are protected.
            if ch == "<" {
                if let auto = AutolinkParser.match(chars, from: i) {
                    i = auto.endIndex
                    continue
                }
                if let html = RawHTMLParser.match(chars, from: i) {
                    i = html.endIndex
                    continue
                }
            }

            // Wikilinks: `[[target]]` consumed atomically when the
            // wikilink path wins (i.e., target doesn't resolve via a
            // ref-def — that's the spec #559 deferral handled in
            // `tokenizeNonEmphasis`). When wikilinks fire, the inner
            // `[`s never become opener delimiters.
            //
            // We mirror the tokenizer's wikilink check exactly so the
            // resolver and tokenizer agree on which `[`s are bracket
            // openers vs. wikilink-consumed.
            if ch == "[" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let match = WikilinkParser.match(chars, from: i) {
                    let labelKey = MarkdownParser.normalizeLabel(match.target)
                    let resolvesViaRefDef = match.display == nil && refDefs[labelKey] != nil
                    if !resolvesViaRefDef
                        && !codeSpanCrossesBoundary(codeSpanRanges, matchStart: i, matchEnd: match.endIndex) {
                        i = match.endIndex
                        continue
                    }
                }
            }

            // Image opener `![`.
            if ch == "!" && i + 1 < chars.count && chars[i + 1] == "[" {
                openerStack.append(Opener(
                    charIdx: i, textStart: i + 2,
                    kind: .imageBracket, active: true
                ))
                i += 2
                continue
            }

            // Bracket opener `[`.
            if ch == "[" {
                openerStack.append(Opener(
                    charIdx: i, textStart: i + 1,
                    kind: .bracket, active: true
                ))
                i += 1
                continue
            }

            // Bracket closer `]`.
            if ch == "]" {
                guard !openerStack.isEmpty else {
                    i += 1
                    continue
                }
                let opener = openerStack.removeLast()
                if !opener.active {
                    // Opener was deactivated by an earlier resolution
                    // — `[` becomes literal, `]` becomes literal.
                    i += 1
                    continue
                }

                let textChars = String(chars[opener.textStart..<i])
                if let body = matchAfterCloser(
                    chars: chars, j: i + 1,
                    textChars: textChars, refDefs: refDefs
                ) {
                    if !codeSpanCrossesBoundary(
                        codeSpanRanges,
                        matchStart: opener.charIdx, matchEnd: body.endIndex
                    ) {
                        resolved.append(ResolvedLink(
                            openCharIdx: opener.charIdx,
                            textStart: opener.textStart,
                            textEnd: i,
                            endCharIdx: body.endIndex,
                            dest: body.dest,
                            isImage: opener.kind == .imageBracket
                        ))
                        // §6.4: when a `[` (link, not image) resolves,
                        // every earlier `[` opener still on the stack
                        // becomes inactive. `![` openers are NOT
                        // deactivated — `[![alt](img)](url)` is
                        // intentional.
                        if opener.kind == .bracket {
                            for k in openerStack.indices where openerStack[k].kind == .bracket {
                                openerStack[k].active = false
                            }
                        }
                        i = body.endIndex
                        continue
                    }
                }
                // No match (or code span crosses boundary): opener +
                // closer fall through as literal.
                i += 1
                continue
            }

            i += 1
        }

        return resolved.sorted { $0.openCharIdx < $1.openCharIdx }
    }

    // MARK: - After-closer body matching

    /// Try to parse a link / image body starting at `chars[j]`, where
    /// `j == ]closerIdx + 1`. Returns the raw destination and the
    /// position after the full body (inline `(...)`, full `[label]`,
    /// collapsed `[]`, or shortcut), or nil if none match.
    ///
    /// Order of attempts:
    /// 1. Inline body `(...)` — preferred.
    /// 2. Full / collapsed reference `[label]` / `[]` — only when `(`
    ///    parse fails AND `chars[j] == '['`.
    /// 3. Shortcut reference — only when `chars[j]` is neither `(`
    ///    nor `[` (or an `(` body parse failed).
    ///
    /// Mirrors the spec ordering: a `]` followed by `[label]` rules
    /// out the shortcut interpretation (the `[label]` makes it a
    /// full-ref attempt; if the label isn't in `refDefs`, neither is
    /// the construct a link). A `]` followed by `(...)` that fails
    /// inline-body parsing falls through to shortcut (spec #568).
    private static func matchAfterCloser(
        chars: [Character], j: Int,
        textChars: String,
        refDefs: [String: (url: String, title: String?)]
    ) -> (dest: String, endIndex: Int)? {
        // 1. Inline body `(...)`.
        if j < chars.count && chars[j] == "(" {
            if let body = LinkParser.parseInlineBody(chars, from: j) {
                return body
            }
            // Spec #568: an `(...)` that fails inline-body parsing
            // doesn't block the shortcut interpretation. Fall
            // through.
        }

        guard !refDefs.isEmpty else { return nil }

        // 2. Full or collapsed reference `[label]` / `[]`.
        if j < chars.count && chars[j] == "[" {
            let labelStart = j + 1
            var k = labelStart
            while k < chars.count && chars[k] != "]" {
                if chars[k] == "\\" && k + 1 < chars.count { k += 1 }
                k += 1
            }
            guard k < chars.count else { return nil }
            let label = String(chars[labelStart..<k])
            let normalizedLabel = label.isEmpty ? textChars : label
            let key = MarkdownParser.normalizeLabel(normalizedLabel)
            if let def = refDefs[key] {
                let rawDest = MarkdownParser.buildRawDest(url: def.url, title: def.title)
                return (rawDest, k + 1)
            }
            // Spec: a `[label]` that doesn't match a refdef rules
            // out shortcut interpretation too — the construct is
            // not a link. Bail.
            return nil
        }

        // 3. Shortcut reference (only when `[` doesn't follow).
        let key = MarkdownParser.normalizeLabel(textChars)
        if let def = refDefs[key] {
            let rawDest = MarkdownParser.buildRawDest(url: def.url, title: def.title)
            return (rawDest, j)
        }
        return nil
    }

    // MARK: - Helpers

    /// Mirrors `MarkdownParser.codeSpanCrossesBoundary` — kept local
    /// to avoid widening that helper's visibility just for the
    /// resolver call site.
    private static func codeSpanCrossesBoundary(
        _ codeSpanRanges: [(start: Int, end: Int)],
        matchStart: Int, matchEnd: Int
    ) -> Bool {
        for cs in codeSpanRanges
        where cs.start > matchStart && cs.start < matchEnd && cs.end > matchEnd {
            return true
        }
        return false
    }
}
