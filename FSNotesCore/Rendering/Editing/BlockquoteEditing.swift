//
//  BlockquoteEditing.swift
//  FSNotesCore
//
//  Blockquote-specific editing operations.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum BlockquoteEditing {

    /// where indentN = N spaces per `>` level. We map render offset to
    /// (line index, offset within line's inline content).

    private struct FlatQuoteLine {
        let line: BlockquoteLine
        let lineIndex: Int
        let prefixLength: Int  // visual indent spaces
        let inlineLength: Int
        let startOffset: Int   // offset within block's rendered output
    }

    private static func flattenBlockquote(
        _ lines: [BlockquoteLine]
    ) -> [FlatQuoteLine] {
        var entries: [FlatQuoteLine] = []
        var offset = 0
        for (i, qLine) in lines.enumerated() {
            let prefixLen = 0 // indentation is via paragraph style, no visible characters
            let inlineLen = inlinesLength(qLine.inline)
            entries.append(FlatQuoteLine(
                line: qLine, lineIndex: i,
                prefixLength: prefixLen, inlineLength: inlineLen,
                startOffset: offset
            ))
            offset += prefixLen + inlineLen
            if i < lines.count - 1 { offset += 1 } // "\n"
        }
        return entries
    }

    private static func quoteEntryContaining(
        entries: [FlatQuoteLine],
        offset: Int,
        forInsertion: Bool
    ) -> (entryIndex: Int, inlineOffset: Int)? {
        for (i, entry) in entries.enumerated() {
            let inlineStart = entry.startOffset + entry.prefixLength
            let inlineEnd = inlineStart + entry.inlineLength
            if forInsertion {
                if offset >= inlineStart && offset <= inlineEnd {
                    return (i, offset - inlineStart)
                }
            } else {
                if offset >= inlineStart && offset < inlineEnd {
                    return (i, offset - inlineStart)
                }
            }
        }
        return nil
    }

    private static func insertIntoBlockquote(
        lines: [BlockquoteLine],
        offsetInBlock: Int,
        string: String
    ) throws -> Block {
        let entries = flattenBlockquote(lines)
        guard let (entryIdx, inlineOffset) = quoteEntryContaining(
            entries: entries, offset: offsetInBlock, forInsertion: true
        ) else {
            throw EditingError.unsupported(
                reason: "blockquote: offset \(offsetInBlock) not within editable inline content"
            )
        }
        let entry = entries[entryIdx]
        let newInline: [Inline]
        if entry.line.inline.isEmpty {
            newInline = [.text(string)]
        } else {
            let runs = flatten(entry.line.inline)
            guard let (runIdx, off) = runAtInsertionPoint(runs, offset: inlineOffset) else {
                throw EditingError.unsupported(
                    reason: "blockquote line: offset \(inlineOffset) out of inline bounds"
                )
            }
            let leaf = runs[runIdx]
            let newText = spliceString(leaf.text, at: off, replacing: 0, with: string)
            newInline = updateLeafText(entry.line.inline, at: leaf.path, newText: newText)
        }
        var newLines = lines
        newLines[entryIdx] = BlockquoteLine(prefix: entry.line.prefix, inline: newInline)
        return .blockquote(lines: newLines)
    }

    private static func deleteInBlockquote(
        lines: [BlockquoteLine],
        from fromOffset: Int,
        to toOffset: Int
    ) throws -> Block {
        let length = toOffset - fromOffset
        if length == 0 { return .blockquote(lines: lines) }
        let entries = flattenBlockquote(lines)
        guard let (startEntry, startOff) = quoteEntryContaining(
            entries: entries, offset: fromOffset, forInsertion: false
        ) else {
            throw EditingError.unsupported(
                reason: "blockquote: delete start \(fromOffset) not within editable inline content"
            )
        }
        guard let (endEntry, _) = quoteEntryContaining(
            entries: entries, offset: toOffset - 1, forInsertion: false
        ) else {
            throw EditingError.unsupported(
                reason: "blockquote: delete end \(toOffset - 1) not within editable inline content"
            )
        }
        guard startEntry == endEntry else { throw EditingError.crossInlineRange }
        let entry = entries[startEntry]
        let runs = flatten(entry.line.inline)
        guard let (startRun, startRunOff) = runContainingChar(runs, charIndex: startOff) else {
            throw EditingError.outOfBounds
        }
        let endOff = startOff + length
        guard let (endRun, endRunOff) = runContainingChar(runs, charIndex: endOff - 1) else {
            throw EditingError.outOfBounds
        }
        guard startRun == endRun else { throw EditingError.crossInlineRange }
        let leaf = runs[startRun]
        let newText = spliceString(leaf.text, at: startRunOff, replacing: endRunOff + 1 - startRunOff, with: "")
        let newInline = updateLeafText(entry.line.inline, at: leaf.path, newText: newText)
        var newLines = lines
        newLines[startEntry] = BlockquoteLine(prefix: entry.line.prefix, inline: newInline)
        return .blockquote(lines: newLines)
    }
}

