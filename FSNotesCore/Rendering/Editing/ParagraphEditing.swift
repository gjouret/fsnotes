//
//  ParagraphEditing.swift
//  FSNotesCore
//
//  Paragraph operations and block-split primitives.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum ParagraphEditing {

    /// BETWEEN the two halves so the parser re-reads them as two
    /// distinct paragraphs on round-trip (two adjacent non-blank
    /// lines would be joined into a single paragraph otherwise).
    /// Container formatting (bold / italic) is preserved on both
    /// sides of the split: splitting inside `bold([text("hello")])`
    /// at offset 2 yields `bold([text("he")])` before and
    /// `bold([text("llo")])` after.
    ///
    /// When one half is empty (split at the paragraph's start or
    /// end) the empty paragraph is replaced by a `blankLine` — an
    /// empty paragraph has no canonical markdown form, but a blank
    /// line does.
    private static func splitParagraphOnNewline(
        inline: [Inline],
        at offset: Int
    ) -> [Block] {
        let (before, after) = splitInlines(inline, at: offset)
        let beforeEmpty = isInlineEmpty(before)
        let afterEmpty = isInlineEmpty(after)
        switch (beforeEmpty, afterEmpty) {
        case (true, true):
            return [.blankLine, .blankLine]
        case (true, false):
            return [.blankLine, .paragraph(inline: after)]
        case (false, true):
            return [.paragraph(inline: before), .blankLine]
        case (false, false):
            return [.paragraph(inline: before), .blankLine, .paragraph(inline: after)]
        }
    }

    /// Whether an inline tree renders to zero characters (empty list
    /// or a tree containing only empty leaves / containers of empty
    /// leaves).
    private static func isInlineEmpty(_ inline: [Inline]) -> Bool {
        return inline.allSatisfy { inlineLength($0) == 0 }
    }

    /// Total render length of an inline node (sum of leaf character
    /// counts; containers contribute no characters of their own).
    private static func inlineLength(_ node: Inline) -> Int {
        switch node {
        case .text(let s): return s.count
        case .code(let s): return s.count
        case .bold(let c, _): return c.reduce(0) { $0 + inlineLength($1) }
        case .italic(let c, _): return c.reduce(0) { $0 + inlineLength($1) }
        case .strikethrough(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .underline(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .highlight(let c): return c.reduce(0) { $0 + inlineLength($1) }
        case .math(let s): return s.count
        case .displayMath(let s): return s.count
        case .link(let text, _): return text.reduce(0) { $0 + inlineLength($1) }
        // Images render as EXACTLY one character (the NSTextAttachment
        // placeholder emitted by InlineRenderer, both for the native
        // attachment path and for the fallback). The alt text is NOT
        // rendered inline — it only survives in the round-trip markdown
        // and the attachment title. Returning the alt length here would
        // make an image-only paragraph look empty to splitInlines /
        // isInlineEmpty, which would in turn cause Return after an image
        // to replace the whole paragraph with blank lines and destroy
        // the image. Keep this in lock-step with InlineRenderer.
        case .image: return 1
        case .autolink(let text, _): return text.count
        case .escapedChar: return 1
        case .lineBreak: return 1
        case .rawHTML(let html): return html.count
        case .entity(let raw): return raw.count
        case .wikilink(let target, let display):
            return (display ?? target).count
        }
    }

    /// Whether an inline tree contains any `.image` atom at any depth.
    /// Paragraphs containing images must be edited via splitInlines-based
    /// splicing (not the flatten/runs path) because flatten() emits no
    /// leaf run for atomic image nodes, so `runAtInsertionPoint` cannot
    /// find an insertion slot at the image boundary.
    private static func containsImage(_ inlines: [Inline]) -> Bool {
        for node in inlines {
            switch node {
            case .image:
                return true
            case .bold(let c, _):
                if containsImage(c) { return true }
            case .italic(let c, _):
                if containsImage(c) { return true }
            case .strikethrough(let c):
                if containsImage(c) { return true }
            case .link(let c, _):
                if containsImage(c) { return true }
            default:
                break
            }
        }
        return false
    }

    /// Split a list of inline nodes at render offset `offset`, returning
    /// (before, after). Containers straddling the split point are
    /// recursively split and REPRODUCED on both sides.
    // Made internal for use by autoConvertParagraph and trimLeadingText.
    static func splitInlines(
        _ inlines: [Inline],
        at offset: Int
    ) -> ([Inline], [Inline]) {
        var before: [Inline] = []
        var after: [Inline] = []
        var acc = 0
        for node in inlines {
            let nodeLen = inlineLength(node)
            if offset >= acc + nodeLen {
                // Entirely before the split.
                before.append(node)
            } else if offset <= acc {
                // Entirely after the split.
                after.append(node)
            } else {
                // Split within this node.
                let localOffset = offset - acc
                switch node {
                case .text(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.text(String(s[..<idx])))
                    after.append(.text(String(s[idx...])))
                case .code(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.code(String(s[..<idx])))
                    after.append(.code(String(s[idx...])))
                case .bold(let children, let marker):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.bold(b, marker: marker))
                    after.append(.bold(a, marker: marker))
                case .italic(let children, let marker):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.italic(b, marker: marker))
                    after.append(.italic(a, marker: marker))
                case .strikethrough(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.strikethrough(b))
                    after.append(.strikethrough(a))
                case .underline(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.underline(b))
                    after.append(.underline(a))
                case .highlight(let children):
                    let (b, a) = splitInlines(children, at: localOffset)
                    before.append(.highlight(b))
                    after.append(.highlight(a))
                case .math(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.math(String(s[..<idx])))
                    after.append(.math(String(s[idx...])))
                case .displayMath(let s):
                    let idx = s.index(s.startIndex, offsetBy: localOffset)
                    before.append(.displayMath(String(s[..<idx])))
                    after.append(.displayMath(String(s[idx...])))
                case .link(let text, let dest):
                    let (b, a) = splitInlines(text, at: localOffset)
                    before.append(.link(text: b, rawDestination: dest))
                    after.append(.link(text: a, rawDestination: dest))
                case .image:
                    // Images are length-1 atoms — splitInlines can never
                    // enter this branch (it's only reached when the split
                    // point is STRICTLY inside a node, and a length-1
                    // node is either entirely before or entirely after).
                    // Keep the case for exhaustiveness; treat as "before"
                    // defensively so we never drop the image.
                    before.append(node)
                case .autolink(let text, _):
                    let idx = text.index(text.startIndex, offsetBy: localOffset)
                    before.append(.text(String(text[..<idx])))
                    after.append(.text(String(text[idx...])))
                case .rawHTML(let html):
                    let idx = html.index(html.startIndex, offsetBy: localOffset)
                    before.append(.rawHTML(String(html[..<idx])))
                    after.append(.rawHTML(String(html[idx...])))
                case .entity(let raw):
                    let idx = raw.index(raw.startIndex, offsetBy: localOffset)
                    before.append(.text(String(raw[..<idx])))
                    after.append(.text(String(raw[idx...])))
                case .escapedChar, .lineBreak:
                    // Length 1 — cannot be split within; goes entirely before or after.
                    // Since localOffset > 0 and nodeLen == 1, localOffset == 1 == nodeLen,
                    // which means offset >= acc + nodeLen, handled above. This is unreachable.
                    before.append(node)
                case .wikilink(let target, let display):
                    // Wikilinks are atomic: split at a wikilink's interior
                    // would produce two half-targets. Treat as before/after
                    // boundary like images.
                    let visible = display ?? target
                    let idx = visible.index(visible.startIndex, offsetBy: localOffset)
                    let leftStr = String(visible[..<idx])
                    let rightStr = String(visible[idx...])
                    before.append(.text(leftStr))
                    after.append(.text(rightStr))
                    _ = target
                }
            }
            acc += nodeLen
        }
        return (before, after)
    }
}

