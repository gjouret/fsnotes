//
//  ViewController+Notes.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Cocoa
import UserNotifications

extension ViewController {
    @IBAction public func openRecentPopup(_ sender: Any) {
        search.searchesMenu = search.generateRecentMenu()
        let general = search.searchesMenu!.item(at: 0)
        search.searchesMenu!.popUp(positioning: general, at: NSPoint(x: 5, y: search.frame.height + 7), in: search)
    }

    @IBAction func searchAndCreate(_ sender: Any) {
        AppDelegate.mainWindowController?.window?.makeKeyAndOrderFront(nil)

        guard let vc = ViewController.shared() else { return }

        if let view = NSApplication.shared.mainWindow?.firstResponder as? NSTextView, let textField = view.superview?.superview {
            if textField.isKind(of: SearchTextField.self) {
                if vc.search.searchesMenu != nil {
                    vc.search.searchesMenu = nil
                } else {
                    vc.search.searchesMenu = vc.search.generateRecentMenu()
                    let general = vc.search.searchesMenu!.item(at: 0)
                    vc.search.searchesMenu!.popUp(positioning: general, at: NSPoint(x: 5, y: vc.search.frame.height + 7), in: vc.search)

                    return
                }
            }
        }

        let size = UserDefaultsManagement.horizontalOrientation
            ? vc.splitView.subviews[0].frame.height
            : vc.splitView.subviews[0].frame.width

        if size == 0 {
            toggleNoteList(self)
        }

        vc.search.window?.makeFirstResponder(vc.search)
    }

    @IBAction func sortBy(_ sender: NSMenuItem) {
        if let id = sender.identifier {
            let key = String(id.rawValue.dropFirst(3))
            let parsedSort: SortBy
            if key == SortBy.none.rawValue {
                parsedSort = SortBy.none
            } else {
                guard let parsed = SortBy(rawValue: key) else { return }
                parsedSort = parsed
            }
            let sortBy = parsedSort

            if sortBy != .none && sortBy.rawValue == UserDefaultsManagement.sort.rawValue {
                UserDefaultsManagement.sortDirection = !UserDefaultsManagement.sortDirection
            }

            UserDefaultsManagement.sort = sortBy

            if let project = storage.searchQuery.projects.first {
                if sortBy != .none && sortBy == project.settings.sortBy {
                    project.settings.sortDirection = project.settings.sortDirection == .asc ? .desc : .asc
                }
                project.settings.sortBy = sortBy
                project.saveSettings()
            } else {
                let virtualProject: Project?
                switch storage.searchQuery.type {
                case .All:
                    virtualProject = storage.allNotesProject
                case .Untagged:
                    virtualProject = storage.untaggedProject
                case .Todo:
                    virtualProject = storage.todoProject
                default:
                    virtualProject = storage.allNotesProject
                }

                if let virtualProject {
                    if sortBy != .none && sortBy == virtualProject.settings.sortBy {
                        virtualProject.settings.sortDirection = virtualProject.settings.sortDirection == .asc ? .desc : .asc
                    }
                    virtualProject.settings.sortBy = sortBy
                }
            }

            ViewController.shared()?.buildSearchQuery()
            storage.buildSortBy()
            ViewController.shared()?.updateTable()
        }
    }

    func setTableRowHeight() {
        notesTableView.rowHeight = CGFloat(21 + UserDefaultsManagement.cellSpacing)
        notesTableView.reloadData()
    }

    @IBAction func makeNote(_ sender: SearchTextField) {
        guard let vc = ViewController.shared() else { return }

        if let type = vc.getSidebarType(), type == .Trash {
            vc.sidebarOutlineView.deselectAllRows()
        }

        _ = createNote(name: sender.stringValue)
        sender.stringValue = String()
    }

    @IBAction func fileMenuNewNote(_ sender: Any) {
        AppDelegate.mainWindowController?.window?.makeKeyAndOrderFront(nil)

        guard let vc = ViewController.shared() else { return }

        if let project = vc.sidebarOutlineView.getSelectedProject(), project.isEncrypted, project.isLocked() {
            let menuItem = NSMenuItem()
            menuItem.identifier = NSUserInterfaceItemIdentifier("menu.newNote")
            vc.sidebarOutlineView.toggleFolderLock(menuItem)
            return
        }

        if let type = vc.getSidebarType(), type == .Trash {
            vc.sidebarOutlineView.deselectAllRows()
        }

        let inlineTags = vc.sidebarOutlineView.getSelectedInlineTags()
        _ = vc.createNote(content: inlineTags)
    }

    @IBAction func fileName(_ sender: NSTextField) {
        guard let note = notesTableView.getNoteFromSelectedRow() else { return }

        let value = sender.stringValue
        let url = note.url
        let newName = sender.stringValue + "." + note.url.pathExtension
        let isSoftRename = note.url.lastPathComponent.lowercased() == newName.lowercased()

        if note.project.fileExist(fileName: value, ext: note.url.pathExtension), !isSoftRename {
            self.alert = NSAlert()
            guard let alert = self.alert else { return }

            let informativeText = NSLocalizedString("Note with name \"%@\" already exists in selected directory.", comment: "")
            alert.alertStyle = .critical
            alert.informativeText = String(format: informativeText, value)
            alert.runModal()

            note.parseURL()
            sender.stringValue = note.getTitleWithoutLabel()
            return
        }

        guard value.count > 0 else {
            sender.stringValue = note.getTitleWithoutLabel()
            return
        }

        sender.isEditable = false

        let newUrl = note.getNewURL(name: value)
        UserDataService.instance.focusOnImport = newUrl

        if note.url.path == newUrl.path {
            return
        }

        note.overwrite(url: newUrl)

        do {
            try FileManager.default.moveItem(at: url, to: newUrl)
            print("File moved from \"\(url.deletingPathExtension().lastPathComponent)\" to \"\(newUrl.deletingPathExtension().lastPathComponent)\"")

            // When "First line as title" is enabled, update the note's
            // first line (H1 heading or first paragraph) to match the new name.
            if note.project.settings.isFirstLineAsTitle(), note.isMarkdown() {
                updateFirstLineTitle(note: note, newTitle: value)
            }
        } catch {
            note.overwrite(url: url)
        }
    }

    /// Update the first line of a note's content to match a new title.
    /// Used when "First line as title" is enabled and the note is renamed.
    private func updateFirstLineTitle(note: Note, newTitle: String) {
        let content = note.content.mutableCopy() as! NSMutableAttributedString
        let string = content.string as NSString
        guard string.length > 0 else { return }

        let firstLineRange = string.paragraphRange(for: NSRange(location: 0, length: 0))
        let firstLine = string.substring(with: firstLineRange).trimmingCharacters(in: .newlines)

        // Detect heading prefix (# , ## , etc.) and preserve it.
        var headingPrefix = ""
        if let hashRange = firstLine.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            headingPrefix = String(firstLine[hashRange])
        }

        let newFirstLine = headingPrefix + newTitle
        let replaceRange = NSRange(location: firstLineRange.location,
                                   length: firstLineRange.length - (firstLine.hasSuffix("\n") ? 0 : 0))
        // Keep the trailing newline if present.
        let hasTrailingNewline = string.substring(with: firstLineRange).hasSuffix("\n")
        let replacement = newFirstLine + (hasTrailingNewline ? "\n" : "")
        content.replaceCharacters(in: firstLineRange, with: replacement)

        note.content = content
        note.save(content: content)

        // Refresh the editor if this note is currently open.
        if editor.note == note {
            editor.fill(note: note)
        }
    }

    @IBAction func makeMenu(_ sender: Any) {
        guard let vc = ViewController.shared() else { return }

        if let type = vc.getSidebarType(), type == .Trash {
            vc.sidebarOutlineView.deselectAllRows()
        }

        _ = vc.createNote()
    }

    @IBAction func renameMenu(_ sender: Any) {
        guard let vc = ViewController.shared() else { return }
        vc.titleLabel.restoreResponder = vc.view.window?.firstResponder
        vc.switchTitleToEditMode()
    }

    @objc func switchTitleToEditMode() {
        guard let vc = ViewController.shared() else { return }

        if vc.notesTableView.selectedRow > -1 {
            vc.titleLabel.editModeOn()
            vc.titleBarAdditionalView.alphaValue = 0

            if let note = vc.editor.note, note.getFileName().isValidUUID {
                vc.titleLabel.stringValue = note.getFileName()
            }

            return
        }

        if let md = AppDelegate.mainWindowController,
           let actionOnDoubleClick = UserDefaults.standard.object(forKey: "AppleActionOnDoubleClick") as? String {
            switch actionOnDoubleClick {
            case "Maximize":
                md.maximizeWindow()
            case "Minimize":
                md.window?.performMiniaturize(nil)
            default:
                break
            }
        }
    }

    @IBAction func emptyTrash(_ sender: NSMenuItem) {
        let notes = storage.getAllTrash()
        for note in notes {
            _ = note.removeFile()
        }

        NSSound(named: "Pop")?.play()
    }

    @IBAction func deleteOrphanedAttachments(_ sender: NSMenuItem) {
        let fm = FileManager.default
        var orphanedFiles: [(url: URL, noteTitle: String)] = []
        var totalSize: UInt64 = 0

        // Scan all notes with textbundle containers
        for note in storage.noteList {
            guard note.container == .textBundle || note.container == .textBundleV2 else { continue }
            guard !note.isTrash() else { continue }

            let assetsURL = note.url.appendingPathComponent("assets")
            guard fm.fileExists(atPath: assetsURL.path) else { continue }

            // Read the note's markdown content
            guard let content = try? String(contentsOf: note.getURL(), encoding: .utf8) else { continue }

            // List all files in assets/
            guard let assetFiles = try? fm.contentsOfDirectory(at: assetsURL,
                                                                includingPropertiesForKeys: [.fileSizeKey],
                                                                options: .skipsHiddenFiles) else { continue }

            for assetFile in assetFiles {
                let filename = assetFile.lastPathComponent
                // Check if the filename is referenced anywhere in the markdown
                if !content.contains(filename) {
                    orphanedFiles.append((url: assetFile, noteTitle: note.getTitle() ?? note.fileName))
                    if let size = try? assetFile.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalSize += UInt64(size)
                    }
                }
            }
        }

        if orphanedFiles.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Orphaned Attachments"
            alert.informativeText = "All attachments in your notes are referenced in their markdown content."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let sizeMB = Double(totalSize) / 1_048_576.0
        let alert = NSAlert()
        alert.messageText = "Delete Orphaned Attachments?"
        alert.informativeText = "Found \(orphanedFiles.count) orphaned attachment(s) totaling \(String(format: "%.1f", sizeMB)) MB across your notes. These files are not referenced in any note's markdown.\n\nThey will be moved to the Trash folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Move orphaned files to Trash
        var deletedCount = 0
        for orphan in orphanedFiles {
            do {
                try fm.trashItem(at: orphan.url, resultingItemURL: nil)
                deletedCount += 1
            } catch {
                // Silently skip files that can't be trashed
            }
        }

        NSSound(named: "Pop")?.play()

        let doneAlert = NSAlert()
        doneAlert.messageText = "Cleanup Complete"
        doneAlert.informativeText = "Moved \(deletedCount) orphaned attachment(s) to Trash."
        doneAlert.alertStyle = .informational
        doneAlert.addButton(withTitle: "OK")
        doneAlert.runModal()
    }

    @IBAction func lockAll(_ sender: Any) {
        let projects = storage.getProjects().filter({ $0.isEncrypted && !$0.isLocked() })
        sidebarOutlineView.lock(projects: projects)

        let editors = AppDelegate.getEditTextViews()
        var unlockedEditors = [EditTextView]()

        for editor in editors {
            if let note = editor.note, note.isUnlocked() {
                unlockedEditors.append(editor)
            }
        }

        for editor in unlockedEditors {
            editor.lockEncryptedView()
        }

        let notes = storage.noteList.filter({ $0.isUnlocked() })
        for note in notes {
            if note.lock() {
                removeTags(note: note)
                notesTableView.reloadRow(note: note)
            }
        }

        if let window = notesTableView.window, window == view.window {
            window.makeFirstResponder(notesTableView)
        }
    }

    @available(macOS 10.14, *)
    public func sendNotification() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.badge, .sound, .alert]) { granted, error in
            if error != nil {
                print("User permission is not granted : \(granted)")
            }
        }

        let content = UNMutableNotificationContent()
        content.title = "Upload over SSH done"
        content.sound = .default

        let date = Date().addingTimeInterval(1)
        let dateComponent = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponent, repeats: false)

        let uuid = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuid, content: content, trigger: trigger)
        center.add(request) { _ in }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField, textField == titleLabel else { return }

        if titleLabel.isEditable == true {
            titleLabel.editModeOff()
            fileName(titleLabel)
            view.window?.makeFirstResponder(notesTableView)
        } else if let currentNote = notesTableView.getSelectedNote() {
            updateTitle(note: currentNote)
        }
    }

    public func reSort(note: Note) {
        if !updateViews.contains(note) {
            updateViews.append(note)
        }

        rowUpdaterTimer.invalidate()
        rowUpdaterTimer = Timer.scheduledTimer(timeInterval: 1.2, target: self, selector: #selector(updateTableViews), userInfo: nil, repeats: false)
    }

    public func removeForever() {
        guard let vc = ViewController.shared() else { return }
        guard let notes = vc.notesTableView.getSelectedNotes() else { return }
        guard let window = MainWindowController.shared() else { return }

        vc.alert = NSAlert()
        guard let alert = vc.alert else { return }

        alert.messageText = String(format: NSLocalizedString("Are you sure you want to irretrievably delete %d note(s)?", comment: ""), notes.count)
        alert.informativeText = NSLocalizedString("This action cannot be undone.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Remove note(s)", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.beginSheetModal(for: window) { returnCode in
            if returnCode == .alertFirstButtonReturn {
                let selectedRow = vc.notesTableView.selectedRowIndexes.min()
                vc.editor.clear()
                vc.storage.removeNotes(notes: notes, completely: true) { _ in
                    DispatchQueue.main.async {
                        vc.notesTableView.removeRows(notes: notes)
                        if let selectedRow, selectedRow > -1 {
                            vc.notesTableView.selectRow(selectedRow)
                        }
                    }
                }
            }

            vc.alert = nil
        }
    }

    @objc private func updateTableViews() {
        let editors = AppDelegate.getEditTextViews()

        notesTableView.beginUpdates()
        for note in updateViews {
            notesTableView.reloadRow(note: note)

            if search.stringValue.count == 0 {
                sortAndMove(note: note)
            }

            for editor in editors {
                if let window = editor.window, let editorNote = editor.note, editorNote == note {
                    if editor.viewDelegate != nil {
                        self.updateCounters(note: editorNote)
                    }

                    if !editor.isLastEdited, !window.isKeyWindow {
                        editor.editorViewController?.refillEditArea(force: true)
                    }
                }
            }
        }

        updateViews.removeAll()
        notesTableView.endUpdates()
    }

    public func updateCounters(note: Note? = nil, charRange: NSRange? = nil) {
        guard let note else {
            self.counter.stringValue = String()
            counterDebounceTimer?.invalidate()
            counterDebounceTimer = nil
            return
        }

        // Debounce (Perf plan #1c): arrow-key scrolling fires
        // `textViewDidChangeSelection` on every cursor move, and the
        // previous implementation queued+cancelled a BlockOperation on
        // each call. Coalesce into one count after 100ms of inactivity.
        counterDebounceTimer?.invalidate()
        counterDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1, repeats: false
        ) { [weak self] _ in
            self?.runCounterUpdate(note: note, charRange: charRange)
        }
    }

    private func runCounterUpdate(note: Note, charRange: NSRange?) {
        counterQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self] in
            let title: String
            if let charRange, charRange.length > 0, let string = note.content.string.substring(nsRange: charRange) {
                title = "W: \(string.countWords()) | C: \(string.countChars())"
            } else {
                title = "W: \(note.content.string.countWords()) | C: \(note.content.string.countChars())"
            }
            if operation.isCancelled { return }
            DispatchQueue.main.async {
                self?.counter.stringValue = title
            }
        }
        counterQueue.addOperation(operation)
    }

    public func updateNotesCounter() {
        let count = notesTableView.selectedRowIndexes.count > 0
            ? notesTableView.selectedRowIndexes.count
            : notesTableView.countNotes()

        notesCounter.stringValue = "N: \(count)"
    }

    func getSidebarType() -> SidebarItemType? {
        let sidebarItem = sidebarOutlineView.item(atRow: sidebarOutlineView.selectedRow) as? SidebarItem
        return sidebarItem?.type
    }

    public func getSidebarItem() -> SidebarItem? {
        return sidebarOutlineView.item(atRow: sidebarOutlineView.selectedRow) as? SidebarItem
    }

    func updateTable(completion: @escaping () -> Void = {}) {
        let timestamp = Date().toMillis()
        self.search.timestamp = timestamp
        self.searchQueue.cancelAllOperations()

        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self] in
            guard let self else { return }

            let projects = Storage.shared().searchQuery.projects
            for project in projects {
                self.preLoadNoteTitles(in: project)
            }

            let source = self.storage.noteList
            var notes = [Note]()

            for note in source {
                if operation.isCancelled {
                    completion()
                    return
                }

                if self.storage.searchQuery.isFit(note: note) {
                    notes.append(note)
                }
            }

            let orderedNotesList: [Note]
            if self.storage.getSortByState() == .none {
                let currentList = self.notesTableView.getNoteList()
                let noteSet = Set(notes)
                var preserved = currentList.filter { noteSet.contains($0) }
                let existingSet = Set(preserved)
                let newNotes = notes.filter { !existingSet.contains($0) }
                preserved.append(contentsOf: newNotes)
                orderedNotesList = preserved
            } else {
                orderedNotesList = self.storage.sortNotes(noteList: notes, operation: operation)
            }

            if orderedNotesList == self.notesTableView.getNoteList() {
                completion()
                return
            }

            if operation.isCancelled {
                return
            }

            guard orderedNotesList.count > 0 else {
                DispatchQueue.main.async {
                    self.editor.clear()
                    self.notesTableView.setNoteList(notes: orderedNotesList)
                    self.notesTableView.reloadData()
                    self.updateNotesCounter()
                    completion()
                }
                return
            }

            DispatchQueue.main.async {
                self.notesTableView.setNoteList(notes: orderedNotesList)
                self.notesTableView.reloadData()
                self.updateNotesCounter()
                completion()
            }
        }

        self.searchQueue.addOperation(operation)
    }

    private func preLoadNoteTitles(in project: Project) {
        if (UserDefaultsManagement.sort == .title || project.settings.sortBy == .title) && project.settings.isFirstLineAsTitle() {
            let notes = storage.noteList.filter({ $0.project == project })
            for note in notes {
                if !note.isLoaded {
                    note.load()
                }

                note.loadPreviewInfo()
            }
        }
    }

    public func reloadFonts() {
        let webkitPreview = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wkPreview")
        try? FileManager.default.removeItem(at: webkitPreview)

        Storage.shared().resetCacheAttributes()

        let editors = AppDelegate.getEditTextViews()
        for editor in editors {
            if let evc = editor.editorViewController {
                NotesTextProcessor.resetCaches()
                evc.refillEditArea(force: true)
            }
        }
    }

    public func buildSearchQuery() {
        let searchQuery = SearchQuery()

        var projects = [Project]()
        var tags = [String]()
        var type: SidebarItemType?

        if let sidebarProjects = sidebarOutlineView.getSidebarProjects() {
            projects = sidebarProjects
        }

        if let project = Storage.shared().welcomeProject {
            projects = [project]
        }

        if let sidebarTags = sidebarOutlineView.getSidebarTags() {
            tags = sidebarTags

            let currentModifiers = NSEvent.modifierFlags
            let isCommandPressed = currentModifiers.contains(.command)
            let isShiftPressed = currentModifiers.contains(.shift)

            if isCommandPressed && isShiftPressed {
                searchQuery.tagsModifierAnd(true)
            }
        }

        let indexPaths = self.sidebarOutlineView.selectedRowIndexes
        for indexPath in indexPaths {
            if let item = self.sidebarOutlineView.item(atRow: indexPath) as? SidebarItem,
               item.type == .All || item.type == .Untagged || item.type == .Todo || item.type == .Trash || item.type == .Inbox {
                type = item.type
            }
        }

        if projects.count == 0 && type == nil {
            type = .All
        }

        searchQuery.projects = projects
        searchQuery.tags = tags
        searchQuery.setFilter(search.stringValue)

        if let type {
            searchQuery.setType(type)
        }

        self.storage.setSearchQuery(value: searchQuery)
    }

    @objc func selectNullTableRow(note: Note) {
        self.selectRowTimer.invalidate()
        self.selectRowTimer = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(self.selectRowInstant), userInfo: note, repeats: false)
    }

    @objc private func selectRowInstant(_ timer: Timer) {
        if let note = timer.userInfo as? Note, let index = self.notesTableView.getIndex(for: note) {
            notesTableView.selectRowIndexes([index], byExtendingSelection: false)
            notesTableView.scrollRowToVisible(index)
        }
    }

    func focusTable() {
        let index = self.notesTableView.selectedRow > -1 ? self.notesTableView.selectedRow : 0
        self.notesTableView.window?.makeFirstResponder(self.notesTableView)
        self.notesTableView.selectRowIndexes([index], byExtendingSelection: false)
        self.notesTableView.scrollRowToVisible(index)
    }

    func cleanSearchAndEditArea(shouldBecomeFirstResponder: Bool = true, completion: (() -> ())? = nil) {
        search.stringValue = ""
        search.lastSearchQuery = ""

        if shouldBecomeFirstResponder {
            search.becomeFirstResponder()
        }

        notesTableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        editor.clear()
        updateCounters(note: nil)

        self.buildSearchQuery()
        self.updateTable {
            DispatchQueue.main.async {
                if shouldBecomeFirstResponder {
                    self.sidebarOutlineView.reloadTags()
                }

                completion?()
            }
        }
    }

    func makeNoteShortcut() {
        let clipboard = NSPasteboard.general.string(forType: NSPasteboard.PasteboardType.string)

        if let clipboard {
            _ = createNote(content: clipboard)

            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else { return }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }

            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("Clipboard successfully saved", comment: "")
            content.body = clipboard
            content.sound = .default

            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
        }
    }

    func searchShortcut(activate: Bool = false) {
        guard let mainWindow = MainWindowController.shared() else { return }

        if NSApplication.shared.isActive && !NSApplication.shared.isHidden && !mainWindow.isMiniaturized {
            NSApplication.shared.hide(nil)
            return
        }

        UserDefaultsManagement.lastScreenX = nil
        UserDefaultsManagement.lastScreenY = nil

        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(self)

        guard let controller = mainWindow.contentViewController as? ViewController else { return }
        if !activate {
            mainWindow.makeFirstResponder(controller.search)
        }
    }

    public func sortAndMove(note: Note, project: Project? = nil) {
        if storage.getSortByState() == .none {
            return
        }

        guard let srcIndex = notesTableView.getIndex(for: note) else { return }

        let resorted = storage.sortNotes(noteList: notesTableView.getNoteList())
        guard let dstIndex = resorted.firstIndex(of: note) else { return }

        if srcIndex != dstIndex {
            notesTableView.moveRow(at: srcIndex, to: dstIndex)
            notesTableView.setNoteList(notes: resorted)
            notesTableView.scrollRowToVisible(dstIndex)
        }
    }

    func pin(selectedNotes: [Note], toggle: Bool = false) {
        if selectedNotes.count == 0 {
            return
        }

        var state = notesTableView.getNoteList()
        var updatedNotes = [(Int, Note)]()

        for selectedNote in selectedNotes {
            guard let atRow = notesTableView.getIndex(for: selectedNote),
                  let rowView = notesTableView.rowView(atRow: atRow, makeIfNecessary: false) as? NoteRowView,
                  let cell = rowView.view(atColumn: 0) as? NoteCellView else { continue }

            updatedNotes.append((atRow, selectedNote))

            if toggle {
                selectedNote.togglePin()
            }

            cell.renderPin()
        }

        let resorted = storage.sortNotes(noteList: notesTableView.getNoteList())

        notesTableView.beginUpdates()
        let nowPinned = updatedNotes.filter { _, note in note.isPinned }
        for (row, note) in nowPinned {
            guard let newRow = resorted.firstIndex(where: { $0 === note }) else { continue }
            notesTableView.moveRow(at: row, to: newRow)
            let moved = state.remove(at: row)
            state.insert(moved, at: newRow)
        }

        let nowUnpinned = updatedNotes
            .filter({ (_, note) -> Bool in !note.isPinned })
            .compactMap({ (_, note) -> (Int, Note)? in
                guard let currentRow = state.firstIndex(where: { $0 === note }) else { return nil }
                return (currentRow, note)
            })
        for (row, note) in nowUnpinned.reversed() {
            guard let newRow = resorted.firstIndex(where: { $0 === note }) else { continue }
            notesTableView.moveRow(at: row, to: newRow)
            let moved = state.remove(at: row)
            state.insert(moved, at: newRow)
        }

        notesTableView.setNoteList(notes: resorted)
        notesTableView.endUpdates()
    }

    func external(selectedNotes: [Note]) {
        if selectedNotes.count == 0 {
            return
        }

        for note in selectedNotes {
            var path = note.url.path
            if note.isTextBundle() && !note.isUnlocked(), let url = note.getContentFileURL() {
                path = url.path
            }

            NSWorkspace.shared.openFile(path, withApplication: UserDefaultsManagement.externalEditor)
        }
    }

    public func restoreOpenedWindows() {
        guard let documentDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let projectsDataUrl = documentDir.appendingPathComponent("editors.settings")

        guard let data = try? Data(contentsOf: projectsDataUrl) else { return }
        guard let unarchivedData = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSArray.self, NSDictionary.self, NSString.self, NSData.self, NSNumber.self, NSURL.self],
            from: data
        ) as? [[String: Any]] else { return }

        var mainKey = false
        for item in unarchivedData.reversed() {
            guard let url = item["url"] as? URL,
                  let frameData = item["frame"] as? Data,
                  let main = item["main"] as? Bool,
                  let isKeyWindow = item["key"] as? Bool,
                  let note = self.storage.getBy(url: url) else { continue }

            if main {
                if isKeyWindow {
                    mainKey = true
                }

                if let index = self.notesTableView.getIndex(for: note) {
                    self.notesTableView.saveNavigationHistory(note: note)
                    self.notesTableView.selectRow(index)
                    self.notesTableView.scrollRowToVisible(index)
                    self.editor.window?.makeFirstResponder(self.editor)
                }
            } else {
                guard let frame = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: frameData)?.rectValue else {
                    continue
                }

                self.openInNewWindow(note: note, frame: frame)
            }
        }

        if mainKey {
            NSApp.activate(ignoringOtherApps: true)
            self.view.window?.makeKeyAndOrderFront(self)
        }
    }

    public func importAndCreate() {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            if let url = appDelegate.url {
                appDelegate.url = nil
                appDelegate.search(url: url)
                return
            }

            if let urls = appDelegate.urls {
                appDelegate.importNotes(urls: urls)
                return
            }

            let name = appDelegate.newName
            let content = appDelegate.newContent

            if name != nil || content != nil,
               let note = self.createNote(name: name ?? "", content: content ?? "", openInNewWindow: appDelegate.newWindow),
               appDelegate.newWindow {
                openInNewWindow(note: note)
            }
        }
    }

    public func isVisibleNoteList() -> Bool {
        guard let vc = ViewController.shared() else { return false }

        let size = UserDefaultsManagement.horizontalOrientation
            ? vc.splitView.subviews[0].frame.height
            : vc.splitView.subviews[0].frame.width

        if size == 0 || vc.splitView.shouldHideDivider {
            return false
        }

        return true
    }
}
