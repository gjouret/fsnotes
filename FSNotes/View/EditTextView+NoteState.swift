//
//  EditTextView+NoteState.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation
import AppKit

extension EditTextView {
    func getSelectedNote() -> Note? {
        return ViewController.shared()?.notesTableView?.getSelectedNote()
    }

    public func isEditable(note: Note) -> Bool {
        if note.container == .encryptedTextPack { return false }
        return editorViewController?.vcEditor != nil
    }

    public func getVC() -> EditorViewController {
        return self.window?.contentViewController as! EditorViewController
    }

    public func getEVC() -> EditorViewController? {
        return self.window?.contentViewController as? EditorViewController
    }

    public func save() {
        guard let note = self.note else { return }
        // Block-model pipeline: serialize Document to markdown
        // directly, bypassing the attribute-stripping save path.
        if let markdown = serializeViaBlockModel() {
            bmLog("💾 save (block-model): \(note.title) — \(markdown.prefix(60))")
            note.save(markdown: markdown)
            // Preserve the cached Document from the current projection —
            // save(markdown:) invalidates it, but the projection's document
            // is still the correct one.
            if let doc = documentProjection?.document {
                note.cachedDocument = doc
            }
            return
        }
        let saving = attributedStringForSaving()
        bmLog("💾 save (legacy): \(note.title) — \(saving.string.prefix(60))")
        note.save(attributed: saving)
    }

    func fill(note: Note, highlight: Bool = false, force: Bool = false) {
        bmLog("📋 fill() called: \(note.title)")
        isScrollPositionSaverLocked = true

        // Clear block-model state BEFORE touching textStorage.
        // This prevents any textDidChange triggered by the
        // storage-clearing below from seeing stale block-model state.
        documentProjection = nil
        textStorageProcessor?.blockModelActive = false
        textStorageProcessor?.blocks = []

        if !note.isLoaded {
            note.load()
        }

        viewDelegate?.updateCounters(note: note)

        textStorage?.setAttributedString(NSAttributedString(string: ""))

        if let length = textStorage?.length {
            textStorage?.layoutManagers.first?.invalidateDisplay(forGlyphRange: NSRange(location: 0, length: length))
            invalidateLayout()
        }

        undoManager?.removeAllActions(withTarget: self)
        registerHandoff(note: note)
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
        note.cacheHash = nil
        UserDefaultsManagement.lastSelectedURL = note.url

        editorViewController?.updateTitle(note: note)
        isEditable = isEditable(note: note)
        editorViewController?.editorUndoManager = note.undoManager

        typingAttributes.removeAll()
        typingAttributes[.font] = UserDefaultsManagement.noteFont

        guard let storage = textStorage else { return }

        if note.isMarkdown(), let content = note.content.mutableCopy() as? NSMutableAttributedString {
            pendingRenderBlockRange = nil
            removeAllInlineTableViews()
            removeAllInlinePDFViews()

            // Block-model renderer: parses markdown → Document → rendered
            // attributed string. Falls back to legacy for source mode.
            if !fillViaBlockModel(note: note) {
                storage.setAttributedString(content)
            }
        } else {
            documentProjection = nil
            storage.setAttributedString(note.content)
        }

        if highlight {
            textStorage?.highlightKeyword(search: getSearchText())
        }

        // When the block-model pipeline rendered this note, all styling
        // (paragraph styles, syntax hiding, code block rendering) is
        // already handled — skip legacy post-processing.
        if documentProjection == nil {
            // Legacy path: fence lines hidden by phase4_hideSyntax
            // (per-char kern + clear color), styled by phase5_paragraphStyles.
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
        }

        // Render inline PDF viewers (works in both block-model and legacy pipelines).
        // Must run after all text is in storage so regex scanning finds PDF references.
        if NotesTextProcessor.hideSyntax {
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let storage = self.textStorage else { return }
                let containerWidth = self.textContainer?.size.width ?? self.frame.width
                PDFAttachmentProcessor.renderPDFAttachments(
                    in: storage,
                    note: note,
                    containerWidth: containerWidth
                )
            }
        }

        viewDelegate?.restoreScrollPosition()
        needsDisplay = true
    }

    public func lockEncryptedView() {
        textStorage?.setAttributedString(NSAttributedString())
        isEditable = false

        if let label = editorViewController?.vcNonSelectedLabel {
            label.stringValue = NSLocalizedString("Locked", comment: "")
            label.isHidden = false
        }
    }

    public func clear() {
        textStorage?.setAttributedString(NSAttributedString())
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

    func getParagraphRange() -> NSRange? {
        guard let storage = textStorage else { return nil }
        let range = selectedRange()
        return storage.mutableString.paragraphRange(for: range)
    }

    func saveSelectedRange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let note = self.note else { return }
            note.setSelectedRange(range: self.selectedRange)
        }
    }

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

    func getSearchText() -> String {
        guard let search = ViewController.shared()?.search else { return String() }

        if let editor = search.currentEditor(), editor.selectedRange.length > 0 {
            return (search.stringValue as NSString).substring(with: NSRange(0..<editor.selectedRange.location))
        }

        return search.stringValue
    }

    public func scrollToCursor() {
        let cursorRange = NSMakeRange(self.selectedRange().location, 0)

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

    func unfocusAllInlineTableViews() {
        tableController.unfocusAllInlineTableViews()
    }

    func removeAllInlineTableViews() {
        for subview in subviews {
            if let tableView = subview as? InlineTableView {
                tableView.collectCellData()
            }
        }

        for subview in subviews {
            if subview is InlineTableView {
                subview.removeFromSuperview()
            }
        }
    }

    func renderTables() {
        tableController.renderTables()
    }

    func removeAllInlinePDFViews() {
        for subview in subviews {
            if subview is InlinePDFView {
                subview.removeFromSuperview()
            }
        }
    }
}
