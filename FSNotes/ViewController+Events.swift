//
//  ViewController+Events.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Cocoa
import Carbon.HIToolbox

extension ViewController {
    public func keyDown(with event: NSEvent) -> Bool {
        guard let mainWindow = MainWindowController.shared() else { return false }

        guard self.alert == nil else {
            if event.keyCode == kVK_Escape, let alert {
                mainWindow.endSheet(alert.window)
                self.alert = nil
            }

            return true
        }

        if event.modifierFlags.contains(.shift)
            && event.modifierFlags.contains(.option)
            && event.keyCode == kVK_ANSI_N {
            createFolder(NSMenuItem())
            return false
        }

        if event.keyCode == kVK_Return {
            if let firstResponder = NSApp.mainWindow?.firstResponder, self.alert == nil {
                if event.modifierFlags.contains(.command) {
                    if firstResponder.isKind(of: NotesTableView.self) {
                        NSApp.mainWindow?.makeFirstResponder(self.sidebarOutlineView)

                        if sidebarOutlineView.selectedRowIndexes.count == 0 {
                            sidebarOutlineView.selectRowIndexes([0], byExtendingSelection: false)
                        } else {
                            sidebarOutlineView.selectRowIndexes(sidebarOutlineView.selectedRowIndexes, byExtendingSelection: false)
                        }

                        return false
                    }

                    if firstResponder.isKind(of: EditTextView.self) {
                        NSApp.mainWindow?.makeFirstResponder(self.notesTableView)
                        return false
                    }
                } else {
                    if firstResponder.isKind(of: SidebarOutlineView.self) {
                        self.notesTableView.selectCurrent()
                        NSApp.mainWindow?.makeFirstResponder(self.notesTableView)
                        return false
                    }

                    if let note = editor.note, firstResponder.isKind(of: NotesTableView.self) {
                        if note.container != .encryptedTextPack {
                            NSApp.mainWindow?.makeFirstResponder(editor)
                        }
                        return false
                    }
                }
            }

            return true
        }

        if event.keyCode == kVK_Tab {
            if event.modifierFlags.contains(.control) {
                self.notesTableView.window?.makeFirstResponder(self.notesTableView)
                return true
            }

            if let firstResponder = NSApp.mainWindow?.firstResponder, firstResponder.isKind(of: NotesTableView.self) {
                editAreaScroll.showFocusBorder()
                focusEditArea()
                return false
            }
        }

        if event.keyCode == kVK_Escape && event.modifierFlags.contains(.option) {
            editor.forceSystemAutocomplete = true
            (view.window?.firstResponder as? NSTextView)?.complete(nil)
            return true
        }

        if (
            (event.keyCode == kVK_Escape || (event.characters == "." && event.modifierFlags.contains(.command)))
            && NSApplication.shared.mainWindow == NSApplication.shared.keyWindow
            && UserDefaultsManagement.shouldFocusSearchOnESCKeyDown
            && !editor.hasMarkedText()
        ) {
            self.view.window?.orderFront(nil)
            self.view.window?.makeKey()

            search.searchesMenu = nil

            if NSApplication.shared.mainWindow?.firstResponder === editor, editor.selectedRange().length > 0 {
                editor.selectedRange = NSRange(location: editor.selectedRange().upperBound, length: 0)
                return false
            }

            if let view = NSApplication.shared.mainWindow?.firstResponder as? NSTextView,
               let textField = view.superview?.superview,
               textField.isKind(of: NameTextField.self) {
                NSApp.mainWindow?.makeFirstResponder(self.notesTableView)
                return false
            }

            if self.editAreaScroll.isFindBarVisible {
                cancelTextSearch()
                NSApp.mainWindow?.makeFirstResponder(editor)
                return false
            }

            if titleLabel.isEditable {
                titleLabel.editModeOff()
                titleLabel.window?.makeFirstResponder(notesTableView)
                return false
            }

            UserDefaultsManagement.lastSidebarItem = nil
            UserDefaultsManagement.lastProjectURL = nil
            UserDefaultsManagement.lastSelectedURL = nil

            notesTableView.scroll(.zero)

            let hasSelectedNotes = notesTableView.selectedRow > -1
            let hasSelectedBarItem = sidebarOutlineView.selectedRow > -1

            if hasSelectedBarItem && hasSelectedNotes {
                UserDataService.instance.isNotesTableEscape = true
                notesTableView.deselectAll(nil)
                NSApp.mainWindow?.makeFirstResponder(search)
                return false
            }

            sidebarOutlineView.deselectAll(nil)
            sidebarOutlineView.scrollRowToVisible(0)
            cleanSearchAndEditArea()

            return true
        }

        if event.characters?.unicodeScalars.first == "f"
            && event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.control) {
            if self.notesTableView.getSelectedNote() != nil {
                if search.stringValue.count > 0 {
                    let fullText = search.stringValue
                    let startIndex = fullText.startIndex
                    let range = search.selectedRange
                    let selectionStart = fullText.index(startIndex, offsetBy: range.location)
                    let textBefore = String(fullText[startIndex..<selectionStart])

                    if !textBefore.isEmpty {
                        let pasteboard = NSPasteboard(name: .find)
                        pasteboard.declareTypes([.textFinderOptions, .string], owner: nil)
                        pasteboard.setString(textBefore, forType: .string)
                    }
                }

                return true
            }
        }

        if let firstResponder = mainWindow.firstResponder,
           !firstResponder.isKind(of: EditTextView.self),
           !firstResponder.isKind(of: NSTextView.self),
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           let characters = event.characters {
            let charSet = CharacterSet(charactersIn: characters)
            if charSet.isSubset(of: CharacterSet.alphanumerics) {
                self.search.becomeFirstResponder()
            }
        }

        if event.modifierFlags.contains(.control)
            && !event.modifierFlags.contains(.shift)
            && !event.modifierFlags.contains(.option) {
            switch event.characters?.unicodeScalars.first {
            case "1":
                sidebarOutlineView.selectRowIndexes([0], byExtendingSelection: false)
            case "2":
                sidebarOutlineView.selectRowIndexes([1], byExtendingSelection: false)
            case "3":
                sidebarOutlineView.selectRowIndexes([2], byExtendingSelection: false)
            case "4":
                sidebarOutlineView.selectRowIndexes([3], byExtendingSelection: false)
            case "5":
                sidebarOutlineView.selectRowIndexes([4], byExtendingSelection: false)
            default:
                return true
            }

            return false
        }

        if event.keyCode == kVK_RightArrow, let firstResponder = mainWindow.firstResponder, firstResponder.isKind(of: NotesTableView.self) {
            if let note = vcEditor?.note, note.isEncryptedAndLocked() {
                unLock(notes: [note])
                return true
            }

            editAreaScroll.showFocusBorder()
            focusEditArea()

            return false
        }

        if event.keyCode == kVK_LeftArrow, let firstResponder = mainWindow.firstResponder, firstResponder.isKind(of: NotesTableView.self) {
            sidebarOutlineView.window?.makeFirstResponder(sidebarOutlineView)

            if sidebarOutlineView.selectedRowIndexes.count == 0 {
                sidebarOutlineView.selectRowIndexes([0], byExtendingSelection: false)
            }

            return false
        }

        return true
    }

    @objc func onWakeNote(note: NSNotification) {
        refillEditArea()
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        for item in menu.items {
            if item.title == NSLocalizedString("Copy Link", comment: "") {
                item.action = #selector(NSText.copy(_:))
            }

            if item.title == NSLocalizedString("Font", comment: "")
                || item.title == "Make Link"
                || item.title == NSLocalizedString("Make Link", comment: "") {
                menu.removeItem(item)
            }
        }

        return menu
    }

    func splitViewWillResizeSubviews(_ notification: Notification) {
        editor.updateTextContainerInset()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Persist the sidebar (folder-pane) width whenever it's at a sensible
        // size. This is the outer splitView's left subview. We need this to
        // survive window auto-resize that would otherwise collapse the pane
        // with no way to recover (NSSplitView autosave persists the 0 state).
        guard let split = notification.object as? NSSplitView,
              split === sidebarSplitView,
              let first = split.subviews.first else { return }
        let w = first.frame.width
        if w > 50 {
            UserDefaultsManagement.sidebarTableWidth = w
        }
        editor?.reflowAttachmentsForWidthChange()
    }

    @objc func onSleepNote(note: NSNotification) {
        if UserDefaultsManagement.lockOnSleep {
            lockAll(self)
        }
    }

    @objc func onScreenLocked(note: NSNotification) {
        if UserDefaultsManagement.lockOnScreenActivated {
            lockAll(self)
        }
    }

    @objc func onAccentColorChanged(note: NSNotification) {
        sidebarOutlineView.reloadSidebar()
    }

    @objc func onUserSwitch(note: NSNotification) {
        if UserDefaultsManagement.lockOnUserSwitch {
            lockAll(self)
        }
    }

    override func restoreUserActivityState(_ userActivity: NSUserActivity) {
        guard let name = userActivity.userInfo?["note-file-name"] as? String,
              let note = Storage.shared().getBy(name: name) else { return }

        notesTableView.selectRowAndSidebarItem(note: note)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView.window?.firstResponder == textView {
            let range = editor.selectedRange()
            if let editor = self.editor, let note = editor.note {
                self.updateCounters(note: note, charRange: range)
            }

            editor.note?.setSelectedRange(range: textView.selectedRange())

            // Phase 4.5: TK1 `cursorCharIndex` gutter tracking removed with
            // the custom layout-manager subclass. The TK2 gutter
            // (`drawIconsTK2`) reads the current cursor from
            // `textView.selectedRange()` on each draw; a redisplay on
            // selection change is enough to refresh H-badges / fold
            // carets when the cursor leaves/enters a heading line.
            if let editView = textView as? EditTextView {
                editView.needsDisplay = true
            }
        }

        // Clear pending inline traits when user moves cursor (not via formatting).
        // This prevents stale traits from affecting text typed after navigating.
        // The suppress flag is set during our own cursor updates (e.g., after insertion).
        if editor.suppressPendingTraitClear {
            editor.suppressPendingTraitClear = false
        } else {
            if !editor.pendingInlineTraits.isEmpty {
                editor.pendingInlineTraits = []
            }
            if !editor.explicitlyOffTraits.isEmpty {
                editor.explicitlyOffTraits = []
            }
        }

        formattingToolbar?.updateButtonStates(for: editor)

        #if os(OSX)
        editor.triggerCodeBlockRenderingIfNeeded()
        // Phase 8 / Slice 4: auto-collapse any code blocks in edit
        // mode whose span no longer contains the cursor. No-op if
        // `editingCodeBlocks` is empty or the selection is still
        // inside every currently-editing block.
        editor.collapseEditingCodeBlocksOutsideSelection()
        #endif

        editor.userActivity?.needsSave = true
    }

    @objc public func toggleAIChat(_ sender: Any) {
        if let panel = aiChatPanel, !panel.isHidden {
            aiChatEditorTrailingConstraint?.isActive = false
            aiChatEditorTrailingConstraint = nil
            panel.removeFromSuperview()
            aiChatPanel = nil
        } else {
            guard let editorView = editAreaScroll.superview else { return }

            let panel = AIChatPanelView()
            panel.editorViewController = self
            panel.translatesAutoresizingMaskIntoConstraints = false
            editorView.addSubview(panel)

            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: editAreaScroll.topAnchor),
                panel.trailingAnchor.constraint(equalTo: editorView.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: editAreaScroll.bottomAnchor),
                panel.widthAnchor.constraint(equalToConstant: AIChatPanelView.panelWidth),
            ])

            let trailing = editAreaScroll.trailingAnchor.constraint(equalTo: panel.leadingAnchor)
            trailing.isActive = true
            aiChatEditorTrailingConstraint = trailing

            aiChatPanel = panel
        }
    }

    // MARK: - Table handle overlay (Phase 2e-T2-g)
    //
    // The overlay hangs off the ViewController via an associated object
    // — `EditTextView+BlockModel.swift` is off-limits under the T2-g
    // scope rules, and the overlay itself needs a stable owner so it
    // can observe scroll / text-change notifications across the life
    // of the editor. Lazy instantiation: the first call constructs the
    // overlay AND kicks a reposition so the handle views exist before
    // the first hover.
    //
    // Production wiring: call `tableHandleOverlay.reposition()` after a
    // note is filled into the editor. Tests construct the overlay
    // directly (bypassing this accessor) so they don't need the full
    // ViewController hierarchy.

    private struct TableHandleOverlayKeys {
        static var overlay = "TableHandleOverlay.overlayKey"
    }

    public var tableHandleOverlay: TableHandleOverlay {
        if let existing = objc_getAssociatedObject(
            self, &TableHandleOverlayKeys.overlay
        ) as? TableHandleOverlay {
            return existing
        }
        let overlay = TableHandleOverlay(editor: editor)
        objc_setAssociatedObject(
            self,
            &TableHandleOverlayKeys.overlay,
            overlay,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return overlay
    }

    // MARK: - Code-block edit toggle overlay (Phase 8 Slice 3)
    //
    // The `</>` hover button that flips a fenced code block between its
    // rendered view and its raw source form. Same shape as
    // `tableHandleOverlay` above: an associated-object lazy getter whose
    // first read constructs the overlay and installs its
    // `NSText.didChangeNotification` +
    // `NSView.boundsDidChangeNotification` +
    // `EditTextView.editingCodeBlocksDidChangeNotification` observers.
    // Those observers drive the auto-reposition pass that keeps buttons
    // aligned with visible code-block fragments on every scroll / edit.
    //
    // Production wiring: call `codeBlockEditToggleOverlay.reposition()`
    // after a note is filled into the editor, alongside the equivalent
    // `tableHandleOverlay` call. Without that call the overlay is never
    // constructed, no observers wire up, and the `</>` buttons never
    // appear. Tests bypass this getter and construct
    // `CodeBlockEditToggleOverlay(editor:)` directly.

    private struct CodeBlockEditToggleOverlayKeys {
        static var overlay = "CodeBlockEditToggleOverlay.overlayKey"
    }

    public var codeBlockEditToggleOverlay: CodeBlockEditToggleOverlay {
        if let existing = objc_getAssociatedObject(
            self, &CodeBlockEditToggleOverlayKeys.overlay
        ) as? CodeBlockEditToggleOverlay {
            return existing
        }
        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        objc_setAssociatedObject(
            self,
            &CodeBlockEditToggleOverlayKeys.overlay,
            overlay,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return overlay
    }
}
