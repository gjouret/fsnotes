//
//  EditorDelegate.swift
//  FSNotesCore
//
//  Protocol that decouples TextStorageProcessor from the concrete EditTextView type.
//  FSNotesCore depends on this protocol; the app target provides the implementation.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What TextStorageProcessor needs from the editor — no concrete UI type dependency.
public protocol EditorDelegate: AnyObject {
    /// The note currently being edited.
    var currentNote: Note? { get }

    /// Request a display refresh.
    func setNeedsDisplay()

    /// The layout manager for glyph/layout calculations.
    var editorLayoutManager: NSLayoutManager? { get }

    /// The text container for width calculations.
    var editorTextContainer: NSTextContainer? { get }

    /// The visible content width (for image/table sizing).
    var editorContentWidth: CGFloat { get }

    /// Queue for async image loading operations.
    var imagesLoaderQueue: OperationQueue { get }
}
