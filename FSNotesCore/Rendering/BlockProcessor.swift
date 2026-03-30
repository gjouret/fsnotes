//
//  BlockProcessor.swift
//  FSNotesCore
//
//  Protocol for Phase 4 block-level processing.
//  Each processor handles one or more block types.
//  Adding a new block visual = one new file implementing this protocol.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Provides mutable access to the isRendering flag for processors that need async dispatch.
public protocol RenderingFlagProvider: AnyObject {
    var isRendering: Bool { get set }
}

// MARK: - Core Protocols (decouple Core from app-target types)

/// Decouples TextStorageProcessor from the concrete EditTextView type.
public protocol EditorDelegate: AnyObject {
    var currentNote: Note? { get }
    func setNeedsDisplay()
    var editorLayoutManager: NSLayoutManager? { get }
    var editorTextContainer: NSTextContainer? { get }
    var editorContentWidth: CGFloat { get }
    var imagesLoaderQueue: OperationQueue { get }
}

/// Decouples MPreviewView from the concrete ViewController type.
public protocol PreviewDelegate: AnyObject {
    var activeNote: Note? { get }
    var editorInsetWidth: CGFloat { get }
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
