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
            let clickGesture = NSClickGestureRecognizer()
            clickGesture.target = self
            clickGesture.numberOfClicksRequired = 2
            clickGesture.buttonMask = 0x1
            clickGesture.action = #selector(switchTitleToEditMode)
            
            titleLabel.addGestureRecognizer(clickGesture)
        }
    }
    @IBOutlet weak var shareButton: NSButton!
    @IBOutlet weak var sortByOutlet: NSMenuItem!

    @IBOutlet weak var titleBarAdditionalView: NSVisualEffectView! {
        didSet {
            let layer = CALayer()
            layer.frame = titleBarAdditionalView.bounds
            layer.backgroundColor = .clear
            titleBarAdditionalView.wantsLayer = true
            titleBarAdditionalView.layer = layer
            titleBarAdditionalView.alphaValue = 0
        }
    }
    @IBOutlet weak var titleBarView: TitleBarView! {
        didSet {
            titleBarView.onMouseExitedClosure = { [weak self] in
                DispatchQueue.main.async {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.35
                        self?.titleBarAdditionalView.alphaValue = 0
                        self?.titleLabel.backgroundColor = .clear
                    }, completionHandler: nil)
                }
            }
            titleBarView.onMouseEnteredClosure = { [weak self] in
                DispatchQueue.main.async {
                    guard self?.titleLabel.isEnabled == false || self?.titleLabel.isEditable == false else { return }
                    
                    if let note = self?.editor.note {
                        if note.isEncryptedAndLocked() {
                            self?.lockUnlock.image = NSImage(named: NSImage.lockLockedTemplateName)
                        } else {
                            self?.lockUnlock.image = NSImage(named: NSImage.lockUnlockedTemplateName)
                        }
                    }

                    self?.lockUnlock.isHidden = (self?.editor.note == nil)

                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.35
                        self?.titleBarAdditionalView.alphaValue = 1
                    }, completionHandler: nil)
                }
            }
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

        // Must before event manager starts
        self.storage.checkWelcome()
        
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
    
    override func viewDidAppear() {

        // Init window size
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
        
        // Restore window position
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

    // Ask project password before move to encrypted
    public static func shared() -> ViewController? {
        return AppDelegate.mainWindowController?.window?.contentViewController as? ViewController
    }

    public var aiChatPanel: AIChatPanelView?
    var aiChatEditorTrailingConstraint: NSLayoutConstraint?

}
