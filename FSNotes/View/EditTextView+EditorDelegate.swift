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
        return self.layoutManager
    }

    public var editorTextContainer: NSTextContainer? {
        return self.textContainer
    }

    public var editorContentWidth: CGFloat {
        return enclosingScrollView?.contentView.bounds.width ?? 400
    }

    // imagesLoaderQueue already exists as a public property on EditTextView
}
