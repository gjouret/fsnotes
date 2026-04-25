//
//  EditTextView+Interaction.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import AppKit

extension EditTextView {
    override func mouseDown(with event: NSEvent) {
        guard let note = self.note else { return }
        guard note.container != .encryptedTextPack else {
            editorViewController?.unLock(notes: [note])
            editorViewController?.vcNonSelectedLabel?.isHidden = false
            return
        }

        self.isEditable = true

        // Image resize handle hit-test. Runs BEFORE any other click
        // dispatching so grabbing a handle doesn't also place a text
        // caret or trigger a selection change. A drag is only possible
        // when an image is already selected (the user clicked it in a
        // prior mouseDown and saw the handles appear).
        if beginImageResizeDragIfPossible(event) {
            return
        }

        if NotesTextProcessor.hideSyntax, gutterController.handleClick(event) {
            return
        }

        if NotesTextProcessor.hideSyntax, handleRenderedBlockClick(event) {
            return
        }

        if NotesTextProcessor.hideSyntax, let storage = textStorage {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            if charIndex >= 0 && charIndex < storage.length {
                if let link = storage.attribute(.link, at: charIndex, effectiveRange: nil) {
                    // Wikilinks (`wiki:<target>`) must be resolved against
                    // the local note store — never dispatched to
                    // NSWorkspace, which would surface the system
                    // "no application set to open URL wiki:..." dialog.
                    // Run this check BEFORE the generic URL dispatch
                    // so clicking a wikilink in WYSIWYG mode opens the
                    // matching note instead of escaping to the OS.
                    if handleWikiLink(link) { return }
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

        if handleTodo(event) {
            // Todo checkbox was toggled. Don't change cursor position
            // or focus state — just save and return.
            saveSelectedRange()
            return
        }

        dragDetected = false
        skipLoadSelectedRange = true

        // Click-on-table-cell: place the cursor at the correct cell
        // offset BEFORE super.mouseDown runs. TK2's default click→
        // cursor mapping uses naturally-flowing text line fragments,
        // but `TableLayoutFragment.draw` paints cells at custom grid
        // positions. So the default mapping never lands clicks on
        // cell text inside the right cell's storage range — the
        // user can never place the caret in a cell to type.
        if handleTableCellClick(event: event) {
            saveSelectedRange()
            return
        }

        super.mouseDown(with: event)

        // Phase 4.8: legacy clear-color-marker skip removed. Before 4.4,
        // source-mode rendered markdown markers via `NotesTextProcessor
        // .highlightMarkdown`, which hid syntax characters by setting
        // `.foregroundColor = NSColor.clear` and compressing them with
        // negative kern. A click could land inside that invisible run
        // and we'd have to walk forward to the next visible glyph.
        //
        // Post-4.4 the only two live renderers are `DocumentRenderer`
        // (WYSIWYG — markers are not in storage at all) and
        // `SourceRenderer` (source mode — markers are in storage tagged
        // with `.markerRange` and painted in `ThemeChrome.sourceMarker`,
        // fully visible and click-addressable). Clear-color foreground
        // now appears only on `.foldedContent` runs, which are not
        // click-addressable (the fold layout fragment takes them out of
        // the layout path). The walk-past-clear-color fixup therefore
        // has no work to do under either pipeline.

        saveSelectedRange()

        if !self.dragDetected {
            self.handleClick(event)
            self.dragDetected = false
        }

        triggerCodeBlockRenderingIfNeeded()
    }

    public func triggerCodeBlockRenderingIfNeeded() {
        #if os(OSX)
        // Block-model pipeline handles its own rendering — skip source-mode
        // mermaid/math rendering when it's active.
        if textStorageProcessor?.blockModelActive == true { return }

        guard NotesTextProcessor.hideSyntax,
              let processor = self.textStorageProcessor,
              let storage = self.textStorage else { return }

        let cursorLoc = selectedRange().location
        let freshRanges = processor.codeBlockRanges
        let isInCodeBlock = freshRanges.contains { NSLocationInRange(cursorLoc, $0) }

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

        if !isInCodeBlock && !freshRanges.isEmpty {
            processor.renderSpecialCodeBlocks(textStorage: storage, codeBlockRanges: freshRanges)
        }
        #endif
    }

    @objc public func toggleFoldAtCursor() {
        gutterController.toggleFoldAtCursor()
    }

    @objc public func foldAtCursor() {
        gutterController.foldAtCursor()
    }

    @objc public func unfoldAtCursor() {
        gutterController.unfoldAtCursor()
    }

    @objc public func foldAllHeaders() {
        gutterController.foldAllHeaders()
    }

    @objc public func unfoldAllHeaders() {
        gutterController.unfoldAllHeaders()
    }

    override func mouseMoved(with event: NSEvent) {
        if editorViewController?.vcNonSelectedLabel?.isHidden == false {
            NSCursor.arrow.set()
            return
        }

        let point = self.convert(event.locationInWindow, from: nil)

        if NotesTextProcessor.hideSyntax {
            gutterController.updateMouseTracking(at: point)
        }

        let properPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )

        // Phase 4.5: TK1 cursor hit-testing removed with the custom
        // layout-manager subclass. TK2 path below uses
        // `NSTextLayoutManager.textLayoutFragment(for:)` via
        // `characterIndexTK2(at:)` to resolve the point to a character,
        // then reads the
        // `.link` / `.tag` / checkbox attributes off the text storage
        // just like the TK1 branch above. Glyph-rect containment
        // checks are skipped because TK2 doesn't expose a glyph bbox
        // API — `textLayoutFragment(for:)` already guarantees the
        // point falls inside a layout fragment, and
        // `characterIndex(for:)` on the line fragment resolves the
        // exact character the cursor is over.
        if let textStorage = self.textStorage,
           let index = characterIndexTK2(at: properPoint),
           index < textStorage.length {

            if self.isTodo(index) || self.hasAttachment(at: index) {
                NSCursor.pointingHand.set()
                return
            }

            if let link = textStorage.attribute(.link, at: index, effectiveRange: nil) {
                if textStorage.attribute(.tag, at: index, effectiveRange: nil) != nil {
                    NSCursor.pointingHand.set()
                    return
                }

                if NotesTextProcessor.hideSyntax {
                    NSCursor.pointingHand.set()
                    return
                }

                if link as? URL != nil {
                    if UserDefaultsManagement.clickableLinks
                        || event.modifierFlags.contains(.command)
                        || event.modifierFlags.contains(.shift) {
                        NSCursor.pointingHand.set()
                        return
                    }

                    NSCursor.iBeam.set()
                    return
                }
            }
        }

        super.mouseMoved(with: event)
    }

    /// Phase 2f.3: TK2-equivalent of
    /// `NSLayoutManager.characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)`.
    ///
    /// Resolves a point in text-container coordinates to a character
    /// offset into `textStorage`. Returns `nil` when no layout fragment
    /// exists at that y-band, or when the point falls between line
    /// fragments.
    ///
    /// Post-4.5 this is the only hit-test path — the TK1
    /// NSLayoutManager.characterIndex path was removed with the custom
    /// layout-manager subclass.
    /// Map a mouse-down event to a table cell + cursor offset, and
    /// place the selection there. Returns true if the click landed
    /// on a `TableLayoutFragment` cell (caller should NOT fall
    /// through to `super.mouseDown`); false otherwise.
    ///
    /// Why we own this rather than letting NSTextView's default
    /// click handler do the work: `TableLayoutFragment.draw` paints
    /// cells at custom grid positions, but TK2's hit test uses the
    /// naturally-flowing text line fragments. So a click on visible
    /// cell text doesn't map to the storage offset of that cell's
    /// content — typing after such a click never routes through
    /// `handleTableCellEdit` because `cursorIsInTableElement()` only
    /// holds when the cursor is in the element's range, not when
    /// the click "missed" into adjacent paragraph storage.
    fileprivate func handleTableCellClick(event: NSEvent) -> Bool {
        guard let tlm = self.textLayoutManager,
              let contentStorage = tlm.textContentManager
                as? NSTextContentStorage
        else {
            bmLog("🖱 handleTableCellClick: no tlm or contentStorage")
            return false
        }
        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        guard let fragment = tlm.textLayoutFragment(for: properPoint) else {
            bmLog("🖱 handleTableCellClick: no fragment at properPoint=\(properPoint)")
            return false
        }
        let fragClass = String(describing: Swift.type(of: fragment))
        guard let tableFrag = fragment as? TableLayoutFragment,
              let element = fragment.textElement as? TableElement,
              let elementRange = element.elementRange
        else {
            bmLog("🖱 handleTableCellClick: fragment is \(fragClass), not TableLayoutFragment — pass-through")
            return false
        }
        let localPoint = CGPoint(
            x: properPoint.x - fragment.layoutFragmentFrame.origin.x,
            y: properPoint.y - fragment.layoutFragmentFrame.origin.y
        )
        guard let (row, col) = tableFrag.cellHit(at: localPoint) else {
            bmLog("🖱 handleTableCellClick: cellHit nil at localPoint=\(localPoint) fragFrame=\(fragment.layoutFragmentFrame)")
            return false
        }
        guard let cellLocalRange = element.cellRange(
            forCellAt: (row: row, col: col)
        ) else {
            bmLog("🖱 handleTableCellClick: no cellRange for (\(row),\(col))")
            return false
        }
        let docStart = contentStorage.documentRange.location
        let elementStart = contentStorage.offset(
            from: docStart, to: elementRange.location
        )
        // Park the cursor at the END of the cell's content. Most
        // intuitive for a click on a non-empty cell; for an empty
        // cell, end == start so it's still right.
        let target = elementStart + cellLocalRange.location +
            cellLocalRange.length
        setSelectedRange(NSRange(location: target, length: 0))
        bmLog("🖱 handleTableCellClick: cell=(\(row),\(col)) target=\(target) elementStart=\(elementStart) cellLocal=\(cellLocalRange)")
        return true
    }

    func characterIndexTK2(at point: NSPoint) -> Int? {
        guard let tlm = self.textLayoutManager,
              let fragment = tlm.textLayoutFragment(for: point) else {
            return nil
        }
        let localPoint = CGPoint(
            x: point.x - fragment.layoutFragmentFrame.origin.x,
            y: point.y - fragment.layoutFragmentFrame.origin.y
        )
        guard let lineFragment = fragment.textLineFragments.first(where: { line in
            line.typographicBounds.contains(localPoint)
        }) else {
            return nil
        }
        let charOffsetInElement = lineFragment.characterIndex(for: localPoint)
        guard let contentStorage = tlm.textContentManager as? NSTextContentStorage,
              let elementRange = fragment.textElement?.elementRange else {
            return nil
        }
        let docStart = contentStorage.documentRange.location
        let elementStart = contentStorage.offset(from: docStart, to: elementRange.location)
        return elementStart + charOffsetInElement
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)

        if let mouseEvent = NSApp.currentEvent {
            updateCursorForMouse(at: mouseEvent)
        }
    }

    private func updateCursorForMouse(at event: NSEvent) {
        let pointInView = self.convert(event.locationInWindow, from: nil)

        // Phase 4.5: TK1 link-hover cursor detection removed with the
        // custom layout-manager subclass. TK2 path resolves via
        // NSTextLayoutManager.
        // `characterIndexTK2` expects a point in text-container coords
        // (NOT flipped), matching the `mouseMoved` entry point above.
        guard let textStorage = self.textStorage else { return }
        let properPoint = NSPoint(
            x: pointInView.x - textContainerInset.width,
            y: pointInView.y - textContainerInset.height
        )
        guard let index = characterIndexTK2(at: properPoint),
              index < textStorage.length else {
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

        // Block-model path: check for checkbox attachment (NSTextAttachment).
        if documentProjection != nil {
            let range = (storage.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let string = storage.attributedSubstring(from: range).string
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            // Checkbox renders as attachment char \u{FFFC}
            if trimmed.hasPrefix("\u{FFFC}") {
                // Verify it's actually a checkbox attachment
                let indentLen = string.count - trimmed.count
                let attachIdx = range.location + indentLen
                if attachIdx < storage.length,
                   storage.attribute(.attachment, at: attachIdx, effectiveRange: nil) is CheckboxTextAttachment {
                    // Click target is exactly the attachment character (1 char).
                    if location == attachIdx {
                        return true
                    }
                }
            }
            return false
        }

        // Legacy path: check for raw markdown checkbox syntax.
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

    private func handleRenderedBlockClick(_ event: NSEvent) -> Bool {
        // Phase 4.5: TK1 glyph hit-test removed with the custom
        // layout-manager subclass. TK2 path resolves via
        // `characterIndexTK2(at:)`.
        guard let storage = textStorage else { return false }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        guard let index = characterIndexTK2(at: properPoint) else { return false }

        guard index < storage.length else { return false }

        guard storage.attribute(.attachment, at: index, effectiveRange: nil) != nil,
              let originalMarkdown = storage.attribute(.renderedBlockOriginalMarkdown, at: index, effectiveRange: nil) as? String else {
            return false
        }

        // Native images use the dedicated click-to-select flow in
        // handleClick (single = select, double = open external). They
        // DO carry `.renderedBlockOriginalMarkdown` like every other
        // rendered attachment, but the legacy "revert to source"
        // behavior below is for mermaid/math/code blocks, not images.
        // Fall through to the normal click path.
        if let blockType = storage.attribute(.renderedBlockType, at: index, effectiveRange: nil) as? String,
           blockType == RenderedBlockType.image.rawValue {
            return false
        }

        // Table click handling used to intercept here when the legacy
        // `InlineTableAttachmentCell` widget path was live. With the
        // native `TableLayoutFragment` path, TK2's default hit-testing
        // positions the selection inside the cell via
        // `EditTextView+TableNav`'s cursor context logic — no
        // click-handler override needed. Tables render as real text
        // content, not a single attachment character, so the check
        // below (`.attachment != nil`) would never match a table anyway.

        let attachmentRange = NSRange(location: index, length: 1)
        guard NSMaxRange(attachmentRange) <= storage.length else { return false }

        if let processor = self.textStorageProcessor,
           let idx = processor.blocks.firstIndex(where: { $0.renderMode == .rendered && $0.range.location == index }) {
            processor.blocks[idx].renderMode = .source
        }

        var markdown = originalMarkdown
        if !markdown.hasSuffix("\n") {
            markdown += "\n"
        }

        typingAttributes = [
            .font: UserDefaultsManagement.noteFont,
            .foregroundColor: NotesTextProcessor.fontColor
        ]

        breakUndoCoalescing()
        insertText(markdown, replacementRange: attachmentRange)
        breakUndoCoalescing()

        let restoredRange = NSRange(location: index, length: min(markdown.count, storage.length - index))
        let cursorPos = min(index + markdown.count - 5, storage.length)
        setSelectedRange(NSRange(location: cursorPos, length: 0))
        pendingRenderBlockRange = restoredRange

        return true
    }

    private func handleTodo(_ event: NSEvent) -> Bool {
        // Phase 4.5: TK1 glyph hit-test removed with the custom
        // layout-manager subclass. TK2 path uses `characterIndexTK2`,
        // which only resolves when the point is inside a line fragment —
        // so the explicit glyph-rect containment check is no longer
        // needed (the fragment lookup already guarantees it).
        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        guard let index = characterIndexTK2(at: properPoint) else { return false }

        if isTodo(index) {
            // Block-model path: toggle via EditingOps.
            if documentProjection != nil {
                _ = toggleTodoCheckboxViaBlockModel(at: index)
                DispatchQueue.main.async { NSCursor.pointingHand.set() }
                return true
            }

            // Legacy path.
            guard let formatter = self.getTextFormatter() else { return false }
            formatter.toggleTodo(index)

            DispatchQueue.main.async {
                NSCursor.pointingHand.set()
            }

            return true
        }

        return false
    }

    private func handleClick(_ event: NSEvent) {
        // Phase 4.5: TK1 click hit-testing removed with the custom
        // layout-manager subclass. TK2 path uses `characterIndexTK2`,
        // which only returns a valid index when the click is inside a
        // line fragment — `hitInsideAttachment` is derived from whether
        // the resolved character carries an `.attachment` attribute.
        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        guard let index = characterIndexTK2(at: properPoint) else { return }

        let hitInsideAttachment = hasAttachment(at: index) ||
            (textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment) != nil

        // Image attachment: single click selects, double click opens.
        // The selection is ephemeral view state — nothing is written to
        // the document. Clearing on click elsewhere is handled below.
        if hitInsideAttachment, isNativeImageAttachment(at: index) {
            if event.clickCount >= 2 {
                // Double click falls through to the existing open path.
                selectedImageRange = nil
                if event.modifierFlags.contains(.command) {
                    openTitleEditor(at: index)
                } else {
                    openFileViewer(at: index)
                }
                return
            }
            // Single click → select the image for resize handles.
            selectedImageRange = NSRange(location: index, length: 1)
            return
        }

        // Click landed somewhere other than a selectable image —
        // clear any prior image selection.
        if selectedImageRange != nil {
            selectedImageRange = nil
        }

        guard hitInsideAttachment else { return }

        if hasAttachment(at: index) {
            if event.modifierFlags.contains(.command) {
                openTitleEditor(at: index)
            } else {
                openFileViewer(at: index)
            }
        }
    }

    /// Return true iff the character at `index` is a native image
    /// attachment — i.e. an NSTextAttachment whose
    /// `renderedBlockType` attribute is `"image"`. PDFs, QuickLook
    /// previews, and generic file attachments all return false
    /// (phase 1 scope: image resize is native images only).
    private func isNativeImageAttachment(at index: Int) -> Bool {
        guard let storage = textStorage,
              index >= 0, index < storage.length else { return false }
        guard storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment != nil else {
            return false
        }
        guard let blockType = storage.attribute(.renderedBlockType, at: index, effectiveRange: nil) as? String else {
            return false
        }
        return blockType == RenderedBlockType.image.rawValue
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
        vc.alert?.beginSheetModal(for: window) { returnCode in
            if returnCode == .alertFirstButtonReturn {
                attachment.title = field.stringValue

                var range = NSRange()
                if self.textStorage?.attribute(.attachment, at: at, effectiveRange: &range) as? NSTextAttachment != nil {
                    self.textStorage?.addAttribute(.attachmentTitle, value: attachment.title, range: range)
                    self.hasUserEdits = true
                    self.save()
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
        NSWorkspace.shared.open(attachment.url)
    }

    // MARK: - Image resize drag

    /// If the mouseDown event landed on one of the 8 resize handles of
    /// the currently-selected image, prime `currentImageDrag` and
    /// return true so the caller short-circuits its own click handling.
    /// Otherwise no state is touched and the method returns false.
    private func beginImageResizeDragIfPossible(_ event: NSEvent) -> Bool {
        guard let selRange = selectedImageRange,
              let rect = imageAttachmentRect(forRange: selRange),
              let storage = textStorage,
              let attachment = storage.attribute(.attachment, at: selRange.location, effectiveRange: nil) as? NSTextAttachment
        else { return false }

        let point = convert(event.locationInWindow, from: nil)
        guard let handle = ImageSelectionHandleDrawer.handle(at: point, in: rect) else {
            return false
        }

        currentImageDrag = ImageResizeDrag(
            range: selRange,
            startBounds: attachment.bounds,
            startMouse: point,
            aspect: attachment.bounds.height / max(attachment.bounds.width, 1),
            handle: handle
        )
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        guard currentImageDrag != nil else {
            super.mouseDragged(with: event)
            return
        }
        // Phase 4.5: TK1 live-resize invalidation dance (invalidateGlyphs /
        // invalidateLayout / invalidateDisplay on `NSLayoutManager`)
        // removed with the custom layout-manager subclass. Live image
        // resize mid-drag requires a TK2-native `NSTextLayoutManager`
        // invalidation path; the drag state is still tracked so
        // `mouseUp` can commit the final width, but there is no visual
        // update while the user drags.
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = currentImageDrag else {
            super.mouseUp(with: event)
            return
        }
        currentImageDrag = nil

        guard let storage = textStorage,
              drag.range.location < storage.length,
              let attachment = storage.attribute(.attachment, at: drag.range.location, effectiveRange: nil) as? NSTextAttachment,
              let projection = documentProjection
        else { return }

        let finalWidth = Int(attachment.bounds.width.rounded())

        // Skip the commit if the drag didn't actually change the width
        // (user clicked a handle and released without moving). Avoids
        // a no-op undo step cluttering the history.
        if finalWidth == Int(drag.startBounds.width.rounded()) {
            return
        }

        guard let (blockIndex, offsetInBlock) = projection.blockContaining(
            storageIndex: drag.range.location
        ) else { return }
        let block = projection.document.blocks[blockIndex]
        guard case .paragraph(let inline) = block,
              let inlinePath = EditingOps.findImageInlinePath(in: inline, at: offsetInBlock)
        else { return }

        breakUndoCoalescing()
        do {
            let result = try EditingOps.setImageSize(
                blockIndex: blockIndex,
                inlinePath: inlinePath,
                newWidth: finalWidth,
                in: projection
            )
            applyEditResultWithUndo(result, actionName: "Resize Image")

            // The splice replaces the live-mutated attachment with a
            // freshly-rendered placeholder attachment (bounds 1×1, no
            // cell). Re-run the hydrator so it loads the image into
            // the new attachment and sizes it via the width hint that
            // setImageSize just wrote. Without this, the image appears
            // blank until the user switches notes and comes back.
            if let storage = textStorage {
                ImageAttachmentHydrator.hydrate(textStorage: storage, editor: self)
            }
        } catch {
            // Commit failed — the live-update bounds already reflect
            // what the user wants, so at worst the next save will
            // serialize without the width hint. Log but don't crash.
            bmLog("⚠️ setImageSize failed after drag: \(error)")
        }
        breakUndoCoalescing()
    }

    /// Maximum width (in points) an image is allowed to grow to in the
    /// current text container. Matches the safety clamp used by
    /// ImageAttachmentHydrator.containerMaxWidth.
    private func imageContainerMaxWidth() -> CGFloat {
        if let container = textContainer {
            let lfp = container.lineFragmentPadding
            let w = container.size.width - lfp * 2
            if w > 0 { return w }
        }
        if let editorWidth = enclosingScrollView?.contentView.bounds.width {
            return editorWidth - 40
        }
        // Last-resort fallback — see ImageAttachmentHydrator.containerMaxWidth.
        return 450
    }
}
