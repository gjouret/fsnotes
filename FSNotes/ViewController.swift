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
    // Note navigation history (browser-style back/forward)
    public var noteHistory: [Note] = []
    public var noteHistoryIndex: Int = -1
    var isNavigatingHistory = false

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
