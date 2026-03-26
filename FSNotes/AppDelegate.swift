//
//  AppDelegate.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/20/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import UserNotifications
import WebKit
import libcmark_gfm

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var prefsWindowController: PrefsWindowController?
    var aboutWindowController: AboutWindowController?
    var statusItem: NSStatusItem?

    public var urls: [URL]? = nil
    public var url: URL? = nil
    public var newName: String? = nil
    public var newContent: String? = nil
    public var folderName: String? = nil
    public var newWindow: Bool = false

    public static var mainWindowController: MainWindowController?
    public static var noteWindows = [NSWindowController]()
    
    public static var appTitle: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return name ?? Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as! String
    }
    
    public static var gitProgress: GitProgress?

    func applicationWillFinishLaunching(_ notification: Notification) {
        checkStorageChanges()
        loadDockIcon()
        
        if UserDefaultsManagement.showInMenuBar {
            constructMenu()
        }
        
        if !UserDefaultsManagement.showDockIcon {
            let transformState = ProcessApplicationTransformState(kProcessTransformToUIElementApplication)
            var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
            TransformProcessType(&psn, transformState)

            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Check for render-comparison mode (used by automated visual tests)
        if ProcessInfo.processInfo.arguments.contains("--render-comparison") {
            // Force light mode immediately for consistent comparison
            NSApp.appearance = NSAppearance(named: .aqua)
            for window in NSApp.windows {
                window.appearance = NSAppearance(named: .aqua)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                // Also set on any windows created after launch
                for window in NSApp.windows {
                    window.appearance = NSAppearance(named: .aqua)
                }
                self.runRenderComparison()
            }
        }

        // Ensure the font panel is closed when the app starts, in case it was
        // left open when the app quit.
        NSFontManager.shared.fontPanel(false)?.orderOut(self)

        applyAppearance()

        #if CLOUD_RELATED_BLOCK
        if let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents").standardized {
            
            if (!FileManager.default.fileExists(atPath: iCloudDocumentsURL.path, isDirectory: nil)) {
                do {
                    try FileManager.default.createDirectory(at: iCloudDocumentsURL, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("Home directory creation: \(error)")
                }
            }
        }
        #endif

        if UserDefaultsManagement.storagePath == nil {
            self.requestStorageDirectory()
            return
        }

        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        
        guard let mainWC = storyboard.instantiateController(withIdentifier: "MainWindowController") as? MainWindowController else {
            fatalError("Error getting main window controller")
        }
        
        AppDelegate.mainWindowController = mainWC
        mainWC.window?.makeKeyAndOrderFront(nil)
    }
        
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if (!flag) {
            AppDelegate.mainWindowController?.makeNew()
        }
                
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaultsManagement.crashedLastTime = false
        
        AppDelegate.saveWindowsState()
        
        Storage.shared().saveUploadPaths()
        
        let webkitPreview = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wkPreview")
        try? FileManager.default.removeItem(at: webkitPreview)

        let printDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Print")
        try? FileManager.default.removeItem(at: printDir)

        let encryption = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Encryption")
        try? FileManager.default.removeItem(at: encryption)

        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent("ThumbnailsBig")
        try? FileManager.default.removeItem(at: temporary)

        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        guard let mainWC = storyboard.instantiateController(withIdentifier: "MainWindowController") as? MainWindowController else {
            return
        }

        if let x = mainWC.window?.frame.origin.x, let y = mainWC.window?.frame.origin.y {
            UserDefaultsManagement.lastScreenX = Int(x)
            UserDefaultsManagement.lastScreenY = Int(y)
        }
        
        Storage.shared().saveProjectsCache()
        
        print("Termination end, crash status: \(UserDefaultsManagement.crashedLastTime)")
    }
    
    private static func saveWindowsState() {
        var result = [[String: Any]]()
                
        let noteWindows = self.noteWindows.sorted(by: { $0.window!.orderedIndex > $1.window!.orderedIndex })
        for windowController in noteWindows {
            if let frame = windowController.window?.frame,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: frame, requiringSecureCoding: true),
               let controller = windowController.contentViewController as? NoteViewController,
                   let note = controller.editor.note {


                let key = windowController.window?.isKeyWindow == true

                result.append(["frame": data, "preview": controller.editor.isPreviewEnabled(), "url": note.url, "main": false, "key": key])
            }
        }
        
        // Main frame
        if let vc = ViewController.shared(), let note = vc.editor?.note, let mainFrame = vc.view.window?.frame,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: mainFrame, requiringSecureCoding: true) {

            let key = vc.view.window?.isKeyWindow == true
            
            result.append(["frame": data, "preview": vc.editor.isPreviewEnabled(), "url": note.url, "main": true, "key": key])
        }
    
        let projectsData = try? NSKeyedArchiver.archivedData(withRootObject: result, requiringSecureCoding: true)
        if let documentDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? projectsData?.write(to: documentDir.appendingPathComponent("editors.settings"))
        }
    }
    
    private func applyAppearance() {
        if UserDefaultsManagement.appearanceType == .Dark {
            NSApp.appearance = NSAppearance.init(named: NSAppearance.Name.darkAqua)
            UserDataService.instance.isDark = true
        }

        if UserDefaultsManagement.appearanceType == .Light {
            NSApp.appearance = NSAppearance.init(named: NSAppearance.Name.aqua)
            UserDataService.instance.isDark = false
        }

        if UserDefaultsManagement.appearanceType == .System, NSAppearance.current.isDark {
            UserDataService.instance.isDark = true
        }
    }
    
    private func restartApp() {
        guard let resourcePath = Bundle.main.resourcePath else { return }
        
        let url = URL(fileURLWithPath: resourcePath)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        
        exit(0)
    }
    
    private func requestStorageDirectory() {
        var directoryURL: URL? = nil
        if let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            directoryURL = URL(fileURLWithPath: path)
        }
        
        let panel = NSOpenPanel()
        panel.directoryURL = directoryURL
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Please select default storage directory"
        panel.begin { (result) -> Void in
            if result == .OK {
                guard let url = panel.url else {
                    return
                }
                
                let bookmarks = SandboxBookmark.sharedInstance()
                bookmarks.save(url: url)

                UserDefaultsManagement.storageType = .custom
                UserDefaultsManagement.customStoragePath = url.path
                
                self.restartApp()
            } else {
                exit(EXIT_SUCCESS)
            }
        }
    }
    
    func constructMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button, let image = NSImage(named: "menuBar") {
            image.size.width = 20
            image.size.height = 20
            button.image = image
        }

        statusItem?.button?.action = #selector(AppDelegate.clickStatusBarItem(sender:))
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    public func attachMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: NSLocalizedString("New Note", comment: ""), action: #selector(AppDelegate.new(_:)), keyEquivalent: "n"))

        let newWindow = NSMenuItem(title: NSLocalizedString("New Note in New Window", comment: ""), action: #selector(AppDelegate.createInNewWindow(_:)), keyEquivalent: "n")
        var modifier = NSEvent.modifierFlags
        modifier.insert(.command)
        modifier.insert(.shift)
        newWindow.keyEquivalentModifierMask = modifier
        menu.addItem(newWindow)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Search and create", comment: ""), action: #selector(AppDelegate.searchAndCreate(_:)), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Settings", comment: ""), action: #selector(AppDelegate.openPreferences(_:)), keyEquivalent: ","))

        let lock = NSMenuItem(title: NSLocalizedString("Lock All Encrypted", comment: ""), action: #selector(ViewController.shared()?.lockAll(_:)), keyEquivalent: "l")
        lock.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(lock)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit FSNotes", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem?.menu = menu
    }

    @objc func clickStatusBarItem(sender: NSStatusItem) {
        let event = NSApp.currentEvent!

        if event.type == NSEvent.EventType.leftMouseUp {
            
            // Hide active not hidden and not miniaturized
            if !NSApp.isHidden && NSApp.isActive {
                if let mainWindow = AppDelegate.mainWindowController?.window, !mainWindow.isMiniaturized {
                    NSApp.hide(nil)
                    return
                }
            }
            
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            
            AppDelegate.mainWindowController?.window?.makeKeyAndOrderFront(nil)
            ViewController.shared()?.search.becomeFirstResponder()
            
            return
        }

        attachMenu()

        DispatchQueue.main.async {
            if let statusItem = self.statusItem, let button = statusItem.button {
                statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: button.frame.origin.x, y: button.frame.height + 10), in: button)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
    
    // MARK: IBActions
    
    @IBAction func openMainWindow(_ sender: Any) {
        AppDelegate.mainWindowController?.makeNew()
    }
    
    @IBAction func openHelp(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/glushchenko/fsnotes/wiki")!)
    }

    @IBAction func openReportsAndRequests(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/glushchenko/fsnotes/issues/new/choose")!)
    }

    @IBAction func openSite(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://fsnot.es")!)
    }
    
    @IBAction func openPreferences(_ sender: Any?) {
        if prefsWindowController == nil {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)
            
            prefsWindowController = storyboard.instantiateController(withIdentifier: "Preferences") as? PrefsWindowController
        }
        
        guard let prefsWindowController = prefsWindowController else { return }
        
        prefsWindowController.showWindow(nil)
        prefsWindowController.window?.makeKeyAndOrderFront(prefsWindowController)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @IBAction func new(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        ViewController.shared()?.fileMenuNewNote(self)
    }
    
    @IBAction func createInNewWindow(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        ViewController.shared()?.createInNewWindow(self)
    }
    
    @IBAction func searchAndCreate(_ sender: Any?) {
        AppDelegate.mainWindowController?.makeNew()
        NSApp.activate(ignoringOtherApps: true)
        
        guard let vc = ViewController.shared() else { return }
        
        DispatchQueue.main.async {
            vc.search.window?.makeFirstResponder(vc.search)
        }
    }
    
    @IBAction func removeMenuBar(_ sender: Any?) {
        guard let statusItem = statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
    
    @IBAction func addMenuBar(_ sender: Any?) {
        constructMenu()
    }

    @IBAction func showAboutWindow(_ sender: AnyObject) {
        if aboutWindowController == nil {
            let storyboard = NSStoryboard(name: "Main", bundle: nil)

            aboutWindowController = storyboard.instantiateController(withIdentifier: "About") as? AboutWindowController
        }

        guard let aboutWindowController = aboutWindowController else { return }

        aboutWindowController.showWindow(nil)
        aboutWindowController.window?.makeKeyAndOrderFront(aboutWindowController)

        NSApp.activate(ignoringOtherApps: true)
    }

    public func loadDockIcon() {
        var image: Image?

        switch UserDefaultsManagement.dockIcon {
        case 0:
            image = NSImage(named: "modern")
            break
        case 1:
            image = NSImage(named: "AppIconClassic")
            break
        default:
            break
        }

        guard let im = image else { return }

        let appDockTile = NSApplication.shared.dockTile
        if #available(OSX 10.12, *) {
            appDockTile.contentView = NSImageView(image: im)
        }

        appDockTile.display()
    }

    private func checkStorageChanges() {
        if Storage.shared().shouldMovePrompt,
            let local = UserDefaultsManagement.localDocumentsContainer,
            let iCloudDrive = UserDefaultsManagement.iCloudDocumentsContainer
        {
            let message = NSLocalizedString("We are detect that you are install FSNotes from Mac App Store with default storage in iCloud Drive, do you want to move old database in iCloud Drive?", comment: "")

            promptToMoveDatabase(from: local, to: iCloudDrive, messageText: message)
        }
    }

    public func promptToMoveDatabase(from currentURL: URL, to url : URL, messageText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText =
            NSLocalizedString("Otherwise, the database of your notes will be available at: ", comment: "") + currentURL.path

        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("No", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Yes", comment: ""))

        if alert.runModal() == .alertSecondButtonReturn {
            move(from: currentURL, to: url)

            let localTrash = currentURL.appendingPathComponent("Trash", isDirectory: true)
            let cloudTrash = url.appendingPathComponent("Trash", isDirectory: true)

            move(from: localTrash, to: cloudTrash)
        }
    }

    private func move(from currentURL: URL, to url: URL) {
        if let list = try? FileManager.default.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: nil, options: .init()) {

            if !FileManager.default.fileExists(atPath: currentURL.path) {
                return
            }

            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }

            for item in list {
                let fileName = item.lastPathComponent

                do {
                    let dst = url.appendingPathComponent(fileName)
                    try FileManager.default.moveItem(at: item, to: dst)
                } catch {

                    if ["Trash", "Welcome"].contains(fileName) {
                        continue
                    }

                    let exist = NSAlert()
                    var message = NSLocalizedString("We can not move \"{DST_PATH}\" because this item already exist in selected destination.", comment: "")

                    message = message.replacingOccurrences(of: "{DST_PATH}", with: item.path)

                    exist.messageText = message
                    exist.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    exist.runModal()
                }
            }
        }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {

        ViewController.shared()?.restoreUserActivityState(userActivity)

        return true
    }

    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {

        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    public static func getEditTextViews() -> [EditTextView] {
        var views = getOpenedEditTextViews()
                
        if let controller = mainWindowController?.contentViewController as? ViewController {
            views.append(controller.editor)
        }
        
        return views
    }
    
    public static func getOpenedEditTextViews() -> [EditTextView] {
        var views = [EditTextView]()
        
        for window in noteWindows {
            if let controller = window.contentViewController as? NoteViewController {
                views.append(controller.editor)
            }
        }
        
        return views
    }

    // MARK: - Render Comparison Test

    func runRenderComparison() {
        let outputDir = "/tmp/fsnotes_compare"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Find the ViewController — it may be the contentViewController or a child
        // Force light mode for consistent comparison
        NSApp.appearance = NSAppearance(named: .aqua)

        var vc: ViewController?
        for window in NSApp.windows {
            if let v = window.contentViewController as? ViewController {
                vc = v
                break
            }
            // Check children
            for child in (window.contentViewController?.children ?? []) {
                if let v = child as? ViewController {
                    vc = v
                    break
                }
            }
        }

        guard let viewController = vc else {
            NSLog("[RenderComparison] No ViewController found in %d windows", NSApp.windows.count)
            for w in NSApp.windows {
                NSLog("[RenderComparison] Window: %@ vc: %@", w.title, String(describing: type(of: w.contentViewController)))
            }
            NSApp.terminate(nil)
            return
        }

        let editor = viewController.editor!

        // If a specific note title is provided via --compare-note argument, select it
        if let noteArgIdx = ProcessInfo.processInfo.arguments.firstIndex(of: "--compare-note"),
           noteArgIdx + 1 < ProcessInfo.processInfo.arguments.count {
            let targetTitle = ProcessInfo.processInfo.arguments[noteArgIdx + 1]
            NSLog("[RenderComparison] Looking for note: %@", targetTitle)
            let allNotes = Storage.shared().noteList
            if let targetNote = allNotes.first(where: { $0.title == targetTitle }) {
                viewController.notesTableView.select(note: targetNote)
                // Wait for note to load, then continue comparison
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.continueRenderComparison(viewController: viewController, editor: editor, outputDir: outputDir)
                }
                return
            }
        }

        continueRenderComparison(viewController: viewController, editor: editor, outputDir: outputDir)
    }

    private func continueRenderComparison(viewController: ViewController, editor: EditTextView, outputDir: String) {
        guard let note = editor.note,
              let storage = editor.textStorage else {
            NSLog("[RenderComparison] No note loaded")
            NSApp.terminate(nil)
            return
        }

        let noteTitle = note.title
        NSLog("[RenderComparison] Rendering note: %@", noteTitle)

        // Debug: write block model to file
        if let processor = editor.textStorageProcessor {
            var debugLines = "[RenderComparison] Block model has \(processor.blocks.count) blocks:\n"
            for (i, block) in processor.blocks.enumerated() {
                let typeStr: String
                switch block.type {
                case .paragraph: typeStr = "paragraph"
                case .heading(let l): typeStr = "heading(\(l))"
                case .headingSetext(let l): typeStr = "headingSetext(\(l))"
                case .codeBlock(let lang): typeStr = "codeBlock(\(lang ?? "nil"))"
                case .blockquote: typeStr = "blockquote"
                case .unorderedList: typeStr = "unorderedList"
                case .orderedList: typeStr = "orderedList"
                case .todoItem(let c): typeStr = "todoItem(\(c))"
                case .horizontalRule: typeStr = "horizontalRule"
                case .table: typeStr = "table"
                case .yamlFrontmatter: typeStr = "yamlFrontmatter"
                case .empty: typeStr = "empty"
                }
                debugLines += "  [\(i)] \(typeStr) range=(\(block.range.location),\(block.range.length)) syntaxRanges=\(block.syntaxRanges.count)\n"
            }
            // Also check LayoutManager's processor reference
            if let lm = editor.layoutManager as? LayoutManager {
                debugLines += "LayoutManager.processor: \(lm.processor != nil ? "SET" : "NIL")\n"
                debugLines += "LayoutManager.processor?.blocks.count: \(lm.processor?.blocks.count ?? -1)\n"
            }
            // Check paragraph styles at START and END of first few blocks
            for i in 0..<min(5, processor.blocks.count) {
                let block = processor.blocks[i]
                let startPos = block.range.location
                let endPos = min(NSMaxRange(block.range) - 1, storage.length - 1)
                if startPos < storage.length {
                    if let pStart = storage.attribute(.paragraphStyle, at: startPos, effectiveRange: nil) as? NSParagraphStyle {
                        debugLines += "  -> pStyle START[\(startPos)]: before=\(pStart.paragraphSpacingBefore) after=\(pStart.paragraphSpacing)\n"
                    }
                    if endPos > startPos, endPos < storage.length {
                        if let pEnd = storage.attribute(.paragraphStyle, at: endPos, effectiveRange: nil) as? NSParagraphStyle {
                            debugLines += "  -> pStyle END[\(endPos)]: before=\(pEnd.paragraphSpacingBefore) after=\(pEnd.paragraphSpacing)\n"
                        }
                    }
                }
            }
            try? debugLines.write(toFile: outputDir + "/blocks_debug.txt", atomically: true, encoding: .utf8)
        }

        // Save markdown before bullet substitution changes it
        let markdown = storage.string

        // 1. Wait for async bullet substitution to complete, then capture NSTextView
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Force light mode on the editor for capture
            editor.appearance = NSAppearance(named: .aqua)
            editor.window?.appearance = NSAppearance(named: .aqua)
            editor.enclosingScrollView?.appearance = NSAppearance(named: .aqua)
            // Force re-display with light appearance
            editor.needsDisplay = true
            editor.display()

            let nstextviewPNG = self.captureNSTextView(editor: editor, outputDir: outputDir)

            // 2. Capture MPreview rendering
            self.captureMPreview(markdown: markdown, outputDir: outputDir, viewController: viewController) {
            // 3. Compare the two images
            if let nsImg = NSImage(contentsOfFile: nstextviewPNG),
               let mpImg = NSImage(contentsOfFile: outputDir + "/mpreview.png") {
                self.compareImages(nsImage: nsImg, mpImage: mpImg, outputDir: outputDir)
            }

                NSLog("[RenderComparison] Done. Output in %@", outputDir)
                NSLog("[RenderComparison] Open: open %@", outputDir)
                NSApp.terminate(nil)
            }
        }
    }

    private func captureNSTextView(editor: EditTextView, outputDir: String) -> String {
        let path = outputDir + "/nstextview.png"

        // Force complete layout
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)

        // Get the full document size
        let usedRect = editor.layoutManager?.usedRect(for: editor.textContainer!) ?? editor.bounds
        let captureRect = NSRect(x: 0, y: 0, width: editor.bounds.width, height: usedRect.height + 20)

        // Use cacheDisplay which handles flipped coordinates and Retina correctly
        guard let bitmapRep = editor.bitmapImageRepForCachingDisplay(in: captureRect) else {
            NSLog("[RenderComparison] Failed to create bitmap rep")
            return path
        }
        editor.cacheDisplay(in: captureRect, to: bitmapRep)

        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
            NSLog("[RenderComparison] Saved NSTextView: %@ (%dx%d)", path, bitmapRep.pixelsWide, bitmapRep.pixelsHigh)
        }

        return path
    }

    // WARNING: DEBUG ONLY — captureMPreview uses WKWebView/MPreview solely for the
    // --render-comparison visual test. It is not called in normal app operation.
    // All production rendering uses NSTextView (WYSIWYG mode). Do not add new
    // production code paths that invoke this method.
    private func captureMPreview(markdown: String, outputDir: String, viewController: ViewController, completion: @escaping () -> Void) {
        let path = outputDir + "/mpreview.png"

        // Try both Bundle.main and the executable's Resources directory
        let bundleURL: URL
        if let url = Bundle.main.url(forResource: "MPreview", withExtension: "bundle") {
            bundleURL = url
        } else {
            // Fallback: look relative to the executable
            let execURL = Bundle.main.bundleURL
            let resourcesURL = execURL.appendingPathComponent("Contents/Resources/MPreview.bundle")
            if FileManager.default.fileExists(atPath: resourcesURL.path) {
                bundleURL = resourcesURL
            } else {
                NSLog("[RenderComparison] MPreview.bundle not found at %@ or %@",
                      Bundle.main.resourceURL?.path ?? "nil", resourcesURL.path)
                completion()
                return
            }
        }

        // Use the ACTUAL MPreview template (index.html) — same as MPreviewView uses
        guard let indexURL = bundleURL.appendingPathComponent("index.html") as URL?,
              var template = try? String(contentsOf: indexURL, encoding: .utf8) else {
            NSLog("[RenderComparison] index.html not found in MPreview.bundle")
            completion()
            return
        }

        // Convert markdown to HTML using cmark-gfm (same pipeline as MPreviewView)
        let html = renderMarkdownHTML(markdown: markdown) ?? ""

        // Replace template placeholders inline below.
        // NOTE: This intentionally duplicates MPreviewView.htmlFromTemplate. This is a
        // DEBUG-only render-comparison path that must not depend on MPreviewView's full
        // initialization (note context, appearance prefs, etc.), so the substitutions
        // are kept explicit and self-contained here.
        template = template.replacingOccurrences(of: "{NOTE_BODY}", with: html)
        template = template.replacingOccurrences(of: "{FSNOTES_APPEARANCE}", with: "")  // light mode
        template = template.replacingOccurrences(of: "{FSNOTES_PLATFORM}", with: "macos")
        template = template.replacingOccurrences(of: "{WEB_PATH}", with: "")
        template = template.replacingOccurrences(of: "{TITLE}", with: "Comparison")
        template = template.replacingOccurrences(of: "{INLINE_CSS}", with: "")
        template = template.replacingOccurrences(of: "{MATH_JAX_JS}", with: "")

        let fullHTML = template

        // Match the editor width for fair comparison
        let editorWidth = viewController.editor?.bounds.width ?? 800
        let renderHeight: CGFloat = 3000

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: editorWidth, height: renderHeight))

        // WKWebView must be in a window for takeSnapshot to work
        // Use a visible (but offscreen) window on Retina display for 2x rendering
        let offscreenWindow = NSWindow.makeOffscreen(width: editorWidth, height: renderHeight)
        offscreenWindow.contentView = webView
        offscreenWindow.orderBack(nil)

        webView.loadHTMLString(fullHTML, baseURL: bundleURL)

        // Wait for load, then snapshot
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let config = WKSnapshotConfiguration()
            config.rect = NSRect(x: 0, y: 0, width: editorWidth, height: renderHeight)
            // Force 2x scale for Retina-quality output
            config.snapshotWidth = NSNumber(value: Int(editorWidth * 2))

            webView.takeSnapshot(with: config) { image, error in
                if let image = image, let pngData = image.PNGRepresentation {
                    try? pngData.write(to: URL(fileURLWithPath: path))
                    NSLog("[RenderComparison] Saved MPreview: %@", path)
                } else {
                    NSLog("[RenderComparison] MPreview snapshot failed: %@", error?.localizedDescription ?? "unknown")
                }
                completion()
            }
        }
    }

    private func compareImages(nsImage: NSImage, mpImage: NSImage, outputDir: String) {
        guard let nsRep = nsImage.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let mpRep = mpImage.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else {
            NSLog("[RenderComparison] Failed to get bitmap reps for comparison")
            return
        }

        let width = min(nsRep.pixelsWide, mpRep.pixelsWide)
        let height = min(nsRep.pixelsHigh, mpRep.pixelsHigh)

        guard width > 0, height > 0 else { return }

        // Create diff image
        let diffRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!

        var diffPixels = 0
        let totalPixels = width * height
        let threshold: Int = 32 // per-channel tolerance

        for y in 0..<height {
            for x in 0..<width {
                let nsColor = nsRep.colorAt(x: x, y: y) ?? .black
                let mpColor = mpRep.colorAt(x: x, y: y) ?? .black

                let dr = abs(Int(nsColor.redComponent * 255) - Int(mpColor.redComponent * 255))
                let dg = abs(Int(nsColor.greenComponent * 255) - Int(mpColor.greenComponent * 255))
                let db = abs(Int(nsColor.blueComponent * 255) - Int(mpColor.blueComponent * 255))

                if dr > threshold || dg > threshold || db > threshold {
                    diffPixels += 1
                    diffRep.setColor(.red, atX: x, y: y)
                } else {
                    // Show dimmed version of the MPreview pixel
                    let dimmed = NSColor(
                        red: mpColor.redComponent * 0.3 + 0.7,
                        green: mpColor.greenComponent * 0.3 + 0.7,
                        blue: mpColor.blueComponent * 0.3 + 0.7,
                        alpha: 1.0
                    )
                    diffRep.setColor(dimmed, atX: x, y: y)
                }
            }
        }

        let diffPercent = Double(diffPixels) / Double(totalPixels) * 100.0

        if let pngData = diffRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: outputDir + "/diff.png"))
        }

        NSLog("[RenderComparison] Pixel difference: %.2f%% (%d/%d pixels)", diffPercent, diffPixels, totalPixels)
        NSLog("[RenderComparison] Threshold: 5.0%% — %@", diffPercent <= 5.0 ? "PASS" : "FAIL")
    }
}
