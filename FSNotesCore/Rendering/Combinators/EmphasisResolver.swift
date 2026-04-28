//
//  EmphasisResolver.swift
//  FSNotesCore
//
//  Phase 12.C.4 — Emphasis algorithm port (CommonMark §6.2 delimiter
//  stack).
//
//  This is the canonical "stateful, ambiguous, hard to debug" parser
//  case in the inline grammar. The algorithm walks an intermediate
//  token stream produced by Phase A (`MarkdownParser.tokenizeNonEmphasis`)
//  and resolves runs of `*` / `_` into `.bold` / `.italic` Inlines:
//
//    Phase A token stream    →  Phase B (this file)   →  [Inline]
//    [text, delim*, ...]                                 [.text, .italic(...), ...]
//
//  Why this lives in `Combinators/` even though it isn't a `Parser<…>`:
//  the rest of the inline tokenizer chain ports are in this directory
//  (HardLineBreakParser, CodeSpanParser, … LinkParser); the emphasis
//  algorithm is the last piece of inline parsing logic to move out of
//  MarkdownParser, and colocating the data types
//  (`InlineToken`, `DelimiterRun`) with the consumer is the right
//  ownership. Phase A still uses both types from here.
//
//  Not a literal "combinator" port: the algorithm is a stateful
//  doubly-walked rewrite over tokens, not a backtracking parse over
//  characters. A `Parser<…>` shape would obscure the spec text.
//
//  CommonMark spec bucket: Emphasis and strong emphasis 132/132 (100%).
//  Pure-regression-detection — any drop in the bucket is a clear bug.
//

import Foundation

/// A token in the intermediate representation between Phase A
/// (non-emphasis inline parsing) and Phase B (emphasis resolution).
public enum InlineToken {
    case inline(Inline)                 // already-parsed inline (code, link, etc.)
    case text(String)                   // raw text needing no further processing
    case delimiter(DelimiterRun)        // a run of * or _ to be resolved
}

/// A delimiter run on the stack. Tracks the character, remaining
/// count (decremented as emphasis is consumed), and flanking status.
public final class DelimiterRun {
    public let char: Character          // '*' or '_'
    public var count: Int               // remaining delimiter chars (decremented)
    public let originalCount: Int       // original count (for Rule of 3)
    public let canOpen: Bool
    public let canClose: Bool
    public var active: Bool = true      // set to false when removed from stack

    public init(char: Character, count: Int, canOpen: Bool, canClose: Bool) {
        self.char = char
        self.count = count
        self.originalCount = count
        self.canOpen = canOpen
        self.canClose = canClose
    }
}

public enum EmphasisResolver {

    // MARK: - Flanking

    /// Determine whether a delimiter run can open and/or close emphasis.
    /// Implements CommonMark §6.2 flanking rules. Used by Phase A to
    /// stamp `canOpen` / `canClose` on each `DelimiterRun` at construction.
    ///
    /// `*` is permissive (opens iff left-flanking, closes iff right-flanking).
    /// `_` is stricter — to avoid the intra-word use that would otherwise
    /// turn `snake_case_var` into emphasis, an `_` run that is both
    /// left- and right-flanking can only open after punctuation and
    /// only close before punctuation.
    public static func flanking(
        delimChar: Character, before: Character?, after: Character?
    ) -> (canOpen: Bool, canClose: Bool) {
        let beforeIsWhitespace = before == nil || isUnicodeWhitespace(before!)
        let afterIsWhitespace = after == nil || isUnicodeWhitespace(after!)
        let beforeIsPunct = before != nil && isUnicodePunctuation(before!)
        let afterIsPunct = after != nil && isUnicodePunctuation(after!)

        // Left-flanking: not followed by whitespace, AND
        // (not followed by punctuation OR preceded by whitespace/punctuation)
        let leftFlanking = !afterIsWhitespace &&
            (!afterIsPunct || beforeIsWhitespace || beforeIsPunct)

        // Right-flanking: not preceded by whitespace, AND
        // (not preceded by punctuation OR followed by whitespace/punctuation)
        let rightFlanking = !beforeIsWhitespace &&
            (!beforeIsPunct || afterIsWhitespace || afterIsPunct)

        let canOpen: Bool
        let canClose: Bool
        if delimChar == "*" {
            canOpen = leftFlanking
            canClose = rightFlanking
        } else {
            canOpen = leftFlanking && (!rightFlanking || beforeIsPunct)
            canClose = rightFlanking && (!leftFlanking || afterIsPunct)
        }
        return (canOpen, canClose)
    }

    // MARK: - Resolution

    /// Phase B entry point. Walks the token stream and replaces matched
    /// delimiter runs with `.bold` / `.italic` containers per CommonMark
    /// §6.2. Unmatched delimiters fall through as literal `.text`.
    ///
    /// `refDefs` is unused here today; kept in the signature so future
    /// reference-link processing inside emphasized content can be added
    /// without changing the caller.
    public static func resolve(
        _ tokens: [InlineToken],
        refDefs: [String: (url: String, title: String?)]
    ) -> [Inline] {
        // Build a doubly-linked-list-flavored array. Each element is
        // either a resolved Inline, raw text, or a delimiter run that
        // may still be consumed.
        struct Node {
            var token: InlineToken
            var removed: Bool = false
        }
        var nodes = tokens.map { Node(token: $0) }

        // Collect indices of delimiter runs.
        var delimiterIndices: [Int] = []
        for (idx, node) in nodes.enumerated() {
            if case .delimiter = node.token {
                delimiterIndices.append(idx)
            }
        }

        // Process closers: scan left to right for potential closers.
        // For each closer, search backwards for a matching opener.
        var closerDIdx = 0
        while closerDIdx < delimiterIndices.count {
            let closerIdx = delimiterIndices[closerDIdx]
            guard !nodes[closerIdx].removed else {
                closerDIdx += 1
                continue
            }
            guard case .delimiter(let closer) = nodes[closerIdx].token,
                  closer.canClose, closer.active, closer.count > 0 else {
                closerDIdx += 1
                continue
            }

            // Search backwards for a matching opener.
            var foundOpener = false
            var openerDIdx = closerDIdx - 1
            while openerDIdx >= 0 {
                let openerIdx = delimiterIndices[openerDIdx]
                guard !nodes[openerIdx].removed else {
                    openerDIdx -= 1
                    continue
                }
                guard case .delimiter(let opener) = nodes[openerIdx].token,
                      opener.canOpen, opener.active, opener.count > 0,
                      opener.char == closer.char else {
                    openerDIdx -= 1
                    continue
                }

                // Rule of 3: If the closer can open OR the opener can close,
                // and the sum of their original counts is a multiple of 3,
                // and neither original count is a multiple of 3, skip.
                if closer.canOpen || opener.canClose {
                    let sum = opener.originalCount + closer.originalCount
                    if sum % 3 == 0 && opener.originalCount % 3 != 0 && closer.originalCount % 3 != 0 {
                        openerDIdx -= 1
                        continue
                    }
                }

                foundOpener = true
                break
            }

            if !foundOpener {
                // No matching opener found. If this closer can't open
                // either, deactivate it.
                if !closer.canOpen {
                    closer.active = false
                }
                closerDIdx += 1
                continue
            }

            let openerIdx = delimiterIndices[openerDIdx]
            guard case .delimiter(let opener) = nodes[openerIdx].token else {
                closerDIdx += 1
                continue
            }

            // Determine emphasis type: strong if both have >= 2 chars.
            let isStrong = opener.count >= 2 && closer.count >= 2
            let consumed = isStrong ? 2 : 1
            let marker: EmphasisMarker = opener.char == "_" ? .underscore : .asterisk

            // Collect all content between opener and closer into children.
            var children: [Inline] = []
            for k in (openerIdx + 1)..<closerIdx {
                guard !nodes[k].removed else { continue }
                switch nodes[k].token {
                case .text(let s):
                    children.append(.text(s))
                case .inline(let inl):
                    children.append(inl)
                case .delimiter(let run):
                    if run.count > 0 {
                        let s = String(repeating: run.char, count: run.count)
                        children.append(.text(s))
                    }
                }
                nodes[k].removed = true
            }

            // Consume from opener and closer.
            opener.count -= consumed
            closer.count -= consumed

            // Create the emphasis inline.
            let emphInline: Inline =
                isStrong
                ? .bold(children, marker: marker)
                : .italic(children, marker: marker)

            // Replace the content between opener and closer with the
            // emphasis node. Three cases:
            //   1. Opener fully consumed → replace opener slot with emph
            //   2. Opener partially consumed → insert emph in the first
            //      removed slot after opener
            //   3. No slots between (shouldn't happen with valid input
            //      but handle gracefully) → fall back on opener slot.
            if opener.count == 0 {
                nodes[openerIdx] = Node(token: .inline(emphInline))
            } else {
                var inserted = false
                for k in (openerIdx + 1)..<closerIdx {
                    nodes[k] = Node(token: .inline(emphInline))
                    inserted = true
                    break
                }
                if !inserted {
                    if closer.count == 0 {
                        nodes[closerIdx] = Node(token: .inline(emphInline))
                    } else {
                        nodes[openerIdx] = Node(token: .inline(emphInline))
                    }
                }
            }

            // If closer is fully consumed and the slot is still a
            // delimiter (we didn't repurpose it for the emph node),
            // mark it removed.
            if closer.count == 0 {
                if !nodes[closerIdx].removed,
                   case .delimiter = nodes[closerIdx].token {
                    nodes[closerIdx].removed = true
                }
            }

            // Rebuild delimiterIndices to reflect the rewrite.
            delimiterIndices = []
            for (idx, node) in nodes.enumerated() {
                if node.removed { continue }
                if case .delimiter(let run) = node.token, run.count > 0, run.active {
                    delimiterIndices.append(idx)
                }
            }

            // If closer still has remaining count, re-process it.
            if closer.count > 0 {
                if let newCloserDIdx = delimiterIndices.firstIndex(where: {
                    if case .delimiter(let r) = nodes[$0].token {
                        return r === closer
                    }
                    return false
                }) {
                    closerDIdx = newCloserDIdx
                } else {
                    closerDIdx = 0
                }
            } else {
                // Closer fully consumed — advance to the first delimiter
                // after the emphasis we just created.
                closerDIdx = 0
                for (di, idx) in delimiterIndices.enumerated() {
                    if idx > openerIdx {
                        closerDIdx = di
                        break
                    }
                    if di == delimiterIndices.count - 1 {
                        closerDIdx = delimiterIndices.count
                    }
                }
            }
        }

        // Flatten remaining nodes into [Inline].
        var result: [Inline] = []
        for node in nodes {
            guard !node.removed else { continue }
            switch node.token {
            case .text(let s):
                result.append(.text(s))
            case .inline(let inl):
                result.append(inl)
            case .delimiter(let run):
                if run.count > 0 {
                    let s = String(repeating: run.char, count: run.count)
                    result.append(.text(s))
                }
            }
        }

        // Merge adjacent .text nodes for cleanliness.
        var merged: [Inline] = []
        for inl in result {
            if case .text(let s) = inl, let last = merged.last, case .text(let prev) = last {
                merged[merged.count - 1] = .text(prev + s)
            } else {
                merged.append(inl)
            }
        }
        return merged
    }
}

// MARK: - Unicode classification (used by flanking rules)

/// True if `ch` is a Unicode whitespace character per CommonMark.
/// Includes ASCII whitespace + non-breaking space + Unicode Zs.
private func isUnicodeWhitespace(_ ch: Character) -> Bool {
    if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" ||
       ch == "\u{000C}" || ch == "\u{000B}" || ch == "\u{00A0}" {
        return true
    }
    if let scalar = ch.unicodeScalars.first {
        return scalar.properties.generalCategory == .spaceSeparator
    }
    return false
}

/// True if `ch` is a Unicode punctuation character per CommonMark
/// 0.31.2 §6.2: ASCII punctuation, Unicode P* (punctuation), or
/// Unicode S* categories Sc/Sk/Sm/So (the v0.31.2 broadening fixes
/// `*£*bravo.` and similar currency-symbol cases — spec #354).
private func isUnicodePunctuation(_ ch: Character) -> Bool {
    if isASCIIPunctuation(ch) { return true }
    if let scalar = ch.unicodeScalars.first {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .closePunctuation,
             .finalPunctuation, .initialPunctuation, .otherPunctuation,
             .openPunctuation,
             .currencySymbol, .modifierSymbol, .mathSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
    return false
}

private func isASCIIPunctuation(_ ch: Character) -> Bool {
    let punctuation: Set<Character> = [
        "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".",
        "/", ":", ";", "<", "=", ">", "?", "@", "[", "\\", "]", "^", "_",
        "`", "{", "|", "}", "~"
    ]
    return punctuation.contains(ch)
}
