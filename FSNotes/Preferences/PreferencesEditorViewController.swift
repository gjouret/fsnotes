//
//  PreferencesEditorViewController.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/17/19.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class PreferencesEditorViewController: NSViewController {

    @IBOutlet weak var codeFontPreview: NSTextField!
    @IBOutlet weak var noteFontPreview: NSTextField!
    @IBOutlet weak var codeBlockHighlight: NSButton!
    @IBOutlet weak var markdownCodeTheme: NSPopUpButton!
    @IBOutlet weak var indentUsing: NSPopUpButton!
    @IBOutlet weak var inEditorFocus: NSButton!
    @IBOutlet weak var autocloseBrackets: NSButton!
    @IBOutlet weak var lineSpacing: NSSlider!
    @IBOutlet weak var imagesWidth: NSSlider!
    @IBOutlet weak var lineWidth: NSSlider!
    @IBOutlet weak var marginSize: NSSlider!
    @IBOutlet weak var inlineTags: NSButton!
    @IBOutlet weak var clickableLinks: NSButton!

    // Phase 7.4 — Theme section (programmatic, appended below the
    // storyboard-defined content). Kept as stored properties so the
    // appear pass can refresh the popup selection without rebuilding.
    private var themeSectionBuilt = false
    private var themePopUp: NSPopUpButton?

    override func viewWillAppear() {
        super.viewWillAppear()
        // Height tuned after removing the Italic/Bold radio section:
        // the storyboard chain (top-anchored) terminates at the "Code
        // block live highlighting" checkbox ~440pt from the top; the
        // programmatic Theme section below needs ~80pt for separator +
        // header + popup row + bottom margin. 550 leaves a clean ~20pt
        // gap between the checkbox and the Theme separator.
        preferredContentSize = NSSize(width: 550, height: 550)
    }

    override func viewDidAppear() {
        if let window = self.view.window {
            window.title = NSLocalizedString("Settings", comment: "")
        }

        codeBlockHighlight.state = UserDefaultsManagement.codeBlockHighlight ? NSControl.StateValue.on : NSControl.StateValue.off

        inEditorFocus.state = UserDefaultsManagement.focusInEditorOnNoteSelect ? NSControl.StateValue.on : NSControl.StateValue.off
        indentUsing.selectItem(at: UserDefaultsManagement.indentUsing)
        autocloseBrackets.state = UserDefaultsManagement.autocloseBrackets ? .on : .off

        markdownCodeTheme.selectItem(withTitle: UserDefaultsManagement.codeTheme.getName())

        lineSpacing.floatValue = Float((UserDefaultsManagement.lineHeightMultiple - 1) * 10)
        imagesWidth.floatValue = UserDefaultsManagement.imagesWidth
        lineWidth.floatValue = UserDefaultsManagement.lineWidth

        marginSize.floatValue = UserDefaultsManagement.marginSize

        inlineTags.state = UserDefaultsManagement.inlineTags ? .on : .off
        
        clickableLinks.state = UserDefaultsManagement.clickableLinks ? .on : .off
        
        setCodeFontPreview()
        setNoteFontPreview()

        // Phase 7.4 — build (once) + refresh the Theme section.
        buildThemeSectionIfNeeded()
        refreshThemePopup()
    }

    // MARK: - Phase 7.4: Theme section

    /// Construct the programmatic Theme section and append it to the
    /// VC's view. Idempotent — called once per VC lifetime. The
    /// section is laid out below the existing storyboard content so
    /// it doesn't disturb any existing frames or constraints.
    private func buildThemeSectionIfNeeded() {
        guard !themeSectionBuilt else { return }
        themeSectionBuilt = true

        let container = self.view

        // Separator + header
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        let header = NSTextField(labelWithString: NSLocalizedString("Theme", comment: "Editor preferences theme section header"))
        header.font = NSFont.boldSystemFont(ofSize: 13)
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)

        let label = NSTextField(labelWithString: NSLocalizedString("Active:", comment: "Preferences: active theme label"))
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(themeDidChange(_:))
        container.addSubview(popup)
        self.themePopUp = popup

        let importButton = NSButton(
            title: NSLocalizedString("Import…", comment: "Preferences: import theme button"),
            target: self,
            action: #selector(importTheme(_:))
        )
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(importButton)

        let revealButton = NSButton(
            title: NSLocalizedString("Reveal in Finder", comment: "Preferences: reveal themes folder button"),
            target: self,
            action: #selector(revealThemesFolder(_:))
        )
        revealButton.bezelStyle = .rounded
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(revealButton)

        // Layout — the VC view is 550×550 (post Italic/Bold removal).
        // Attach to bottom-left with fixed offsets so the section sits
        // below the storyboard content without touching existing frames.
        //
        // The `-90` separator offset was chosen to (a) clear the last
        // storyboard control ("Code block live highlighting" checkbox,
        // which terminates the top-anchored storyboard chain around
        // y=440 from the top) by ~20pt and (b) leave ~30pt of bottom
        // margin below the popup row. If future storyboard edits add or
        // remove rows above, this constant needs to be re-tuned — there
        // is no constraint-chain link between the storyboard content and
        // this programmatic section.
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -90),
            separator.heightAnchor.constraint(equalToConstant: 1),

            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 33),
            header.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),

            label.trailingAnchor.constraint(equalTo: popup.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: popup.centerYAnchor),

            popup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 145),
            popup.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            importButton.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 8),
            importButton.centerYAnchor.constraint(equalTo: popup.centerYAnchor),

            revealButton.leadingAnchor.constraint(equalTo: importButton.trailingAnchor, constant: 8),
            revealButton.centerYAnchor.constraint(equalTo: popup.centerYAnchor)
        ])
    }

    /// Repopulate the theme popup from the current available-themes
    /// enumeration and select the active entry. Called from
    /// `viewDidAppear` and after Import finishes.
    private func refreshThemePopup() {
        guard let popup = themePopUp else { return }
        popup.removeAllItems()

        let descriptors = Theme.availableThemes()
        for descriptor in descriptors {
            let suffix = descriptor.isBuiltIn ? "" : " (user)"
            popup.addItem(withTitle: descriptor.name + suffix)
            popup.lastItem?.representedObject = descriptor
        }

        let activeName = UserDefaultsManagement.currentThemeName ?? Theme.defaultThemeName
        for item in popup.itemArray {
            if let d = item.representedObject as? ThemeDescriptor,
               d.name.caseInsensitiveCompare(activeName) == .orderedSame {
                popup.select(item)
                break
            }
        }
    }

    @IBAction func themeDidChange(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem,
              let descriptor = item.representedObject as? ThemeDescriptor else {
            return
        }
        UserDefaultsManagement.currentThemeName = descriptor.name
        Theme.shared = Theme.load(named: descriptor.name)
        NotificationCenter.default.post(
            name: Theme.didChangeNotification, object: nil
        )
    }

    @IBAction func importTheme(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString(
            "Import Theme",
            comment: "Preferences: open-panel title for theme import"
        )
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.beginSheetModal(for: self.view.window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            self?.installUserTheme(from: source)
        }
    }

    private func installUserTheme(from source: URL) {
        let destDir = Theme.defaultUserThemesDirectory()
        do {
            try FileManager.default.createDirectory(
                at: destDir,
                withIntermediateDirectories: true
            )
            let dest = destDir.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Theme import failed",
                comment: "Preferences: theme import error alert title"
            )
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        refreshThemePopup()
    }

    @IBAction func revealThemesFolder(_ sender: NSButton) {
        let dir = Theme.defaultUserThemesDirectory()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    //MARK: global variables

    let storage = Storage.shared()

    @IBAction func codeBlockHighlight(_ sender: NSButton) {
        UserDefaultsManagement.codeBlockHighlight = (sender.state == NSControl.StateValue.on)
        Storage.shared().resetCacheAttributes()

        let editors = AppDelegate.getEditTextViews()
        
        for editor in editors {
            if let evc = editor.editorViewController {
                evc.refillEditArea(force: true)
            }
        }
    }

    @IBAction func markdownCodeThemeAction(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else {
            return
        }

        Storage.shared().resetCacheAttributes()
        
        if let theme = EditorTheme(themeName: item.title) {
            UserDefaultsManagement.codeTheme = theme
        }

        let editors = AppDelegate.getEditTextViews()
        for editor in editors {
            if let evc = editor.editorViewController {
                editor.textStorage?.updateParagraphStyle()

                NotesTextProcessor.resetCaches()

                evc.refillEditArea(force: true)
            }
        }
    }

    @IBAction func inEditorFocus(_ sender: NSButton) {
        UserDefaultsManagement.focusInEditorOnNoteSelect = (sender.state == .on)
    }

    @IBAction func autocloseBrackets(_ sender: NSButton) {
        UserDefaultsManagement.autocloseBrackets = (sender.state == .on)
    }

    @IBAction func lineSpacing(_ sender: NSSlider) {
        let newMultiple = CGFloat(1 + sender.floatValue / 10)
        // Phase 7.5 transitional: dual-write to UD until proxy slice lands.
        // `lineHeightMultiple` has no flat-field storage on BlockStyleTheme
        // (it lives in the synthesized ThemeSpacing group), so we only
        // dual-write to UD this slice; a later 7.5 slice adds flat storage
        // on the Theme schema and will mutate `Theme.shared` here too.
        UserDefaultsManagement.editorLineSpacing = 1
        UserDefaultsManagement.lineHeightMultiple = newMultiple
        persistActiveTheme()

        let editors = AppDelegate.getEditTextViews()
        for editor in editors {
            if let evc = editor.editorViewController {
                NotesTextProcessor.resetCaches()

                if let lm = evc.vcEditor?.layoutManager as? LayoutManager {
                    lm.lineHeightMultiple = CGFloat(UserDefaultsManagement.lineHeightMultiple)
                    lm.refreshLayoutSoftly()
                }
            }
        }
    }

    @IBAction func imagesWidth(_ sender: NSSlider) {
        Theme.shared.imagesWidth = CGFloat(sender.floatValue)
        // Phase 7.5 transitional: dual-write to UD until proxy slice lands.
        UserDefaultsManagement.imagesWidth = sender.floatValue
        persistActiveTheme()

        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        temporary.appendPathComponent("ThumbnailsBig")
        try? FileManager.default.removeItem(at: temporary)

        let editors = AppDelegate.getEditTextViews()
        for editor in editors {
            if let _ = editor.note, let evc = editor.editorViewController {
                // Phase 4.4: both WYSIWYG (block-model) and source-mode
                // (SourceRenderer) re-render via `refillEditArea()` —
                // the legacy `NotesTextProcessor.highlight(note.content)`
                // call was retired in 4.4.
                evc.disablePreview()
                evc.refillEditArea()
            }
        }
    }

    @IBAction func lineWidth(_ sender: NSSlider) {
        Theme.shared.lineWidth = CGFloat(sender.floatValue)
        // Phase 7.5 transitional: dual-write to UD until proxy slice lands.
        UserDefaultsManagement.lineWidth = sender.floatValue
        persistActiveTheme()

        let editors = AppDelegate.getEditTextViews()
        for editor in editors {
            if let evc = editor.editorViewController {
                editor.updateTextContainerInset()

                NotesTextProcessor.resetCaches()

                evc.refillEditArea(force: true)
            }
        }
    }

    private func restart() {
        guard let resourcePath = Bundle.main.resourcePath else {
            // No resourcePath means the app bundle is malformed — fall
            // back to just terminating; the user can relaunch manually.
            exit(0)
        }
        let url = URL(fileURLWithPath: resourcePath)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        exit(0)
    }

    @IBAction func indentUsing(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else {
            return
        }
        
        UserDefaultsManagement.indentUsing = item.tag
    }

    @IBAction func marginSize(_ sender: NSSlider) {
        Theme.shared.marginSize = CGFloat(sender.floatValue)
        // Phase 7.5 transitional: dual-write to UD until proxy slice lands.
        UserDefaultsManagement.marginSize = sender.floatValue
        persistActiveTheme()

        let editors = AppDelegate.getEditTextViews()
        for editor in editors {
            if let evc = editor.editorViewController {
                editor.updateTextContainerInset()

                NotesTextProcessor.resetCaches()

                evc.refillEditArea(force: true)
            }
        }
    }

    @IBAction func inlineTags(_ sender: NSButton) {
        UserDefaultsManagement.inlineTags = (sender.state == .on)

        guard let vc = ViewController.shared() else { return }

        Storage.shared().tags = []

        for note in Storage.shared().noteList {
            note.tags = []

            if UserDefaultsManagement.inlineTags {
                _ = note.scanContentTags()
            }
        }

        vc.sidebarOutlineView.reloadSidebar()
    }
    
    @IBAction func highlightLinks(_ sender: NSButton) {
        UserDefaultsManagement.clickableLinks = (sender.state == NSControl.StateValue.on)

        Storage.shared().resetCacheAttributes()
        
        let editors = AppDelegate.getEditTextViews()
        for editor in editors {
            if let evc = editor.editorViewController {
                evc.refillEditArea()
            }
        }
    }
    
    @IBAction func setCodeFont(_ sender: NSButton) {
        let fontManager = NSFontManager.shared
        fontManager.setSelectedFont(UserDefaultsManagement.codeFont, isMultiple: false)
        fontManager.orderFrontFontPanel(self)
        fontManager.target = self
        fontManager.action = #selector(changeCodeFont(_:))
    }
    
    @IBAction func setNoteFont(_ sender: NSButton) {
        let fontManager = NSFontManager.shared
        fontManager.setSelectedFont(UserDefaultsManagement.noteFont, isMultiple: false)
        fontManager.orderFrontFontPanel(self)
        fontManager.target = self
        fontManager.action = #selector(changeNoteFont(_:))
    }

    @IBAction func changeCodeFont(_ sender: Any?) {
        let fontManager = NSFontManager.shared
        let newFont = fontManager.convert(UserDefaultsManagement.codeFont)

        Theme.shared.codeFontName = newFont.familyName ?? "Source Code Pro"
        Theme.shared.codeFontSize = newFont.pointSize
        // Phase 7.5 transitional: dual-write to UD until proxy slice lands.
        UserDefaultsManagement.codeFont = newFont
        NotesTextProcessor.codeFont = newFont
        persistActiveTheme()

        ViewController.shared()?.reloadFonts()

        setCodeFontPreview()
    }

    @IBAction func changeNoteFont(_ sender: Any?) {
        let fontManager = NSFontManager.shared
        let newFont = fontManager.convert(UserDefaultsManagement.noteFont)

        Theme.shared.noteFontName = newFont.fontName
        Theme.shared.noteFontSize = newFont.pointSize
        // Phase 7.5 transitional: dual-write to UD until proxy slice lands.
        UserDefaultsManagement.noteFont = newFont
        persistActiveTheme()

        ViewController.shared()?.reloadFonts()

        setNoteFontPreview()
    }

    @IBAction func resetFont(_ sender: Any) {
        Theme.shared.noteFontName = nil
        Theme.shared.codeFontName = "Source Code Pro"
        // Phase 7.5 transitional: dual-write to UD until proxy slice lands.
        UserDefaultsManagement.fontName = nil
        UserDefaultsManagement.codeFontName = "Source Code Pro"
        persistActiveTheme()

        ViewController.shared()?.reloadFonts()

        setCodeFontPreview()
        setNoteFontPreview()
    }

    // MARK: - Phase 7.5: persist helper
    //
    // Centralizes the Theme.save() call so every IBAction gets the same
    // semantics (write current `Theme.shared` to the active user theme
    // file + post `didChangeNotification`). Errors are logged by the
    // save helper and swallowed here — the UI never blocks on a disk
    // failure (e.g. permissions).
    //
    // Continuous `NSSlider` IBActions (`lineSpacing`, `marginSize`,
    // `lineWidth`, `imagesWidth`) tick at ~60Hz during a drag; writing
    // the full Theme JSON on every tick is wasteful. Route through the
    // debounced helper so the disk write is coalesced to one after
    // 150ms of quiescence. `didChangeNotification` still fires per-tick
    // from inside the helper so live-preview observers keep updating.
    private func persistActiveTheme() {
        Theme.saveActiveThemeDebounced()
    }
    
    // UI-only preview label font size — NOT a rendering value. The
    // preview label in the Editor preferences pane displays the selected
    // family name at a fixed size so typography stays readable regardless
    // of the user's configured body font. Phase 7.5.d's grep gate
    // whitelists this one named constant.
    private static let previewFontSize: CGFloat = 13

    private func setCodeFontPreview() {
        let familyName = UserDefaultsManagement.codeFont.familyName ?? "Source Code Pro"

        codeFontPreview.font = NSFont(name: familyName, size: Self.previewFontSize)
        codeFontPreview.stringValue = "\(familyName) \(UserDefaultsManagement.codeFont.pointSize)pt"
    }

    private func setNoteFontPreview() {
        noteFontPreview.font = NSFont(
            name: UserDefaultsManagement.noteFont.fontName,
            size: Self.previewFontSize
        )

        if let familyName = UserDefaultsManagement.noteFont.familyName {
            noteFontPreview.stringValue = "\(familyName) \(UserDefaultsManagement.noteFont.pointSize)pt"
        }
    }
}
