//
//  Preferences.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 8/8/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

#if os(OSX)
    import Cocoa
#else
    import UIKit
#endif

public class UserDefaultsManagement {
    
    static var apiPath = "https://api.fsnot.es/"
    static var webPath = "https://p.fsnot.es/"

    public static var global = NSUbiquitousKeyValueStore.default
    
#if os(OSX)
    typealias Color = NSColor
    typealias Image = NSImage
    typealias Font = NSFont

    public static var shared: UserDefaults? = UserDefaults.standard
    public static var DefaultFontSize = 14
#else
    typealias Color = UIColor
    typealias Image = UIImage
    typealias Font = UIFont

    public static var shared: UserDefaults? = UserDefaults(suiteName: "group.es.fsnot.user.defaults")
    static var DefaultFontSize = 17
#endif

    static var DefaultSnapshotsInterval = 1
    static var DefaultSnapshotsIntervalMinutes = 5
    
    static var DefaultFontColor = Color.black
    static var DefaultBgColor = Color.white

    private struct Constants {
        static let AllowTouchID = "allowTouchID"
        static let AppearanceTypeKey = "appearanceType"
        static let AskCommitMessage = "askCommitMessage"
        static let ApiBookmarksData = "apiBookmarksData"
        static let AutoInsertHeader = "autoInsertHeader"
        static let AutoVersioning = "autoVersioning"
        static let AutomaticSpellingCorrection = "automaticSpellingCorrection"
        static let AutomaticQuoteSubstitution = "automaticQuoteSubstitution"
        static let AutomaticDataDetection = "automaticDataDetection"
        static let AutomaticLinkDetection = "automaticLinkDetection"
        static let AutomaticTextReplacement = "automaticTextReplacement"
        static let AutomaticDashSubstitution = "automaticDashSubstitution"
        static let AutomaticConflictsResolution = "automaticConflictsResolution"
        static let BackupManually = "backupManually"
        static let BgColorKey = "bgColorKeyed"
        static let boldKey = "boldKeyed"
        static let CacheDiff = "cacheDiff"
        static let CellSpacing = "cellSpacing"
        static let CellFrameOriginY = "cellFrameOriginY"
        static let ClickableLinks = "clickableLinks"
        static let CodeFontNameKey = "codeFont"
        static let CodeFontSizeKey = "codeFontSize"
        static let codeBlockHighlight = "codeBlockHighlight"
        static let CodeBlocksWithSyntaxHighlighting = "codeBlocksWithSyntaxHighlighting"
        static let codeTheme = "codeTheme2025"
        static let ContinuousSpellChecking = "continuousSpellChecking"
        static let CrashedLastTime = "crashedLastTime"
        static let CustomWebServer = "customWebServer"
        static let DefaultLanguageKey = "defaultLanguage"
        static let DefaultKeyboardKey = "defaultKeyboard"
        static let FontNameKey = "font"
        static let FontSizeKey = "fontsize"
        static let FontColorKey = "fontColorKeyed"
        static let FullScreen = "fullScreen"
        static let FirstLineAsTitle = "firstLineAsTitle"
        static let MaxChildDirs = "maxChildDirs"
        static let NoteType = "noteType"
        static let NoteExtension = "noteExtension"
        static let GrammarChecking = "grammarChecking"
        static let GitStorage = "gitStorage"
        static let GitUsername = "gitUsername"
        static let GitPassword = "gitPassword"
        static let GitOrigin = "gitOrigin"
        static let GitPrivateKeyData = "gitPrivateKeyData"
        static let GitPasspharse = "gitPasspharse"
        static let HideDate = "hideDate"
        static let HideOnDeactivate = "hideOnDeactivate"
        static let HideSidebar = "hideSidebar"
        static let HidePreviewKey = "hidePreview"
        static let HidePreviewImages = "hidePreviewImages"
        static let iCloudDrive = "iCloudDrive"
        static let IndentUsing = "indentUsing"
        static let InlineTags = "inlineTags"
        static let IsFirstLaunch = "isFirstLaunch"
        static let italicKey = "italicKeyed"
        static let LastCommitMessage = "lastCommitMessage"
        static let LastNews = "lastNews"
        static let LastSelectedPath = "lastSelectedPath"
        static let LastScreenX = "lastScreenX"
        static let LastScreenY = "lastScreenY"
        static let LastSidebarItem = "lastSidebarItem"
        static let LastProjectURL = "lastProjectUrl"
        static let LineHeightMultipleKey = "lineHeightMultipleKey"
        static let LineSpacingEditorKey = "lineSpacingEditor"
        static let LineWidthKey = "lineWidth"
        static let LockOnSleep = "lockOnSleep"
        static let LockOnScreenActivated = "lockOnScreenActivated"
        static let LockAfterIDLE = "lockAfterIdle"
        static let LockAfterUserSwitch = "lockAfterUserSwitch"
        static let MarginSizeKey = "marginSize"
        static let MasterPasswordHint = "masterPasswordHint"
        static let MathJaxPreview = "mathJaxPreview"
        static let WysiwygMode = "wysiwygMode"
        static let AIAPIKey = "aiAPIKey"
        static let AIProvider = "aiProvider"
        static let AIModel = "aiModel"
        static let AIEndpoint = "aiEndpoint"
        static let AIOllamaHost = "aiOllamaHost"
        static let NonContiguousLayout = "allowsNonContiguousLayout"
        static let NoteContainer = "noteContainer"
        static let Preview = "preview"
        static let PreviewFontSize = "previewFontSize"
        static let ProjectsKey = "projects"
        static let ProjectsKeyNew = "ProjectsKeyNew"
        static let RecentSearches = "recentSearches"
        static let PullInterval = "pullInterval"
        static let SaveInKeychain = "saveInKeychain"
        static let SearchHighlight = "searchHighlighting"
        static let SeparateRepo = "separateRepo"
        static let SftpHost = "sftpHost"
        static let SftpPort = "sftpPort"
        static let SftpPath = "sftpPath"
        static let SftpPasspharse = "sftpPassphrase"
        static let SftpWeb = "sftpWeb"
        static let SftpUsername = "sftpUsername"
        static let SftpPassword = "sftpPassword"
        static let SftpKeysAccessData = "sftpKeysAccessData"
        static let SftpUploadBookmarksData = "sftpUploadBookmarksData"
        static let SharedContainerKey = "sharedContainer"
        static let ShowDockIcon = "showDockIcon"
        static let shouldFocusSearchOnESCKeyDown = "shouldFocusSearchOnESCKeyDown"
        static let ShowInMenuBar = "showInMenuBar"
        static let SmartInsertDelete = "smartInsertDelete"
        static let SnapshotsInterval = "snapshotsInterval"
        static let SnapshotsIntervalMinutes = "snapshotsIntervalMinutes"
        static let SortBy = "sortBy"
        static let StorageType = "storageType"
        static let StoragePathKey = "storageUrl"
        static let TableOrientation = "isUseHorizontalMode"
        static let TextMatchAutoSelection = "textMatchAutoSelection"
        static let TrashKey = "trashKey"
        static let UploadKey = "uploadKey"
        static let UseTextBundleToStoreDates = "useTextBundleToStoreDates"
        static let AutocloseBrackets = "autocloseBrackets"
        static let UseSubviewTables = "useSubviewTables"
        static let Welcome = "welcome2026"
    }

    // Phase 7.5.c — Theme proxy layer.
    //
    // The editor typography / layout properties below (codeFontName,
    // codeFontSize, fontName, fontSize, editorLineSpacing,
    // lineHeightMultiple, lineWidth, marginSize, italic,
    // bold) are computed proxies over `Theme.shared`. Getters read
    // from Theme each call (no caching — a `Theme.shared = ...` swap
    // is visible to readers immediately). Setters mutate Theme and
    // post `Theme.didChangeNotification` so live observers re-render.
    //
    // Legacy UD key constants (e.g. `Constants.CodeFontNameKey`) are
    // retained because `migrateEditorKeysIntoTheme75c()` uses them to
    // read pre-7.5.c saved values into Theme on first launch.
    //
    // The IBAction layer in `PreferencesEditorViewController` still
    // calls `persistActiveTheme()` (→ `Theme.saveActiveThemeDebounced`)
    // to drive the JSON write — this proxy deliberately does NOT trigger
    // a save on every set (a disk write per UD access would be wrong).

    static var codeFontName: String {
        get { BlockStyleTheme.shared.codeFontName }
        set {
            BlockStyleTheme.shared.codeFontName = newValue
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    static var codeFontSize: Int {
        get { Int(BlockStyleTheme.shared.codeFontSize) }
        set {
            BlockStyleTheme.shared.codeFontSize = CGFloat(newValue)
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    static var fontName: String? {
        get { BlockStyleTheme.shared.noteFontName }
        set {
            BlockStyleTheme.shared.noteFontName = newValue
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    static var fontSize: Int {
        get { Int(BlockStyleTheme.shared.noteFontSize) }
        set {
            BlockStyleTheme.shared.noteFontSize = CGFloat(newValue)
            UserDefaultsManagement.postTheme75cChange()
        }
    }
    
    static var externalEditor: String {
        get {
            
            if let name = shared?.object(forKey: "externalEditorApp") as? String, name.count > 0 {
                return name
            } else {
                return "TextEdit"
            }
        }
        set {
            shared?.set(newValue, forKey: "externalEditorApp")
        }
    }

    /// Phase 8 (Subview Tables): table blocks render via a
    /// view-provider-hosted `TableContainerView` containing per-cell
    /// `NSTextView` subviews.
    ///
    /// The old preference key is retained only as migration ballast:
    /// older installs may have persisted `false`, but the native route
    /// is no longer a selectable production path.
    static var useSubviewTables: Bool {
        get {
            return true
        }
        set {
            shared?.set(true, forKey: Constants.UseSubviewTables)
        }
    }

    static var horizontalOrientation: Bool {
        get {
            if let returnHorizontalOrientation = shared?.object(forKey: Constants.TableOrientation) as? Bool {
                return returnHorizontalOrientation
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.TableOrientation)
            
            // reset the note list height / width
            shared?.removeObject(forKey: "NSSplitView Subview Frames EditorSplitView")
            
            if (newValue){
                // for top-to-bottom layout, set note list cell height to 0
                cellSpacing = 0
            } else {
                // for side-by-side layout, reset note list cell height to default
                shared?.removeObject(forKey: Constants.CellSpacing)
            }
        }
    }
    
    static var iCloudDocumentsContainer: URL? {
        get {
            if let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents").standardized {
                if (!FileManager.default.fileExists(atPath: iCloudDocumentsURL.path, isDirectory: nil)) {
                    do {
                        try FileManager.default.createDirectory(at: iCloudDocumentsURL, withIntermediateDirectories: true, attributes: nil)
                        
                        return iCloudDocumentsURL.standardized
                    } catch {
                        print("Home directory creation: \(error)")
                    }
                } else {
                   return iCloudDocumentsURL.standardized
                }
            }

            return nil
        }
    }
    
    static var localDocumentsContainer: URL? {
        get {
            if var path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {

#if os(iOS)
                if path.starts(with: "/var") {
                    path = "/private\(path)"
                }
#endif

                return URL(fileURLWithPath: path, isDirectory: true)
            }
 
            return nil
        }
    }
    
    static var customStoragePath: String? {
        get {
            if let storagePath = shared?.object(forKey: Constants.StoragePathKey) as? String {
                if FileManager.default.isWritableFile(atPath: storagePath) {
                    storageType = .custom
                    return storagePath
                } else {
                    print("Storage path not accessible, settings resetted to default")
                }
            }
            
            return nil
        }
        
        set {
            shared?.set(newValue, forKey: Constants.StoragePathKey)
        }
    }
    
    static var storagePath: String? {
        get {
            if let customStoragePath = self.customStoragePath {
                return customStoragePath
            }

            if let iCloudDocumentsURL = self.iCloudDocumentsContainer {
                storageType = .iCloudDrive
                return iCloudDocumentsURL.path
            }

            if let localDocumentsContainer = localDocumentsContainer {
                storageType = .local
                return localDocumentsContainer.path
            }

            return nil
        }
    }

    public static var storageType: StorageType {
        get {
            if let type = shared?.object(forKey: Constants.StorageType) as? Int {
                return StorageType(rawValue: type) ?? .none
            }
            return .none
        }
        set {
            shared?.set(newValue.rawValue, forKey: Constants.StorageType)
        }
    }
    
    static var storageUrl: URL? {
        get {
            if let path = storagePath {
                let expanded = NSString(string: path).expandingTildeInPath

                return URL.init(fileURLWithPath: expanded, isDirectory: true).standardized
            }
            
            return nil
        }
    }

    static var preview: Bool {
        get {
            if let preview = shared?.object(forKey: Constants.Preview) as? Bool {
                return preview
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.Preview)
        }
    }
    
    static var lastSync: Date? {
        get {
            if let sync = shared?.object(forKey: "lastSync") as? Date {
                return sync
            } else {
                return nil
            }
        }
        set {
            shared?.set(newValue, forKey: "lastSync")
        }
    }
    
    static var hideOnDeactivate: Bool {
        get {
            if let hideOnDeactivate = shared?.object(forKey: Constants.HideOnDeactivate) as? Bool {
                return hideOnDeactivate
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.HideOnDeactivate)
        }
    }
    
    static var cellSpacing: Int {
        get {
            if let cellSpacing = shared?.object(forKey: Constants.CellSpacing) as? NSNumber {
                return cellSpacing.intValue
            } else {
                return 33
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.CellSpacing)
        }
    }
        
    static var cellViewFrameOriginY: CGFloat? {
        get {
            if let number = shared?.object(forKey: Constants.CellFrameOriginY) as? NSNumber {
                return CGFloat(number.doubleValue)
            }
            return nil
        }
        set {
            if let newValue = newValue {
                shared?.set(Double(newValue), forKey: Constants.CellFrameOriginY)
            } else {
                shared?.removeObject(forKey: Constants.CellFrameOriginY)
            }
        }
    }
    
    static var hidePreview: Bool {
        get {
            if let returnMode = shared?.object(forKey: Constants.HidePreviewKey) as? Bool {
                return returnMode
            } else {
                return false
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.HidePreviewKey)
        }
    }
        
    static var sort: SortBy {
        get {
            // Read from UserDefaults first (reliable), then iCloud KV Store
            if let result = shared?.object(forKey: Constants.SortBy) as? String {
                if result == "none" {
                    return SortBy.none
                }
                return SortBy(rawValue: result) ?? .modificationDate
            }
            if let result = global.object(forKey: Constants.SortBy) as? String {
                if result == "none" {
                    return SortBy.none
                }
                return SortBy(rawValue: result) ?? .modificationDate
            }
            return .modificationDate
        }
        set {
            shared?.set(newValue.rawValue, forKey: Constants.SortBy)
            global.set(newValue.rawValue, forKey: Constants.SortBy)
        }
    }
    
    static var sortDirection: Bool {
        get {
            if let returnMode = global.object(forKey: "sortDirection") as? Bool {
                return returnMode
            } else {
                return true
            }
        }
        set {
            global.set(newValue, forKey: "sortDirection")
        }
    }
    
    static var hideSidebar: Bool {
        get {
            if let hide = shared?.object(forKey: "hideSidebar") as? Bool {
                return hide
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: "hideSidebar")
        }
    }
    
    static var notesTableWidth: CGFloat {
        get {
            if let value = shared?.object(forKey: "sidebarSize") as? Int {
                return CGFloat(value)
            }

            #if os(iOS)
                return 0
            #else
                return 300
            #endif
        }
        set {
            shared?.set(Int(newValue), forKey: "sidebarSize")
        }
    }
    
    static var hideSidebarTable: Bool {
        get {
            if let hide = shared?.object(forKey: "hideRealSidebar") as? Bool {
                return hide
            }
            
            return false
        }
        set {
            shared?.set(newValue, forKey: "hideRealSidebar")
        }
    }
    
    static var sidebarTableWidth: CGFloat {
        get {
            if let size = shared?.object(forKey: "realSidebarSize") as? Int {
                return CGFloat(size)
            }
            return 150
        }
        set {
            shared?.set(Int(newValue), forKey: "realSidebarSize")
        }
    }

    /// Persisted width of the notes-list pane (inner split view, left subview).
    /// Saved whenever the user resizes the pane to a sensible width so we can
    /// restore it after window auto-resize collapses the pane to 0.
    static var notesListWidth: CGFloat {
        get {
            if let size = shared?.object(forKey: "notesListWidth") as? Int {
                return CGFloat(size)
            }
            return 300
        }
        set {
            shared?.set(Int(newValue), forKey: "notesListWidth")
        }
    }
    
    static var codeBlockHighlight: Bool {
        get {
            if let highlight = shared?.object(forKey: Constants.codeBlockHighlight) as? Bool {
                return highlight
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.codeBlockHighlight)
        }
    }

    // Phase 7.4 — user-selected theme name (nil = bundled default).
    //
    // Stored as a plain string so the plist is human-readable. The
    // matching JSON file is resolved at read time via
    // `Theme.load(named:)`; if the user deletes or renames the file
    // the loader falls back to the bundled default without crashing.
    public static var currentThemeName: String? {
        get {
            if let name = shared?.string(forKey: "currentThemeName"),
               !name.isEmpty {
                return name
            }
            return nil
        }
        set {
            if let newValue = newValue {
                shared?.set(newValue, forKey: "currentThemeName")
            } else {
                shared?.removeObject(forKey: "currentThemeName")
            }
        }
    }

    static var lastSelectedURL: URL? {
        get {
            if let url = shared?.url(forKey: Constants.LastSelectedPath) {
                return url
            }
            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastSelectedPath)
        }
    }
    
    static var focusInEditorOnNoteSelect: Bool {
        get {
            if let result = shared?.object(forKey: "focusInEditorOnNoteSelect") as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: "focusInEditorOnNoteSelect")
        }
    }
    
    static var defaultKeyboard: String? {
        get {
            if let dk = shared?.string(forKey: Constants.DefaultKeyboardKey) as? String {
                return dk
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.DefaultKeyboardKey)
        }
    }
    
    static var defaultLanguage: Int {
        get {
            if let dl = shared?.object(forKey: Constants.DefaultLanguageKey) as? Int {
                return dl
            }

            if let code = NSLocale.current.languageCode {
                return LanguageType.withCode(rawValue: code)
            }
            
            return 0
        }
        set {
            shared?.set(newValue, forKey: Constants.DefaultLanguageKey)
        }
    }
    
    static var autocloseBrackets: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutocloseBrackets) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutocloseBrackets)
        }
    }
    
    static var lastProjectURL: URL? {
        get {
            if let lastProject = shared?.url(forKey: Constants.LastProjectURL) {
                return lastProject
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastProjectURL)
        }
    }

    static var lastSidebarItem: Int? {
        get {
            if let index = shared?.object(forKey: Constants.LastSidebarItem) as? Int {
                return index
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastSidebarItem)
        }
    }
    
    static var showDockIcon: Bool {
        get {
            if let result = shared?.object(forKey: Constants.ShowDockIcon) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.ShowDockIcon)
        }
    }
    
    // Phase 7.5.c proxy — reads/writes through `Theme.shared.editorLineSpacing`.
    // The original body truncated `Float(Int(result))` at read time; we
    // preserve that by doing the same truncation on the CGFloat read.
    static var editorLineSpacing: Float {
        get { Float(Int(BlockStyleTheme.shared.editorLineSpacing)) }
        set {
            BlockStyleTheme.shared.editorLineSpacing = CGFloat(newValue)
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    // Phase 7.5.c proxy — reads/writes through `Theme.shared.lineHeightMultiple`.
    static var lineHeightMultiple: CGFloat {
        get { BlockStyleTheme.shared.lineHeightMultiple }
        set {
            BlockStyleTheme.shared.lineHeightMultiple = newValue
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    // Phase 7.5.c proxy — reads/writes through `Theme.shared.lineWidth`.
    static var lineWidth: Float {
        get { Float(BlockStyleTheme.shared.lineWidth) }
        set {
            BlockStyleTheme.shared.lineWidth = CGFloat(newValue)
            UserDefaultsManagement.postTheme75cChange()
        }
    }
    
    static var textMatchAutoSelection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.TextMatchAutoSelection) as? Bool {
                return result
            }
            
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.TextMatchAutoSelection)
        }
    }
    
    static var continuousSpellChecking: Bool {
        get {
            if let result = shared?.object(forKey: Constants.ContinuousSpellChecking) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.ContinuousSpellChecking)
        }
    }
    
    static var grammarChecking: Bool {
        get {
            if let result = shared?.object(forKey: Constants.GrammarChecking) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.GrammarChecking)
        }
    }
    
    static var smartInsertDelete: Bool {
        get {
            if let result = shared?.object(forKey: Constants.SmartInsertDelete) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.SmartInsertDelete)
        }
    }
    
    static var automaticSpellingCorrection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticSpellingCorrection) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticSpellingCorrection)
        }
    }
    
    static var automaticQuoteSubstitution: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticQuoteSubstitution) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticQuoteSubstitution)
        }
    }
    
    static var automaticDataDetection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticDataDetection) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticDataDetection)
        }
    }
    
    static var automaticLinkDetection: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticLinkDetection) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticLinkDetection)
        }
    }
        
    static var automaticTextReplacement: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticTextReplacement) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticTextReplacement)
        }
    }
    
    static var automaticDashSubstitution: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutomaticDashSubstitution) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AutomaticDashSubstitution)
        }
    }

    static var isHiddenSidebar: Bool {
        get {
            if let result = shared?.object(forKey: Constants.HideSidebar) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.HideSidebar)
        }
    }
    
    static var shouldFocusSearchOnESCKeyDown: Bool {
        get {
            if let result = UserDefaults.standard.object(forKey: Constants.shouldFocusSearchOnESCKeyDown) as? Bool {
                return result
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.shouldFocusSearchOnESCKeyDown)
        }
    }
    
    static var automaticConflictsResolution: Bool {
        get {
            if let result = UserDefaults.standard.object(forKey: Constants.AutomaticConflictsResolution) as? Bool {
                return result
            }
            return false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.AutomaticConflictsResolution)
        }
    }

    static var useTextBundleMetaToStoreDates: Bool {
        get {
            if let result = UserDefaults.standard.object(forKey: Constants.UseTextBundleToStoreDates) as? Bool {
                return result
            }

            return false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.UseTextBundleToStoreDates)
        }
    }

    static var showInMenuBar: Bool {
        get {
            if let result = shared?.object(forKey: Constants.ShowInMenuBar) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.ShowInMenuBar)
        }
    }
    
    static var fileContainer: NoteContainer {
        get {
            #if SHARE_EXT
                let defaults = UserDefaults.init(suiteName: "group.es.fsnot.user.defaults")
                if let result = defaults?.object(forKey: Constants.SharedContainerKey) as? Int, let container = NoteContainer(rawValue: result) {
                    return container
                }
            #endif

            if let result = shared?.object(forKey: Constants.NoteContainer) as? Int, let container = NoteContainer(rawValue: result) {
                return container
            }
            return .none
        }
        set {
            #if os(iOS)
            UserDefaults.init(suiteName: "group.es.fsnot.user.defaults")?.set(newValue.rawValue, forKey: Constants.SharedContainerKey)
            #endif

            shared?.set(newValue.rawValue, forKey: Constants.NoteContainer)
        }
    }

    static var fileFormat: NoteType {
        get {
            return .Markdown
        }
        set {
            shared?.set(newValue.tag, forKey: Constants.NoteType)
        }
    }

    static var noteExtension: String {
        get {
            if let result = shared?.object(forKey: Constants.NoteExtension) as? String {
                return result
            }

            return "markdown"
        }
        set {
            shared?.set(newValue, forKey: Constants.NoteExtension)
        }
    }

    static var previewFontSize: Int {
        get {
            if let result = shared?.object(forKey: Constants.PreviewFontSize) as? Int {
                return result
            }
            return 11
        }
        set {
            shared?.set(newValue, forKey: Constants.PreviewFontSize)
        }
    }

    static var hidePreviewImages: Bool {
        get {
            if let result = shared?.object(forKey: Constants.HidePreviewImages) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.HidePreviewImages)
        }
    }

    static var masterPasswordHint: String {
        get {
            if let hint = shared?.object(forKey: Constants.MasterPasswordHint) as? String {
                return hint
            }
            return String()
        }
        set {
            shared?.set(newValue, forKey: Constants.MasterPasswordHint)
        }
    }

    static var lockOnSleep: Bool {
        get {
            if let result = shared?.object(forKey: Constants.LockOnSleep) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.LockOnSleep)
        }
    }

    static var lockOnScreenActivated: Bool {
        get {
            if let result = shared?.object(forKey: Constants.LockOnScreenActivated) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.LockOnScreenActivated)
        }
    }

    static var lockOnUserSwitch: Bool {
        get {
            if let result = shared?.object(forKey: Constants.LockAfterUserSwitch) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.LockAfterUserSwitch)
        }
    }

    static var allowTouchID: Bool {
        get {
            if NSClassFromString("NSTouchBar") == nil {
                return false
            }

            if let result = shared?.object(forKey: Constants.AllowTouchID) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.AllowTouchID)
        }
    }

    static var hideDate: Bool {
        get {
            if let result = shared?.object(forKey: Constants.HideDate) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.HideDate)
        }
    }

    static var indentUsing: Int {
        get {
            if let result = shared?.integer(forKey: Constants.IndentUsing) {
                return result
            }

            return 0
        }
        set {
            shared?.set(newValue, forKey: Constants.IndentUsing)
        }
    }

    static var firstLineAsTitle: Bool {
        get {
            if let result = shared?.object(forKey: Constants.FirstLineAsTitle) as? Bool {
                return result
            }

            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.FirstLineAsTitle)
        }
    }

    // Phase 7.5.c proxy — reads/writes through `Theme.shared.marginSize`.
    static var marginSize: Float {
        get { Float(BlockStyleTheme.shared.marginSize) }
        set {
            BlockStyleTheme.shared.marginSize = CGFloat(newValue)
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    static var gitStorage: URL? {
        get {
            if let repositories = shared?.url(forKey: Constants.GitStorage) {
                if !FileManager.default.fileExists(atPath: repositories.path) {
                    try? FileManager.default.createDirectory(at: repositories, withIntermediateDirectories: true, attributes: nil)
                }

                return repositories
            }

            if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let repositories = applicationSupport.appendingPathComponent("Repositories")
                
                if !FileManager.default.fileExists(atPath: repositories.path) {
                    try? FileManager.default.createDirectory(at: repositories, withIntermediateDirectories: true, attributes: nil)
                }
                
                return repositories
            }
            
            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.GitStorage)
        }
    }
    
    static var gitUsername: String? {
        get {
            if let result = shared?.object(forKey: Constants.GitUsername) as? String {
                if result.count == 0 {
                    return nil
                }
                
                return result
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.GitUsername)
        }
    }
    
    static var gitPassword: String? {
        get {
            if let result = shared?.object(forKey: Constants.GitPassword) as? String {
                if result.count == 0 {
                    return nil
                }
                
                return result
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.GitPassword)
        }
    }
    
    static var gitOrigin: String? {
        get {
            if let result = shared?.object(forKey: Constants.GitOrigin) as? String {
                if result.count == 0 {
                    return nil
                }
                
                return result
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.GitOrigin)
        }
    }

    static var snapshotsInterval: Int {
        get {
            if let interval = shared?.object(forKey: Constants.SnapshotsInterval) as? Int {
                return interval
            }

            return self.DefaultSnapshotsInterval
        }
        set {
            shared?.set(newValue, forKey: Constants.SnapshotsInterval)
        }
    }
    
    static var pullInterval: Int {
        get {
            if let interval = shared?.object(forKey: Constants.PullInterval) as? Int {
                return interval
            }

            return 10
        }
        set {
            shared?.set(newValue, forKey: Constants.PullInterval)
        }
    }

    static var snapshotsIntervalMinutes: Int {
        get {
            if let interval = shared?.object(forKey: Constants.SnapshotsIntervalMinutes) as? Int {
                return interval
            }

            return self.DefaultSnapshotsIntervalMinutes
        }
        set {
            shared?.set(newValue, forKey: Constants.SnapshotsIntervalMinutes)
        }
    }

    static var backupManually: Bool {
        get {
            if let returnMode = shared?.object(forKey: Constants.BackupManually) as? Bool {
                return returnMode
            } else {
                return true
            }
        }
        set {
            shared?.set(newValue, forKey: Constants.BackupManually)
        }
    }

    static var fullScreen: Bool {
        get {
            if let result = shared?.object(forKey: Constants.FullScreen) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.FullScreen)
        }
    }

    static var inlineTags: Bool {
        get {
            if let result = shared?.object(forKey: Constants.InlineTags) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.InlineTags)
        }
    }

    static var showWelcome: Bool {
        get {
            if let result = shared?.object(forKey: Constants.Welcome) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.Welcome)
        }
    }

    static var mathJaxPreview: Bool {
        get {
            if let result = shared?.object(forKey: Constants.MathJaxPreview) as? Bool {
                return result
            }

            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.MathJaxPreview)
        }
    }

    static var aiAPIKey: String {
        get {
            // Migrate from UserDefaults to Keychain on first read
            if let legacyKey = shared?.string(forKey: Constants.AIAPIKey), !legacyKey.isEmpty {
                let item = KeychainPasswordItem(service: KeychainConfiguration.serviceName, account: "aiAPIKey")
                try? item.savePassword(legacyKey)
                shared?.removeObject(forKey: Constants.AIAPIKey)
                return legacyKey
            }
            let item = KeychainPasswordItem(service: KeychainConfiguration.serviceName, account: "aiAPIKey")
            return (try? item.readPassword()) ?? ""
        }
        set {
            let item = KeychainPasswordItem(service: KeychainConfiguration.serviceName, account: "aiAPIKey")
            if newValue.isEmpty {
                try? item.deleteItem()
            } else {
                try? item.savePassword(newValue)
            }
            // Remove any older UserDefaults copy after saving to Keychain.
            shared?.removeObject(forKey: Constants.AIAPIKey)
        }
    }

    static var aiProvider: String {
        get { shared?.string(forKey: Constants.AIProvider) ?? "anthropic" }
        set { shared?.set(newValue, forKey: Constants.AIProvider) }
    }

    static var aiModel: String {
        get { shared?.string(forKey: Constants.AIModel) ?? "" }
        set { shared?.set(newValue, forKey: Constants.AIModel) }
    }

    static var aiEndpoint: String {
        get { shared?.string(forKey: Constants.AIEndpoint) ?? "" }
        set { shared?.set(newValue, forKey: Constants.AIEndpoint) }
    }

    static var aiOllamaHost: String {
        get { shared?.string(forKey: Constants.AIOllamaHost) ?? "http://localhost:11434" }
        set { shared?.set(newValue, forKey: Constants.AIOllamaHost) }
    }

    static var wysiwygMode: Bool {
        get {
            if let result = shared?.object(forKey: Constants.WysiwygMode) as? Bool {
                return result
            }
            return true // Default to WYSIWYG mode
        }
        set {
            shared?.set(newValue, forKey: Constants.WysiwygMode)
        }
    }
    
    static var sidebarVisibilityInbox: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityInbox") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityInbox")
        }
    }

    static var sidebarVisibilityNotes: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityNotes") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityNotes")
        }
    }

    static var sidebarVisibilityTodo: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityTodo") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityTodo")
        }
    }

    static var sidebarVisibilityUntagged: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityUntagged") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityUntagged")
        }
    }

    static var sidebarVisibilityTrash: Bool {
        get {
            if let result = shared?.object(forKey: "sidebarVisibilityTrash") as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: "sidebarVisibilityTrash")
        }
    }

    static var crashedLastTime: Bool {
        get {
            if let result = shared?.object(forKey: Constants.CrashedLastTime) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.CrashedLastTime)
        }
    }

    static var lastNews: Date? {
        get {
            if let sync = shared?.object(forKey: "lastNews") {
                return sync as? Date
            } else {
                return nil
            }
        }
        set {
            shared?.set(newValue, forKey: "lastNews")
        }
    }

    static var naming: SettingsFilesNaming {
        get {
            if let result = shared?.object(forKey: "naming") as? Int, let settings = SettingsFilesNaming(rawValue: result) {
                return settings
            }

            return .autoRename
        }
        set {
            shared?.set(newValue.rawValue, forKey: "naming")
        }
    }

    static var autoInsertHeader: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutoInsertHeader) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.AutoInsertHeader)
        }
    }

    static var nonContiguousLayout: Bool {
        get {
            if let result = shared?.object(forKey: Constants.NonContiguousLayout), let data = result as? Bool {
                return data
            }

            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.NonContiguousLayout)
        }
    }

    static var codeBlocksWithSyntaxHighlighting: Bool {
        get {
            if let result = shared?.object(forKey: Constants.CodeBlocksWithSyntaxHighlighting) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.CodeBlocksWithSyntaxHighlighting)
        }
    }

    static var lastScreenX: Int? {
        get {
            if let value = shared?.object(forKey: Constants.LastScreenX) as? Int {
                return value
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastScreenX)
        }
    }

    static var lastScreenY: Int? {
        get {
            if let value = shared?.object(forKey: Constants.LastScreenY) as? Int {
                return value
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.LastScreenY)
        }
    }

    static var recentSearches: [String]? {
        get {
            if let value = shared?.array(forKey: Constants.RecentSearches) as? [String] {
                return value
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.RecentSearches)
        }
    }

    static var searchHighlight: Bool {
        get {
            if let result = shared?.object(forKey: Constants.SearchHighlight) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.SearchHighlight)
        }
    }

    static var autoVersioning: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AutoVersioning) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.AutoVersioning)
        }
    }
    
    static var iCloudDrive: Bool {
        get {
            if let result = shared?.object(forKey: Constants.iCloudDrive) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.iCloudDrive)
        }
    }
    
    static var customWebServer: Bool {
        get {
            if let result = shared?.object(forKey: Constants.CustomWebServer) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.CustomWebServer)
        }
    }
    
    static var sftpHost: String {
        get {
            if let result = shared?.object(forKey: Constants.SftpHost) as? String {
                return result
            }

            return ""
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpHost)
        }
    }
    
    static var sftpPort: Int32 {
        get {
            if let result = shared?.object(forKey: Constants.SftpPort) as? Int32 {
                return result
            }

            return 22
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpPort)
        }
    }
    
    static var sftpUsername: String {
        get {
            if let result = shared?.object(forKey: Constants.SftpUsername) as? String {
                return result
            }

            return ""
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpUsername)
        }
    }
    
    static var sftpPassword: String {
        get {
            if let result = shared?.object(forKey: Constants.SftpPassword) as? String {
                return result
            }

            return ""
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpPassword)
        }
    }
    
    static var sftpPath: String? {
        get {
            if let result = shared?.object(forKey: Constants.SftpPath) as? String {
                if result.count == 0 {
                    return nil
                }
                
                let suffix = result.hasSuffix("/") ? "" : "/"
                return result + suffix
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpPath)
        }
    }
    
    static var sftpPassphrase: String {
        get {
            if let result = shared?.object(forKey: Constants.SftpPasspharse) as? String {
                return result
            }

            return ""
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpPasspharse)
        }
    }
    
    static var sftpWeb: String? {
        get {
            if let result = shared?.object(forKey: Constants.SftpWeb) as? String {
                if result.count == 0 {
                    return nil
                }
                
                if result.last != "/" {
                    return result + "/"
                }
                
                return result
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpWeb)
        }
    }
    
    static var sftpAccessData: Data? {
        get {
            return shared?.data(forKey: Constants.SftpKeysAccessData)
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpKeysAccessData)
        }
    }
    
    static var sftpUploadBookmarksData: Data? {
        get {
            return shared?.data(forKey: Constants.SftpUploadBookmarksData)
        }
        set {
            shared?.set(newValue, forKey: Constants.SftpUploadBookmarksData)
        }
    }
    
    static var apiBookmarksData: Data? {
        get {
            return shared?.data(forKey: Constants.ApiBookmarksData)
        }
        set {
            shared?.set(newValue, forKey: Constants.ApiBookmarksData)
        }
    }
    
    static var gitPrivateKeyData: Data? {
        get {
            return shared?.data(forKey: Constants.GitPrivateKeyData)
        }
        set {
            shared?.set(newValue, forKey: Constants.GitPrivateKeyData)
        }
    }
    
    static var gitPassphrase: String {
        get {
            if let result = shared?.object(forKey: Constants.GitPasspharse) as? String {
                return result
            }

            return ""
        }
        set {
            shared?.set(newValue, forKey: Constants.GitPasspharse)
        }
    }
    
    static var uploadKey: String {
        get {
            if let result = global.object(forKey: Constants.UploadKey) as? String, result.count > 0 {
                return result
            }

            let key = String.random(length: 20)
            global.set(key, forKey: Constants.UploadKey)

            return key
        }
        set {
            global.set(newValue, forKey: Constants.UploadKey)
        }
    }

    static var deprecatedUploadKey: String? {
        get {
            if let result = shared?.object(forKey: Constants.UploadKey) as? String, result.count > 0 {
                return result
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.UploadKey)
        }
    }

    static var clickableLinks: Bool {
        get {
            if let highlight = shared?.object(forKey: Constants.ClickableLinks) as? Bool {
                return highlight
            }
            
            #if os(iOS)
                return true
            #else
                return false
            #endif
        }
        set {
            shared?.set(newValue, forKey: Constants.ClickableLinks)
        }
    }
    
    static var trashURL: URL? {
        get {
            if let trashUrl = shared?.url(forKey: Constants.TrashKey) {
                return trashUrl
            }

            return nil
        }
        set {
            shared?.set(newValue, forKey: Constants.TrashKey)
        }
    }
    
    static var separateRepo: Bool {
        get {
            if let result = shared?.object(forKey: Constants.SeparateRepo) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.SeparateRepo)
        }
    }
    
    static var askCommitMessage: Bool {
        get {
            if let result = shared?.object(forKey: Constants.AskCommitMessage) as? Bool {
                return result
            }
            return false
        }
        set {
            shared?.set(newValue, forKey: Constants.AskCommitMessage)
        }
    }
    
    static var lastCommitMessage: String? {
        get {
            if let result = shared?.object(forKey: Constants.LastCommitMessage) as? String, result.count > 0 {
                return result
            }
            
            return nil
        }
        
        set {
            shared?.set(newValue, forKey: Constants.LastCommitMessage)
        }
    }
    
    static var lightCodeTheme: String {
        get {
            if let theme = UserDefaults.standard.object(forKey: Constants.codeTheme) as? String {
                return theme
            }

            return "github"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.codeTheme)
        }
    }
    
    static var projects: [URL] {
        get {
            guard let defaults = UserDefaults.init(suiteName: "group.es.fsnot.user.defaults") else { return [] }

            if let data = defaults.data(forKey: Constants.ProjectsKeyNew), let urls = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSURL.self], from: data) as? [URL] {
                return urls
            }

            return []
        }
        set {
            guard let defaults = UserDefaults.init(suiteName: "group.es.fsnot.user.defaults") else { return }

            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) {
                defaults.set(data, forKey: Constants.ProjectsKeyNew)
            }
        }
    }

    static var maxChildDirs: Int {
        get {
            if let returnFontSize = shared?.object(forKey: Constants.MaxChildDirs), 
                let value = returnFontSize as? Int {

                if value < 200 {
                    return 200
                }

                return value
            }

            return 200
        }
        set {
            shared?.set(newValue, forKey: Constants.CodeFontSizeKey)
        }
    }

#if !SHARE_EXT
    static var codeTheme: EditorTheme {
        get {
            guard
                let raw = UserDefaults.standard.string(forKey: Constants.codeTheme),
                let theme = EditorTheme(rawValue: raw)
            else {
                return .atomOne
            }
                
            return theme
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Constants.codeTheme)
        }
    }
#endif
    
    static var isFirstLaunch: Bool {
        get {
            if let result = shared?.object(forKey: Constants.IsFirstLaunch) as? Bool {
                return result
            }
            return true
        }
        set {
            shared?.set(newValue, forKey: Constants.IsFirstLaunch)
        }
    }
    
    // Phase 7.5.c proxy — reads/writes through `Theme.shared.italic`.
    static var italic: String {
        get { BlockStyleTheme.shared.italic }
        set {
            BlockStyleTheme.shared.italic = newValue
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    // Phase 7.5.c proxy — reads/writes through `Theme.shared.bold`.
    static var bold: String {
        get { BlockStyleTheme.shared.bold }
        set {
            BlockStyleTheme.shared.bold = newValue
            UserDefaultsManagement.postTheme75cChange()
        }
    }

    // Phase 7.5.c helper — post `Theme.didChangeNotification` after a
    // proxied setter mutates `Theme.shared`. The JSON save is owned by
    // the IBAction layer (Phase 7.5.a), not by this proxy.
    fileprivate static func postTheme75cChange() {
        NotificationCenter.default.post(
            name: BlockStyleTheme.didChangeNotification, object: nil
        )
    }

    // MARK: - Phase 7.5.c migration from legacy UD keys into Theme
    //
    // Phase 7.5.c migration:
    //   On first launch after 7.5.c lands, copy any values the user had
    //   previously saved into the legacy UserDefaults keys (these were
    //   the backing store before the proxy replaced them) into the
    //   active `Theme.shared` values. Then delete the legacy keys and
    //   set a sentinel so the migration runs exactly once.
    //
    //   The raw legacy values are read directly via
    //   `UserDefaults.standard.object(forKey:)` using the key constants
    //   below — NOT through the new proxy, which now reads from Theme
    //   instead of UserDefaults. After migration, the proxy handles all
    //   reads/writes and the UD keys are gone.
    //
    //   Called from `AppDelegate.applicationDidFinishLaunching(_:)` right
    //   after `Theme.shared = Theme.load(...)` so the migration layers on
    //   top of the newly-loaded theme (user overrides legacy UD).

    /// Sentinel key. When `true`, migration has already run and will
    /// not re-run.
    public static let theme75cMigrationCompleteKey = "theme75cMigrationComplete"

    /// Legacy-key name list used by the migration. Kept separate from
    /// the `Constants` struct so this remains self-contained and easy
    /// to delete in a future phase once the install base has rotated.
    private enum LegacyProxyKeys {
        static let codeFontName = "codeFont"
        static let codeFontSize = "codeFontSize"
        static let fontName = "font"
        static let fontSize = "fontsize"
        static let editorLineSpacing = "lineSpacingEditor"
        static let lineHeightMultiple = "lineHeightMultipleKey"
        static let lineWidth = "lineWidth"
        static let marginSize = "marginSize"
        static let italic = "italicKeyed"
        static let bold = "boldKeyed"
    }

    /// One-shot migration: copy preferences from the legacy
    /// `co.fluder.FSNotes` UserDefaults domain into the current app's
    /// domain. Runs ONCE per install — gated by a sentinel.
    ///
    /// Background (bd-fsnotes-dbe): the bundle ID was changed from
    /// `co.fluder.FSNotes` to `app.fsnotes.fork-gjouret` to eliminate
    /// LaunchServices ambiguity with the upstream `/Applications/FSNotes.app`
    /// build. UserDefaults is keyed by bundle ID, so on first launch
    /// under the new ID the user would lose every persisted setting
    /// (theme choice, pin state, fold cache, sort order, etc.).
    /// This helper reads the legacy plist and copies non-conflicting
    /// keys into the new domain so the change is invisible to the user.
    ///
    /// Conflict policy: the new domain wins. If a key already exists
    /// under the new bundle ID, we don't overwrite it. This keeps
    /// re-running the migration safe (defensive — the sentinel should
    /// prevent re-run anyway) and avoids clobbering values the user
    /// changed after the migration first ran.
    public static func migrateLegacyBundleIdPreferencesIfNeeded() {
        let migrationKey = "didMigrateFromCoFluderFSNotes"
        let new = UserDefaults.standard
        if new.bool(forKey: migrationKey) { return }

        let legacyURL = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first?
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("co.fluder.FSNotes.plist")

        guard let url = legacyURL,
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            new.set(true, forKey: migrationKey)
            return
        }

        for (key, value) in dict {
            // Skip Apple-managed CFPreferences keys that shouldn't be
            // copied (these are framework-internal, not app settings).
            if key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.") {
                continue
            }
            // Skip keys already populated under the new bundle ID.
            if new.object(forKey: key) != nil { continue }
            new.set(value, forKey: key)
        }
        new.set(true, forKey: migrationKey)
    }

    /// Copy any legacy UD values into `Theme.shared`, save the active
    /// theme, then delete the legacy keys + set the sentinel. Idempotent.
    ///
    /// `userThemesDirectory` is optional so tests can redirect the JSON
    /// write; production passes `nil` (Application Support default).
    public static func migrateEditorKeysIntoTheme75c(
        userThemesDirectory: URL? = nil
    ) {
        guard let defaults = shared else { return }
        if defaults.bool(forKey: theme75cMigrationCompleteKey) { return }

        // Code font name/size.
        if let name = defaults.object(forKey: LegacyProxyKeys.codeFontName) as? String {
            BlockStyleTheme.shared.codeFontName = name
        }
        if let size = defaults.object(forKey: LegacyProxyKeys.codeFontSize) as? Int {
            BlockStyleTheme.shared.codeFontSize = CGFloat(size)
        }

        // Note font name/size.
        if let name = defaults.object(forKey: LegacyProxyKeys.fontName) as? String {
            BlockStyleTheme.shared.noteFontName = name
        }
        if let size = defaults.object(forKey: LegacyProxyKeys.fontSize) as? Int {
            BlockStyleTheme.shared.noteFontSize = CGFloat(size)
        }

        // Editor layout (Float-backed in UD).
        if let v = defaults.object(forKey: LegacyProxyKeys.editorLineSpacing) as? Float {
            BlockStyleTheme.shared.editorLineSpacing = CGFloat(v)
        }
        if let v = defaults.object(forKey: LegacyProxyKeys.lineHeightMultiple) as? Float {
            BlockStyleTheme.shared.lineHeightMultiple = CGFloat(v)
        }
        if let v = defaults.object(forKey: LegacyProxyKeys.lineWidth) as? Float {
            BlockStyleTheme.shared.lineWidth = CGFloat(v)
        }
        if let v = defaults.object(forKey: LegacyProxyKeys.marginSize) as? Float {
            BlockStyleTheme.shared.marginSize = CGFloat(v)
        }

        // Markers.
        if let v = defaults.object(forKey: LegacyProxyKeys.italic) as? String {
            BlockStyleTheme.shared.italic = v
        }
        if let v = defaults.object(forKey: LegacyProxyKeys.bold) as? String {
            BlockStyleTheme.shared.bold = v
        }

        // Persist the migrated theme so the override is picked up on
        // subsequent launches.
        _ = BlockStyleTheme.saveActiveTheme(userThemesDirectory: userThemesDirectory)

        // Delete the legacy keys — Theme is now the single source of truth.
        for key in [
            LegacyProxyKeys.codeFontName, LegacyProxyKeys.codeFontSize,
            LegacyProxyKeys.fontName, LegacyProxyKeys.fontSize,
            LegacyProxyKeys.editorLineSpacing, LegacyProxyKeys.lineHeightMultiple,
            LegacyProxyKeys.lineWidth, LegacyProxyKeys.marginSize,
            LegacyProxyKeys.italic, LegacyProxyKeys.bold
        ] {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: theme75cMigrationCompleteKey)
    }
}
