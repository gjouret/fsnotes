//
//  EditTextView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 8/11/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import PDFKit

class EditTextView: NSTextView, NSTextFinderClient, NSSharingServicePickerDelegate, EditorDelegate {
    public var editorViewController: EditorViewController?
    public var textStorageProcessor: TextStorageProcessor?

    /// Materialize live table widget state back into the attachment attributes
    /// before a save reads the editor storage.
    func prepareRenderedTablesForSave() {
        tableController.prepareRenderedTablesForSave()
    }

    /// Explicit save boundary for the editor. Reading the storage remains pure;
    /// only this method is allowed to prepare live rendered widgets first.
    func attributedStringForSaving() -> NSAttributedString {
        prepareRenderedTablesForSave()
        return attributedString()
    }

    func refreshParagraphRendering(range: NSRange) {
        guard let storage = textStorage else { return }

        if NotesTextProcessor.hideSyntax,
           let processor = textStorageProcessor,
           !processor.blocks.isEmpty {
            processor.phase5_paragraphStyles(textStorage: storage, range: range)
            processor.phase4_hideSyntax(textStorage: storage, range: range)
        } else {
            storage.updateParagraphStyle(range: range)
        }

        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    }

    public var note: Note?
    public var viewDelegate: ViewController?

    /// Range of a code block that was restored from a rendered image and needs re-rendering
    /// when the cursor moves outside it
    public var pendingRenderBlockRange: NSRange?

    /// Storage length at the last call to triggerCodeBlockRenderingIfNeeded.
    /// Used to skip re-scanning when only the cursor moved and no edit occurred.
    
    let storage = Storage.shared()
    let caretWidth: CGFloat = 2
    
    public var timer: Timer?
    public var tagsTimer: Timer?
    public var isLastEdited: Bool = false
    
    @IBOutlet weak var previewMathJax: NSMenuItem!

    public var imagesLoaderQueue = OperationQueue.init()
    public var attributesCachingQueue = OperationQueue.init()
    public lazy var gutterController = GutterController(textView: self)
    public lazy var tableController = TableRenderController(textView: self)
    
    public var isScrollPositionSaverLocked = false
    public var skipLoadSelectedRange = false
    var dragDetected = false

    override func becomeFirstResponder() -> Bool {
        if let note = self.note {
            if note.container == .encryptedTextPack {
                return false
            }

            textStorage?.removeHighlight()
        }

        if skipLoadSelectedRange {
            skipLoadSelectedRange = false
        } else {
            loadSelectedRange()
        }

        // Show focus border when editor gains focus
        if let scrollView = enclosingScrollView as? EditorScrollView {
            scrollView.showFocusBorder()
        }

        return super.becomeFirstResponder()
    }

    //MARK: caret width

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw gutter icons (fold carets, H-level badges) in the text view's coordinate space.
        // Must be here (not in LayoutManager.drawBackground) because the gutter is OUTSIDE
        // the text container bounds and would be clipped by the layout manager.
        if NotesTextProcessor.hideSyntax {
            gutterController.drawIcons(in: dirtyRect)
        }

        guard UserDefaultsManagement.inlineTags else { return }

        if #available(OSX 10.16, *) {
            guard let textStorage = self.textStorage,
                  let layoutManager = self.layoutManager
            else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)

            attributedString().enumerateAttributes(in: fullRange, options: .reverse) { attributes, range, _ in
                guard range.location >= 0,
                      range.location + range.length <= textStorage.length else { return }
                
                guard attributes.index(forKey: .tag) != nil,
                      let font = attributes[.font] as? NSFont
                else { return }

                let tag = attributedString().attributedSubstring(from: range).string
                let tagAttributes = attributedString().attributes(at: range.location, effectiveRange: nil)

                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                
                let ascent = font.ascender
                let descent = abs(font.descender)
                let fontHeight = ascent + descent

                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, textContainer, lineGlyphRange, stop in

                    let intersectionRange = NSIntersectionRange(glyphRange, lineGlyphRange)
                    guard intersectionRange.length > 0 else { return }
                    
                    var fragmentRect = layoutManager.boundingRect(forGlyphRange: intersectionRange, in: textContainer)
                    
                    fragmentRect.origin.x += self.textContainerOrigin.x
                    fragmentRect.origin.y += self.textContainerOrigin.y
                    fragmentRect = self.convertToLayer(fragmentRect)
                    fragmentRect = fragmentRect.integral

                    let verticalInset = max(0, (fragmentRect.height - fontHeight) / 2)
                    var tagRect = NSRect(
                        x: fragmentRect.minX,
                        y: fragmentRect.minY + verticalInset,
                        width: fragmentRect.width - 3,
                        height: fontHeight
                    )

                    let oneCharSize = ("A" as NSString).size(withAttributes: tagAttributes)
                    tagRect.size.width += oneCharSize.width * 0.25
                    tagRect = tagRect.integral

                    NSGraphicsContext.saveGraphicsState()
                    let path = NSBezierPath(roundedRect: tagRect, xRadius: 3, yRadius: 3)
                    NSColor.tagColor.setFill()
                    path.fill()

                    let fragmentCharRange = layoutManager.characterRange(forGlyphRange: intersectionRange, actualGlyphRange: nil)
                    let fragmentText = (tag as NSString).substring(with: NSRange(
                        location: fragmentCharRange.location - range.location,
                        length: fragmentCharRange.length
                    ))

                    var drawAttrs = tagAttributes
                    drawAttrs[.font] = font
                    drawAttrs[.foregroundColor] = NSColor.white
                    drawAttrs.removeValue(forKey: .link)
                    drawAttrs.removeValue(forKey: .baselineOffset)

                    let baselineOrigin = NSPoint(x: tagRect.minX, y: tagRect.minY + descent - 3)

                    (fragmentText as NSString).draw(at: baselineOrigin, withAttributes: drawAttrs)

                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
    }

    public func initTextStorage() {
        let processor = TextStorageProcessor()
        processor.editor = self
        
        textStorageProcessor = processor
        textStorage?.delegate = processor

        guard let textStorage = self.textStorage,
              let oldLayoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }
        
        textStorage.removeLayoutManager(oldLayoutManager)

        let customLayoutManager = LayoutManager()
        customLayoutManager.addTextContainer(textContainer)
        customLayoutManager.delegate = customLayoutManager
        
        customLayoutManager.processor = processor
        
        textStorage.addLayoutManager(customLayoutManager)
    }
    
    public func configure() {
        DispatchQueue.main.async {
            self.updateTextContainerInset()
        }
            
        attributesCachingQueue.qualityOfService = .background
        textContainerInset.height = 10
        isEditable = false

        let isOpenedWindow = window?.contentViewController as? NoteViewController != nil
        
        layoutManager?.allowsNonContiguousLayout =
            isOpenedWindow
                ? false
                : UserDefaultsManagement.nonContiguousLayout

        layoutManager?.defaultAttachmentScaling = .scaleProportionallyDown
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        defaultParagraphStyle = paragraphStyle
        typingAttributes[.paragraphStyle] = paragraphStyle
        typingAttributes[.font] = UserDefaultsManagement.noteFont
    }

    public func invalidateLayout() {
        if let length = self.textStorage?.length {
            self.textStorage?.layoutManagers.first?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length), actualCharacterRange: nil)
        }
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        return []
    }

    @IBAction func moveSelectedLinesDown(_ sender: NSMenuItem) {
        self.moveSelectedLinesDown()
    }
    
    @IBAction func moveSelectedLinesUp(_ sender: NSMenuItem) {
        self.moveSelectedLinesUp()
    }
    
    @IBAction func clearCompletedTodos(_ sender: NSMenuItem) {
        self.clearCompletedTodos()
    }
    
    // MARK: Autocomplete overrides
    
    var suppressCompletion = false
    
    public var forceSystemAutocomplete = false
    private var isSystemCompletionSession = false
    
    override func didChangeText() {
        super.didChangeText()
        
        if suppressCompletion {
            suppressCompletion = false
            return
        }
        
        if detectCompletionContext() != .none {
            complete(nil)
        }
    }
    
    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {

        if forceSystemAutocomplete {
            isSystemCompletionSession = true
            forceSystemAutocomplete = false
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }

        return handleCompletions(index: index)
    }

    override func insertCompletion(_ word: String,
                                   forPartialWordRange charRange: NSRange,
                                   movement: Int,
                                   isFinal flag: Bool) {

        if isSystemCompletionSession {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)

            if flag {
                isSystemCompletionSession = false
            }
            return
        }

        handleInsertCompletion(word: word, movement: movement, isFinal: flag)
    }

    override var rangeForUserCompletion: NSRange {
        if isSystemCompletionSession {
            return super.rangeForUserCompletion
        }

        return calculateCompletionRange()
    }
    
    @objc public func scanTagsAndAutoRename() {
        guard let vc = ViewController.shared() else { return }
        let notes = vc.tagsScannerQueue

        attributesCachingQueue.addOperation {
            for note in notes {
                note.cache()
            }
        }
        
        for note in notes {
            let result = note.scanContentTags()
            guard let outline = ViewController.shared()?.sidebarOutlineView else { return }

            let added = result.0
            let removed = result.1

            if removed.count > 0 {
                outline.removeTags(removed)
            }

            if added.count > 0 {
                outline.addTags(added)
            }

            if let title = note.getAutoRenameTitle() {
                note.rename(to: title)

                if let editorViewController = getEVC() {
                    editorViewController.vcTitleLabel?.updateNotesTableView()
                    editorViewController.updateTitle(note: note)
                }
            }

            ViewController.shared()?.tagsScannerQueue.removeAll(where: { $0 === note })
        }
    }

    func setEditorTextColor(_ color: NSColor) {
        if let note = self.note, !note.isMarkdown() {
            textColor = color
        }
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y - 7)
    }

    // drawGutterIcons moved to GutterController

    /// Width of the left-hand gutter for header fold/unfold controls.
    public static let gutterWidth: CGFloat = 32

    @available(OSX 10.12.2, *)
    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [
            NSTouchBarItem.Identifier("Todo"),
            NSTouchBarItem.Identifier("Bold"),
            NSTouchBarItem.Identifier("Italic"),
            .fixedSpaceSmall,
            NSTouchBarItem.Identifier("Link"),
            NSTouchBarItem.Identifier("Image or file"),
            NSTouchBarItem.Identifier("CodeBlock"),
            .fixedSpaceSmall,
            NSTouchBarItem.Identifier("Indent"),
            NSTouchBarItem.Identifier("UnIndent")
        ]
        return touchBar
    }

    @available(OSX 10.12.2, *)
    override func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case NSTouchBarItem.Identifier("Todo"):
            if let im = NSImage(named: "todo"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(todo(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Bold"):
            if let im = NSImage(named: "bold"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(pressBold(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Italic"):
            if let im = NSImage(named: "italic"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(pressItalic(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Image or file"):
            if let im = NSImage(named: "image"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(insertFileOrImage(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }

        case NSTouchBarItem.Identifier("Indent"):
            if let im = NSImage(named: "indent"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(shiftRight(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }

        case NSTouchBarItem.Identifier("UnIndent"):
            if let im = NSImage(named: "unindent"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(shiftLeft(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("CodeBlock"):
            if let im = NSImage(named: "codeblock"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(insertCodeBlock(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        case NSTouchBarItem.Identifier("Link"):
            if let im = NSImage(named: "tb_link"), im.isValid, im.size.height > 0 {
                let image = im.tint(color: NSColor.white)
                image.size = NSSize(width: 20, height: 20)
                let button = NSButton(image: image, target: self, action: #selector(insertLink(_:)))
                button.bezelColor = NSColor(red:0.21, green:0.21, blue:0.21, alpha:1.0)

                let customViewItem = NSCustomTouchBarItem(identifier: identifier)
                customViewItem.view = button
                return customViewItem
            }
        default: break
        }

        return super.touchBar(touchBar, makeItemForIdentifier: identifier)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)

        let editTitle = NSLocalizedString("Edit Link…", comment: "")
        if let editLink = menu?.item(withTitle: editTitle) {
            menu?.removeItem(editLink)
        }

        let removeTitle = NSLocalizedString("Remove Link", comment: "")
        if let removeLink = menu?.item(withTitle: removeTitle) {
            menu?.removeItem(removeLink)
        }

        return menu
    }

    /**
     Handoff methods
     */
    override func updateUserActivityState(_ userActivity: NSUserActivity) {
        guard let note = self.note else { return }

        let position =
            window?.firstResponder == self ? selectedRange().location : -1
        let data =
            [
                "note-file-name": note.name,
                "position": String(position)
            ]

        userActivity.addUserInfoEntries(from: data)
    }

    override func resignFirstResponder() -> Bool {
        userActivity?.needsSave = true

        if let scrollView = enclosingScrollView as? EditorScrollView {
            scrollView.hideFocusBorder()
        }

        return super.resignFirstResponder()
    }

    public func registerHandoff(note: Note) {
        self.userActivity?.invalidate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let updateDict:  [String: String] = ["note-file-name": note.name]
            let activity = NSUserActivity(activityType: "es.fsnot.handoff-open-note")
            activity.isEligibleForHandoff = true
            activity.userInfo = updateDict
            activity.title = NSLocalizedString("Open note", comment: "Document opened")
            self.userActivity = activity
            self.userActivity?.becomeCurrent()
        }
    }
    
    public func scheduleTagScan(for note: Note) {
        if let vc = ViewController.shared(),
           !vc.tagsScannerQueue.contains(note) {
            vc.tagsScannerQueue.append(note)
        }

        tagsTimer?.invalidate()
        tagsTimer = Timer.scheduledTimer(
            timeInterval: 2.5,
            target: self,
            selector: #selector(scanTagsAndAutoRename),
            userInfo: nil,
            repeats: false
        )
    }

    public func resetTypingAttributes() {
        typingAttributes.removeValue(forKey: .attachmentUrl)
        typingAttributes.removeValue(forKey: .attachmentTitle)
        typingAttributes.removeValue(forKey: .attachmentPath)
        typingAttributes.removeValue(forKey: .attachmentSave)
        typingAttributes.removeValue(forKey: .tag)

        if let style = typingAttributes[.paragraphStyle] as? NSMutableParagraphStyle {
            style.alignment = .left
        }
        
        typingAttributes[.font] = UserDefaultsManagement.noteFont
    }
}
