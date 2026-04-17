//
//  InlineEditing.swift
//  FSNotesCore
//
//  Inline tree navigation and trait toggling.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum InlineEditing {

    typealias InlinePath = [Int]

    /// A leaf inline run: a `.text(...)` or `.code(...)` node carrying
    /// character content, along with its path from the tree root and
    /// whether it is a code span (affects which Inline case we rebuild).
    struct LeafRun {
        let path: InlinePath
        let text: String
        let isCode: Bool
    }

    /// Flatten an inline tree to its sequence of leaf runs, in render
    /// order. Containers (`.bold`, `.italic`) contribute no characters
    /// of their own — only their descendants do.
    private static func flatten(_ inlines: [Inline]) -> [LeafRun] {
        var runs: [LeafRun] = []
        var path: InlinePath = []
        walkFlatten(inlines, path: &path, into: &runs)
        return runs
    }

    private static func walkFlatten(
        _ inlines: [Inline],
        path: inout InlinePath,
        into runs: inout [LeafRun]
    ) {
        for (i, node) in inlines.enumerated() {
            path.append(i)
            switch node {
            case .text(let s):
                runs.append(LeafRun(path: path, text: s, isCode: false))
            case .code(let s):
                runs.append(LeafRun(path: path, text: s, isCode: true))
            case .bold(let children, _):
                walkFlatten(children, path: &path, into: &runs)
            case .italic(let children, _):
                walkFlatten(children, path: &path, into: &runs)
            case .strikethrough(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .underline(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .highlight(let children):
                walkFlatten(children, path: &path, into: &runs)
            case .math(let s):
                runs.append(LeafRun(path: path, text: s, isCode: true))
            case .displayMath(let s):
                runs.append(LeafRun(path: path, text: s, isCode: true))
            case .link(let text, _):
                walkFlatten(text, path: &path, into: &runs)
            case .image(let alt, _, _):
                walkFlatten(alt, path: &path, into: &runs)
            case .autolink(let text, _):
                runs.append(LeafRun(path: path, text: text, isCode: false))
            case .escapedChar(let ch):
                runs.append(LeafRun(path: path, text: String(ch), isCode: false))
            case .lineBreak:
                runs.append(LeafRun(path: path, text: "\n", isCode: false))
            case .rawHTML(let html):
                runs.append(LeafRun(path: path, text: html, isCode: false))
            case .entity(let raw):
                runs.append(LeafRun(path: path, text: raw, isCode: false))
            case .wikilink(let target, let display):
                // Wikilinks are atomic from the editor's perspective —
                // emit a single leaf run with the visible text so the
                // run-based insertion machinery can position the cursor
                // at the wikilink's edges (but not inside).
                runs.append(LeafRun(path: path, text: display ?? target, isCode: false))
            }
            path.removeLast()
        }
    }

    /// Locate an INSERTION POINT at render offset `offset` within
    /// `runs`. At a run boundary, prefers the EARLIER run (so typing
    /// at offset == end-of-run-i lands at the end of run i, not the
    /// start of run i+1). This matches the editor invariant that the
    /// insertion point belongs to the run whose last character was
    /// just rendered.
    private static func runAtInsertionPoint(
        _ runs: [LeafRun],
        offset: Int
    ) -> (runIndex: Int, offsetInRun: Int)? {
        if runs.isEmpty { return nil }
        var acc = 0
        for (i, run) in runs.enumerated() {
            let end = acc + run.text.count
            if offset >= acc && offset <= end {
                return (i, offset - acc)
            }
            acc = end
        }
        return nil
    }

    /// Locate the run that OWNS the rendered character at index
    /// `charIndex` (strict less-than upper bound). Used for delete
    /// ranges [from, to): each character is owned by exactly one run.
    private static func runContainingChar(
        _ runs: [LeafRun],
        charIndex: Int
    ) -> (runIndex: Int, offsetInRun: Int)? {
        if charIndex < 0 { return nil }
        var acc = 0
        for (i, run) in runs.enumerated() {
            let end = acc + run.text.count
            if charIndex >= acc && charIndex < end {
                return (i, charIndex - acc)
            }
            acc = end
        }
        return nil
    }

    /// Rebuild an inline tree with the leaf at `path` replaced by a
    /// new text value. The Inline case (`.text` vs `.code`) at the
    /// leaf is preserved.
    private static func updateLeafText(
        _ inlines: [Inline],
        at path: InlinePath,
        newText: String
    ) -> [Inline] {
        guard let first = path.first else { return inlines }
        let rest = Array(path.dropFirst())
        var out = inlines
        out[first] = replaceLeafText(in: inlines[first], path: rest, newText: newText)
        return out
    }

    private static func replaceLeafText(
        in inline: Inline,
        path: InlinePath,
        newText: String
    ) -> Inline {
        if path.isEmpty {
            switch inline {
            case .text: return .text(newText)
            case .code: return .code(newText)
            case .math: return .math(newText)
            case .displayMath: return .displayMath(newText)
            case .autolink: return .text(newText)
            case .escapedChar: return .text(newText)
            case .lineBreak: return .text(newText)
            case .rawHTML: return .rawHTML(newText)
            case .entity: return .entity(newText)
            case .wikilink: return .text(newText)
            case .bold, .italic, .strikethrough, .underline, .highlight, .link, .image, .math, .displayMath:
                // Path exhausted on a container: should not happen
                // when paths come from `flatten`. Leave unchanged.
                return inline
            }
        }
        let idx = path.first!
        let rest = Array(path.dropFirst())
        switch inline {
        case .text, .code, .math, .displayMath, .autolink, .escapedChar, .lineBreak, .rawHTML, .entity, .wikilink:
            // Cannot descend into a leaf.
            return inline
        case .bold(let children, let marker):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .bold(c, marker: marker)
        case .italic(let children, let marker):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .italic(c, marker: marker)
        case .strikethrough(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .strikethrough(c)
        case .underline(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .underline(c)
        case .highlight(let children):
            var c = children
            c[idx] = replaceLeafText(in: children[idx], path: rest, newText: newText)
            return .highlight(c)
        case .link(let text, let dest):
            var c = text
            c[idx] = replaceLeafText(in: text[idx], path: rest, newText: newText)
            return .link(text: c, rawDestination: dest)
        case .image(let alt, let dest, let width):
            var c = alt
            c[idx] = replaceLeafText(in: alt[idx], path: rest, newText: newText)
            return .image(alt: c, rawDestination: dest, width: width)
        }
    }


    // MARK: - Inline trait toggle internals
    private static func toggleTraitOnInlines(
        _ inlines: [Inline],
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        // Check if the entire [from, to) range is already inside the
        // target trait. This is approximate: we check if ALL leaf runs
        // in the range share a common ancestor of the target trait type.
        let runs = flatten(inlines)
        let coveredRuns = runsInRange(runs, from: from, to: to)

        if !coveredRuns.isEmpty && allRunsInsideTrait(coveredRuns, trait: trait, in: inlines) {
            // Unwrap: remove the trait wrapper.
            return unwrapTrait(inlines, trait: trait, from: from, to: to)
        }

        // Wrap: split at boundaries and insert trait wrapper.
        return wrapTrait(inlines, trait: trait, from: from, to: to)
    }

    /// Find which leaf runs overlap [from, to).
    private static func runsInRange(
        _ runs: [LeafRun],
        from: Int,
        to: Int
    ) -> [(index: Int, run: LeafRun)] {
        var result: [(index: Int, run: LeafRun)] = []
        var acc = 0
        for (i, run) in runs.enumerated() {
            let runEnd = acc + run.text.count
            if acc < to && runEnd > from {
                result.append((i, run))
            }
            acc = runEnd
        }
        return result
    }

    /// Check if all runs have a parent of the given trait type in their
    /// path within the inline tree, or are themselves that trait (for code).
    private static func allRunsInsideTrait(
        _ runs: [(index: Int, run: LeafRun)],
        trait: InlineTrait,
        in inlines: [Inline]
    ) -> Bool {
        for (_, run) in runs {
            // Code is a leaf, not a container — check the leaf itself.
            if trait == .code {
                if !run.isCode { return false }
            } else {
                if !pathContainsTrait(run.path, trait: trait, in: inlines) {
                    return false
                }
            }
        }
        return true
    }

    /// Check if any node along the path (including the leaf) is the given trait.
    private static func pathContainsTrait(
        _ path: InlinePath,
        trait: InlineTrait,
        in inlines: [Inline]
    ) -> Bool {
        var current: [Inline] = inlines
        for (depth, idx) in path.enumerated() {
            guard idx < current.count else { return false }
            let node = current[idx]
            // Check if this node IS the trait (at any depth, including leaf).
            switch (node, trait) {
            case (.bold, .bold): return true
            case (.italic, .italic): return true
            case (.strikethrough, .strikethrough): return true
            case (.underline, .underline): return true
            case (.highlight, .highlight): return true
            default: break
            }
            // Descend into interior nodes.
            if depth < path.count - 1 {
                switch node {
                case .bold(let c, _): current = c
                case .italic(let c, _): current = c
                case .strikethrough(let c): current = c
                case .underline(let c): current = c
                case .highlight(let c): current = c
                case .link(let text, _): current = text
                case .image(let alt, _, _): current = alt
                default: return false
                }
            }
        }
        return false
    }

    /// Wrap a subrange [from, to) in a trait. Splits at boundaries.
    private static func wrapTrait(
        _ inlines: [Inline],
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        let (before, rest) = splitInlines(inlines, at: from)
        let middleLength = to - from
        let (middle, after) = splitInlines(rest, at: middleLength)

        let wrapped: Inline
        switch trait {
        case .bold:          wrapped = .bold(middle, marker: .asterisk)
        case .italic:        wrapped = .italic(middle, marker: .asterisk)
        case .strikethrough: wrapped = .strikethrough(middle)
        case .underline:     wrapped = .underline(middle)
        case .highlight:     wrapped = .highlight(middle)
        case .code:
            // Code wrapping: flatten the middle to plain text.
            let text = middle.map { inlineToText($0) }.joined()
            wrapped = .code(text)
        }

        return cleanInlines(before + [wrapped] + after)
    }

    /// Unwrap a trait from a subrange. This is the inverse of wrap.
    private static func unwrapTrait(
        _ inlines: [Inline],
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        // Strategy: rebuild the inline tree, and for any trait node
        // of the target type whose content overlaps [from, to),
        // replace it with its children (i.e., remove the wrapper).
        var acc = 0
        var result: [Inline] = []
        for node in inlines {
            let nodeLen = inlineLength(node)
            let nodeStart = acc
            let nodeEnd = acc + nodeLen

            if nodeStart >= from && nodeEnd <= to {
                // Fully inside the selection.
                switch (node, trait) {
                case (.bold(let children, _), .bold):
                    result.append(contentsOf: children)
                case (.italic(let children, _), .italic):
                    result.append(contentsOf: children)
                case (.strikethrough(let children), .strikethrough):
                    result.append(contentsOf: children)
                case (.underline(let children), .underline):
                    result.append(contentsOf: children)
                case (.highlight(let children), .highlight):
                    result.append(contentsOf: children)
                case (.code(let s), .code):
                    result.append(.text(s))
                default:
                    // Different trait or leaf — recurse if container.
                    result.append(contentsOf: unwrapTraitInNode(node, trait: trait, from: from - nodeStart, to: to - nodeStart))
                }
            } else if nodeEnd > from && nodeStart < to {
                // Partially overlaps — recurse into children.
                result.append(contentsOf: unwrapTraitInNode(node, trait: trait, from: from - nodeStart, to: to - nodeStart))
            } else {
                // Outside selection — keep unchanged.
                result.append(node)
            }
            acc = nodeEnd
        }
        return cleanInlines(result)
    }

    /// Unwrap a trait within a single inline node that partially overlaps
    /// the selection [from, to).
    ///
    /// When the node's own trait matches the target, we split the children
    /// into three segments:
    ///   1. [0, from)  — stays wrapped in the trait
    ///   2. [from, to) — unwrapped (trait removed)
    ///   3. [to, end)  — stays wrapped in the trait
    ///
    /// When the node's trait doesn't match, we recurse into children
    /// preserving the wrapper.
    private static func unwrapTraitInNode(
        _ node: Inline,
        trait: InlineTrait,
        from: Int,
        to: Int
    ) -> [Inline] {
        let clampedFrom = max(from, 0)

        switch node {
        case .bold(let children, let marker):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .bold {
                return splitAndUnwrap(children, wrapWith: { .bold($0, marker: marker) }, from: clampedFrom, to: clampedTo)
            }
            return [.bold(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo), marker: marker)]
        case .italic(let children, let marker):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .italic {
                return splitAndUnwrap(children, wrapWith: { .italic($0, marker: marker) }, from: clampedFrom, to: clampedTo)
            }
            return [.italic(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo), marker: marker)]
        case .strikethrough(let children):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .strikethrough {
                return splitAndUnwrap(children, wrapWith: { .strikethrough($0) }, from: clampedFrom, to: clampedTo)
            }
            return [.strikethrough(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo))]
        case .underline(let children):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .underline {
                return splitAndUnwrap(children, wrapWith: { .underline($0) }, from: clampedFrom, to: clampedTo)
            }
            return [.underline(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo))]
        case .highlight(let children):
            let len = inlinesLength(children)
            let clampedTo = min(to, len)
            if trait == .highlight {
                return splitAndUnwrap(children, wrapWith: { .highlight($0) }, from: clampedFrom, to: clampedTo)
            }
            return [.highlight(unwrapTrait(children, trait: trait, from: clampedFrom, to: clampedTo))]
        case .link(let text, let dest):
            let len = inlinesLength(text)
            let clampedTo = min(to, len)
            return [.link(text: unwrapTrait(text, trait: trait, from: clampedFrom, to: clampedTo), rawDestination: dest)]
        case .image(let alt, let dest, let width):
            let len = inlinesLength(alt)
            let clampedTo = min(to, len)
            return [.image(alt: unwrapTrait(alt, trait: trait, from: clampedFrom, to: clampedTo), rawDestination: dest, width: width)]
        case .text, .code, .math, .displayMath, .autolink, .escapedChar, .lineBreak, .rawHTML, .entity, .wikilink:
            return [node]
        }
    }

    /// Split children at [from, to), keeping the portions outside the
    /// range wrapped via `wrapWith` and leaving the inside unwrapped.
    private static func splitAndUnwrap(
        _ children: [Inline],
        wrapWith: ([Inline]) -> Inline,
        from: Int,
        to: Int
    ) -> [Inline] {
        var result: [Inline] = []
        let len = inlinesLength(children)

        // Part before selection — stays wrapped
        if from > 0 {
            let (beforePart, _) = splitInlines(children, at: from)
            let cleaned = cleanInlines(beforePart)
            if !cleaned.isEmpty {
                result.append(wrapWith(cleaned))
            }
        }

        // Part inside selection — unwrapped (trait removed)
        let innerStart = max(from, 0)
        let innerEnd = min(to, len)
        if innerStart < innerEnd {
            let (_, afterStart) = splitInlines(children, at: innerStart)
            let (middle, _) = splitInlines(afterStart, at: innerEnd - innerStart)
            let cleaned = cleanInlines(middle)
            result.append(contentsOf: cleaned)
        }

        // Part after selection — stays wrapped
        if to < len {
            let (_, afterPart) = splitInlines(children, at: to)
            let cleaned = cleanInlines(afterPart)
            if !cleaned.isEmpty {
                result.append(wrapWith(cleaned))
            }
        }

        return result
    }

    /// Remove empty text nodes and merge adjacent text nodes.
    private static func cleanInlines(_ inlines: [Inline]) -> [Inline] {
        var result: [Inline] = []
        for node in inlines {
            switch node {
            case .text(let s):
                if s.isEmpty { continue }
                if case .text(let prev) = result.last {
                    result[result.count - 1] = .text(prev + s)
                } else {
                    result.append(node)
                }
            case .code(let s):
                if s.isEmpty { continue }
                result.append(node)
            case .math(let s):
                if s.isEmpty { continue }
                result.append(node)
            case .displayMath(let s):
                if s.isEmpty { continue }
                result.append(node)
            case .bold(let children, let marker):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.bold(cleaned, marker: marker))
            case .italic(let children, let marker):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.italic(cleaned, marker: marker))
            case .strikethrough(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.strikethrough(cleaned))
            case .underline(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.underline(cleaned))
            case .highlight(let children):
                let cleaned = cleanInlines(children)
                if cleaned.isEmpty { continue }
                result.append(.highlight(cleaned))
            case .link(let text, let dest):
                let cleaned = cleanInlines(text)
                if cleaned.isEmpty { continue }
                result.append(.link(text: cleaned, rawDestination: dest))
            case .image(let alt, let dest, let width):
                let cleaned = cleanInlines(alt)
                if cleaned.isEmpty { continue }
                result.append(.image(alt: cleaned, rawDestination: dest, width: width))
            case .autolink(let text, _):
                if text.isEmpty { continue }
                result.append(node)
            case .escapedChar:
                result.append(node)
            case .lineBreak:
                result.append(node)
            case .rawHTML(let html):
                if html.isEmpty { continue }
                result.append(node)
            case .entity(let raw):
                if raw.isEmpty { continue }
                result.append(node)
            case .wikilink(let target, _):
                if target.isEmpty { continue }
                result.append(node)
            }
        }
        return result
    }

    /// Simple inline parser: treats the string as plain text (no inline
    /// formatting). Used when converting headings to paragraphs or vice
    /// versa, where the suffix is a raw string.
    private static func parseInlinesFromText(_ text: String) -> [Inline] {
        if text.isEmpty { return [] }
        return [.text(text)]
    }
}

