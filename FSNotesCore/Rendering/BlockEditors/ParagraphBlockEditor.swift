//
//  ParagraphBlockEditor.swift
//  FSNotesCore
//
//  Phase 12.B.1 — Per-block-kind dispatch (paragraph kind).
//
//  First vertical slice of the `BlockEditor` protocol introduced in
//  Phase 12. The `.paragraph` cases in `EditingOps.insertIntoBlock` /
//  `deleteInBlock` / `replaceInBlock` (formerly inline switch arms,
//  ~80 LoC collectively) are extracted here so paragraph editing logic
//  has a single, independently-testable home.
//
//  The 8 inline-tree helpers this editor depends on (`containsImage`,
//  `splitInlines`, `flatten`, `runContainingChar`, `updateLeafText`,
//  `spliceString`, `insertInlinesPreservingContainerContext`,
//  `cleanInlines`) were widened from `private static` to `static` (i.e.
//  module-internal) as part of this slice — they're pure, side-effect-
//  free helpers, so the visibility widening doesn't introduce any new
//  contract risk.
//
//  Subsequent slices (12.B.2 → 12.B.7) will extract heading, codeBlock,
//  blankLine, htmlBlock, table, list, blockquote in turn.
//

import Foundation

#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// In-block editor for the `.paragraph` block kind. Stateless — all
/// methods are pure functions on `Block.paragraph` values.
public enum ParagraphBlockEditor: BlockEditor {

    /// Insert `string` at `offsetInBlock` into a paragraph block.
    ///
    /// Three control-flow branches:
    ///   1. Empty paragraph at offset 0: replace with a single `.text`
    ///      run carrying the inserted string.
    ///   2. Paragraph contains an image (a length-1 atomic inline that
    ///      `flatten` skips over): use `splitInlines` to cut the tree
    ///      at the offset, then splice the new text between the halves.
    ///   3. Otherwise: use `insertInlinesPreservingContainerContext` to
    ///      honour fence semantics (insertion at end-of-bold produces a
    ///      sibling, mid-bold extends the bold span — see that helper).
    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .paragraph(let inline) = block else {
            #if DEBUG
            assertionFailure("ParagraphBlockEditor.insert: block is not .paragraph (\(block))")
            #endif
            throw EditingError.unsupported(reason: "ParagraphBlockEditor.insert called with non-paragraph block")
        }

        if inline.isEmpty {
            guard offsetInBlock == 0 else {
                throw EditingError.unsupported(
                    reason: "paragraph: offset \(offsetInBlock) beyond empty paragraph"
                )
            }
            return .paragraph(inline: [.text(string)])
        }

        if EditingOps.containsImage(inline) {
            let (before, after) = EditingOps.splitInlines(inline, at: offsetInBlock)
            let newInline = before + [.text(string)] + after
            return .paragraph(inline: newInline)
        }

        let newInline = EditingOps.insertInlinesPreservingContainerContext(
            inline, at: offsetInBlock, inserting: [.text(string)]
        )
        return .paragraph(inline: newInline)
    }

    /// Delete characters [`fromOffset`, `toOffset`) from a paragraph.
    ///
    /// Two paths:
    ///   - Image-containing paragraph: `splitInlines` at both
    ///     boundaries, drop the middle.
    ///   - Pure-text paragraph: locate the leaf run via `flatten` +
    ///     `runContainingChar`, splice out the substring within that
    ///     leaf. Cross-leaf deletes throw `crossInlineRange` (callers
    ///     fall back to a wider `replace`-style splice).
    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .paragraph(let inline) = block else {
            #if DEBUG
            assertionFailure("ParagraphBlockEditor.delete: block is not .paragraph (\(block))")
            #endif
            throw EditingError.unsupported(reason: "ParagraphBlockEditor.delete called with non-paragraph block")
        }

        let length = toOffset - fromOffset
        if length == 0 { return block }

        if EditingOps.containsImage(inline) {
            let (before, _) = EditingOps.splitInlines(inline, at: fromOffset)
            let (_, after) = EditingOps.splitInlines(inline, at: toOffset)
            let newInline = before + after
            return .paragraph(inline: newInline)
        }

        let runs = EditingOps.flatten(inline)
        guard let (startRun, startOff) = EditingOps.runContainingChar(runs, charIndex: fromOffset) else {
            throw EditingError.outOfBounds
        }
        guard let (endRun, endOffInclusive) = EditingOps.runContainingChar(runs, charIndex: toOffset - 1) else {
            throw EditingError.outOfBounds
        }
        if startRun != endRun {
            throw EditingError.crossInlineRange
        }
        let leaf = runs[startRun]
        let endExclusive = endOffInclusive + 1
        let newText = EditingOps.spliceString(
            leaf.text, at: startOff, replacing: endExclusive - startOff, with: ""
        )
        let newInline = EditingOps.updateLeafText(inline, at: leaf.path, newText: newText)
        return .paragraph(inline: newInline)
    }

    /// Replace characters [`fromOffset`, `toOffset`) with `replacement`
    /// in a paragraph. Three branches mirror `insert` + `delete`, plus
    /// a cross-inline path that tolerates selections spanning multiple
    /// formatting runs (the cross-leaf case `delete` throws on).
    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .paragraph(let inline) = block else {
            #if DEBUG
            assertionFailure("ParagraphBlockEditor.replace: block is not .paragraph (\(block))")
            #endif
            throw EditingError.unsupported(reason: "ParagraphBlockEditor.replace called with non-paragraph block")
        }

        if inline.isEmpty {
            return .paragraph(inline: [.text(replacement)])
        }
        if EditingOps.containsImage(inline) {
            let (before, _) = EditingOps.splitInlines(inline, at: fromOffset)
            let (_, after) = EditingOps.splitInlines(inline, at: toOffset)
            return .paragraph(inline: before + [.text(replacement)] + after)
        }
        let runs = EditingOps.flatten(inline)
        guard let (startRun, startOff) = EditingOps.runContainingChar(runs, charIndex: fromOffset) else {
            throw EditingError.outOfBounds
        }
        guard let (endRun, endOffInclusive) = EditingOps.runContainingChar(runs, charIndex: toOffset - 1) else {
            throw EditingError.outOfBounds
        }
        if startRun == endRun {
            // Within a single leaf — splice in place, preserving formatting context.
            let leaf = runs[startRun]
            let endExclusive = endOffInclusive + 1
            let newText = EditingOps.spliceString(
                leaf.text, at: startOff, replacing: endExclusive - startOff, with: replacement
            )
            let newInline = EditingOps.updateLeafText(inline, at: leaf.path, newText: newText)
            return .paragraph(inline: newInline)
        }
        // Cross-inline selection: cut at both boundaries and splice the
        // replacement into the first half's formatting context.
        let (before, _) = EditingOps.splitInlines(inline, at: fromOffset)
        let (_, after) = EditingOps.splitInlines(inline, at: toOffset)
        return .paragraph(inline: EditingOps.cleanInlines(before + [.text(replacement)] + after))
    }
}
