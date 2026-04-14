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

        if NotesTextProcessor.hideSyntax, gutterController.handleClick(event) {
            return
        }

        if NotesTextProcessor.hideSyntax, handleRenderedBlockClick(event) {
            return
        }

        unfocusAllInlineTableViews()

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
    }

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
        guard let storage = textStorage,
              let container = self.textContainer,
              let manager = self.layoutManager else { return false }

        let point = self.convert(event.locationInWindow, from: nil)
        let properPoint = NSPoint(x: point.x - textContainerInset.width, y: point.y)
        let index = manager.characterIndex(for: properPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)

        guard index < storage.length else { return false }

        guard storage.attribute(.attachment, at: index, effectiveRange: nil) != nil,
              let originalMarkdown = storage.attribute(.renderedBlockOriginalMarkdown, at: index, effectiveRange: nil) as? String else {
            return false
        }

        if let blockType = storage.attribute(.renderedBlockType, at: index, effectiveRange: nil) as? String,
           blockType == RenderedBlockType.table.rawValue {
            if let att = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
               let attCell = att.attachmentCell as? InlineTableAttachmentCell {
                let tableView = attCell.inlineTableView
                let tablePoint = tableView.convert(event.locationInWindow, from: nil)
                let hitCell = tableView.cellPool.contains(where: { !$0.isHidden && $0.frame.contains(tablePoint) })
                let hitHandle = tableView.subviews.contains(where: { $0 is NSVisualEffectView && $0.frame.contains(tablePoint) })

                if !hitCell && !hitHandle {
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
              let manager = self.layoutManager else { return false }

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
        guard let container = self.textContainer,
              let manager = self.layoutManager else { return }

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
}
