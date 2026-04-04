//
//  ViewController+Setup.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Cocoa
import MASShortcut
import UserNotifications

extension ViewController {
    func performInitialViewLoad() {
        if #available(macOS 12.0, *) {
            let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
            var config = NSImage.SymbolConfiguration(textStyle: .body, scale: .large)
            config = config.applying(.init(paletteColors: [.systemTeal, .systemGray]))
            newNoteButton.image = image?.withSymbolConfiguration(config)
        } else {
            newNoteButton.image = NSImage(imageLiteralResourceName: "new_note_button").resize(to: CGSize(width: 20, height: 20))
        }

        configureShortcuts()
        configureDelegates()
        configureLayout()
        configureEditor()

        storage.checkWelcome()

        fsManager = FileSystemEventManager(storage: storage, delegate: self)
        fsManager?.start()

        loadBookmarks(data: UserDefaultsManagement.sftpAccessData)
        loadBookmarks(data: UserDefaultsManagement.gitPrivateKeyData)

        loadMoveMenu()
        loadSortBySetting()
        checkSidebarConstraint()

    #if CLOUD_RELATED_BLOCK
        registerKeyValueObserver()
    #endif

        ViewController.gitQueue.maxConcurrentOperationCount = 1
        notesTableView.doubleAction = #selector(self.doubleClickOnNotesTable)

        DispatchQueue.global().async {
            self.storage.loadInboxAndTrash()

            DispatchQueue.main.async {
                self.buildSearchQuery()
                self.configureSidebar()
                self.configureNoteList()
            }
        }
    }

    func restoreWindowStateAfterLaunch() {
        if UserDefaultsManagement.isFirstLaunch {
            if let window = self.view.window {
                let newSize = NSSize(width: 1200, height: window.frame.height)
                window.setContentSize(newSize)
                window.center()
            }

            self.sidebarSplitView.setPosition(200, ofDividerAt: 0)
            self.splitView.setPosition(300, ofDividerAt: 0)

            UserDefaultsManagement.sidebarTableWidth = 200
            UserDefaultsManagement.notesTableWidth = 300
            UserDefaultsManagement.isFirstLaunch = false
        }

        if let x = UserDefaultsManagement.lastScreenX,
           let y = UserDefaultsManagement.lastScreenY {
            view.window?.setFrameOrigin(NSPoint(x: x, y: y))
            UserDefaultsManagement.lastScreenX = nil
            UserDefaultsManagement.lastScreenY = nil
        }

        if UserDefaultsManagement.fullScreen {
            view.window?.toggleFullScreen(nil)
        }
    }

    public func preLoadProjectsData() {
        let projectsLoading = Date()
        let results = self.storage.getProjectDiffs()

        OperationQueue.main.addOperation {
            self.sidebarOutlineView.removeRows(projects: results.0)
            self.sidebarOutlineView.insertRows(projects: results.1)
            self.notesTableView.doVisualChanges(results: (results.2, results.3, []))
        }

        print("0. Projects diff loading finished in \(projectsLoading.timeIntervalSinceNow * -1) seconds")

        let diffLoading = Date()
        for project in self.storage.getProjects() {
            let changes = project.checkNotesCacheDiff()
            self.notesTableView.doVisualChanges(results: changes)
        }

        self.fsManager?.restart()
        self.storage.migrationAPIIds()

        print("1. Notes diff loading finished in \(diffLoading.timeIntervalSinceNow * -1) seconds")

        let tagsPoint = Date()

        self.scheduleSnapshots()
        self.schedulePull()
        self.storage.loadNotesContent()

        DispatchQueue.main.async {
            if self.storage.isCrashedLastTime && !UserDefaultsManagement.showWelcome {
                self.restoreSidebar()
            }

            UserDefaultsManagement.showWelcome = false
            self.sidebarOutlineView.loadAllTags()
        }

        print("2. Tags loading finished in \(tagsPoint.timeIntervalSinceNow * -1) seconds")

        let highlightCachePoint = Date()
        for note in self.storage.noteList {
            note.cache()
        }

        print("3. Notes attributes cache for \(self.storage.noteList.count) notes in \(highlightCachePoint.timeIntervalSinceNow * -1) seconds")

        let gitCachePoint = Date()
        self.cacheGitRepositories()
        print("4. git history cached in \(gitCachePoint.timeIntervalSinceNow * -1) seconds")
    }

    func configureLayout() {
        dropTitle()

        editor.configure()
        notesTableView.setDraggingSourceOperationMask(.every, forLocal: false)

        if UserDefaultsManagement.horizontalOrientation {
            self.splitView.isVertical = false
            notesCounterViewHeight.constant = 0
            notesCounter.isHidden = true
        }

        self.menuChangeCreationDate.title = NSLocalizedString("Change Creation Date", comment: "Menu")

        self.shareButton.sendAction(on: .leftMouseDown)
        self.setTableRowHeight()

        self.sidebarOutlineView.sidebarItems = sidebarDisplayController.makeSidebarItems()
        self.sidebarOutlineView.reloadData()

        sidebarOutlineView.selectionHighlightStyle = .regular
        sidebarOutlineView.backgroundColor = .windowBackgroundColor

        self.sidebarSplitView.autosaveName = "SidebarSplitView"
        self.splitView.autosaveName = "EditorSplitView"

        if self.splitView.subviews[0].frame.width < 10 {
            self.splitView.setPosition(300, ofDividerAt: 0)
        }

        notesScrollView.scrollerStyle = .overlay
        sidebarScrollView.scrollerStyle = .overlay

        if let cell = search.cell as? NSSearchFieldCell {
            cell.searchButtonCell?.target = self
            cell.searchButtonCell?.action = #selector(openRecentPopup(_:))
        }

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(onWakeNote(note:)), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onSleepNote(note:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(onUserSwitch(note:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onScreenLocked(note:)),
            name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onAccentColorChanged(note:)),
            name: NSNotification.Name(rawValue: "AppleColorPreferencesChangedNotification"),
            object: nil
        )

        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(onAccentColorChanged(note:)),
            name: NSNotification.Name(rawValue: "AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    func configureNoteList() {
        updateTable() {
            DispatchQueue.main.async {
                if let note = Storage.shared().welcomeNote {
                    self.notesTableView.select(note: note)
                    Storage.shared().welcomeNote = nil
                }

                self.restoreOpenedWindows()
                self.importAndCreate()
                NSApp.mainWindow?.makeFirstResponder(self.notesTableView)

                DispatchQueue.global().async {
                    self.preLoadProjectsData()
                }
            }
        }
    }

    func configureEditor() {
        NotesTextProcessor.hideSyntax = UserDefaultsManagement.wysiwygMode

        self.editor?.linkTextAttributes = [
            .foregroundColor: NSColor.init(named: "link")!
        ]

        self.editor.usesFindBar = true
        self.editor.isIncrementalSearchingEnabled = true

        editor.initTextStorage()
        editor.editorViewController = self
        self.editor.viewDelegate = self

        vcEditor = editor
        vcTitleLabel = titleLabel
        vcEditorScrollView = editAreaScroll
        vcNonSelectedLabel = nonSelectedLabel
        vcTitleBarView = titleBarView

        super.initView()
    }

    func configureShortcuts() {
        MASShortcutMonitor.shared().register(UserDefaultsManagement.newNoteShortcut, withAction: {
            self.makeNoteShortcut()
        })

        MASShortcutMonitor.shared().register(UserDefaultsManagement.searchNoteShortcut, withAction: {
            self.searchShortcut()
        })

        MASShortcutMonitor.shared().register(UserDefaultsManagement.quickNoteShortcut, withAction: {
            self.quickNote(self)
        })

        MASShortcutMonitor.shared().register(UserDefaultsManagement.activateShortcut, withAction: {
            self.searchShortcut(activate: true)
        })

        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.flagsChanged) {
            return $0
        }

        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.keyDown) {
            if self.keyDown(with: $0) {
                return $0
            }

            return nil
        }
    }

    func configureDelegates() {
        self.search.vcDelegate = self
        self.search.delegate = self.search
        self.sidebarSplitView.delegate = self
        self.sidebarOutlineView.viewDelegate = self

        if #available(macOS 10.14, *) {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func loadBookmarks(data: Data?) {
        if let accessData = data,
           let bookmarks = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSURL.self, NSData.self], from: accessData) as? [URL: Data] {

            for bookmark in bookmarks {
                var isStale = false

                do {
                    let url = try URL(
                        resolvingBookmarkData: bookmark.value,
                        options: NSURL.BookmarkResolutionOptions.withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )

                    if !url.startAccessingSecurityScopedResource() {
                        print("RSA key not available: \(url.path)")
                    } else {
                        print("Access for RSA key is successfull restored \(url)")
                    }
                } catch {
                    print("Error restoring sftp bookmark: \(error)")
                }
            }
        }
    }

    func loadSortBySetting() {
        // Sort By menu checkmarks are handled in EditorViewController.validateMenuItem
    }

    func registerKeyValueObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ubiquitousKeyValueStoreDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )

        if NSUbiquitousKeyValueStore.default.synchronize() == false {
            fatalError("This app was not built with the proper entitlement requests.")
        }

        NSUbiquitousKeyValueStore.default.synchronize()
    }

    @objc func ubiquitousKeyValueStoreDidChange(_ notification: NSNotification) {
        if let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            for key in keys {
                if key == "co.fluder.fsnotes.pins.shared" {
                    let result = storage.restoreCloudPins()

                    DispatchQueue.main.async {
                        if let added = result.added {
                            ViewController.shared()?.pin(selectedNotes: added)
                        }

                        if let removed = result.removed {
                            ViewController.shared()?.pin(selectedNotes: removed)
                        }
                    }
                }

                if key.startsWith(string: "es.fsnot.project-settings") {
                    let settingsKey = key.replacingOccurrences(of: "es.fsnot.project-settings", with: "")
                    if let project = storage.getProjectBy(settingsKey: settingsKey) {
                        project.reloadSettings()

                        DispatchQueue.main.async {
                            if let result = project.loadWebAPI() {
                                let toReload = result.0 + result.1

                                for note in toReload {
                                    ViewController.shared()?.notesTableView.reloadRow(note: note)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func cacheGitRepositories() {
        _ = Storage.shared().getProjects().filter({ $0.hasRepository() }).map({
            $0.cacheHistory()
        })
    }
}
