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

    // MARK: - EditorDelegate conformance
    public var currentNote: Note? { return self.note }
    public func setNeedsDisplay() { self.needsDisplay = true }
    public var editorLayoutManager: NSLayoutManager? { return self.layoutManager }
    public var editorTextContainer: NSTextContainer? { return self.textContainer }
    public var editorContentWidth: CGFloat { return enclosingScrollView?.contentView.bounds.width ?? 400 }
    // imagesLoaderQueue already declared as public property

    public var editorViewController: EditorViewController?
    public var textStorageProcessor: TextStorageProcessor?
    // retainedTableEditorVC removed — table editing is now inline via InlineTableView

    /// Collect cell data from all live InlineTableViews and update their
    /// .renderedBlockOriginalMarkdown attributes on the attachment.
    /// Called from save() and EditorViewController.saveContent() BEFORE reading
    /// the text storage for saving. NOT called from attributedString() to avoid
    /// re-entrancy (attributedString() should be a pure read).
    func syncAllTableData() {
        guard let storage = textStorage else { return }
        // DEBUG: count how many renderedBlockOriginalMarkdown attributes exist
        var blockCount = 0
        storage.enumerateAttribute(.renderedBlockOriginalMarkdown, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            if value != nil { blockCount += 1 }
        }
        if blockCount > 0 || !subviews.contains(where: { $0 is InlineTableView }) {
            let dbgPath = NSHomeDirectory() + "/fsnotes_table_sync_debug.log"
            // Dump the full text storage content and attribute values
            var attrDump = ""
            storage.enumerateAttribute(.renderedBlockOriginalMarkdown, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
                if let md = value as? String {
                    attrDump += "  attr at (\(range.location),\(range.length)): \(md.prefix(80).replacingOccurrences(of: "\n", with: "\\n"))...\n"
                }
            }
            let storageText = storage.string.prefix(200).replacingOccurrences(of: "\n", with: "\\n")
            let msg = "\(Date()): syncAllTableData — \(blockCount) attrs, \(subviews.filter { $0 is InlineTableView }.count) tables, len=\(storage.length)\n  storage: \(storageText)\n\(attrDump)\n"
            if let fh = FileHandle(forWritingAtPath: dbgPath) {
                fh.seekToEndOfFile(); fh.write(msg.data(using: .utf8)!); fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: dbgPath, contents: msg.data(using: .utf8))
            }
        }
        // First, clean up any "spread" rendered-block attributes from non-attachment chars.
        // NSTextStorage inherits attributes from the preceding character when the user types,
        // causing .renderedBlockOriginalMarkdown to spread beyond the attachment character.
        // This spread causes restoreRenderedBlocks() to duplicate the markdown on save.
        let fullCleanRange = NSRange(location: 0, length: storage.length)
        let string = storage.string as NSString
        var cleanRanges: [NSRange] = []
        storage.enumerateAttribute(.renderedBlockOriginalMarkdown, in: fullCleanRange, options: []) { value, range, _ in
            guard value != nil else { return }
            // Keep the attribute ONLY on attachment characters (\u{FFFC})
            for i in range.location..<NSMaxRange(range) {
                if i < string.length && string.character(at: i) != 0xFFFC {
                    cleanRanges.append(NSRange(location: i, length: 1))
                }
            }
        }
        for r in cleanRanges.reversed() {
            storage.removeAttribute(.renderedBlockOriginalMarkdown, range: r)
            storage.removeAttribute(.renderedBlockSource, range: r)
            storage.removeAttribute(.renderedBlockType, range: r)
        }

        // Update each table attachment with current cell data.
        // Find tables via attachment cells (not subviews) — tables outside the viewport
        // may not have been added as subviews yet.
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, stop in
            guard let att = value as? NSTextAttachment,
                  let cell = att.attachmentCell as? InlineTableAttachmentCell else { return }
            let tableView = cell.inlineTableView
            tableView.collectCellData()
            let markdown = tableView.generateMarkdown()
            storage.addAttribute(.renderedBlockOriginalMarkdown, value: markdown, range: range)
            storage.addAttribute(.renderedBlockSource, value: markdown, range: range)
        }
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
    var downView: MPreviewView?
    
    public var timer: Timer?
    public var tagsTimer: Timer?
    public var markdownView: MPreviewContainerView?
    public var isLastEdited: Bool = false
    
    @IBOutlet weak var previewMathJax: NSMenuItem!

    public var imagesLoaderQueue = OperationQueue.init()
    public var attributesCachingQueue = OperationQueue.init()
    
    private var preview = false
    
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
            drawGutterIcons(in: dirtyRect)
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

        if editorViewController?.vcEditor?.isPreviewEnabled() == false {
            self.isEditable = true
        }

        // Check for click in the gutter (fold/unfold toggle)
        if NotesTextProcessor.hideSyntax, handleGutterClick(event) {
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
    
    // MARK: - Gutter Click (Fold/Unfold)

    private func handleGutterClick(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let gutterWidth = EditTextView.gutterWidth

        // Gutter occupies the space from (insetWidth - gutterWidth) to insetWidth,
        // which is the reserved area left of the text container origin
        let gutterRight = textContainerInset.width
        let gutterLeft = gutterRight - gutterWidth
        guard point.x >= gutterLeft, point.x < gutterRight else { return false }

        guard let manager = self.layoutManager,
              let container = self.textContainer,
              let storage = self.textStorage,
              let processor = self.textStorageProcessor else { return false }

        // Map click Y to a character index
        let textPoint = NSPoint(x: textContainerInset.width + 1, y: point.y)
        let charIndex = manager.characterIndex(for: textPoint, in: container,
                                                fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < storage.length else { return false }

        // Find the header block at this position
        if let blockIdx = processor.headerBlockIndex(at: charIndex) {
            processor.toggleFold(headerBlockIndex: blockIdx, textStorage: storage)
            needsDisplay = true
            return true
        }
        return false
    }

    @objc public func toggleFoldAtCursor() {
        guard let storage = textStorage,
              let processor = textStorageProcessor else { return }
        let cursorPos = selectedRange().location
        // Find the header at cursor, or the nearest header above cursor
        if let idx = processor.headerBlockIndex(at: cursorPos) {
            processor.toggleFold(headerBlockIndex: idx, textStorage: storage)
            needsDisplay = true
        }
    }

    @objc public func foldAllHeaders() {
        guard let storage = textStorage,
              let processor = textStorageProcessor else { return }
        processor.foldAll(textStorage: storage)
        needsDisplay = true
    }

    @objc public func unfoldAllHeaders() {
        guard let storage = textStorage,
              let processor = textStorageProcessor else { return }
        processor.unfoldAll(textStorage: storage)
        needsDisplay = true
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

        breakUndoCoalescing()
        insertText(markdown, replacementRange: attachmentRange)
        breakUndoCoalescing()

        // Strip leaked rendered-block attributes from the restored text
        // (insertText inherits typing attributes from the attachment, which had these)
        let restoredRange = NSRange(location: index, length: min(markdown.count, storage.length - index))
        if restoredRange.length > 0 {
            storage.removeAttribute(.renderedBlockSource, range: restoredRange)
            storage.removeAttribute(.renderedBlockType, range: restoredRange)
            storage.removeAttribute(.renderedBlockOriginalMarkdown, range: restoredRange)
        }

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
            let inGutter = point.x < textContainerInset.width && point.x >= textContainerInset.width - EditTextView.gutterWidth
            if inGutter != isMouseInGutter {
                isMouseInGutter = inGutter
                needsDisplay = true  // Redraw to show/hide fold carets
            }
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

        if editorViewController?.vcEditor?.isPreviewEnabled() == true {
            return
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

        if storage.attribute(.todo, at: location, effectiveRange: nil) != nil {
            return true
        }

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
            let attributedString = attributedString.unloadTasks()
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

            let mutable = NSMutableAttributedString(attributedString: attributed)
            mutable.loadTasks()

            breakUndoCoalescing()
            insertText(mutable, replacementRange: selectedRange())
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
            attributed.loadTasks()

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

    func getSelectedNote() -> Note? {
        return ViewController.shared()?.notesTableView?.getSelectedNote()
    }
    
    public func isEditable(note: Note) -> Bool {
        if note.container == .encryptedTextPack { return false }

        guard let editor = editorViewController?.vcEditor else { return false }

        if editor.isPreviewEnabled() {
            return false
        }
        
        return true
    }

    public func getVC() -> EditorViewController {
        return self.window?.contentViewController as! EditorViewController
    }
    
    public func getEVC() -> EditorViewController? {
        return self.window?.contentViewController as? EditorViewController
    }

    public func save() {
        guard let note = self.note else { return }

        syncAllTableData()
        note.save(attributed: self.attributedString())
    }

    func fill(note: Note, highlight: Bool = false, force: Bool = false) {
        isScrollPositionSaverLocked = true

        // Clear block model before loading new note — rendered blocks from the
        // previous note have stale ranges that can crash the LayoutManager.
        textStorageProcessor?.blocks = []

        if !note.isLoaded {
            note.load()
        }

        viewDelegate?.updateCounters(note: note)

        textStorage?.setAttributedString(NSAttributedString(string: ""))
        
        // Hack for invalidate prev layout data (order is important, only before fill)
        if let length = textStorage?.length {
            textStorage?.layoutManagers.first?.invalidateDisplay(forGlyphRange: NSRange(location: 0, length: length))

            invalidateLayout()
        }

        undoManager?.removeAllActions(withTarget: self)
        registerHandoff(note: note)

        // resets timer if editor refilled 
        viewDelegate?.breakUndoTimer.invalidate()

        unregisterDraggedTypes()
        registerForDraggedTypes([
            NSPasteboard.note,
            NSPasteboard.PasteboardType.fileURL,
            NSPasteboard.PasteboardType.URL,
            NSPasteboard.PasteboardType.string
        ])

        if let label = editorViewController?.vcNonSelectedLabel {
            label.isHidden = true

            if note.container == .encryptedTextPack {
                label.stringValue = NSLocalizedString("Locked", comment: "")
                label.isHidden = false
            } else {
                label.stringValue = NSLocalizedString("None Selected", comment: "")
                label.isHidden = true
            }
        }
    
        self.note = note
        // Clear cache hash so process() repopulates the block model.
        // fill() clears blocks to [], but the cacheHash guard in process()
        // skips updateBlockModel if the content hasn't changed — leaving
        // blocks empty and mermaid/table rendering unable to find them.
        note.cacheHash = nil
        UserDefaultsManagement.lastSelectedURL = note.url

        editorViewController?.updateTitle(note: note)

        isEditable = isEditable(note: note)
        
        editorViewController?.editorUndoManager = note.undoManager

        typingAttributes.removeAll()
        typingAttributes[.font] = UserDefaultsManagement.noteFont

        if isPreviewEnabled() {
            loadMarkdownWebView(note: note, force: force)
            return
        }

        markdownView?.removeFromSuperview()
        markdownView = nil

        guard let storage = textStorage else { return }

        if note.isMarkdown(), let content = note.content.mutableCopy() as? NSMutableAttributedString {
            textStorageProcessor?.detector = CodeBlockDetector()

            // Clear stale state BEFORE replacing storage content
            pendingRenderBlockRange = nil
            removeAllInlineTableViews()

            storage.setAttributedString(content)
        } else {
            storage.setAttributedString(note.content)
        }
        
        if highlight {
            textStorage?.highlightKeyword(search: getSearchText())
        }

        // In WYSIWYG mode, ensure code fences are hidden after fill
        // (process() may not always run the fence-hiding path on setAttributedString)
        if NotesTextProcessor.hideSyntax, let storage = textStorage, let processor = textStorageProcessor {
            let codeBlockRanges = processor.codeBlockRanges
            let string = storage.string as NSString
            // Half-height paragraph style for hidden fence lines
            let fenceParaStyle = NSMutableParagraphStyle()
            fenceParaStyle.maximumLineHeight = CGFloat(UserDefaultsManagement.fontSize) * 0.5
            fenceParaStyle.lineSpacing = 0
            let fenceFont = NSFont.systemFont(ofSize: CGFloat(UserDefaultsManagement.fontSize) * 0.5)

            for codeRange in codeBlockRanges {
                guard codeRange.location < string.length, NSMaxRange(codeRange) <= string.length else { continue }
                let openingLineRange = string.lineRange(for: NSRange(location: codeRange.location, length: 0))
                if openingLineRange.length > 0 {
                    // Set font BEFORE hiding — kern calculation uses the current font
                    storage.addAttribute(.font, value: fenceFont, range: openingLineRange)
                    storage.addAttribute(.paragraphStyle, value: fenceParaStyle, range: openingLineRange)
                    processor.hideSyntaxRange(openingLineRange, in: storage)
                }
                let endLoc = NSMaxRange(codeRange)
                if endLoc > 0 {
                    let closingLineRange = string.lineRange(for: NSRange(location: endLoc - 1, length: 0))
                    if closingLineRange.length > 0, closingLineRange.location != openingLineRange.location {
                        storage.addAttribute(.font, value: fenceFont, range: closingLineRange)
                        storage.addAttribute(.paragraphStyle, value: fenceParaStyle, range: closingLineRange)
                        processor.hideSyntaxRange(closingLineRange, in: storage)
                    }
                }
            }
        }

        // In WYSIWYG mode, render mermaid/math blocks and table markdown.
        // Defer to next run loop iteration so layout manager has computed glyph positions.
        if NotesTextProcessor.hideSyntax {
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let storage = self.textStorage,
                      let processor = self.textStorageProcessor else { return }
                let codeRanges = processor.codeBlockRanges
                if !codeRanges.isEmpty {
                    processor.renderSpecialCodeBlocks(textStorage: storage, codeBlockRanges: codeRanges)
                }
                self.renderTables()
            }
        }

        viewDelegate?.restoreScrollPosition()

        // Force full redraw so gutter icons (drawn outside text container bounds)
        // render after block model is populated by process()
        needsDisplay = true
    }

    private func loadMarkdownWebView(note: Note, force: Bool) {
        self.note = nil
        textStorage?.setAttributedString(NSAttributedString())
        self.note = note

        guard let scrollView = editorViewController?.vcEditorScrollView else { return }
        
        if markdownView == nil {
            let frame = scrollView.bounds
            
            let containerView = MPreviewContainerView(frame: frame, note: note, closure: { [weak self] in
                guard let self = self, let note = self.note else { return }

                // If we have a saved web scroll position, use it;
                // otherwise use the cursor's scroll fraction to approximate
                if note.contentOffsetWeb != .zero {
                    self.markdownView?.restoreScrollPosition(note.contentOffsetWeb)
                    note.contentOffsetWeb = .zero
                } else if note.cursorScrollFraction > 0 {
                    self.markdownView?.scrollToFraction(note.cursorScrollFraction)
                }
            })
            markdownView = containerView
            
            containerView.webView.setEditorVC(evc: editorViewController)
            if self.note == note {
                scrollView.addSubview(containerView)
            }
        } else {
            /// Resize markdownView
            let frame = scrollView.bounds
            markdownView?.frame = frame

            /// Load note if needed
            markdownView?.webView.load(note: note, force: force)
        }
    }

    public func lockEncryptedView() {
        textStorage?.setAttributedString(NSAttributedString())
        markdownView?.removeFromSuperview()
        markdownView = nil

        isEditable = false
        
        if let label = editorViewController?.vcNonSelectedLabel {
            label.stringValue = NSLocalizedString("Locked", comment: "")
            label.isHidden = false
        }
    }
    
    public func clear() {
        textStorage?.setAttributedString(NSAttributedString())
        markdownView?.removeFromSuperview()
        markdownView = nil

        isEditable = false
        
        window?.title = AppDelegate.appTitle
        
        if let label = editorViewController?.vcNonSelectedLabel {
            label.stringValue = NSLocalizedString("None Selected", comment: "")
            label.isHidden = false
            editorViewController?.dropTitle()
        }
        
        self.note = nil
        
        if let vc = viewDelegate {
            vc.updateCounters()
        }
    }

    @IBAction func boldMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        if applyInlineTableCellFormatting("**") { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.bold()
        deselectAfterFormatting()
    }

    @IBAction func italicMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        if applyInlineTableCellFormatting("*") { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.italic()
        deselectAfterFormatting()
    }

    /// If an InlineTableView cell is being edited, wrap the selection (or insert markers at cursor).
    /// Returns true if formatting was applied to a cell, false if the caller should fall through.
    private func applyInlineTableCellFormatting(_ marker: String) -> Bool {
        guard let fieldEditor = window?.fieldEditor(false, for: nil),
              let cell = fieldEditor.delegate as? NSTextField,
              cell.superview is InlineTableView else { return false }

        let sel = fieldEditor.selectedRange
        let nsText = fieldEditor.string as NSString

        if sel.length > 0 {
            let selected = nsText.substring(with: sel)
            if selected.hasPrefix(marker) && selected.hasSuffix(marker) && selected.count > marker.count * 2 {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                fieldEditor.replaceCharacters(in: sel, with: inner)
                fieldEditor.selectedRange = NSRange(location: sel.location, length: inner.count)
            } else {
                let wrapped = marker + selected + marker
                fieldEditor.replaceCharacters(in: sel, with: wrapped)
                fieldEditor.selectedRange = NSRange(location: sel.location + marker.count, length: sel.length)
            }
        } else {
            let doubleMarker = marker + marker
            fieldEditor.replaceCharacters(in: sel, with: doubleMarker)
            fieldEditor.selectedRange = NSRange(location: sel.location + marker.count, length: 0)
        }
        return true
    }

    @IBAction func linkMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        // Check clipboard for a URL
        if let clipboardString = NSPasteboard.general.string(forType: .string) {
            let normalized = clipboardString.normalizedAsURL()
            if let url = URL(string: normalized),
               let scheme = url.scheme, ["http", "https", "ftp", "ftps", "mailto"].contains(scheme.lowercased()) {
                // Clipboard has a URL — insert link directly
                let selectedText = attributedSubstring(forProposedRange: selectedRange(), actualRange: nil)?.string ?? ""
                let displayText = selectedText.isEmpty ? normalized : selectedText
                let markdown = "[\(displayText)](\(normalized))"
                let range = selectedRange()
                insertText(markdown, replacementRange: range)
                return
            }
        }
        // No URL in clipboard — show dialog
        showLinkDialog()
    }

    private func showLinkDialog() {
        guard let window = self.window else { return }

        let alert = NSAlert()
        alert.messageText = "Enter the Internet address (URL) for this link."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Link")

        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        urlField.placeholderString = "https://example.com"
        alert.accessoryView = urlField
        alert.window.initialFirstResponder = urlField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            if response == .alertFirstButtonReturn {
                let rawInput = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawInput.isEmpty else { return }
                let urlString = rawInput.normalizedAsURL()

                let selectedText = self.attributedSubstring(forProposedRange: self.selectedRange(), actualRange: nil)?.string ?? ""
                let displayText = selectedText.isEmpty ? urlString : selectedText
                let markdown = "[\(displayText)](\(urlString))"
                let range = self.selectedRange()
                self.insertText(markdown, replacementRange: range)
            } else if response == .alertThirdButtonReturn {
                // Remove link: if cursor is inside a markdown link, strip the syntax
                let range = self.selectedRange()
                guard let storage = self.textStorage else { return }
                let nsString = storage.string as NSString
                let paraRange = nsString.paragraphRange(for: range)
                let paraString = nsString.substring(with: paraRange)

                // Match [text](url) pattern around cursor
                let linkPattern = "\\[([^\\]]*?)\\]\\(([^)]*?)\\)"
                if let regex = try? NSRegularExpression(pattern: linkPattern),
                   let match = regex.firstMatch(in: paraString, range: NSRange(location: 0, length: paraString.count)) {
                    let cursorInPara = range.location - paraRange.location
                    if NSLocationInRange(cursorInPara, match.range) {
                        let textRange = match.range(at: 1)
                        let displayText = (paraString as NSString).substring(with: textRange)
                        let fullRange = NSRange(location: paraRange.location + match.range.location, length: match.range.length)
                        self.insertText(displayText, replacementRange: fullRange)
                    }
                }
            }
        }
    }

    @IBAction func underlineMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.underline()
        deselectAfterFormatting()
    }

    @IBAction func strikeMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.strike()
        deselectAfterFormatting()
    }

    @IBAction func highlightMenu(_ sender: Any) {
        guard let note = self.note, isEditable, note.isMarkdown() else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.wrapSelection(with: "<mark>", close: "</mark>")
        deselectAfterFormatting()
    }

    /// Collapse selection to cursor at end so the user can see the applied formatting.
    private func deselectAfterFormatting() {
        let sel = selectedRange()
        if sel.length > 0 {
            setSelectedRange(NSRange(location: NSMaxRange(sel), length: 0))
        }
    }

    @IBAction func headerMenu(_ sender: NSMenuItem) {
        guard let note = self.note, isEditable else { return }

        guard let id = sender.identifier?.rawValue else { return }

        let code =
            Int(id.replacingOccurrences(of: "format.h", with: ""))

        var string = String()
        for index in [1, 2, 3, 4, 5, 6] {
            string = string + "#"
            if code == index {
                break
            }
        }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.header(string)
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

    func getParagraphRange() -> NSRange? {
        guard let storage = textStorage else { return nil }
        
        let range = selectedRange()
        return storage.mutableString.paragraphRange(for: range)
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

    func saveSelectedRange() {
        // Defer to the next run loop iteration to avoid Swift exclusivity violations.
        // When deleting table attachments, keyDown triggers text storage mutations
        // that re-enter self.note access. By deferring, the access happens after
        // keyDown's call stack has unwound completely.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let note = self.note else { return }
            note.setSelectedRange(range: self.selectedRange)
        }
    }

    /// Returns the cursor's vertical position as a fraction (0.0 to 1.0) of the document
    func getCursorScrollFraction() -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        return CGFloat(selectedRange().location) / CGFloat(storage.length)
    }
    
    func loadSelectedRange() {
        guard let storage = textStorage else { return }

        if let range = self.note?.getSelectedRange(), range.upperBound <= storage.length {
            setSelectedRange(range)
            scrollToCursor()
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

    private func drawGutterIcons(in dirtyRect: NSRect) {
        guard let storage = textStorage,
              let lm = layoutManager as? LayoutManager,
              let container = textContainer,
              let processor = textStorageProcessor else { return }
        guard !processor.blocks.isEmpty else { return }

        let origin = textContainerOrigin
        let gutterWidth = EditTextView.gutterWidth
        let gutterLeft = origin.x - gutterWidth
        let gutterRight = origin.x

        // Reset clip rect to the full view bounds so gutter area isn't clipped
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()

        // Visible glyph range
        let visibleRect = enclosingScrollView?.contentView.bounds ?? bounds
        let visibleGlyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleCharRange = lm.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let cursorParagraphRange: NSRange? = {
            let idx = lm.cursorCharIndex
            guard idx >= 0, idx < storage.length else { return nil }
            return (storage.string as NSString).paragraphRange(for: NSRange(location: idx, length: 0))
        }()

        for block in processor.blocks {
            let level: Int
            switch block.type {
            case .heading(let l): level = l
            case .headingSetext(let l): level = l
            default: continue
            }

            guard NSIntersectionRange(block.range, visibleCharRange).length > 0 else { continue }
            guard block.range.location < storage.length,
                  NSMaxRange(block.range) <= storage.length else { continue }
            // Skip blocks inside a folded region
            if storage.attribute(.foldedContent, at: block.range.location, effectiveRange: nil) != nil { continue }

            let glyphRange = lm.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            if glyphRange.length == 0 { continue }
            let lineFragRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            if lineFragRect.isEmpty { continue }

            let midY = lineFragRect.midY + origin.y

            let isCollapsed = block.collapsed

            // Fold carets only visible when mouse hovers in the gutter, or when collapsed
            if isMouseInGutter || isCollapsed {
                let caretStr = isCollapsed ? "▶" : "▼"
                let caretFont = NSFont.systemFont(ofSize: 16, weight: .regular)
                let caretAttrs: [NSAttributedString.Key: Any] = [
                    .font: caretFont,
                    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)
                ]
                let caretSize = (caretStr as NSString).size(withAttributes: caretAttrs)
                let caretX = gutterRight - caretSize.width - 4
                let caretY = midY - caretSize.height / 2
                (caretStr as NSString).draw(at: NSPoint(x: caretX, y: caretY), withAttributes: caretAttrs)
            }

            // H-level badge: show when mouse hovers in gutter (for all headers),
            // or when cursor is actively editing this specific header line
            let cursorOnThisLine = cursorParagraphRange.map { NSIntersectionRange($0, block.range).length > 0 } ?? false
            let isEditing = window?.firstResponder === self
            if isMouseInGutter || (cursorOnThisLine && isEditing) {
                let badge = "H\(level)"
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor.gray
                ]
                let badgeSize = (badge as NSString).size(withAttributes: badgeAttrs)
                (badge as NSString).draw(at: NSPoint(x: gutterLeft + 2, y: midY - badgeSize.height / 2), withAttributes: badgeAttrs)
            }

            // "⋯" after collapsed header
            if isCollapsed {
                let ellipsis = " ⋯ "
                let ellipsisAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1.0),
                    .backgroundColor: NSColor(calibratedWhite: 0.92, alpha: 1.0)
                ]
                let usedRect = lm.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let ellipsisSize = (ellipsis as NSString).size(withAttributes: ellipsisAttrs)
                (ellipsis as NSString).draw(at: NSPoint(x: usedRect.maxX + origin.x + 4, y: midY - ellipsisSize.height / 2), withAttributes: ellipsisAttrs)
            }
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let note = self.note, let storage = textStorage else { return false }

        let pasteboard = sender.draggingPasteboard
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let caretLocation = characterIndexForInsertion(at: dropPoint)
        let replacementRange = NSRange(location: caretLocation, length: 0)

        // Handle local file drops first — route through saveFile which handles
        // PDFs (thumbnail), images (attachment), and other files (markdown link).
        // This must come before handleAttributedText, which would insert non-image
        // files (DOCX, PPTX, etc.) as NSTextAttachments with image syntax.
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !fileURLs.isEmpty {
            var handled = false
            setSelectedRange(replacementRange)
            for url in fileURLs where url.isFileURL {
                if saveFile(url: url, in: note) {
                    handled = true
                }
            }
            if handled { return true }
        }

        if handleAttributedText(pasteboard, note: note, storage: storage, replacementRange: replacementRange) { return true }
        if handleNoteReference(pasteboard, note: note, replacementRange: replacementRange) { return true }
        if handleURLs(pasteboard, note: note, replacementRange: replacementRange) { return true }

        return super.performDragOperation(sender)
    }

    func fetchDataFromURL(url: URL, completion: @escaping (Data?, Error?) -> Void) {
        let session = URLSession.shared

        let task = session.dataTask(with: url) { (data, response, error) in
            if let error = error {
                completion(nil, error)
                return
            }

            completion(data, nil)
        }

        task.resume()
    }

    
    func getHTMLTitle(from data: Data) -> String? {
        guard let htmlString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return extractTitle(from: htmlString)
    }

    func getSearchText() -> String {
        guard let search = ViewController.shared()?.search else { return String() }

        if let editor = search.currentEditor(), editor.selectedRange.length > 0 {
            return (search.stringValue as NSString).substring(with: NSRange(0..<editor.selectedRange.location))
        }
        
        return search.stringValue
    }

    public func scrollToCursor() {
        let cursorRange = NSMakeRange(self.selectedRange().location, 0)

        // DispatchQueue fixes rare bug when textStorage invalidation not working (blank page instead text)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.scrollRangeToVisible(cursorRange)
        }
    }
    
    public func hasFocus() -> Bool {
        if let fr = self.window?.firstResponder, fr.isKind(of: EditTextView.self) {
            return true
        }
        
        return false
    }

    @IBAction func shiftLeft(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let f = TextFormatter(textView: self, note: note)
        f.unTab()
    }
    
    @IBAction func shiftRight(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let f = TextFormatter(textView: self, note: note)
        f.tab()
    }

    @IBAction func todo(_ sender: Any) {
        guard let f = self.getTextFormatter(), isEditable else { return }
        
        f.todo()
    }

    @IBAction func wikiLinks(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.wikiLink()
    }

    @IBAction func pressBold(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.bold()
    }

    @IBAction func pressItalic(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.italic()
    }
    
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

    // MARK: - WYSIWYG Toolbar Actions

    @IBAction func quoteMenu(_ sender: Any) {
        guard let note = self.note, isEditable, let storage = textStorage else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.quote()

        // Force re-highlight to apply blockquote indent immediately
        if NotesTextProcessor.hideSyntax {
            let cursorLoc = min(selectedRange().location, storage.length - 1)
            if cursorLoc >= 0 {
                let paraRange = (storage.string as NSString).paragraphRange(
                    for: NSRange(location: cursorLoc, length: 0))
                storage.updateParagraphStyle(range: paraRange)
                layoutManager?.invalidateLayout(forCharacterRange: paraRange, actualCharacterRange: nil)
            }
        }
    }

    @IBAction func bulletListMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.list()
    }

    @IBAction func numberedListMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.orderedList()
    }

    @IBAction func imageMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.image()
    }

    @IBAction func insertTableMenu(_ sender: Any) {
        guard let storage = textStorage, isEditable else { return }

        // Insert a 2x2 empty markdown table at cursor
        let tableMarkdown = "|  |  |\n|--|--|\n|  |  |"
        let insertRange = selectedRange()
        let prefix = insertRange.location > 0 ? "\n" : ""
        insertText(prefix + tableMarkdown + "\n", replacementRange: insertRange)

        // In WYSIWYG mode, immediately render as InlineTableView
        if NotesTextProcessor.hideSyntax {
            renderTables()
            // Focus the first cell after a brief delay so the table is fully laid out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.focusFirstInlineTableCell()
            }
        }
    }

    /// Focus the first editable cell in the most recently added InlineTableView
    private func focusFirstInlineTableCell() {
        for subview in subviews.reversed() {
            if let tableView = subview as? InlineTableView {
                tableView.focusState = .editing
                tableView.focusFirstCell()
                // Invalidate layout so the attachment cell picks up the new (editing) size
                if let storage = textStorage, let lm = layoutManager {
                    lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                }
                break
            }
        }
    }

    /// Unfocus all inline table views (hide their controls)
    func unfocusAllInlineTableViews() {
        for subview in subviews {
            if let tableView = subview as? InlineTableView, tableView.isFocused {
                tableView.isFocused = false
            }
        }
    }

    /// Remove all inline table view subviews (called on source mode toggle or note switch).
    /// First collects any pending cell edits and restores table attachments to markdown
    /// so the note content reflects the latest edits.
    func removeAllInlineTableViews() {
        // Collect pending cell values into the data model (does NOT fire callbacks).
        // Do NOT call notifyChanged() here — it fires onMarkdownChanged which can
        // trigger saves. During fill(), self.note already points to the NEW note
        // and the text storage is EMPTY, so a save would write 0 bytes.
        for subview in subviews {
            if let tableView = subview as? InlineTableView {
                tableView.collectCellData()
            }
        }

        // Do NOT call storage.restoreRenderedBlocks() here!
        // Modifying the text storage during note switching triggers auto-save
        // which writes empty/corrupt content to the PREVIOUS note's file.
        // Rendered blocks are restored in the save path (Note.save(content:)
        // calls unloadAttachments() which calls restoreRenderedBlocks()).

        // Remove the table subviews only
        for subview in subviews {
            if subview is InlineTableView {
                subview.removeFromSuperview()
            }
        }
    }

    // MARK: - Inline Table Rendering

    /// Render markdown tables as inline InlineTableView widgets in WYSIWYG mode
    func renderTables() {
        guard NotesTextProcessor.hideSyntax,
              let storage = textStorage,
              let processor = textStorageProcessor else { return }

        let tableRanges = TableUtility.findAllTableRanges(in: storage)
        let string = storage.string as NSString

        // Process in reverse so range offsets stay valid
        for tableRange in tableRanges.reversed() {
            guard tableRange.location < string.length, NSMaxRange(tableRange) <= string.length else { continue }

            let tableMarkdown = string.substring(with: tableRange)

            // Check if already rendered
            if storage.attribute(.renderedBlockSource, at: tableRange.location, effectiveRange: nil) as? String == tableMarkdown {
                continue
            }

            guard let data = TableUtility.parse(markdown: tableMarkdown) else { continue }

            let maxWidth = getTableMaxWidth()

            // Create the inline table view
            let tableView = InlineTableView()
            tableView.configure(with: data)
            tableView.containerWidth = maxWidth
            tableView.isFocused = false

            // NO onMarkdownChanged callback needed. Table data is synced to
            // attributes in attributedString() override, called by the save path.
            // This matches how mermaid works: zero custom callbacks.

            tableView.rebuild()

            // Create attachment
            let attachment = NSTextAttachment()
            let cellSize = tableView.intrinsicContentSize
            let cell = InlineTableAttachmentCell(tableView: tableView, size: cellSize)
            attachment.attachmentCell = cell
            attachment.bounds = NSRect(origin: .zero, size: cellSize)

            // Store markdown WITHOUT trailing \n (matches the trimmed replaceRange)
            let trimmedMarkdown = tableMarkdown.hasSuffix("\n")
                ? String(tableMarkdown.dropLast())
                : tableMarkdown

            let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            let attRange = NSRange(location: 0, length: attachmentString.length)
            attachmentString.addAttributes([
                .renderedBlockSource: trimmedMarkdown,
                .renderedBlockType: RenderedBlockType.table.rawValue,
                .renderedBlockOriginalMarkdown: trimmedMarkdown
            ], range: attRange)
            attachmentString.removeAttribute(.backgroundColor, range: attRange)

            // Replace table markdown with attachment.
            // Trim trailing \n from the replacement range so blank lines between
            // tables are preserved. findAllTableRanges includes the trailing \n
            // (from paragraphRange), but consuming it swallows the blank line.
            var replaceRange = tableRange
            if replaceRange.length > 0 && string.character(at: NSMaxRange(replaceRange) - 1) == 0x0A {
                replaceRange.length -= 1
            }
            // Mark the table block as .rendered BEFORE replacing text.
            // This way process() (fired by replaceCharacters) adjusts all block
            // positions via delta but skips reparsing the rendered block.
            if let idx = processor.blocks.firstIndex(where: {
                if case .table = $0.type, $0.renderMode == .source {
                    return NSIntersectionRange($0.range, replaceRange).length > 0
                }
                return false
            }) {
                processor.blocks[idx].renderMode = .rendered
            }

            storage.beginEditing()
            storage.replaceCharacters(in: replaceRange, with: attachmentString)
            let replacedRange = NSRange(location: tableRange.location, length: attachmentString.length)
            if replacedRange.location + replacedRange.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: replacedRange)
            }
            storage.endEditing()

            // Do NOT addSubview here. InlineTableAttachmentCell.draw() adds the
            // subview when the layout manager computes a valid frame. This prevents
            // tables outside the viewport from being positioned at (0,0).

            // NO onMarkdownChanged callback. Table data is synced to attributes
            // in the attributedString() override, which the save path calls.
            // This eliminates the data loss bug caused by callbacks firing during fill().
        }
    }

    private func getTableMaxWidth() -> CGFloat {
        if let editorWidth = enclosingScrollView?.contentView.bounds.width {
            return editorWidth - 40
        }
        return 400
    }

    @IBAction func horizontalRuleMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.horizontalRule()
    }

    @IBAction func headerMenu1(_ sender: Any) {
        applyHeader(level: "#")
    }

    @IBAction func headerMenu2(_ sender: Any) {
        applyHeader(level: "##")
    }

    @IBAction func headerMenu3(_ sender: Any) {
        applyHeader(level: "###")
    }

    private func applyHeader(level: String) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.header(level)

        // After header() inserts "# " (which gets hidden at 0.1pt font),
        // the cursor sits after hidden characters. NSTextView draws the cursor
        // using the font at the insertion point, which is the 0.1pt hidden font.
        //
        // Fix: set typing attributes to header font AND force cursor redraw.
        let baseFontSize = CGFloat(UserDefaultsManagement.fontSize)
        let headerLevel = level.filter({ $0 == "#" }).count
        let headerSize: CGFloat
        switch headerLevel {
        case 1: headerSize = baseFontSize * 2.0
        case 2: headerSize = baseFontSize * 1.7
        case 3: headerSize = baseFontSize * 1.4
        default: headerSize = baseFontSize
        }
        let headerFont = NSFont.boldSystemFont(ofSize: headerSize)
        typingAttributes = [
            .font: headerFont,
            .foregroundColor: NotesTextProcessor.fontColor
        ]
        // Force cursor to redraw with the new typing attributes
        updateInsertionPointStateAndRestartTimer(true)
    }

    @IBAction func insertCodeBlock(_ sender: NSButton) {
        guard isEditable else { return }

        let currentRange = selectedRange()

        if currentRange.length > 0 {
            let mutable = NSMutableAttributedString(string: "```\n")
            if let substring = attributedSubstring(forProposedRange: currentRange, actualRange: nil) {
                mutable.append(substring)

                if substring.string.last != "\n" {
                    mutable.append(NSAttributedString(string: "\n"))
                }
            }

            mutable.append(NSAttributedString(string: "```\n"))

            insertText(mutable, replacementRange: currentRange)
            setSelectedRange(NSRange(location: currentRange.location + 4, length: 0))

            return
        }

        insertText("```\n\n```\n", replacementRange: currentRange)
        // Place cursor at end of opening ``` so user can type language name
        setSelectedRange(NSRange(location: currentRange.location + 3, length: 0))
    }

    @IBAction func insertCodeSpan(_ sender: NSMenuItem) {
        guard isEditable else { return }

        let currentRange = selectedRange()

        if currentRange.length > 0 {
            let mutable = NSMutableAttributedString(string: "`")
            if let substring = attributedSubstring(forProposedRange: currentRange, actualRange: nil) {
                mutable.append(substring)
            }

            mutable.append(NSAttributedString(string: "`"))

            insertText(mutable, replacementRange: currentRange)
            return
        }

        insertText("``", replacementRange: currentRange)
        setSelectedRange(NSRange(location: currentRange.location + 1, length: 0))
    }

    @IBAction func insertList(_ sender: NSMenuItem) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.list()
    }

    @IBAction func insertOrderedList(_ sender: NSMenuItem) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.orderedList()
    }

    @IBAction func insertQuote(_ sender: NSMenuItem) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.quote()
    }

    @IBAction func insertLink(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.link()
    }
    
    private func getTextFormatter() -> TextFormatter? {
        guard let note = self.note, isEditable else { return nil }
        
        return TextFormatter(textView: self, note: note)
    }
    
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.data(forType: NSPasteboard.note) != nil {
            let dropPoint = convert(sender.draggingLocation, from: nil)
            let caretLocation = characterIndexForInsertion(at: dropPoint)
            setSelectedRange(NSRange(location: caretLocation, length: 0))
            return .copy
        }

        return super.draggingUpdated(sender)
    }
    
    override func clicked(onLink link: Any, at charIndex: Int) {
        if handleEmailLink(link) { return }
        
        if handleAnchorLink(link) { return }

        if !isAttachmentAtPosition(charIndex) {
            if handleRegularLink(link, at: charIndex) { return }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        UserDataService.instance.isDark = effectiveAppearance.isDark
        storage.resetCacheAttributes()

        // clear preview cache
        MPreviewView.template = nil
        let webkitPreview = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wkPreview")
        try? FileManager.default.removeItem(at: webkitPreview)

        NotesTextProcessor.hl = nil

        guard let note = self.note else { return }
        NotesTextProcessor.highlight(attributedString: note.content)

        let funcName = effectiveAppearance.isDark ? "switchToDarkMode" : "switchToLightMode"
        let switchScript = "if (typeof(\(funcName)) == 'function') { \(funcName)(); }"

        downView?.evaluateJavaScript(switchScript)

        viewDelegate?.refillEditArea(force: true)
    }

    /// Image file extensions that should be pasted directly inline
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "webp", "heic", "heif", "svg", "bmp", "ico"
    ]

    private func saveFile(url: URL, in note: Note) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let preferredName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Images: paste directly inline as attachment
        if EditTextView.imageExtensions.contains(ext) || data.getFileType() != .unknown {
            guard let attributed = NSMutableAttributedString.build(data: data, preferredName: preferredName) else { return false }
            breakUndoCoalescing()
            insertText(attributed, replacementRange: selectedRange())
            breakUndoCoalescing()
            return true
        }

        // Other files: save file, generate QuickLook thumbnail, insert table card.
        // For files QL can't render, uses a generic file icon.
        return saveFileWithThumbnail(data: data, preferredName: preferredName, in: note)
    }

    /// Save a non-image file to the note's assets, generate a QuickLook thumbnail,
    /// and insert a markdown table with the thumbnail image + clickable link.
    /// Uses QLThumbnailGenerator for consistent thumbnail rendering across all
    /// document types (PDF, SVG, Office, iWork, etc.).
    private func saveFileWithThumbnail(data: Data, preferredName: String, in note: Note) -> Bool {
        // 1. Save file to assets/
        guard let (fileRelPath, fileURL) = note.save(data: data, preferredName: preferredName) else { return false }

        // 2. Generate QuickLook thumbnail asynchronously
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 480, height: 480),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )

        let insertionRange = selectedRange()
        let capturedNote = note
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            DispatchQueue.main.async {
                // Verify the note hasn't changed since the async request was made
                guard let self = self, self.note === capturedNote else { return }
                self.insertThumbnailCard(
                    thumbnail: thumbnail,
                    fileRelPath: fileRelPath,
                    preferredName: preferredName,
                    note: capturedNote,
                    insertionRange: insertionRange
                )
            }
        }

        return true
    }

    /// Insert the markdown table card with thumbnail + link after QuickLook generates the thumbnail.
    private func insertThumbnailCard(thumbnail: QLThumbnailRepresentation?, fileRelPath: String, preferredName: String, note: Note, insertionRange: NSRange) {
        let encodedFilePath = fileRelPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileRelPath
        let displayName = preferredName

        var markdown: String

        if let cgImage = thumbnail?.cgImage {
            // Convert thumbnail to PNG and save
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            if let pngData = nsImage.PNGRepresentation {

                let thumbName = (preferredName as NSString).deletingPathExtension + "_thumb.png"
                if let (thumbRelPath, thumbURL) = note.save(data: pngData, preferredName: thumbName) {
                    let encodedThumbPath = thumbRelPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? thumbRelPath
                    let thumbDisplayName = (preferredName as NSString).deletingPathExtension + "_thumb.png"

                    // Update note.imageUrl so loadImages() finds the thumbnail in preview mode
                    if note.imageUrl != nil {
                        note.imageUrl!.append(thumbURL)
                    } else {
                        note.imageUrl = [thumbURL]
                    }

                    markdown = "\n| Thumbnail |\n|:---:|\n| ![\(thumbDisplayName)](\(encodedThumbPath)) |\n| [\(displayName)](\(encodedFilePath)) |\n"
                } else {
                    markdown = "\n[\(displayName)](\(encodedFilePath))\n"
                }
            } else {
                markdown = "\n[\(displayName)](\(encodedFilePath))\n"
            }
        } else {
            // No QL thumbnail available — use the system file icon as thumbnail
            let ext = (preferredName as NSString).pathExtension
            let fileIcon = NSWorkspace.shared.icon(forFileType: ext)
            fileIcon.size = NSSize(width: 128, height: 128)
            if let pngData = fileIcon.PNGRepresentation {
                let iconName = (preferredName as NSString).deletingPathExtension + "_icon.png"
                if let (iconRelPath, iconURL) = note.save(data: pngData, preferredName: iconName) {
                    let encodedIconPath = iconRelPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? iconRelPath
                    if note.imageUrl != nil {
                        note.imageUrl!.append(iconURL)
                    } else {
                        note.imageUrl = [iconURL]
                    }
                    markdown = "\n| Attachment |\n|:---:|\n| ![\(iconName)](\(encodedIconPath)) |\n| [\(displayName)](\(encodedFilePath)) |\n"
                } else {
                    markdown = "\n[\(displayName)](\(encodedFilePath))\n"
                }
            } else {
                markdown = "\n[\(displayName)](\(encodedFilePath))\n"
            }
        }

        breakUndoCoalescing()
        insertText(NSMutableAttributedString(string: markdown), replacementRange: selectedRange())
        breakUndoCoalescing()

        // Save to disk synchronously, then reload so loadImagesAndFiles()
        // converts ![](path) to NSTextAttachment for immediate inline rendering
        note.content = NSMutableAttributedString(attributedString: attributedString())
        _ = note.save()
        note.load()
        viewDelegate?.refillEditArea(force: true)
    }

    public func updateTextContainerInset() {
        textContainerInset.width = getInsetWidth()
    }

    /// Width of the left-hand gutter for header fold/unfold controls.
    public static let gutterWidth: CGFloat = 32

    /// Whether the mouse is currently hovering over the gutter (pipe) area.
    /// Fold carets only appear on hover, matching Bear/Apple Notes behavior.
    private var isMouseInGutter = false

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
        let state = editorViewController?.vcEditor?.preview == true ? "preview" : "editor"
        let data =
            [
                "note-file-name": note.name,
                "position": String(position),
                "state": state
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
    
    public func changePreviewState(_ state: Bool) {
        preview = state
    }
    
    public func togglePreviewState() {
        self.preview = !self.preview
        
        note?.previewState = self.preview
    }
    
    public func isPreviewEnabled() -> Bool {
        // In WYSIWYG mode, MPreview is never used for production rendering.
        // The NSTextView WYSIWYG renderer handles all display, so preview (MPreview)
        // must always be disabled when hideSyntax is active.
        if NotesTextProcessor.hideSyntax {
            return false
        }
        return preview
    }
    
    public func disablePreviewEditorAndNote() {
        preview = false
        
        note?.previewState = false
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
        typingAttributes.removeValue(forKey: .todo)
        typingAttributes.removeValue(forKey: .tag)

        if let style = typingAttributes[.paragraphStyle] as? NSMutableParagraphStyle {
            style.alignment = .left
        }
        
        typingAttributes[.font] = UserDefaultsManagement.noteFont
    }
}
