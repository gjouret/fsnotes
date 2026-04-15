//
//  EditTextView+Formatting.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation
import AppKit

extension EditTextView {
    @IBAction func boldMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        if applyInlineTableCellFormatting("**") { return }
        if toggleBoldViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        clearBlockModelAndRefill()
        let formatter = TextFormatter(textView: self, note: note)
        formatter.bold()
        updateToolbarAfterFormatting()
    }

    @IBAction func italicMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        if applyInlineTableCellFormatting("*") { return }
        if toggleItalicViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        clearBlockModelAndRefill()
        let formatter = TextFormatter(textView: self, note: note)
        formatter.italic()
        updateToolbarAfterFormatting()
    }

    func applyInlineTableCellFormatting(_ marker: String) -> Bool {
        return tableController.applyInlineTableCellFormatting(marker)
    }

    func applyInlineTableCellFormat(_ format: TableRenderController.InlineCellFormat) -> Bool {
        return tableController.applyInlineTableCellFormat(format)
    }

    @IBAction func linkMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        // In-cell path: if a table cell is being edited, honor the same
        // clipboard-URL shortcut but wrap the cell's field-editor
        // selection instead of the outer text view's selection.
        if tryLinkInTableCell() { return }

        if let clipboardString = NSPasteboard.general.string(forType: .string) {
            let normalized = clipboardString.normalizedAsURL()
            if let url = URL(string: normalized),
               let scheme = url.scheme, ["http", "https", "ftp", "ftps", "mailto"].contains(scheme.lowercased()) {
                let selectedText = attributedSubstring(forProposedRange: selectedRange(), actualRange: nil)?.string ?? ""
                let displayText = selectedText.isEmpty ? normalized : selectedText
                let markdown = "[\(displayText)](\(normalized))"
                let range = selectedRange()
                insertText(markdown, replacementRange: range)
                return
            }
        }

        showLinkDialog()
    }

    /// If the field editor currently belongs to a table cell, wrap the
    /// cell's selection as a markdown link. Pulls a URL from the
    /// clipboard when possible (matching the outer editor's shortcut);
    /// falls back to a placeholder URL otherwise.
    private func tryLinkInTableCell() -> Bool {
        guard let fieldEditor = window?.fieldEditor(false, for: nil),
              let cell = fieldEditor.delegate as? NSTextField,
              cell.window != nil else { return false }
        // Confirm the cell lives inside an InlineTableView; if not,
        // this is some other field editor (e.g. sidebar) and we should
        // fall through to the outer-editor path.
        var v: NSView? = cell.superview
        var inTable = false
        while let current = v {
            if current is InlineTableView { inTable = true; break }
            v = current.superview
        }
        guard inTable else { return false }

        var url = "https://"
        if let clipboardString = NSPasteboard.general.string(forType: .string) {
            let normalized = clipboardString.normalizedAsURL()
            if let parsed = URL(string: normalized),
               let scheme = parsed.scheme,
               ["http", "https", "ftp", "ftps", "mailto"].contains(scheme.lowercased()) {
                url = normalized
            }
        }
        return applyInlineTableCellFormat(.link(url: url))
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
                let range = self.selectedRange()
                guard let storage = self.textStorage else { return }
                let nsString = storage.string as NSString
                let paraRange = nsString.paragraphRange(for: range)
                let paraString = nsString.substring(with: paraRange)

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

        if applyInlineTableCellFormat(.underline) { return }
        if toggleUnderlineViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        clearBlockModelAndRefill()
        let formatter = TextFormatter(textView: self, note: note)
        formatter.underline()
        updateToolbarAfterFormatting()
    }

    @IBAction func strikeMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        if applyInlineTableCellFormatting("~~") { return }
        if toggleStrikethroughViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        clearBlockModelAndRefill()
        let formatter = TextFormatter(textView: self, note: note)
        formatter.strike()
        updateToolbarAfterFormatting()
    }

    @IBAction func highlightMenu(_ sender: Any) {
        guard let note = self.note, isEditable, note.isMarkdown() else { return }

        if applyInlineTableCellFormat(.highlight) { return }
        if toggleHighlightViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        clearBlockModelAndRefill()
        let formatter = TextFormatter(textView: self, note: note)
        formatter.highlight()
        updateToolbarAfterFormatting()
    }

    private func updateToolbarAfterFormatting() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let vc = ViewController.shared() {
                vc.formattingToolbar?.updateButtonStates(for: self)
            }
        }
    }

    @IBAction func headerMenu(_ sender: NSMenuItem) {
        guard let note = self.note, isEditable else { return }
        guard let id = sender.identifier?.rawValue else { return }

        let code = Int(id.replacingOccurrences(of: "format.h", with: ""))
        if let level = code, changeHeadingLevelViaBlockModel(level) {
            updateToolbarAfterFormatting()
            return
        }

        var string = String()
        for index in [1, 2, 3, 4, 5, 6] {
            string += "#"
            if code == index {
                break
            }
        }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.header(string)
    }

    @IBAction func shiftLeft(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.unTab()
    }

    @IBAction func shiftRight(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.tab()
    }

    @IBAction func todo(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        if toggleTodoViaBlockModel() { updateToolbarAfterFormatting(); return }
        clearBlockModelAndRefill()
        let formatter = TextFormatter(textView: self, note: note)
        formatter.todo()
    }

    @IBAction func wikiLinks(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        if insertWikiLinkViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.wikiLink()
    }

    /// Insert `[[]]` via the block model and place cursor between brackets.
    private func insertWikiLinkViaBlockModel() -> Bool {
        guard let projection = documentProjection else { return false }
        let sel = selectedRange()

        do {
            let selectedText: String
            if sel.length > 0, let storage = textStorage {
                selectedText = (storage.string as NSString).substring(with: sel)
            } else {
                selectedText = ""
            }

            let wikiText = "[[" + selectedText + "]]"
            let result: EditResult
            if sel.length > 0 {
                result = try EditingOps.replace(range: sel, with: wikiText, in: projection)
            } else {
                result = try EditingOps.insert(wikiText, at: sel.location, in: projection)
            }

            applyBlockModelResult(result, actionName: "Wiki Link")

            // Place cursor between brackets (after "[[" + selectedText),
            // or select the text if there was a selection.
            if selectedText.isEmpty {
                setSelectedRange(NSRange(location: sel.location + 2, length: 0))
                complete(nil)
            } else {
                setSelectedRange(NSRange(location: sel.location + 2, length: selectedText.count))
            }
            return true
        } catch {
            bmLog("⚠️ insertWikiLink failed: \(error)")
            return false
        }
    }

    @IBAction func pressBold(_ sender: Any) {
        boldMenu(sender)
    }

    @IBAction func pressItalic(_ sender: Any) {
        italicMenu(sender)
    }

    @IBAction func quoteMenu(_ sender: Any) {
        guard let note = self.note, isEditable, let storage = textStorage else { return }
        if toggleBlockquoteViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.quote()

        if NotesTextProcessor.hideSyntax {
            let cursorLoc = min(selectedRange().location, storage.length - 1)
            if cursorLoc >= 0 {
                let paraRange = (storage.string as NSString).paragraphRange(
                    for: NSRange(location: cursorLoc, length: 0)
                )
                refreshParagraphRendering(range: paraRange)
            }
        }
    }

    @IBAction func bulletListMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        if toggleListViaBlockModel(marker: "-") {
            updateToolbarAfterFormatting()
            return
        }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.list()
    }

    @IBAction func numberedListMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        if toggleListViaBlockModel(marker: "1.") {
            updateToolbarAfterFormatting()
            return
        }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.orderedList()
    }

    @IBAction func imageMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        let formatter = TextFormatter(textView: self, note: note)
        formatter.image()
    }

    @IBAction func insertTableMenu(_ sender: Any) {
        guard let note = self.note, let _ = textStorage, isEditable else { return }

        let tableMarkdown = "|  |  |\n|--|--|\n|  |  |"

        if let projection = documentProjection {
            // Block-model mode: insert a table block after the current block.
            let cursorPos = selectedRange().location
            guard let (blockIndex, _) = projection.blockContaining(storageIndex: cursorPos) else { return }

            let empty = TableCell([])
            let tableBlock = Block.table(
                header: [empty, empty],
                alignments: [.none, .none],
                rows: [[empty, empty]],
                raw: tableMarkdown
            )
            var newDoc = projection.document
            newDoc.blocks.insert(tableBlock, at: blockIndex + 1)

            // Persist the new markdown to disk BEFORE calling fill(), and
            // populate `cachedDocument` so fillViaBlockModel uses the new
            // doc directly instead of re-reading disk. Without the
            // save, `fillViaBlockModel` would re-parse the OLD markdown
            // from disk (because disk hadn't been written yet) and
            // silently drop the new table. Without the cache set,
            // fillViaBlockModel would re-read disk anyway and do
            // extra work.
            let newMarkdown = MarkdownSerializer.serialize(newDoc)
            note.content = NSMutableAttributedString(string: newMarkdown)
            note.save(markdown: newMarkdown)
            note.cachedDocument = newDoc
            hasUserEdits = false
            fill(note: note)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.focusFirstInlineTableCell()
            }
        } else {
            // Source-mode path.
            let insertRange = selectedRange()
            let prefix = insertRange.location > 0 ? "\n" : ""
            insertText(prefix + tableMarkdown + "\n", replacementRange: insertRange)

            if NotesTextProcessor.hideSyntax {
                renderTables()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.focusFirstInlineTableCell()
                }
            }
        }
    }

    private func focusFirstInlineTableCell() {
        tableController.focusFirstInlineTableCell()
    }

    @IBAction func horizontalRuleMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }
        if insertHorizontalRuleViaBlockModel() { return }

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

        if changeHeadingLevelViaBlockModel(level.count) { return }

        let formatter = TextFormatter(textView: self, note: note)
        formatter.header(level)
    }

    @IBAction func insertCodeBlock(_ sender: NSButton) {
        guard isEditable else { return }

        let currentRange = selectedRange()

        // Block-model path: wrap the selection in a code block via
        // `EditingOps.wrapInCodeBlock`, which splits the containing
        // paragraph (preserving text before and after the selection)
        // instead of replacing the whole block. Cursor-only selection
        // inserts an empty code block after the containing block.
        if let projection = documentProjection {
            do {
                let result = try EditingOps.wrapInCodeBlock(
                    range: currentRange, in: projection
                )
                applyBlockModelResult(result, actionName: "Code Block")
                return
            } catch {
                bmLog("⚠️ insertCodeBlock via block model failed: \(error)")
                // Fall through to source-mode path.
            }
        }

        // Source-mode fallback.
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
        setSelectedRange(NSRange(location: currentRange.location + 3, length: 0))
    }

    @IBAction func insertCodeSpan(_ sender: NSMenuItem) {
        guard isEditable else { return }

        if applyInlineTableCellFormat(.code) { return }

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
        bulletListMenu(sender)
    }

    @IBAction func insertOrderedList(_ sender: NSMenuItem) {
        numberedListMenu(sender)
    }

    @IBAction func insertQuote(_ sender: NSMenuItem) {
        quoteMenu(sender)
    }

    @IBAction func insertLink(_ sender: Any) {
        linkMenu(sender)
    }

    func getTextFormatter() -> TextFormatter? {
        guard let note = self.note, isEditable else { return nil }
        return TextFormatter(textView: self, note: note)
    }
}
