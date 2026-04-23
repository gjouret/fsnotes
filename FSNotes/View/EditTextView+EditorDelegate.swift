//
//  EditTextView+EditorDelegate.swift
//  FSNotes
//
//  Conforms EditTextView to the EditorDelegate protocol defined in FSNotesCore.
//  This is the bridge between Core's TextStorageProcessor and the concrete UI.
//

import AppKit

extension EditTextView {
    public var currentNote: Note? {
        return self.note
    }

    public func setNeedsDisplay() {
        self.needsDisplay = true
    }

    public var editorLayoutManager: NSLayoutManager? {
        // Phase 4.5: TK1 accessor deleted with the custom layout-manager
        // subclass. The app is TK2-only; Core callers still see the
        // `EditorDelegate` protocol slot (a nil return tells them to
        // skip the TK1-only branch), but there is no TK1 NSLayoutManager
        // to hand back.
        return nil
    }

    public var editorTextContainer: NSTextContainer? {
        return self.textContainer
    }

    public var editorContentWidth: CGFloat {
        return enclosingScrollView?.contentView.bounds.width ?? 400
    }

    // imagesLoaderQueue already exists as a public property on EditTextView
}
