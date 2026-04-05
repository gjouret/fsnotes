//
//  ViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/20/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import MASShortcut
import Foundation
import Shout
import UserNotifications

class ViewController: EditorViewController,
    NSSplitViewDelegate,
    NSOutlineViewDelegate,
    NSOutlineViewDataSource,
    NSTextFieldDelegate,
    UNUserNotificationCenterDelegate {

    // MARK: - Properties
    public var fsManager: FileSystemEventManager?
    public var projectSettingsViewController: ProjectSettingsViewController?

    private var isPreLoaded = false
    // MARK: - Note Navigation History (browser-style back/forward)
    public var noteHistory: [Note] = []
    public var noteHistoryIndex: Int = -1
    var isNavigatingHistory = false

    // MARK: - Search ↔ Note selection FSM
    //
    // Rules:
    //   1. When search turns ON (query was empty, becomes non-empty):
    //      snapshot the currently active note into preSearchNote, then
    //      auto-select the top of the filtered list.
    //   2. While search is ON, if the user EXPLICITLY clicks/arrow-keys to
    //      a different note, that is a deliberate choice — preSearchNote is
    //      cleared so it won't be restored.
    //   3. When search turns OFF (query was non-empty, becomes empty):
    //      if preSearchNote is still set (user never made an explicit choice
    //      during search), restore it as the active note. Otherwise keep the
    //      currently selected note.
    //
    // `isProgrammaticSearchSelection` is set true around selections that the
    // search() flow makes itself (auto-select top, restore preSearchNote), so
    // tableViewSelectionDidChange can distinguish those from user clicks.
    public var preSearchNote: Note?
    public var searchWasActive: Bool = false
    public var isProgrammaticSearchSelection: Bool = false

    public func pushNoteHistory(_ note: Note) {
        guard !isNavigatingHistory else { return }

        if noteHistoryIndex < noteHistory.count - 1 {
            noteHistory = Array(noteHistory[0...noteHistoryIndex])
        }

        if noteHistory.last === note { return }

        noteHistory.append(note)
        noteHistoryIndex = noteHistory.count - 1

        if noteHistory.count > 50 {
            noteHistory.removeFirst()
            noteHistoryIndex -= 1
        }

        formattingToolbar?.updateNavigationButtons(canGoBack: canGoBack(), canGoForward: canGoForward())
    }

    public func canGoBack() -> Bool {
        return noteHistoryIndex > 0
    }

    public func canGoForward() -> Bool {
        return noteHistoryIndex < noteHistory.count - 1
    }

    @objc public func navigateBack(_ sender: Any) {
        guard canGoBack() else { return }
        noteHistoryIndex -= 1
        navigateToHistoryNote()
    }

    @objc public func navigateForward(_ sender: Any) {
        guard canGoForward() else { return }
        noteHistoryIndex += 1
        navigateToHistoryNote()
    }

    private func navigateToHistoryNote() {
        let note = noteHistory[noteHistoryIndex]
        isNavigatingHistory = true

        if search.stringValue.count > 0 {
            search.stringValue = ""
            search.lastSearchQuery = ""
            buildSearchQuery()
            updateTable {
                self.notesTableView.select(note: note)
            }
        } else {
            notesTableView.select(note: note)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isNavigatingHistory = false
        }
        formattingToolbar?.updateNavigationButtons(canGoBack: canGoBack(), canGoForward: canGoForward())
    }

    let storage = Storage.shared()
    lazy var sidebarDisplayController = SidebarDisplayController(viewController: self)
    
    var sidebarTimer = Timer()
    var selectRowTimer = Timer()

    let searchQueue = OperationQueue()
    let counterQueue = OperationQueue()

    public static var gitQueue = OperationQueue()
    public static var gitQueueBusy: Bool = false
    public static var gitQueueOperationDate: Date?

    public var prevCommit: Commit?

    /* Git */
    var updateViews = [Note]()

    var tagsScannerQueue = [Note]()

    override var representedObject: Any? {
        didSet { }  // Update the view, if already loaded.
    }

    // MARK: - IBOutlets
    @IBOutlet weak var nonSelectedLabel: NSTextField!

    @IBOutlet weak var splitView: EditorSplitView!
    @IBOutlet var editor: EditTextView!
    @IBOutlet weak var editAreaScroll: EditorScrollView!
    @IBOutlet weak var search: SearchTextField!
    @IBOutlet weak var notesTableView: NotesTableView!
    @IBOutlet var noteMenu: NSMenu!
    @IBOutlet weak var sidebarOutlineView: SidebarOutlineView!
    @IBOutlet weak var sidebarSplitView: NSSplitView!
    @IBOutlet weak var notesListCustomView: NSView!
    @IBOutlet weak var outlineHeader: OutlineHeaderView!
    @IBOutlet weak var showInSidebar: NSMenuItem!
    @IBOutlet weak var searchTopConstraint: NSLayoutConstraint!

    @IBOutlet weak var lockedFolder: NSTextField!
    @IBOutlet weak var newNoteButton: NSButton!
    @IBOutlet weak var titleLabel: TitleTextField! {
        didSet {
            configureTitleLabel()
        }
    }
    @IBOutlet weak var shareButton: NSButton!
    @IBOutlet weak var sortByOutlet: NSMenuItem!

    @IBOutlet weak var titleBarAdditionalView: NSVisualEffectView! {
        didSet {
            configureTitleBarAdditionalView()
        }
    }
    @IBOutlet weak var titleBarView: TitleBarView! {
        didSet {
            configureTitleBarView()
        }
    }

    @IBOutlet weak var lockUnlock: NSButton!

    @IBOutlet weak var sidebarScrollView: NSScrollView!
    @IBOutlet weak var notesScrollView: NSScrollView!

    @IBOutlet weak var menuChangeCreationDate: NSMenuItem!
    
    @IBOutlet weak var counter: NSTextField!
    @IBOutlet weak var notesCounterViewHeight: NSLayoutConstraint!
    @IBOutlet weak var notesCounter: NSTextField!
    
    // MARK: - Overrides
    
    override func viewDidLoad() {
        if isPreLoaded {
            return
        }

        isPreLoaded = true
        performInitialViewLoad()
    }
    
    override func viewDidAppear() {
        restoreWindowStateAfterLaunch()
    }

    // Ask project password before move to encrypted
    public static func shared() -> ViewController? {
        return AppDelegate.mainWindowController?.window?.contentViewController as? ViewController
    }

    public var aiChatPanel: AIChatPanelView?
    var aiChatEditorTrailingConstraint: NSLayoutConstraint?

}
