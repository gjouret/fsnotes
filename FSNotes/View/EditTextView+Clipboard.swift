//
//  EditTextView+Clipboard.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import AppKit

extension EditTextView {
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        return [
            NSPasteboard.attributed,
            NSPasteboard.PasteboardType.string,
        ]
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        return super.readablePasteboardTypes + [NSPasteboard.attributed]
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

    override func copy(_ sender: Any?) {
        let attrString = attributedSubstring(forProposedRange: self.selectedRange, actualRange: nil)

        if self.selectedRange.length == 1,
           let url = attrString?.attribute(.attachmentUrl, at: 0, effectiveRange: nil) as? URL {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            return
        }

        if selectedRanges.count > 1 {
            var combined = String()
            for range in selectedRanges {
                if let range = range as? NSRange,
                   let sub = attributedSubstring(forProposedRange: range, actualRange: nil) as? NSMutableAttributedString {
                    combined.append(sub.unloadAttachments().string + "\n")
                }
            }

            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(combined.trim().removeLastNewLine(), forType: .string)
            return
        }

        if self.selectedRange.length == 0,
           let paragraphRange = self.getParagraphRange(),
           let paragraph = attributedSubstring(forProposedRange: paragraphRange, actualRange: nil) {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(paragraph.string.trim().removeLastNewLine(), forType: .string)
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

        if let rtfdData = NSPasteboard.general.data(forType: NSPasteboard.attributed),
           let attributed = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(rtfdData) as? NSAttributedString {
            breakUndoCoalescing()
            insertText(attributed, replacementRange: selectedRange())
            breakUndoCoalescing()
            return
        }

        if let url = NSURL(from: NSPasteboard.general),
           url.isFileURL && saveFile(url: url as URL, in: note) {
            return
        }

        // TSV (tab-separated) from Excel/Numbers → markdown table
        // Must run BEFORE PDF/image checks: Excel/Numbers put PDF+PNG+TSV+HTML on the
        // clipboard simultaneously. Prefer tabular data so pasted cells round-trip as tables.
        let tsvType = NSPasteboard.PasteboardType(rawValue: "public.utf8-tab-separated-values-text")
        if let tsvData = NSPasteboard.general.data(forType: tsvType),
           let tsv = String(data: tsvData, encoding: .utf8),
           let markdown = Self.tsvToMarkdownTable(tsv) {
            breakUndoCoalescing()
            insertText(NSAttributedString(string: markdown), replacementRange: selectedRange())
            breakUndoCoalescing()
            if NotesTextProcessor.hideSyntax { renderTables() }
            return
        }

        // HTML with <table> → markdown table (also before PDF/image for same reason)
        if let htmlData = NSPasteboard.general.data(forType: .html),
           let html = String(data: htmlData, encoding: .utf8),
           let markdown = Self.htmlTableToMarkdown(html) {
            breakUndoCoalescing()
            insertText(NSAttributedString(string: markdown), replacementRange: selectedRange())
            breakUndoCoalescing()
            if NotesTextProcessor.hideSyntax { renderTables() }
            return
        }

        if let pdfData = NSPasteboard.general.data(forType: .pdf)
            ?? NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(rawValue: "com.adobe.pdf")),
           pdfData.isPDF {
            let preferredName = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "document.pdf"
            let name = preferredName.hasSuffix(".pdf") ? preferredName : "document.pdf"

            // Block-model path: save PDF to disk, insert via block model so
            // PDFAttachmentProcessor renders it as an inline PDFKit viewer.
            if documentProjection != nil {
                guard let (relPath, _) = note.save(data: pdfData, preferredName: name) else {
                    return
                }
                let encoded = relPath.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? relPath
                let alt = (name as NSString).deletingPathExtension
                breakUndoCoalescing()
                if insertImageViaBlockModel(alt: alt, destination: encoded) {
                    breakUndoCoalescing()
                    return
                }
                breakUndoCoalescing()
                // Fall through to thumbnail path if block-model insert fails.
            }

            if saveFileWithThumbnail(data: pdfData, preferredName: name, in: note) {
                return
            }
        }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = NSPasteboard.general.data(forType: type) {
                // Block-model WYSIWYG path: save the image to disk, then
                // insert a native `.image` inline via EditingOps.insertImage.
                // The renderer emits a placeholder attachment and
                // ImageAttachmentHydrator loads the real bytes async.
                if documentProjection != nil {
                    let ext = (type == .png) ? "png" : "tiff"
                    let preferredName = "\(UUID().uuidString.lowercased()).\(ext)"
                    guard let (relPath, _) = note.save(data: data, preferredName: preferredName) else {
                        continue
                    }
                    let encoded = relPath.addingPercentEncoding(
                        withAllowedCharacters: .urlPathAllowed
                    ) ?? relPath
                    breakUndoCoalescing()
                    if insertImageViaBlockModel(alt: "", destination: encoded) {
                        breakUndoCoalescing()
                        return
                    }
                    breakUndoCoalescing()
                    // Fall through to source-mode fallback on failure.
                }

                // Source-mode fallback: attachment with deferred save.
                guard let attributed = NSMutableAttributedString.build(data: data) else { continue }

                breakUndoCoalescing()
                insertText(attributed, replacementRange: selectedRange())
                breakUndoCoalescing()

                return
            }
        }

        if let clipboard = NSPasteboard.general.string(forType: .string),
           NSPasteboard.general.string(forType: .fileURL) == nil {
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
        } else if let clipboard = NSPasteboard.general.string(forType: .string),
                  NSPasteboard.general.string(forType: .fileURL) == nil {
            plainText = clipboard
        } else if let url = NSPasteboard.general.string(forType: .fileURL) {
            plainText = url
        }

        if let plainText = plainText {
            self.breakUndoCoalescing()
            self.insertText(plainText, replacementRange: currentRange)
            self.breakUndoCoalescing()
            return
        }

        paste(sender)
    }

    override func cut(_ sender: Any?) {
        guard nil != self.note else {
            super.cut(sender)
            return
        }

        if self.selectedRange.length == 0,
           let paragraphRange = self.getParagraphRange(),
           let paragraph = attributedSubstring(forProposedRange: paragraphRange, actualRange: nil) {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(paragraph.string.trim().removeLastNewLine(), forType: .string)

            // Route through block model if active to keep Document in sync.
            if documentProjection != nil {
                _ = handleEditViaBlockModel(in: paragraphRange, replacementString: "")
            } else {
                insertText(String(), replacementRange: paragraphRange)
            }
            return
        }

        // For selections, copy to clipboard then delete via block model.
        if documentProjection != nil, selectedRange().length > 0 {
            let range = selectedRange()
            if let text = attributedSubstring(forProposedRange: range, actualRange: nil) {
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([NSPasteboard.attributed, .string], owner: nil)
                if let rtfd = try? text.data(from: NSRange(location: 0, length: text.length),
                                             documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
                    pasteboard.setData(rtfd, forType: NSPasteboard.attributed)
                }
                pasteboard.setString(text.string, forType: .string)
            }
            _ = handleEditViaBlockModel(in: range, replacementString: "")
            return
        }

        super.cut(sender)
    }

    @IBAction func insertFileOrImage(_ sender: Any) {
        guard let note = self.note, isEditable else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = true
        panel.begin { result in
            if result == .OK {
                let urls = panel.urls

                for url in urls {
                    if self.saveFile(url: url, in: note), urls.count > 1 {
                        self.insertNewline(nil)
                    }
                }

                if let vc = ViewController.shared() {
                    vc.notesTableView.reloadRow(note: note)
                }
            }
        }
    }

    // MARK: - Table Paste Helpers

    /// Convert tab-separated text to a markdown table.
    static func tsvToMarkdownTable(_ tsv: String) -> String? {
        let lines = tsv.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 1 else { return nil }

        let rows = lines.map { $0.components(separatedBy: "\t") }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount >= 1 else { return nil }

        // Pad rows to uniform column count
        let padded = rows.map { row -> [String] in
            row + Array(repeating: "", count: max(0, colCount - row.count))
        }

        var result = ""
        // Header row
        result += "| " + padded[0].joined(separator: " | ") + " |\n"
        // Separator
        result += "| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |\n"
        // Data rows
        for row in padded.dropFirst() {
            result += "| " + row.joined(separator: " | ") + " |\n"
        }
        return result
    }

    /// Extract the first <table> from HTML and convert to markdown table.
    static func htmlTableToMarkdown(_ html: String) -> String? {
        guard let tableStart = html.range(of: "<table", options: .caseInsensitive),
              let tableEnd = html.range(of: "</table>", options: .caseInsensitive, range: tableStart.lowerBound..<html.endIndex) else {
            return nil
        }

        let tableHTML = String(html[tableStart.lowerBound..<tableEnd.upperBound])

        // Extract rows
        var rows: [[String]] = []
        var searchRange = tableHTML.startIndex..<tableHTML.endIndex

        while let trStart = tableHTML.range(of: "<tr", options: .caseInsensitive, range: searchRange),
              let trEnd = tableHTML.range(of: "</tr>", options: .caseInsensitive, range: trStart.lowerBound..<tableHTML.endIndex) {
            let rowHTML = String(tableHTML[trStart.lowerBound..<trEnd.upperBound])
            let cells = Self.extractHTMLCells(from: rowHTML)
            if !cells.isEmpty {
                rows.append(cells)
            }
            searchRange = trEnd.upperBound..<tableHTML.endIndex
        }

        guard rows.count >= 1 else { return nil }
        let colCount = rows.map(\.count).max() ?? 0
        guard colCount >= 1 else { return nil }

        let padded = rows.map { row -> [String] in
            row + Array(repeating: "", count: max(0, colCount - row.count))
        }

        var result = ""
        result += "| " + padded[0].joined(separator: " | ") + " |\n"
        result += "| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |\n"
        for row in padded.dropFirst() {
            result += "| " + row.joined(separator: " | ") + " |\n"
        }
        return result
    }

    /// Extract cell text from a <tr> element (handles both <th> and <td>).
    private static func extractHTMLCells(from rowHTML: String) -> [String] {
        var cells: [String] = []
        let pattern = try! NSRegularExpression(pattern: "<t[hd][^>]*>(.*?)</t[hd]>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        let matches = pattern.matches(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML))
        for match in matches {
            if let range = Range(match.range(at: 1), in: rowHTML) {
                let cellHTML = String(rowHTML[range])
                // Strip remaining HTML tags and decode basic entities
                let stripped = cellHTML
                    .replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(stripped)
            }
        }
        return cells
    }

    func deleteUnusedImages(checkRange: NSRange) {
        guard let storage = textStorage, self.note != nil else { return }

        storage.enumerateAttribute(.attachment, in: checkRange) { _, range, _ in
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
}
