//
//  ViewController+Menu.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 16.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import AppKit

extension ViewController {
    @IBAction func noteUp(_ sender: NSMenuItem) {
        NSApp.mainWindow?.makeFirstResponder(notesTableView)

        if titleLabel.isEditable {
            titleLabel.editModeOff()
            titleLabel.window?.makeFirstResponder(nil)
        }

        notesTableView.selectPrev()
    }

    @IBAction func noteDown(_ sender: NSMenuItem) {
        NSApp.mainWindow?.makeFirstResponder(notesTableView)

        if titleLabel.isEditable {
            titleLabel.editModeOff()
            titleLabel.window?.makeFirstResponder(nil)
        }

        notesTableView.selectNext()
    }

    @IBAction func sidebarUp(_ sender: NSMenuItem) {
        if titleLabel.isEditable {
            titleLabel.editModeOff()
            titleLabel.window?.makeFirstResponder(nil)
        }

        NSApp.mainWindow?.makeFirstResponder(sidebarOutlineView)

        guard let cgEvent = CGEvent(keyboardEventSource: .none, virtualKey: 126, keyDown: true) else { return }
        cgEvent.flags.remove(.maskShift)
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return }
        sidebarOutlineView.keyDown(with: nsEvent)
    }

    @IBAction func sidebarDown(_ sender: NSMenuItem) {
        if titleLabel.isEditable {
            titleLabel.editModeOff()
            titleLabel.window?.makeFirstResponder(nil)
        }

        NSApp.mainWindow?.makeFirstResponder(sidebarOutlineView)

        guard let cgEvent = CGEvent(keyboardEventSource: .none, virtualKey: 125, keyDown: true) else { return }
        cgEvent.flags.remove(.maskShift)
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return }
        sidebarOutlineView.keyDown(with: nsEvent)
    }

    @IBAction func toggleSidebar(_ sender: Any) {
        sidebarDisplayController.toggleVisibility()
    }

    @IBAction func toggleNoteList(_ sender: Any) {
        guard let vc = ViewController.shared() else { return }

        let size = UserDefaultsManagement.horizontalOrientation
            ? vc.splitView.subviews[0].frame.height
            : vc.splitView.subviews[0].frame.width

        if size == 0 {
            var size = UserDefaultsManagement.notesTableWidth
            if UserDefaultsManagement.notesTableWidth == 0 {
                size = 300
            }

            vc.splitView.shouldHideDivider = false
            vc.splitView.setPosition(size, ofDividerAt: 0)
        } else if vc.splitView.shouldHideDivider {
            vc.splitView.shouldHideDivider = false
            vc.splitView.setPosition(UserDefaultsManagement.notesTableWidth, ofDividerAt: 0)
        } else {
            UserDefaultsManagement.notesTableWidth = size

            vc.splitView.shouldHideDivider = true
            vc.splitView.setPosition(0, ofDividerAt: 0)

            DispatchQueue.main.async {
                vc.splitView.setPosition(0, ofDividerAt: 0)
            }
        }

        vc.editor.updateTextContainerInset()
    }

    @IBAction func prevHistory(_ sender: NSMenuItem) { navigateBack(sender) }
    @IBAction func nextHistory(_ sender: NSMenuItem) { navigateForward(sender) }

    @IBAction func foldCurrentHeader(_ sender: Any) {
        ViewController.shared()?.editor?.foldAtCursor()
    }

    @IBAction func unfoldCurrentHeader(_ sender: Any) {
        ViewController.shared()?.editor?.unfoldAtCursor()
    }

    @IBAction func foldAllHeaders(_ sender: Any) {
        editor.foldAllHeaders()
    }

    @IBAction func unfoldAllHeaders(_ sender: Any) {
        editor.unfoldAllHeaders()
    }

    @objc func doubleClickOnNotesTable() {
        let selected = notesTableView.clickedRow
        guard selected >= 0, let note = notesTableView.getNote(at: selected) else { return }
        openInNewWindow(note: note)
    }

    func processFileMenuItems(_ menuItem: NSMenuItem, menuId: String) -> Bool {
        
        // Submenu
        if menuItem.menu?.identifier?.rawValue == "fileMenu.move" ||
            menuItem.menu?.identifier?.rawValue == "fileMenu.history" {
            return true
        }
        
        guard let vc = ViewController.shared(),
              let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
              let id = menuItem.identifier?.rawValue else { return false }

        // Sidebar
        let tags = vc.sidebarOutlineView.getSidebarTags()
        let projects = vc.sidebarOutlineView.getSelectedProjects()
        let projectSelected = projects?.isEmpty == false
        let tagSelected = tags?.isEmpty == false
        
        let isFirstSidebar = evc.view.window?.firstResponder?.isKind(of: SidebarOutlineView.self) == true
        let isInbox = vc.sidebarOutlineView.getSidebarItems()?.first?.type == .Inbox
        let isTrash = vc.sidebarOutlineView.getSidebarItems()?.first?.type == .Trash
        
        // Notes
        let isFirstResponder = evc.view.window?.firstResponder?.isKind(of: NotesTableView.self) == true
        let isFirstEditor = evc.view.window?.firstResponder?.isKind(of: EditTextView.self) == true
        let isOpenedWindow = NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true
        
        let notes = vc.getSelectedNotes()
        let greaterThanZero = notes?.isEmpty == false
        let isOne = notes?.count == 1
        
        func hasEncrypted(notes: [Note]? = nil) -> Bool {
            guard let notes = notes else { return false }
            return notes.contains { $0.isEncrypted() && !$0.project.isEncrypted }
        }
        
        switch id {
        case "\(menuId).close":
            return true

        case "\(menuId).import":
            return true

        case "\(menuId).attach":
            return true

        case "\(menuId).backup":
            var title = NSLocalizedString("Inbox", comment: "")
            
            if let gitProject = vc.getGitProject() {
                title = gitProject.label
                
                if gitProject.isDefault {
                    title = NSLocalizedString("Inbox", comment: "")
                }
                
                menuItem.title =  String(format: NSLocalizedString("Commit & Push “%@”", comment: "Menu Library"), title)
                return true
            }
            
            return false

        case "\(menuId).new":
            return true

        case "\(menuId).newInNewWindow":
            return true

        case "\(menuId).createFolder":
            return !isTrash

        case "\(menuId).searchAndCreate":
            return true

        case "\(menuId).open":
            return greaterThanZero

        case "\(menuId).duplicate":
            return greaterThanZero && (isFirstResponder || isFirstEditor)

        case "\(menuId).rename":
            
            // sidebar
            if isFirstSidebar {
                if tagSelected {
                    menuItem.title = NSLocalizedString("Rename Tag", comment: "Menu Library")
                } else {
                    menuItem.title = NSLocalizedString("Rename Folder", comment: "Menu Library")
                }
                
                return projectSelected || tagSelected
            }
            
            menuItem.title = NSLocalizedString("Rename", comment: "File Menu")
            return isOne && isFirstResponder || (isFirstEditor && !isOpenedWindow)
            
        case "\(menuId).delete":
            return greaterThanZero && isFirstResponder

        case "\(menuId).forceDelete":
            return greaterThanZero && isFirstResponder

        case "\(menuId).togglePin":
            if let note = notes?.first, note.isPinned {
                menuItem.title = NSLocalizedString("Unpin", comment: "File Menu")
            } else {
                menuItem.title = NSLocalizedString("Pin", comment: "File Menu")
            }
            return greaterThanZero
            
        case "\(menuId).decrypt":
            
            // sidebar
            if isFirstSidebar {
                menuItem.title = NSLocalizedString("Decrypt Folder", comment: "Menu Library")
                
                if let project = projects?.first, !project.isTrash, !project.isDefault, !project.isVirtual, project.isEncrypted {
                    return true
                }
                
                return false
            }
            
            menuItem.title = NSLocalizedString("Decrypt", comment: "File Menu")
            return greaterThanZero && hasEncrypted(notes: notes)
            
        case "\(menuId).toggleLock":
            
            // sidebar
            if isFirstSidebar {
                if let project = projects?.first, !project.isTrash, project.isLocked() {
                    menuItem.title = NSLocalizedString("Unlock Folder", comment: "")
                } else {
                    menuItem.title = NSLocalizedString("Lock Folder", comment: "Menu Library")
                }
                return projectSelected
            }
            
            if let note = notes?.first, note.isEncryptedAndLocked() {
                menuItem.title = NSLocalizedString("Unlock", comment: "File Menu")
            } else {
                menuItem.title = NSLocalizedString("Lock", comment: "File Menu")
            }
            
            return greaterThanZero && (isFirstResponder || isOpenedWindow || isFirstEditor)
            
        case "\(menuId).external":
            return greaterThanZero

        case "\(menuId).reveal":
            if isFirstSidebar {
                return projectSelected || isInbox
            }
            return greaterThanZero && (isFirstResponder || isOpenedWindow || isFirstEditor)

        case "\(menuId).date":
            return greaterThanZero && (isFirstResponder || isOpenedWindow || isFirstEditor)

        case "\(menuId).toggleContainer":
            if let note = notes?.first, note.container == .none {
                menuItem.title = NSLocalizedString("Convert to TextBundle", comment: "")
            } else {
                menuItem.title =  NSLocalizedString("Convert to Plain", comment: "")
            }
            return greaterThanZero && !hasEncrypted(notes: notes) && (isFirstResponder || isOpenedWindow)

        case "\(menuId).move":
            return greaterThanZero && (isFirstResponder || isOpenedWindow || isFirstEditor)

        case "\(menuId).history":
            if let note = notes?.first {
                return isOne && (isFirstResponder || isOpenedWindow || isFirstEditor) && note.project.hasCommitsDiffsCache()
            }

        case "\(menuId).print":
            return isOne && (isFirstResponder || isOpenedWindow || isFirstEditor)
        default:
            break
        }
        
        return false
    }
    
    func processShareMenuItems(_ menuItem: NSMenuItem, menuId: String) -> Bool {
        guard let vc = ViewController.shared(),
              let evc = NSApplication.shared.keyWindow?.contentViewController as? EditorViewController,
              let id = menuItem.identifier?.rawValue else { return false }
        
        let isFirstResponder = evc.view.window?.firstResponder?.isKind(of: NotesTableView.self) == true
        let isFirstEditor = evc.view.window?.firstResponder?.isKind(of: EditTextView.self) == true
        let isOpenedWindow = NSApplication.shared.keyWindow?.contentViewController?.isKind(of: NoteViewController.self) == true
        
        let notes = vc.getSelectedNotes()
        let isOne = notes?.count == 1
        
        switch id {
        case "\(menuId).copyURL":
            return isOne && (isFirstResponder || isOpenedWindow || isFirstEditor)

        case "\(menuId).copyTitle":
            return isOne && (isFirstResponder || isOpenedWindow || isFirstEditor)

        case "\(menuId).uploadOverSSH":
            if let note = notes?.first, note.uploadPath != nil || note.apiId != nil {
                menuItem.title = NSLocalizedString("Update Web Page", comment: "File Menu")
            } else {
                menuItem.title = NSLocalizedString("Create Web Page", comment: "File Menu")
            }
            return isOne && (isFirstResponder || isOpenedWindow || isFirstEditor)

        case "\(menuId).removeOverSSH":
            if let note = notes?.first {
                return (isFirstResponder || isOpenedWindow || isFirstEditor) && isOne && !note.isEncrypted() && (note.uploadPath != nil || note.apiId != nil)
            }
        default:
            return false
        }
        
        return false
    }
    
    func processLibraryMenuItems(_ menuItem: NSMenuItem, menuId: String) -> Bool {
        guard let vc = ViewController.shared(),
              let id = menuItem.identifier?.rawValue else { return false }

        let tags = vc.sidebarOutlineView.getSidebarTags()
        let projects = vc.sidebarOutlineView.getSelectedProjects()
        
        let projectSelected = projects?.isEmpty == false
        let tagSelected = tags?.isEmpty == false
        let isFirstResponder = view.window?.firstResponder?.isKind(of: SidebarOutlineView.self) == true
        
        let isTrash = vc.sidebarOutlineView.getSidebarItems()?.first?.type == .Trash
        let isInbox = vc.sidebarOutlineView.getSidebarItems()?.first?.type == .Inbox
        let isSystem = vc.sidebarOutlineView.getSidebarItems()?.first?.isSystem() == true
        
        switch id {
        case "\(menuId).create":
            return !isTrash

        case "\(menuId).rename":
            if tagSelected {
                menuItem.title = NSLocalizedString("Rename Tag", comment: "Menu Library")
            } else {
                menuItem.title = NSLocalizedString("Rename Folder", comment: "Menu Library")
            }
            return isFirstResponder && (projectSelected || tagSelected)
            
        case "\(menuId).delete":
            if let project = projects?.first, project.isBookmark {
                menuItem.title = NSLocalizedString("Unlink External Folder", comment: "Menu Library")
            } else if tagSelected {
                menuItem.title = NSLocalizedString("Delete Tag", comment: "Menu Library")
            } else {
                menuItem.title = NSLocalizedString("Delete Folder", comment: "Menu Library")
            }
            return isFirstResponder && (projectSelected || tagSelected)
            
        case "\(menuId).decrypt":
            if let project = projects?.first, !project.isTrash, !project.isDefault, !project.isVirtual, project.isEncrypted {
                return isFirstResponder
            }

        case "\(menuId).toggleLock":
            if let project = projects?.first, !project.isTrash, project.isLocked() {
                menuItem.title = NSLocalizedString("Unlock Folder", comment: "")
            } else {
                menuItem.title = NSLocalizedString("Lock Folder", comment: "Menu Library")
            }
            return isFirstResponder && projectSelected
            
        case "\(menuId).reveal":
            return isFirstResponder && (projectSelected || isInbox)

        case "\(menuId).options":
            return isFirstResponder && (projectSelected || isSystem)
        default:
            break
        }
        
        return false
    }
        
    func loadMoveMenu() {
        guard let vc = ViewController.shared(), let note = vc.notesTableView.getSelectedNote() else { return }
        
        let moveTitle = NSLocalizedString("Move Note…", comment: "Menu")
        if let prevMenu = noteMenu.item(withTitle: moveTitle) {
            noteMenu.removeItem(prevMenu)
        }
        // Also remove any leftover legacy "Move" item from previous builds
        if let legacyMove = noteMenu.item(withTitle: NSLocalizedString("Move", comment: "Menu")) {
            noteMenu.removeItem(legacyMove)
        }

        let moveMenuItem = NSMenuItem()
        moveMenuItem.title = NSLocalizedString("Move Note…", comment: "Menu")
        moveMenuItem.image = NSImage(systemSymbolName: "move.3d", accessibilityDescription: nil)
        
        noteMenu.addItem(moveMenuItem)
        let moveMenu = NSMenu()
        moveMenu.identifier = NSUserInterfaceItemIdentifier("fileMenu.move")

        if UserDefaultsManagement.inlineTags, let tagsMenu = noteMenu.item(withTitle: NSLocalizedString("Tags", comment: "")) {
            noteMenu.removeItem(tagsMenu)
        }
        
        if !note.isTrash() {
            let trashMenu = NSMenuItem()
            trashMenu.title = NSLocalizedString("Trash", comment: "Sidebar label")
            trashMenu.action = #selector(vc.notesTableView.delete(_:))
            trashMenu.tag = 555
            moveMenu.addItem(trashMenu)
            moveMenu.addItem(NSMenuItem.separator())
        }
                
        let projects = storage.getSortedProjects()
        for item in projects {
            if note.project == item || item.isTrash {
                continue
            }
            
            let menuItem = NSMenuItem()
            menuItem.title = item.getNestedLabel()
            menuItem.representedObject = item
            menuItem.action = #selector(vc.moveNote(_:))
            moveMenu.addItem(menuItem)
        }

        noteMenu.setSubmenu(moveMenu, for: moveMenuItem)
        loadHistory()
    }
    
    public func loadHistory() {
        guard let vc = ViewController.shared(),
            let notes = vc.notesTableView.getSelectedNotes(),
            let note = notes.first
        else { return }

        let title = NSLocalizedString("History", comment: "")
        let historyMenu = noteMenu.item(withTitle: title)
        historyMenu?.submenu?.removeAllItems()
        historyMenu?.isEnabled = false
        historyMenu?.isHidden = !note.project.hasCommitsDiffsCache()

        guard notes.count == 0x01 else { return }

        DispatchQueue.global().async {
            let commits = note.getCommits()

            DispatchQueue.main.async {
                guard commits.count > 0 else {
                    historyMenu?.isEnabled = false
                    return
                }
                
                for commit in commits {
                    let menuItem = NSMenuItem()
                    menuItem.title = commit.getDate()
                    menuItem.representedObject = commit
                    menuItem.action = #selector(vc.checkoutRevision(_:))
                    historyMenu?.submenu?.addItem(menuItem)
                }
                
                historyMenu?.isEnabled = true
            }
        }
    }
}
