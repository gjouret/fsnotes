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

    /// Pane widths captured at the moment a window live-resize starts.
    /// While the user drags the window edge, NSSplitView shrinks the panes
    /// proportionally — those intermediate widths are not the user's intent
    /// and must not overwrite the persisted values. We snapshot here so we
    /// can restore to the pre-resize widths once the window grows back.
    /// `nil` means no live resize is active (or the pane was already
    /// collapsed at start of resize, in which case there is nothing to
    /// restore).
    private var preResizeSidebarWidth: CGFloat?
    private var preResizeNotesListWidth: CGFloat?

    override func windowDidLoad() {
        AppDelegate.mainWindowController = self

        self.window?.hidesOnDeactivate = UserDefaultsManagement.hideOnDeactivate
        self.window?.titleVisibility = .hidden
        self.window?.titlebarAppearsTransparent = true

        self.windowFrameAutosaveName = "myMainWindow"
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let vc = ViewController.shared() else { return }
        // Only snapshot widths that are currently visible (>50). A pane the
        // user explicitly toggled off has saved width <50 and we should leave
        // its UserDefaults value alone.
        if let sidebar = vc.sidebarSplitView.subviews.first?.frame.width, sidebar > 50 {
            preResizeSidebarWidth = sidebar
        }
        if let notesList = vc.splitView.subviews.first?.frame.width, notesList > 50 {
            preResizeNotesListWidth = notesList
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // One last restore pass at end-of-resize, then drop the snapshots so
        // a future divider drag (which doesn't go through live-resize) can
        // freely update UserDefaults via splitViewDidResizeSubviews.
        restoreCollapsedPanesIfNeeded()
        preResizeSidebarWidth = nil
        preResizeNotesListWidth = nil
    }

    func windowDidResize(_ notification: Notification) {
        refreshEditArea()
        restoreCollapsedPanesIfNeeded()
    }

    /// When the window expands after being shrunk (e.g. half-screen → full),
    /// NSSplitView auto-resize may leave panes collapsed at 0 with no way to
    /// restore them — the autosave remembers the collapsed frames, and
    /// widening the window doesn't magically re-expand anything. We track the
    /// last-known-good widths in UserDefaults during normal use (divider
    /// drags) and snapshot in-memory at start of live resize, then use the
    /// snapshot (or UserDefaults as fallback) to restore here.
    ///
    /// We only restore when the window is wide enough to actually hold the
    /// pane at its target width plus the remaining content. Restoring into a
    /// narrow window would immediately collapse the pane again.
    private func restoreCollapsedPanesIfNeeded() {
        guard let vc = ViewController.shared(),
              let window = self.window else { return }

        let windowWidth = window.frame.width
        let editorMinWidth: CGFloat = 300

        // Prefer the in-memory snapshot taken at windowWillStartLiveResize.
        // Fall back to UserDefaults for the case where a previous run of the
        // app left a pane collapsed (no snapshot in this session yet).
        let targetSidebar = preResizeSidebarWidth ?? UserDefaultsManagement.sidebarTableWidth
        let targetNotesList = preResizeNotesListWidth ?? UserDefaultsManagement.notesListWidth

        // Restore sidebar (outer split) if it was collapsed by auto-resize
        // and the user hasn't explicitly hidden it.
        if !UserDefaultsManagement.hideSidebarTable {
            let sidebarWidth = vc.sidebarSplitView.subviews.first?.frame.width ?? 0
            let notesListCurrent = vc.splitView.subviews.first?.frame.width ?? 0
            let effectiveNotesList = max(notesListCurrent, targetNotesList > 50 ? targetNotesList : 0)
            if sidebarWidth < 10,
               targetSidebar > 50,
               windowWidth >= targetSidebar + effectiveNotesList + editorMinWidth {
                vc.sidebarSplitView.setPosition(targetSidebar, ofDividerAt: 0)
            }
        }

        // Restore notes list (inner split) if it was collapsed by auto-resize.
        let notesListWidth = vc.splitView.subviews.first?.frame.width ?? 0
        if notesListWidth < 10,
           targetNotesList > 50,
           windowWidth >= targetNotesList + editorMinWidth {
            vc.splitView.setPosition(targetNotesList, ofDividerAt: 0)
        }
    }

    /// Pure helper exposed for unit testing. Given current pane widths, the
    /// pre-resize snapshot (or UserDefaults fallback) targets, and the new
    /// window width, return the widths each pane should have after a window
    /// resize. `nil` for a pane means "no change".
    static func computeRestoredPaneWidths(
        currentSidebar: CGFloat,
        currentNotesList: CGFloat,
        targetSidebar: CGFloat,
        targetNotesList: CGFloat,
        windowWidth: CGFloat,
        sidebarHidden: Bool,
        editorMinWidth: CGFloat = 300
    ) -> (sidebar: CGFloat?, notesList: CGFloat?) {
        var newSidebar: CGFloat? = nil
        var newNotesList: CGFloat? = nil

        if !sidebarHidden {
            let effectiveNotesList = max(currentNotesList, targetNotesList > 50 ? targetNotesList : 0)
            if currentSidebar < 10,
               targetSidebar > 50,
               windowWidth >= targetSidebar + effectiveNotesList + editorMinWidth {
                newSidebar = targetSidebar
            }
        }

        if currentNotesList < 10,
           targetNotesList > 50,
           windowWidth >= targetNotesList + editorMinWidth {
            newNotesList = targetNotesList
        }

        return (newSidebar, newNotesList)
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
