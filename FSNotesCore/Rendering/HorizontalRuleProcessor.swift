//
//  HorizontalRuleProcessor.swift
//  FSNotesCore
//
//  Phase 4 processor for horizontal rules. Sets .horizontalRule marker attribute.
//

import Foundation

public struct HorizontalRuleProcessor: BlockProcessor {
    public init() {}

    public func handles(_ type: MarkdownBlockType) -> Bool {
        if case .horizontalRule = type { return true }
        return false
    }

    public func process(block: MarkdownBlock, textStorage: NSMutableAttributedString, flagProvider: RenderingFlagProvider) {
        textStorage.addAttribute(.horizontalRule, value: true, range: block.range)
    }
}
