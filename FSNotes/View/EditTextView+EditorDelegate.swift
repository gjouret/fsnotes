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
        // Phase 2a: TK1-safe accessor — returns nil on TK2 views. The
        // TextStorageProcessor source-mode pipeline is skipped when the
        // block model is active (which is always true for markdown
        // WYSIWYG), so Core sites that still read this will treat nil
        // as "skip the TK1 code path".
        return self.layoutManagerIfTK1
    }

    public var editorTextContainer: NSTextContainer? {
        return self.textContainer
    }

    public var editorContentWidth: CGFloat {
        return enclosingScrollView?.contentView.bounds.width ?? 400
    }

    // imagesLoaderQueue already exists as a public property on EditTextView
}
