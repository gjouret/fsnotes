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
        super.mouseDown(with: event)

        // Source mode only: skip past clear-color hidden syntax characters.
        // In WYSIWYG mode (block model active), there are no clear-color
        // characters — the block model renders without markdown markers.
        if NotesTextProcessor.hideSyntax,
           textStorageProcessor?.blockModelActive != true,
           let storage = textStorage {
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

        // Phase 2a: TK1-only cursor hit-testing. The TK2 equivalent is
        // `NSTextLayoutManager.textLayoutFragment(for:)` — see
        // `characterIndexTK2(at:)` below for the TK2 fallback branch.
        if let container = self.textContainer,
           let manager = self.layoutManagerIfTK1,
           let textStorage = self.textStorage {
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

            super.mouseMoved(with: event)
            return
        }

        // Phase 2f.3: TK2 fallback — use NSTextLayoutManager to
        // resolve the point to a character index, then read the
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
    /// offset into `textStorage`. Returns `nil` when the view is not
    /// on TK2, when no layout fragment exists at that y-band, or
    /// when the point falls between line fragments.
    ///
    /// Under TK1 the caller should go through the `layoutManagerIfTK1`
    /// path — this helper is the TK2 fallback only.
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

        // Phase 2a: TK1 link-hover cursor detection.
        if let container = self.textContainer,
           let manager = self.layoutManagerIfTK1,
           let textStorage = self.textStorage {
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
            return
        }

        // Phase 2f.3: TK2 fallback — resolve via NSTextLayoutManager.
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
        // Phase 2a: rendered-block click hit-testing is TK1-only. Block
        // attachments don't render under TK2 yet (accepted 2a regression).
        guard let storage = textStorage,
              let container = self.textContainer,
              let manager = self.layoutManagerIfTK1 else { return false }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)

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
        guard let container = self.textContainer,
              let manager = self.layoutManagerIfTK1 else { return false }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)

        guard glyphRect.contains(properPoint) else { return false }

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
        // Phase 2a: click hit-testing uses TK1 API. The basic text
        // caret positioning is handled by NSTextView's default mouse
        // handling under TK2 — this function only runs for specialized
        // hit-testing (attachments, todos, links) which is TK1-only.
        guard let container = self.textContainer,
              let manager = self.layoutManagerIfTK1 else { return }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)

        let hitInsideAttachment = glyphRect.contains(properPoint)

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
        guard let drag = currentImageDrag else {
            super.mouseDragged(with: event)
            return
        }
        // Phase 2a TK2-safety (2026-04-22): bare `layoutManager` was an
        // implicit `self.layoutManager` read that silently downgrades
        // TK2 → TK1 on TK2-wired views (see `reflowAttachmentsForWidthChange`
        // for the full rationale). Route through `layoutManagerIfTK1`
        // so a TK2 view short-circuits the TK1 glyph-invalidation dance
        // below. Image resize drag is TK1-only today — TK2 needs a
        // separate invalidation path using NSTextLayoutManager APIs,
        // and landing that is a later phase. Until then, under TK2 the
        // drag bails out here and the user's mouse movement has no
        // visual effect.
        guard let storage = textStorage,
              drag.range.location < storage.length,
              let attachment = storage.attribute(.attachment, at: drag.range.location, effectiveRange: nil) as? NSTextAttachment,
              let lm = layoutManagerIfTK1
        else { return }

        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - drag.startMouse.x

        // Compute proposed new width from the corner the user
        // grabbed. Aspect is locked — height is always derived from
        // width. Only corner handles exist (no edge midpoints).
        var newWidth: CGFloat
        switch drag.handle {
        case .topLeft, .bottomLeft:
            // Left corners: drag left → grow.
            newWidth = drag.startBounds.width - dx
        case .topRight, .bottomRight:
            // Right corners: drag right → grow.
            newWidth = drag.startBounds.width + dx
        }

        // Clamp: minimum 20pt so handles remain grabbable; maximum
        // container width so the image never overflows the text column.
        let maxWidth = imageContainerMaxWidth()
        newWidth = max(20, min(maxWidth, newWidth))
        let newHeight = newWidth * drag.aspect

        // Live visual update. No EditingOps call — this runs dozens
        // of times per drag and we don't want to rebuild the Document
        // on every mouse move. The projection is updated once on
        // mouseUp. Two things MUST change for a live resize:
        //   1. attachment.bounds — controls the draw rect.
        //   2. cell.image.size — controls cellSize(), which
        //      NSLayoutManager queries to place the glyph in its
        //      line fragment. Updating bounds alone leaves the cell
        //      reporting the ORIGINAL size, so the layout slot stays
        //      full-size and the selection ring (which asks
        //      NSLayoutManager for the glyph rect) draws at the old
        //      size while the image shrinks inside it.
        let newSize = NSSize(width: newWidth, height: newHeight)
        attachment.bounds = NSRect(origin: .zero, size: newSize)
        if let cell = attachment.attachmentCell as? FSNTextAttachmentCell,
           let image = cell.image {
            image.size = newSize
        }
        storage.edited(.editedAttributes, range: drag.range, changeInLength: 0)

        // Full invalidation from the attachment forward — mirrors the
        // pattern in applyEditResultWithUndo. Narrower ranges leave
        // NSLayoutManager's line-fragment glyph-position cache intact,
        // so the centered image doesn't actually re-center on each
        // drag tick. We invalidate glyphs, then layout, then force
        // re-layout and re-display.
        let start = drag.range.location
        let affectedRange = NSRange(location: start, length: max(0, storage.length - start))
        lm.invalidateGlyphs(
            forCharacterRange: affectedRange,
            changeInLength: 0,
            actualCharacterRange: nil
        )
        lm.invalidateLayout(forCharacterRange: affectedRange, actualCharacterRange: nil)
        lm.ensureLayout(forCharacterRange: affectedRange)
        let glyphRange = lm.glyphRange(forCharacterRange: affectedRange, actualCharacterRange: nil)
        lm.invalidateDisplay(forGlyphRange: glyphRange)
        needsDisplay = true
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
        return CGFloat(UserDefaultsManagement.imagesWidth)
    }
}
