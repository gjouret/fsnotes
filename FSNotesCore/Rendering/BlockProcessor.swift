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
    /// Save the current note (block-model or legacy path).
    func save()
}

// The legacy BlockProcessor protocol has been removed.
// Phase 4 (syntax hiding) is fully handled by the block-model
// DocumentRenderer. BlockquoteProcessor and HorizontalRuleProcessor
// have been deleted.
