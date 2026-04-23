//
//  NoteViewController.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 25.06.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit

class NoteViewController: EditorViewController, NSWindowDelegate {

    @IBOutlet weak var shareButton: NSButton!
    @IBOutlet weak var lockUnlockButton: NSButton!
    
    @IBOutlet weak var titleLabel: TitleTextField!
    @IBOutlet weak var editor: EditTextView!
    @IBOutlet weak var editorScrollView: EditorScrollView!
    @IBOutlet weak var titleBarView: TitleBarView!
    
    @IBOutlet weak var nonSelectedLabel: NSTextField!

    public func initWindow() {
        view.window?.title = "New note"
        view.window?.titleVisibility = .hidden
        view.window?.titlebarAppearsTransparent = true
        view.window?.backgroundColor = NSColor(named: "background_win")
        view.window?.delegate = self
        view.window?.setFrameOriginToPositionWindowInCenterOfScreen()

        // Phase 2a: swap the storyboard-decoded TK1 editor for a
        // programmatic TK2 editor before any wiring runs. The scroll
        // view retains the new instance, so the weak outlet stays live.
        self.editor = EditTextView.migrateNibEditorToTextKit2(
            oldEditor: editor,
            scrollView: editorScrollView
        )

        editor.initTextStorage()
        editor.editorViewController = self
        editor.configure()
        
        vcEditor = editor
        vcTitleLabel = titleLabel
        vcNonSelectedLabel = nonSelectedLabel
        vcEditorScrollView = editorScrollView
        vcTitleBarView = titleBarView

        editor.updateTextContainerInset()

        super.initView()
    }
    
    func windowDidResize(_ notification: Notification) {
        editor.updateTextContainerInset()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? EditTextView else { return }

        if let note = textView.note {
            note.setSelectedRange(range: textView.selectedRange())
        }

        // Phase 4.5: TK1 gutter cursor tracking (via
        // `LayoutManager.cursorCharIndex`) removed with the custom
        // layout-manager subclass. The TK2 gutter reads the current
        // cursor from `textView.selectedRange()` on each draw — a
        // redisplay on selection change is enough.
        textView.needsDisplay = true

        // Clear pending inline traits on cursor move
        if textView.suppressPendingTraitClear {
            textView.suppressPendingTraitClear = false
        } else if !textView.pendingInlineTraits.isEmpty {
            textView.pendingInlineTraits = []
        }

        // Phase 8 / Slice 4: auto-collapse any code blocks in edit
        // mode whose span no longer contains the cursor.
        textView.collapseEditingCodeBlocksOutsideSelection()

        // Auto-scroll to keep cursor visible
        textView.scrollRangeToVisible(textView.selectedRange())
    }
    
    func windowWillClose(_ notification: Notification) {
        AppDelegate.noteWindows.removeAll(where: { ($0.contentViewController as? NoteViewController)?.editor.note === editor.note  })
    }
    
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let fr = window.firstResponder,
            fr.isKind(of: EditTextView.self),
            editor.isEditable {
            return editor.editorViewController?.editorUndoManager
        }
        
        return nil
    }
}
