//
//  HeadingBlockEditor.swift
//  FSNotesCore
//
//  Phase 12.B.2 — Per-block-kind dispatch (heading kind).
//
//  Render-offset semantics: `HeadingRenderer` strips ONLY leading
//  whitespace from the suffix; trailing whitespace is rendered
//  verbatim. So render offset `o` corresponds to suffix offset
//  `o + leading`, and the displayed count is `suffix.count - leading`.
//  Keeping trailing whitespace in the rendered length is what lets
//  the user type a trailing space into a heading without stranding
//  the cursor.
//
//  Edge case (insert): an "empty heading" (just whitespace in the
//  suffix) has `displayedCount <= 0`. Any insert into this heading
//  should land after the leading whitespace — that becomes the
//  heading's first visible text.
//

import Foundation

#if os(OSX)
import AppKit
#else
import UIKit
#endif

/// In-block editor for the `.heading(level:, suffix:)` block kind.
public enum HeadingBlockEditor: BlockEditor {

    public static func insert(
        into block: Block, offsetInBlock: Int, string: String
    ) throws -> Block {
        guard case .heading(let level, let suffix) = block else {
            #if DEBUG
            assertionFailure("HeadingBlockEditor.insert: block is not .heading (\(block))")
            #endif
            throw EditingError.unsupported(reason: "HeadingBlockEditor.insert called with non-heading block")
        }

        let leading = EditingOps.leadingWhitespaceCount(in: suffix)
        let displayedCount = suffix.count - leading

        // Empty heading (whitespace-only suffix): insertion lands after
        // the leading whitespace so it becomes the first visible text.
        if displayedCount <= 0 {
            let newSuffix = EditingOps.spliceString(
                suffix, at: leading, replacing: 0, with: string
            )
            return .heading(level: level, suffix: newSuffix)
        }

        guard offsetInBlock >= 0, offsetInBlock <= displayedCount else {
            throw EditingError.unsupported(
                reason: "heading: offset \(offsetInBlock) out of displayed range [0, \(displayedCount)]"
            )
        }
        let suffixOffset = offsetInBlock + leading
        let newSuffix = EditingOps.spliceString(
            suffix, at: suffixOffset, replacing: 0, with: string
        )
        return .heading(level: level, suffix: newSuffix)
    }

    public static func delete(
        in block: Block, from fromOffset: Int, to toOffset: Int
    ) throws -> Block {
        guard case .heading(let level, let suffix) = block else {
            #if DEBUG
            assertionFailure("HeadingBlockEditor.delete: block is not .heading (\(block))")
            #endif
            throw EditingError.unsupported(reason: "HeadingBlockEditor.delete called with non-heading block")
        }

        let length = toOffset - fromOffset
        let leading = EditingOps.leadingWhitespaceCount(in: suffix)
        let displayedCount = suffix.count - leading
        guard fromOffset >= 0, toOffset <= displayedCount, fromOffset <= toOffset else {
            throw EditingError.unsupported(
                reason: "heading: delete range [\(fromOffset), \(toOffset)] out of displayed [0, \(displayedCount)]"
            )
        }
        let suffixFrom = fromOffset + leading
        let newSuffix = EditingOps.spliceString(suffix, at: suffixFrom, replacing: length, with: "")
        return .heading(level: level, suffix: newSuffix)
    }

    public static func replace(
        in block: Block, from fromOffset: Int, to toOffset: Int, with replacement: String
    ) throws -> Block {
        guard case .heading(let level, let suffix) = block else {
            #if DEBUG
            assertionFailure("HeadingBlockEditor.replace: block is not .heading (\(block))")
            #endif
            throw EditingError.unsupported(reason: "HeadingBlockEditor.replace called with non-heading block")
        }
        let length = toOffset - fromOffset
        let leading = EditingOps.leadingWhitespaceCount(in: suffix)
        let suffixFrom = fromOffset + leading
        let newSuffix = EditingOps.spliceString(suffix, at: suffixFrom, replacing: length, with: replacement)
        return .heading(level: level, suffix: newSuffix)
    }
}
