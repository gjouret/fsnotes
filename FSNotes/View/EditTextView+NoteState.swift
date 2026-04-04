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
        note.save(attributed: attributedStringForSaving())
    }

    func fill(note: Note, highlight: Bool = false, force: Bool = false) {
        isScrollPositionSaverLocked = true

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
            storage.setAttributedString(content)
        } else {
            storage.setAttributedString(note.content)
        }

        if highlight {
            textStorage?.highlightKeyword(search: getSearchText())
        }

        if NotesTextProcessor.hideSyntax, let storage = textStorage, let processor = textStorageProcessor {
            let codeBlockRanges = processor.codeBlockRanges
            let string = storage.string as NSString
            let fenceParaStyle = NSMutableParagraphStyle()
            fenceParaStyle.maximumLineHeight = CGFloat(UserDefaultsManagement.fontSize) * 0.5
            fenceParaStyle.lineSpacing = 0
            let fenceFont = NSFont.systemFont(ofSize: CGFloat(UserDefaultsManagement.fontSize) * 0.5)

            for codeRange in codeBlockRanges {
                guard codeRange.location < string.length, NSMaxRange(codeRange) <= string.length else { continue }
                let openingLineRange = string.lineRange(for: NSRange(location: codeRange.location, length: 0))
                if openingLineRange.length > 0 {
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
}
