//
//  BlockquoteProcessor.swift
//  FSNotesCore
//
//  Phase 4 processor for blockquotes. Counts > depth per line,
//  sets .blockquote attribute with Int depth for LayoutManager border drawing.
//

import Foundation

public struct BlockquoteProcessor: BlockProcessor {
    public init() {}

    public func handles(_ type: MarkdownBlockType) -> Bool {
        if case .blockquote = type { return true }
        return false
    }

    public func process(block: MarkdownBlock, textStorage: NSMutableAttributedString, flagProvider: RenderingFlagProvider) {
        let nsStr = textStorage.string as NSString
        var lineStart = block.range.location
        let blockEnd = NSMaxRange(block.range)

        while lineStart < blockEnd {
            let lineRange = nsStr.paragraphRange(for: NSRange(location: lineStart, length: 0))
            let line = nsStr.substring(with: lineRange).trimmingCharacters(in: .newlines)
            var depth = 0
            for ch in line {
                if ch == ">" { depth += 1 }
                else if ch == " " { continue }
                else { break }
            }
            if depth > 0 {
                let charRange = NSIntersectionRange(lineRange, block.range)
                if charRange.length > 0 {
                    textStorage.addAttribute(.blockquote, value: depth, range: charRange)
                }
            }
            lineStart = NSMaxRange(lineRange)
            if lineStart <= lineRange.location { break }
        }
    }
}
