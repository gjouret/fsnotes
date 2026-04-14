//
//  MainWindowController.swift
//  FSNotes
//
//  Created by BUDDAx2 on 8/9/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import AppKit


class MainWindowController: NSWindowController, NSWindowDelegate {
    let notesListUndoManager = UndoManager()
    
    public var lastWindowSize: NSRect? = nil

    override func windowDidLoad() {
        AppDelegate.mainWindowController = self

        self.window?.hidesOnDeactivate = UserDefaultsManagement.hideOnDeactivate
        self.window?.titleVisibility = .hidden
        self.window?.titlebarAppearsTransparent = true

        self.windowFrameAutosaveName = "myMainWindow"
    }
    
    func windowDidResize(_ notification: Notification) {
        refreshEditArea()
        restoreCollapsedPanesIfNeeded()
    }

    /// When the window expands after being shrunk (e.g. half-screen → full),
    /// NSSplitView auto-resize may leave panes collapsed at 0 with no way to
    /// restore them — the autosave remembers the collapsed frames, and
    /// widening the window doesn't magically re-expand anything. We track the
    /// last-known-good widths in UserDefaults during normal resize and use
    /// them to restore here.
    ///
    /// We only restore when the window is wide enough to actually hold the
    /// pane at its saved width plus the remaining content. Restoring into a
    /// narrow window would immediately collapse the pane again.
    private func restoreCollapsedPanesIfNeeded() {
        guard let vc = ViewController.shared(),
              let window = self.window else { return }

        let windowWidth = window.frame.width
        let editorMinWidth: CGFloat = 300

        // Restore sidebar (outer split) if it was collapsed by auto-resize
        // and the user hasn't explicitly hidden it.
        if !UserDefaultsManagement.hideSidebarTable {
            let sidebarWidth = vc.sidebarSplitView.subviews.first?.frame.width ?? 0
            let savedSidebar = UserDefaultsManagement.sidebarTableWidth
            let notesListCurrent = vc.splitView.subviews.first?.frame.width ?? 0
            let savedNotesList = UserDefaultsManagement.notesListWidth
            let effectiveNotesList = max(notesListCurrent, savedNotesList > 50 ? savedNotesList : 0)
            if sidebarWidth < 10,
               savedSidebar > 50,
               windowWidth >= savedSidebar + effectiveNotesList + editorMinWidth {
                vc.sidebarSplitView.setPosition(savedSidebar, ofDividerAt: 0)
            }
        }

        // Restore notes list (inner split) if it was collapsed by auto-resize.
        let notesListWidth = vc.splitView.subviews.first?.frame.width ?? 0
        let savedNotesList = UserDefaultsManagement.notesListWidth
        if notesListWidth < 10,
           savedNotesList > 50,
           windowWidth >= savedNotesList + editorMinWidth {
            vc.splitView.setPosition(savedNotesList, ofDividerAt: 0)
        }
    }
        
    func makeNew() {
        window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
        refreshEditArea(focusSearch: true)
    }
    
    func refreshEditArea(focusSearch: Bool = false) {
        guard let vc = ViewController.shared() else { return }

        if vc.sidebarOutlineView.isFirstLaunch || focusSearch {
            vc.search.window?.makeFirstResponder(vc.search)
        } else {
            vc.focusEditArea()
        }

        vc.editor.updateTextContainerInset()
    }
    
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let fr = window.firstResponder else {
            return notesListUndoManager
        }
        
        if fr.isKind(of: NotesTableView.self) {
            return notesListUndoManager
        }
        
        if fr.isKind(of: EditTextView.self) {
            guard let vc = ViewController.shared(), let ev = vc.editor, ev.isEditable else { return notesListUndoManager }
            
            return vc.editorUndoManager
        }
        
        return notesListUndoManager
    }

    public static func shared() -> NSWindow? {
        return AppDelegate.mainWindowController?.window
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaultsManagement.fullScreen = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        UserDefaultsManagement.fullScreen = false
    }
}
