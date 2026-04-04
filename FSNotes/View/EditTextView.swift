//
//  EditTextView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 8/11/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa
import Carbon.HIToolbox
import PDFKit
import QuickLookThumbnailing

class EditTextView: NSTextView, NSTextFinderClient, NSSharingServicePickerDelegate, EditorDelegate {
    public var currentNote: Note? { return self.note }
    public func setNeedsDisplay() { self.needsDisplay = true }
    public var editorLayoutManager: NSLayoutManager? { return self.layoutManager }
    public var editorTextContainer: NSTextContainer? { return self.textContainer }
    public var editorContentWidth: CGFloat { return enclosingScrollView?.contentView.bounds.width ?? 400 }

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
    
    // MARK: Overrides

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var newRect = rect
        newRect.size.width = caretWidth

        // Fixes last line height
        if let textStorage = self.textStorage,
           let layoutManager = self.layoutManager as? LayoutManager {
            let insertionPoint = self.selectedRange().location

            if insertionPoint == textStorage.length, insertionPoint > 0 {
                let lastIndex = insertionPoint - 1
                let attributes = textStorage.attributes(at: lastIndex, effectiveRange: nil)

                let isNewline: Bool = {
                    let ns = textStorage.string as NSString
                    return ns.character(at: lastIndex) == 0x0A
                }()

                let fontToUse: NSFont
                if !isNewline, let font = attributes[.font] as? NSFont {
                    fontToUse = font
                } else {
                    fontToUse = UserDefaultsManagement.noteFont
                }

                newRect.size.height = layoutManager.lineHeight(for: fontToUse)
            }
        }

        let clr = NSColor(red: 0.47, green: 0.53, blue: 0.69, alpha: 1.0)
        super.drawInsertionPoint(in: newRect, color: clr, turnedOn: flag)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(true)
    }
    
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        var newInvalidRect = NSRect(origin: invalidRect.origin, size: invalidRect.size)
        newInvalidRect.size.width += self.caretWidth - 1
        super.setNeedsDisplay(newInvalidRect)
    }
    
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.continuousSpellChecking = (menu.state == .off)
        }
        super.toggleContinuousSpellChecking(sender)
    }
    
    override func toggleGrammarChecking(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.grammarChecking = (menu.state == .off)
        }
        super.toggleGrammarChecking(sender)
    }
    
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticSpellingCorrection = (menu.state == .off)
        }
        super.toggleAutomaticSpellingCorrection(sender)
    }
    
    override func toggleSmartInsertDelete(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.smartInsertDelete = (menu.state == .off)
        }
        super.toggleSmartInsertDelete(sender)
    }
    
    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticQuoteSubstitution = (menu.state == .off)
        }
        super.toggleAutomaticQuoteSubstitution(sender)
    }
    
    override func toggleAutomaticDataDetection(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticDataDetection = (menu.state == .off)
        }
        super.toggleAutomaticDataDetection(sender)
    }
    
    override func toggleAutomaticLinkDetection(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticLinkDetection = (menu.state == .off)
        }
        super.toggleAutomaticLinkDetection(sender)
    }
    
    override func toggleAutomaticTextReplacement(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticTextReplacement = (menu.state == .off)
        }
        super.toggleAutomaticTextReplacement(sender)
    }
    
    override func toggleAutomaticDashSubstitution(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticDashSubstitution = (menu.state == .off)
        }
        super.toggleAutomaticDashSubstitution(sender)
    }

    private var dragDetected = false

    override func mouseDown(with event: NSEvent) {
        guard let note = self.note else { return }
        guard note.container != .encryptedTextPack else {
            editorViewController?.unLock(notes: [note])
            editorViewController?.vcNonSelectedLabel?.isHidden = false
            return
        }

        self.isEditable = true

        // Check for click in the gutter (fold/unfold toggle)
        if NotesTextProcessor.hideSyntax, gutterController.handleClick(event) {
            return
        }

        // Check for click on rendered block (mermaid/math) — open source editor
        // But NOT tables — those are handled as interactive views
        if NotesTextProcessor.hideSyntax, handleRenderedBlockClick(event) {
            return
        }

        // Unfocus all inline table views when clicking in the editor
        unfocusAllInlineTableViews()

        // In WYSIWYG mode, clicking a link opens it (like a browser)
        if NotesTextProcessor.hideSyntax, let storage = textStorage {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            if charIndex >= 0 && charIndex < storage.length {
                if let link = storage.attribute(.link, at: charIndex, effectiveRange: nil) {
                    if let urlString = link as? String {
                        if urlString.isValidEmail(), let mail = URL(string: "mailto:\(urlString)") {
                            NSWorkspace.shared.open(mail)
                        } else if let url = URL(string: urlString) {
                            NSWorkspace.shared.open(url)
                        }
                    } else if let url = link as? URL {
                        NSWorkspace.shared.open(url)
                    }
                    return
                }
            }
        }

        let range = selectedRange
        if handleTodo(event) {
            self.window?.makeFirstResponder(self)
            setSelectedRange(range)
            self.window?.makeFirstResponder(nil)
            return
        }
        
        dragDetected = false
        super.mouseDown(with: event)

        // In WYSIWYG mode, snap cursor out of hidden syntax areas (e.g., ## prefix)
        if NotesTextProcessor.hideSyntax, let storage = textStorage {
            var loc = selectedRange().location
            while loc < storage.length {
                let color = storage.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
                if color == NSColor.clear {
                    loc += 1
                } else {
                    break
                }
            }
            if loc != selectedRange().location {
                setSelectedRange(NSRange(location: loc, length: 0))
            }
        }

        saveSelectedRange()

        if !self.dragDetected {
            self.handleClick(event)
            self.dragDetected = false
        }

        // Trigger mermaid rendering if cursor moved outside a code block
        triggerCodeBlockRenderingIfNeeded()
    }

    /// Trigger rendering of mermaid/math code blocks if cursor is outside all code blocks.
    /// Skips re-scanning when only the cursor moved and no edit occurred (text length unchanged).
    public func triggerCodeBlockRenderingIfNeeded() {
        #if os(OSX)
        guard NotesTextProcessor.hideSyntax,
              let processor = self.textStorageProcessor,
              let storage = self.textStorage else { return }

        let cursorLoc = selectedRange().location

        // Use block model for code block ranges (single source of truth)
        let freshRanges = processor.codeBlockRanges
        let isInCodeBlock = freshRanges.contains { NSLocationInRange(cursorLoc, $0) }

        // If there's a specific pending block, check if cursor left it
        if let pendingRange = pendingRenderBlockRange {
            let isInsidePending = NSLocationInRange(cursorLoc, pendingRange)

            if !isInsidePending {
                pendingRenderBlockRange = nil
                if !freshRanges.isEmpty {
                    processor.renderSpecialCodeBlocks(textStorage: storage, codeBlockRanges: freshRanges)
                }
            }
            return
        }

        // Render if cursor is outside all code blocks
        if !isInCodeBlock && !freshRanges.isEmpty {
            processor.renderSpecialCodeBlocks(textStorage: storage, codeBlockRanges: freshRanges)
        }
        #endif
    }
    
    // Gutter click handling moved to GutterController

    @objc public func toggleFoldAtCursor() {
        gutterController.toggleFoldAtCursor()
    }

    @objc public func foldAllHeaders() {
        gutterController.foldAllHeaders()
    }

    @objc public func unfoldAllHeaders() {
        gutterController.unfoldAllHeaders()
    }

    private func handleRenderedBlockClick(_ event: NSEvent) -> Bool {
        guard let storage = textStorage,
              let container = self.textContainer,
              let manager = self.layoutManager else { return false }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)

        guard index < storage.length else { return false }

        // Check if clicked on an attachment with rendered block metadata
        guard storage.attribute(.attachment, at: index, effectiveRange: nil) != nil,
              let originalMarkdown = storage.attribute(.renderedBlockOriginalMarkdown, at: index, effectiveRange: nil) as? String else {
            return false
        }

        // CLICK-OUTSIDE-TABLE FIX (do not break this — it was fixed after many iterations):
        //
        // Problem: Table attachment occupies a visual area in NSTextView. Clicks ANYWHERE
        // in that area map to the attachment character. Without this check, clicking to the
        // right of the table (outside cells) would re-focus the table instead of placing
        // the cursor after it.
        //
        // Solution: Two-layer defense:
        // 1. InlineTableView.hitTest() returns nil for points outside cells → click passes to EditTextView
        // 2. HERE: check if the click is within any cell/handle. If not, return false.
        //    This prevents re-focusing the table from clicks that map to the attachment
        //    character but are visually outside the table grid.
        //
        // Both layers are needed because hitTest works on the NSView frame, while this
        // check works on the character index → attachment mapping in the text storage.
        if let blockType = storage.attribute(.renderedBlockType, at: index, effectiveRange: nil) as? String,
           blockType == RenderedBlockType.table.rawValue {
            if let att = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
               let attCell = att.attachmentCell as? InlineTableAttachmentCell {
                let tableView = attCell.inlineTableView
                let tablePoint = tableView.convert(event.locationInWindow, from: nil)

                // Check if click is within any cell
                let hitCell = tableView.cellPool.contains(where: { !$0.isHidden && $0.frame.contains(tablePoint) })
                let hitHandle = tableView.subviews.contains(where: { $0 is NSVisualEffectView && $0.frame.contains(tablePoint) })

                if !hitCell && !hitHandle {
                    // Click is outside the table grid — don't capture
                    return false
                }

                tableView.focusState = .editing
                DispatchQueue.main.async {
                    let deferredPoint = tableView.convert(event.locationInWindow, from: nil)
                    for cell in tableView.cellPool where !cell.isHidden {
                        if cell.frame.contains(deferredPoint) {
                            tableView.window?.makeFirstResponder(cell)
                            return
                        }
                    }
                    if let first = tableView.headerCells.first {
                        tableView.window?.makeFirstResponder(first)
                    }
                }
            }
            return true
        }

        // Restore the original markdown code block inline (replacing the attachment)
        let attachmentRange = NSRange(location: index, length: 1)
        guard NSMaxRange(attachmentRange) <= storage.length else { return false }

        // Flip the block's render mode to .source BEFORE replacing text,
        // so the incremental update in process() will reparse it correctly.
        if let processor = self.textStorageProcessor {
            if let idx = processor.blocks.firstIndex(where: { $0.renderMode == .rendered && $0.range.location == index }) {
                processor.blocks[idx].renderMode = .source
            }
        }

        // Ensure the restored markdown ends with \n so the code block regex can
        // match the closing fence (requires \n or end-of-string after ```)
        var markdown = originalMarkdown
        if !markdown.hasSuffix("\n") {
            markdown += "\n"
        }

        // Set clean typing attributes BEFORE insertion so the restored markdown
        // doesn't inherit rendered-block attributes from the attachment.
        typingAttributes = [
            .font: UserDefaultsManagement.noteFont,
            .foregroundColor: NotesTextProcessor.fontColor
        ]

        breakUndoCoalescing()
        insertText(markdown, replacementRange: attachmentRange)
        breakUndoCoalescing()

        let restoredRange = NSRange(location: index, length: min(markdown.count, storage.length - index))

        // Place cursor inside the code block for editing
        let cursorPos = min(index + markdown.count - 5, storage.length) // before closing ```\n
        setSelectedRange(NSRange(location: cursorPos, length: 0))

        // Mark this code block range as needing re-render when cursor leaves
        pendingRenderBlockRange = restoredRange

        return true
    }

    private func handleTodo(_ event: NSEvent) -> Bool {
        guard let container = self.textContainer,
              let manager = self.layoutManager
        else { return false }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)

        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)

        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)

        guard glyphRect.contains(properPoint) else { return false }
        
        if isTodo(index) {
            guard let f = self.getTextFormatter() else { return false }
            f.toggleTodo(index)

            DispatchQueue.main.async {
                NSCursor.pointingHand.set()
            }

            return true
        }
        
        return false
    }

    private func handleClick(_ event: NSEvent) {
        guard let container = self.textContainer,
              let manager = self.layoutManager
        else { return }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)

        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)

        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)

        guard glyphRect.contains(properPoint) else { return }

        if hasAttachment(at: index) {
            if event.modifierFlags.contains(.command) {
                openTitleEditor(at: index)
            } else {
                openFileViewer(at: index)
            }

            return
        }
    }

    private func openTitleEditor(at: Int) {
        guard let vc = editorViewController,
              let window = vc.view.window,
              var attachment = getAttachment(at: at) else { return }

        vc.alert = NSAlert()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 20))
        field.placeholderString = "All Hail the Crimson King"
        field.stringValue = attachment.title

        vc.alert?.messageText = NSLocalizedString("Please enter image title:", comment: "Edit area")
        vc.alert?.accessoryView = field
        vc.alert?.alertStyle = .informational
        vc.alert?.addButton(withTitle: "OK")
        vc.alert?.beginSheetModal(for: window) { (returnCode: NSApplication.ModalResponse) -> Void in
            if returnCode == NSApplication.ModalResponse.alertFirstButtonReturn {
                attachment.title = field.stringValue

                var range = NSRange()
                if self.textStorage?.attribute(.attachment, at: at, effectiveRange: &range) as? NSTextAttachment != nil {
                    self.textStorage?.addAttribute(.attachmentTitle, value: attachment.title, range: range)

                    let content = NSMutableAttributedString(attributedString: self.attributedString())
                    _ = self.note?.save(content: content)
                }
            }
            vc.alert = nil
        }

        DispatchQueue.main.async {
            field.becomeFirstResponder()
        }
    }

    private func openFileViewer(at: Int) {
        guard let attachment = getAttachment(at: at) else { return }

        let url = attachment.url

        if !url.isImage {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        NSWorkspace.shared.open(url)
    }

    override func mouseMoved(with event: NSEvent) {
        if editorViewController?.vcNonSelectedLabel?.isHidden == false {
            NSCursor.arrow.set()
            return
        }

        let point = self.convert(event.locationInWindow, from: nil)

        // Track gutter hover — fold carets only show when mouse is in the pipe area
        if NotesTextProcessor.hideSyntax {
            gutterController.updateMouseTracking(at: point)
        }
        let properPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )

        guard let container = self.textContainer,
              let manager = self.layoutManager,
              let textStorage = self.textStorage else { return }

        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)

        guard index < textStorage.length else { return }

        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)

        if glyphRect.contains(properPoint), self.isTodo(index) || self.hasAttachment(at: index) {
            NSCursor.pointingHand.set()
            return
        }

        if glyphRect.contains(properPoint),
           let link = textStorage.attribute(.link, at: index, effectiveRange: nil) {

            if textStorage.attribute(.tag, at: index, effectiveRange: nil) != nil {
                NSCursor.pointingHand.set()
                return
            }

            // In WYSIWYG mode, always show hand cursor for links
            if NotesTextProcessor.hideSyntax {
                NSCursor.pointingHand.set()
                return
            }

            if link as? URL != nil {
                if UserDefaultsManagement.clickableLinks
                    || event.modifierFlags.contains(.command)
                    || event.modifierFlags.contains(.shift)
                {
                    NSCursor.pointingHand.set()
                    return
                }

                NSCursor.iBeam.set()
                return
            }
        }

        super.mouseMoved(with: event)
    }

    public func hasAttachment(at: Int) -> Bool {
        guard let storage = textStorage,
                  at >= 0,
                  at < storage.length else { return false }
        
        guard textStorage?.attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment != nil else {
            return false
        }

        return textStorage?.getMeta(at: at) != nil
    }

    public func getAttachment(at: Int) -> (url: URL, title: String, path: String)? {
        if textStorage?.attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment != nil,
           let meta = textStorage?.getMeta(at: at) {
            return meta
        }

        return nil
    }

    public func isTodo(_ location: Int) -> Bool {
        guard let storage = self.textStorage else { return false }
        
        let range = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let string = storage.attributedSubstring(from: range).string as NSString

        var length = string.range(of: "- [ ] ").length
        if length == 0 {
            length = string.range(of: "- [x] ").length
        }
        
        if length > 0 {
            let upper = range.location + length
            if location >= range.location && location <= upper {
                return true
            }
        }

        return false
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        get {
            return [
                NSPasteboard.attributed,
                NSPasteboard.PasteboardType.string,
            ]
        }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        get {
            return super.readablePasteboardTypes + [NSPasteboard.attributed]
        }
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let storage = textStorage else { return false }

        dragDetected = true
        
        let range = selectedRange()
        let attributedString = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))

        if type == .string {
            let plainText = attributedString.unloadAttachments().string
            pboard.setString(plainText, forType: .string)
            return true
        }

        if type == NSPasteboard.attributed {
            attributedString.saveData()

            if let data = try? NSKeyedArchiver.archivedData(
                withRootObject: attributedString,
                requiringSecureCoding: false
            ) {
                pboard.setData(data, forType: NSPasteboard.attributed)
                return true
            }
        }

        return false
    }

    // Copy empty string
    override func copy(_ sender: Any?) {
        let attrString = attributedSubstring(forProposedRange: self.selectedRange, actualRange: nil)

        if self.selectedRange.length == 1,
            let url = attrString?.attribute(.attachmentUrl, at: 0, effectiveRange: nil) as? URL
        {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            return
        }

        if selectedRanges.count > 1 {
            var combined = String()
            for range in selectedRanges {
                if let range = range as? NSRange, let sub = attributedSubstring(forProposedRange: range, actualRange: nil) as? NSMutableAttributedString {

                    combined.append(sub.unloadAttachments().string + "\n")
                }
            }

            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
            pasteboard.setString(combined.trim().removeLastNewLine(), forType: NSPasteboard.PasteboardType.string)
            return
        }

        if self.selectedRange.length == 0, let paragraphRange = self.getParagraphRange(), let paragraph = attributedSubstring(forProposedRange: paragraphRange, actualRange: nil) {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
            pasteboard.setString(paragraph.string.trim().removeLastNewLine(), forType: NSPasteboard.PasteboardType.string)
            return
        }
        
        if let menuItem = sender as? NSMenuItem,
           menuItem.identifier?.rawValue == "copy:",
           self.selectedRange.length > 0 {
            
            let attrString = attributedSubstring(forProposedRange: self.selectedRange, actualRange: nil)
            
            if let attrString = attrString,
               let link = attrString.attribute(.link, at: 0, effectiveRange: nil) as? String {
                
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(link, forType: .string)
                return
            }
        }

        super.copy(sender)
    }

    override func paste(_ sender: Any?) {
        guard let note = self.note else { return }

        // RTFD
        if let rtfdData = NSPasteboard.general.data(forType: NSPasteboard.attributed),
           let attributed = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(rtfdData) as? NSAttributedString {

            breakUndoCoalescing()
            insertText(attributed, replacementRange: selectedRange())
            breakUndoCoalescing()

            return
        }

        // File URL (copy from Finder) — check before images, because copying
        // a file from Finder puts both a file URL and a TIFF icon on the pasteboard.
        if let url = NSURL(from: NSPasteboard.general) {
            if url.isFileURL && saveFile(url: url as URL, in: note) {
                return
            }
        }

        // PDF data (e.g., copied from Preview.app or drag-and-drop) — check before
        // images, because pasting a PDF also puts a TIFF icon on the pasteboard.
        if let pdfData = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType.pdf) ?? NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(rawValue: "com.adobe.pdf")),
           pdfData.isPDF {
            let preferredName = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "document.pdf"
            let name = preferredName.hasSuffix(".pdf") ? preferredName : "document.pdf"
            if saveFileWithThumbnail(data: pdfData, preferredName: name, in: note) {
                return
            }
        }

        // Images png or tiff — check before plain text, because copying an image
        // from a browser puts both image data and a URL string on the pasteboard.
        // Without this priority, the URL string gets pasted instead of the image.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = NSPasteboard.general.data(forType: type) {
                guard let attributed = NSMutableAttributedString.build(data: data) else { continue }

                breakUndoCoalescing()
                insertText(attributed, replacementRange: selectedRange())
                breakUndoCoalescing()

                return
            }
        }

        // Plain text
        if let clipboard = NSPasteboard.general.string(forType: NSPasteboard.PasteboardType.string),
            NSPasteboard.general.string(forType: NSPasteboard.PasteboardType.fileURL) == nil {

            let attributed = NSMutableAttributedString(string: clipboard.trim())

            breakUndoCoalescing()
            insertText(attributed, replacementRange: selectedRange())
            breakUndoCoalescing()

            return
        }

        super.paste(sender)
    }
    
    override func pasteAsPlainText(_ sender: Any?) {
        let currentRange = selectedRange()
        var plainText: String?

        if let rtfd = NSPasteboard.general.data(forType: NSPasteboard.attributed),
           let attributedString = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(rtfd) as? NSAttributedString {

            let mutable = NSMutableAttributedString(attributedString: attributedString)
            plainText = mutable.unloadAttachments().string
        } else if let clipboard = NSPasteboard.general.string(forType: NSPasteboard.PasteboardType.string), NSPasteboard.general.string(forType: NSPasteboard.PasteboardType.fileURL) == nil {
            plainText = clipboard
        } else if let url = NSPasteboard.general.string(forType: NSPasteboard.PasteboardType.fileURL) {
            plainText = url
        }

        if let plainText = plainText {
            self.breakUndoCoalescing()
            self.insertText(plainText, replacementRange: currentRange)
            self.breakUndoCoalescing()

            return
        }

        return paste(sender)
    }

    override func cut(_ sender: Any?) {
        guard nil != self.note else {
            super.cut(sender)
            return
        }

        if self.selectedRange.length == 0, let paragraphRange = self.getParagraphRange(), let paragraph = attributedSubstring(forProposedRange: paragraphRange, actualRange: nil) {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([NSPasteboard.PasteboardType.string], owner: nil)
            pasteboard.setString(paragraph.string.trim().removeLastNewLine(), forType: NSPasteboard.PasteboardType.string)

            insertText(String(), replacementRange: paragraphRange)
            return
        }

        super.cut(sender)
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

    // Clickable links flag changed with cmd / shift
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)

        if let mouseEvent = NSApp.currentEvent {
            updateCursorForMouse(at: mouseEvent)
        }
    }

    private func updateCursorForMouse(at event: NSEvent) {
        guard let container = self.textContainer,
              let manager = self.layoutManager,
              let textStorage = self.textStorage else { return }

        let pointInView = self.convert(event.locationInWindow, from: nil)
        
        let pointInContainer = NSPoint(
            x: pointInView.x - textContainerInset.width,
            y: (self.bounds.size.height - pointInView.y) - textContainerInset.height
        )

        let index = manager.characterIndex(
            for: pointInContainer,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        guard index < textStorage.length else {
            NSCursor.iBeam.set()
            return
        }

        if let link = textStorage.attribute(.link, at: index, effectiveRange: nil) {
            if textStorage.attribute(.tag, at: index, effectiveRange: nil) != nil {
                NSCursor.pointingHand.set()
            } else if link as? URL != nil {
                if UserDefaultsManagement.clickableLinks
                    || NSEvent.modifierFlags.contains(.command)
                    || NSEvent.modifierFlags.contains(.shift) {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.iBeam.set()
                }
            }
        } else {
            NSCursor.iBeam.set()
        }
    }
    
    override func keyDown(with event: NSEvent) {
        defer {
            saveSelectedRange()
        }

        // fixes backtick marked text
        if let characters = event.characters, characters == "`" {
            super.insertText("`", replacementRange: selectedRange())
            return
        }

        guard !(
            event.modifierFlags.contains(.shift) &&
            [
                kVK_UpArrow,
                kVK_DownArrow,
                kVK_LeftArrow,
                kVK_RightArrow
            ].contains(Int(event.keyCode))
        ) else {
            super.keyDown(with: event)
            return
        }
        
        guard let note = self.note else { return }
        
        // Handle autoclose brackets
        if UserDefaultsManagement.autocloseBrackets,
           handleAutocloseBrackets(for: event) {
            return
        }

        // hasMarkedText added for Japanese hack https://yllan.org/blog/archives/231
        if event.keyCode == kVK_Tab && !hasMarkedText(){
            breakUndoCoalescing()
            
            let formatter = TextFormatter(textView: self, note: note)
            if formatter.isListParagraph() {
                if NSEvent.modifierFlags.contains(.shift) {
                    formatter.unTab()
                } else {
                    formatter.tab()
                }
                
                breakUndoCoalescing()
                return
            }
            
            if UserDefaultsManagement.indentUsing == 0x01 {
                let tab = TextFormatter.getAttributedCode(string: "  ")
                insertText(tab, replacementRange: selectedRange())
                breakUndoCoalescing()
                return
            }
            
            if UserDefaultsManagement.indentUsing == 0x02 {
                let tab = TextFormatter.getAttributedCode(string: "    ")
                insertText(tab, replacementRange: selectedRange())
                breakUndoCoalescing()
                return
            }
            super.keyDown(with: event)
            return
        }

        if event.keyCode == kVK_Return && !hasMarkedText() && isEditable {
            breakUndoCoalescing()
            let formatter = TextFormatter(textView: self, note: note)
            formatter.newLine()
            breakUndoCoalescing()

            return
        }

        if event.characters?.unicodeScalars.first == "o" && event.modifierFlags.contains(.command) {
            guard let storage = textStorage else { return }

            var location = selectedRange().location
            if location == storage.length && location > 0 {
                location = location - 1
            }

            if storage.length > location, let link = textStorage?.attribute(.link, at: location, effectiveRange: nil) as? String {
                if link.isValidEmail(), let mail = URL(string: "mailto:\(link)") {
                    NSWorkspace.shared.open(mail)
                } else if let url = URL(string: link) {
                    _ = try? NSWorkspace.shared.open(url, options: .default, configuration: [:])
                }
            }
            return
        }
        
        super.keyDown(with: event)
    }

    // MARK: - Autoclose Brackets

    private func handleAutocloseBrackets(for event: NSEvent) -> Bool {
        let brackets: [String: String] = [
            "(" : ")",
            "[" : "]",
            "{" : "}",
            "\"" : "\""
        ]
        
        guard let character = event.characters else {
            return false
        }
        
        // Check if user is typing a closing bracket
        let closingBrackets = Array(brackets.values)
        if closingBrackets.contains(character) {
            // Check if the next character is the same closing bracket
            let currentRange = selectedRange()
            if currentRange.length == 0,
               let storage = textStorage,
               currentRange.location < storage.length {
                let nextCharRange = NSRange(location: currentRange.location, length: 1)
                let nextCharString = storage.attributedSubstring(from: nextCharRange).string
                
                if nextCharString == character {
                    // Skip the closing bracket and move cursor forward
                    setSelectedRange(NSMakeRange(currentRange.location + 1, 0))
                    return true
                }
            }
        }
        
        // Handle opening brackets
        guard let closingBracket = brackets[character] else {
            return false
        }
        
        if selectedRange().length > 0 {
            // Wrap selection with brackets
            let before = NSMakeRange(selectedRange().lowerBound, 0)
            self.insertText(character, replacementRange: before)
            let after = NSMakeRange(selectedRange().upperBound, 0)
            self.insertText(closingBracket, replacementRange: after)
        } else {
            // Insert bracket pair
            super.keyDown(with: event)
            self.insertText(closingBracket, replacementRange: selectedRange())
            self.moveBackward(self)
        }
        
        return true
    }
    
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard let note = self.note else {
            return super.shouldChangeText(in: range, replacementString: replacementString)
        }

        note.resetAttributesCache()
                
        scheduleTagScan(for: note)
        deleteUnusedImages(checkRange: range)
        resetTypingAttributes()

        return super.shouldChangeText(in: range, replacementString: replacementString)
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
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        imagesLoaderQueue.maxConcurrentOperationCount = 3
        imagesLoaderQueue.qualityOfService = .userInteractive
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y - 7)
    }

    // drawGutterIcons moved to GutterController

    @IBAction func insertFileOrImage(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = true
        panel.begin { (result) -> Void in
            if result == NSApplication.ModalResponse.OK {
                let urls = panel.urls

                for url in urls {
                    if self.saveFile(url: url, in: note) {
                        if urls.count > 1 {
                            self.insertNewline(nil)
                        }
                    }
                }

                if let vc = ViewController.shared() {
                    vc.notesTableView.reloadRow(note: note)
                }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        UserDataService.instance.isDark = effectiveAppearance.isDark
        storage.resetCacheAttributes()

        let webkitPreview = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wkPreview")
        try? FileManager.default.removeItem(at: webkitPreview)

        NotesTextProcessor.hl = nil

        guard let note = self.note else { return }
        NotesTextProcessor.highlight(attributedString: note.content)

        viewDelegate?.refillEditArea(force: true)
    }

    public func updateTextContainerInset() {
        textContainerInset.width = getInsetWidth()
    }

    /// Width of the left-hand gutter for header fold/unfold controls.
    public static let gutterWidth: CGFloat = 32

    /// Whether the mouse is currently hovering over the gutter (pipe) area.
    /// Fold carets only appear on hover, matching Bear/Apple Notes behavior.

    public func getInsetWidth() -> CGFloat {
        let lineWidth = UserDefaultsManagement.lineWidth
        let margin = UserDefaultsManagement.marginSize
        let width = frame.width
        // Reserve extra space for the header gutter in WYSIWYG mode
        let gutter: Float = NotesTextProcessor.hideSyntax ? Float(EditTextView.gutterWidth) : 0

        if lineWidth == 1000 {
            return CGFloat(margin + gutter)
        }

        guard Float(width) - margin * 2 > lineWidth else {
            return CGFloat(margin + gutter)
        }

        return CGFloat((Float(width) - lineWidth) / 2 + gutter)
    }

    private func deleteUnusedImages(checkRange: NSRange) {
        guard let storage = textStorage, self.note != nil else { return }

        storage.enumerateAttribute(.attachment, in: checkRange) { (value, range, _) in
            guard let meta = storage.getMeta(at: range.location) else { return }

            do {
                if let data = try? Data(contentsOf: meta.url) {
                    storage.addAttribute(.attachmentSave, value: data, range: range)

                    try FileManager.default.removeItem(at: meta.url)
                }
            } catch {
                print(error)
            }
        }
    }

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
