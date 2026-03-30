//
//  BlockProcessor.swift
//  FSNotesCore
//
//  Protocol for Phase 4 block-level processing.
//  Each processor handles one or more block types.
//  Adding a new block visual = one new file implementing this protocol.
//

import Foundation

/// Provides mutable access to the isRendering flag for processors that need async dispatch.
public protocol RenderingFlagProvider: AnyObject {
    var isRendering: Bool { get set }
}

/// Processes a block during Phase 4 (syntax hiding + attribute marking).
public protocol BlockProcessor {
    /// Block types this processor handles.
    func handles(_ type: MarkdownBlockType) -> Bool

    /// Whether to skip syntax hiding for blocks this processor handles.
    /// True for lists (which use character substitution instead of kern hiding).
    var skipSyntaxHiding: Bool { get }

    /// Process the block: set marker attributes, perform substitutions, etc.
    func process(block: MarkdownBlock, textStorage: NSMutableAttributedString, flagProvider: RenderingFlagProvider)
}

/// Default: don't skip syntax hiding.
public extension BlockProcessor {
    var skipSyntaxHiding: Bool { false }
}
