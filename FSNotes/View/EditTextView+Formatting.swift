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

        if toggleItalicViaBlockModel() {
            updateToolbarAfterFormatting()
            return
        }

        clearBlockModelAndRefill()
        let formatter = TextFormatter(textView: self, note: note)
        formatter.italic()
        updateToolbarAfterFormatting()
    }

    @IBAction func linkMenu(_ sender: Any) {
        guard self.note != nil, isEditable else { return }

        if let clipboardString = NSPasteboard.general.string(forType: .string) {
            let normalized = clipboardString.normalizedAsURL()
            if let url = URL(string: normalized),
               let scheme = url.scheme, ["http", "https", "ftp", "ftps", "mailto"].contains(scheme.lowercased()) {
                let selectedText = attributedSubstring(forProposedRange: selectedRange(), actualRange: nil)?.string ?? ""
                let displayText = selectedText.isEmpty ? normalized : selectedText
                let markdown = "[\(displayText)](\(normalized))"
                let range = selectedRange()
                // Phase 5a bypass: `insertText(_:replacementRange:)` from
                // an IBAction goes through AppKit's `_insertText:` which
                // skips `shouldChangeText`, so the block-model gatekeeper
                // never runs. Wrap in `performingLegacyStorageWrite` to
                // authorize the mutation. A follow-up slice should route
                // this through a proper `EditingOps.wrapInLink` primitive.
                StorageWriteGuard.performingLegacyStorageWrite {
                    insertText(markdown, replacementRange: range)
                }
                return
            }
        }

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
                // Phase 5a bypass — see linkMenu() above.
                StorageWriteGuard.performingLegacyStorageWrite {
                    self.insertText(markdown, replacementRange: range)
                }
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
                        // Phase 5a bypass — see linkMenu() above.
                        StorageWriteGuard.performingLegacyStorageWrite {
                            self.insertText(displayText, replacementRange: fullRange)
                        }
                    }
                }
            }
        }
    }

    @IBAction func underlineMenu(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

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
        let sel = selectedRange()
        let hasProj = (documentProjection != nil)
        let bmActive = textStorageProcessor?.blockModelActive ?? false
        bmLog("☑ CMD+T diag: sel=\(sel) hasProj=\(hasProj) bmActive=\(bmActive) noteType=\(note.type) isMarkdown=\(note.isMarkdown())")
        if toggleTodoViaBlockModel() {
            bmLog("☑ CMD+T diag: block-model path succeeded")
            updateToolbarAfterFormatting()
            return
        }
        bmLog("☑ CMD+T diag: block-model path FAILED — falling through to source-mode formatter.todo() (this is the bug #20 source of literal '- [ ]')")
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
                columnWidths: nil
            )
            var newDoc = projection.document
            newDoc.insertBlock(tableBlock, at: blockIndex + 1)

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
            // Place the caret inside the new table's top-left cell.
            // Without this, the cursor stays at its pre-insert
            // position and the user's first keystroke after
            // "Insert Table" lands OUTSIDE the table — exactly the
            // symptom the previous TODO comment misdescribed as a
            // non-issue ("TK2's default hit-testing places the
            // caret in the first table cell on the next user
            // click"). It doesn't, because `TableLayoutFragment`
            // paints cells at custom grid positions that TK2's
            // natural-flow hit test doesn't agree with.
            placeCursorInFirstCellOfTable(at: blockIndex + 1)
        } else {
            // Source-mode path. Tables only render live in block-model
            // mode; in source mode the raw markdown is inserted and the
            // user sees it as plain text (still round-trips correctly).
            let insertRange = selectedRange()
            let storageString = textStorage?.string ?? ""
            let prefix = EditTextView.tablePrefixForSourceModeInsertion(
                at: insertRange.location, in: storageString
            )
            // Phase 5a bypass — IBAction insertText skips shouldChangeText.
            StorageWriteGuard.performingLegacyStorageWrite {
                insertText(prefix + tableMarkdown + "\n", replacementRange: insertRange)
            }
        }
    }

    /// Pure helper for the source-mode `insertTableMenu` prefix logic.
    ///
    /// GFM requires a BLANK line between a paragraph and a following
    /// table — otherwise external parsers (GitHub, Obsidian, Bear) eat
    /// the table's first row as paragraph continuation. The prefix
    /// returned here produces the required blank separator while
    /// avoiding a stray double-blank-line:
    ///
    /// - `location == 0` (document start): `""` — nothing before us.
    /// - char before `location` is `\n` (cursor on a fresh line):
    ///   `"\n"` — one extra newline plus the existing one = blank line.
    /// - otherwise (mid-paragraph or end-of-paragraph without
    ///   trailing newline): `"\n\n"` — full blank-line separator.
    ///
    /// Bug #34 fix.
    public static func tablePrefixForSourceModeInsertion(
        at location: Int, in text: String
    ) -> String {
        guard location > 0 else { return "" }
        let nsText = text as NSString
        guard location <= nsText.length else { return "\n\n" }
        let prevChar = nsText.substring(
            with: NSRange(location: location - 1, length: 1)
        )
        return (prevChar == "\n") ? "\n" : "\n\n"
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

            // Phase 5a bypass — IBAction insertText skips shouldChangeText.
            StorageWriteGuard.performingLegacyStorageWrite {
                insertText(mutable, replacementRange: currentRange)
            }
            setSelectedRange(NSRange(location: currentRange.location + 4, length: 0))
            return
        }

        StorageWriteGuard.performingLegacyStorageWrite {
            insertText("```\n\n```\n", replacementRange: currentRange)
        }
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
            // Phase 5a bypass — IBAction insertText skips shouldChangeText.
            StorageWriteGuard.performingLegacyStorageWrite {
                insertText(mutable, replacementRange: currentRange)
            }
            return
        }

        StorageWriteGuard.performingLegacyStorageWrite {
            insertText("``", replacementRange: currentRange)
        }
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
