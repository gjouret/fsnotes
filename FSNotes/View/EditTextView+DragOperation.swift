//
//  EditTextView+DragOperation.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 15.10.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa
import QuickLookThumbnailing

extension EditTextView
{
    /// Image file extensions that should be pasted directly inline.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "webp", "heic", "heif", "svg", "bmp", "ico"
    ]

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let note = self.note, let storage = textStorage else { return false }

        let pasteboard = sender.draggingPasteboard
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let caretLocation = characterIndexForInsertion(at: dropPoint)
        let replacementRange = NSRange(location: caretLocation, length: 0)

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
            if handled {
                return true
            }
        }

        if handleAttributedText(pasteboard, note: note, storage: storage, replacementRange: replacementRange) { return true }
        if handleNoteReference(pasteboard, note: note, replacementRange: replacementRange) { return true }
        if handleURLs(pasteboard, note: note, replacementRange: replacementRange) { return true }

        return super.performDragOperation(sender)
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

    func fetchDataFromURL(url: URL, completion: @escaping (Data?, Error?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error {
                completion(nil, error)
                return
            }

            completion(data, nil)
        }.resume()
    }

    func getHTMLTitle(from data: Data) -> String? {
        guard let htmlString = String(data: data, encoding: .utf8) else {
            return nil
        }

        return extractTitle(from: htmlString)
    }

    public func handleAttributedText(_ pasteboard: NSPasteboard, note: Note, storage: NSTextStorage, replacementRange: NSRange) -> Bool {

        let locationDiff = selectedRange().location > replacementRange.location
            ? replacementRange.location
            : replacementRange.location - selectedRange().length

        let insertRange = NSRange(location: locationDiff, length: 0)
        let removeRange = selectedRange()

        // drag
        insertText("", replacementRange: removeRange)

        guard let data = pasteboard.data(forType: NSPasteboard.attributed),
              let attributedString = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSAttributedString else { return false }

        // drop
        insertText(attributedString, replacementRange: insertRange)

        // select
        let selectedRange = NSRange(location: locationDiff, length: attributedString.length)
        setSelectedRange(selectedRange)

        return true
    }

    public func handleNoteReference(_ pasteboard: NSPasteboard, note: Note, replacementRange: NSRange) -> Bool {
        guard
            let archivedData = pasteboard.data(forType: NSPasteboard.note),
            let urls = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSURL.self], from: archivedData) as? [URL],
            let url = urls.first,
            let draggableNote = Storage.shared().getBy(url: url),
            self.textStorage != nil
        else { return false }

        let title = "[[\(draggableNote.title)]]"

        DispatchQueue.main.async {
            self.window?.makeFirstResponder(self)

            // Phase 5f follow-up: route the wiki-link insertion through
            // `handleEditViaBlockModel` — the sanctioned 5a write path.
            // `applyEditResultWithUndo` handles undo registration (no
            // `shouldChangeText` / `didChangeText` pairing needed). In
            // source mode `documentProjection` is nil so the block-model
            // path returns false; fall back to AppKit's `insertText`,
            // which mutates storage through the source-mode branch
            // (`sourceRendererActive=true`) — that branch is explicitly
            // exempt from the Phase 5a assertion and is NOT a bypass.
            if self.handleEditViaBlockModel(in: replacementRange, replacementString: title) {
                self.setSelectedRange(NSRange(location: replacementRange.location + title.count, length: 0))
            } else {
                self.insertText(title, replacementRange: replacementRange)
                self.setSelectedRange(NSRange(location: replacementRange.location + title.count, length: 0))
            }

            self.undoManager?.setActionName("Insert Note Reference")
        }

        return true
    }

    /// Build the markdown representation of a dropped URL. Web URLs
    /// (`isWebURL == true`) render as `[title](absoluteString)` inline
    /// links; local file paths render as `![title](path)` image syntax
    /// — matching the serialized form produced by
    /// `NSMutableAttributedString.unloadImagesAndFiles()` at save time,
    /// so the block-model parser resolves it to a `.image` inline on
    /// the next re-parse pass.
    ///
    /// This helper is pure on its inputs so the markdown-construction
    /// logic can be unit-tested without the async URL-fetch dance
    /// `handleURLs` performs at runtime.
    static func markdownForDroppedURL(isWebURL: Bool, webTitle: String?, webURLString: String?, filePath: String?) -> String? {
        if isWebURL, let webURLString = webURLString {
            let title = webTitle ?? (URL(string: webURLString)?.lastPathComponent ?? webURLString)
            return "[\(title)](\(webURLString))"
        }
        if let filePath = filePath {
            return "![](\(filePath))"
        }
        return nil
    }

    public func handleURLs(_ pasteboard: NSPasteboard, note: Note, replacementRange: NSRange) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return false }

        save()

        let group = DispatchGroup()
        let total = urls.count
        var results = Array<String?>(repeating: nil, count: total)

        for (index, url) in urls.enumerated() {
            group.enter()
            fetchDataFromURL(url: url) { data, error in
                defer { group.leave() }
                guard let data = data, error == nil else { return }

                if url.isWebURL {
                    let title = self.getHTMLTitle(from: data) ?? url.lastPathComponent
                    results[index] = EditTextView.markdownForDroppedURL(
                        isWebURL: true,
                        webTitle: title,
                        webURLString: url.absoluteString,
                        filePath: nil
                    )
                } else if let filePath = ImagesProcessor.writeFile(data: data, url: url, note: note) {
                    // Image-syntax markdown matches the serialized form
                    // `NSMutableAttributedString.unloadImagesAndFiles`
                    // produces at save time; the parser resolves it to
                    // a `.image` inline on the next re-parse pass.
                    results[index] = EditTextView.markdownForDroppedURL(
                        isWebURL: false,
                        webTitle: nil,
                        webURLString: nil,
                        filePath: filePath
                    )
                }
            }
        }

        group.notify(queue: .main) {
            let finalMarkdown = results.compactMap { $0 }.joined(separator: "\n\n")

            self.window?.makeFirstResponder(self)

            // Phase 5f follow-up: route the dropped-URL insertion through
            // `handleEditViaBlockModel` — the sanctioned 5a write path.
            // `applyEditResultWithUndo` registers undo (no
            // `shouldChangeText` / `didChangeText` pairing needed). The
            // RC4 `reparseCurrentBlockInlines` step inside
            // `handleEditViaBlockModel` re-parses the inserted markdown
            // so `[title](url)` becomes a `.link` inline and
            // `![](path)` becomes a `.image` inline — the same visual
            // result the old direct-storage path produced, now with
            // `Document ↔ NSTextContentStorage` in sync.
            if self.handleEditViaBlockModel(in: replacementRange, replacementString: finalMarkdown) {
                self.setSelectedRange(
                    NSRange(location: replacementRange.location + finalMarkdown.count, length: 0)
                )
            } else {
                // Source mode (or block-model unavailable): AppKit's
                // `insertText` mutates storage through the source-mode
                // branch (`sourceRendererActive=true`), which is
                // explicitly exempt from the Phase 5a assertion.
                self.insertText(finalMarkdown, replacementRange: replacementRange)
                self.setSelectedRange(
                    NSRange(location: replacementRange.location + finalMarkdown.count, length: 0)
                )
            }

            self.undoManager?.setActionName("Insert URLs")

            self.viewDelegate?.notesTableView.reloadRow(note: note)
        }

        return true
    }

    func saveFile(url: URL, in note: Note) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let preferredName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Block-model WYSIWYG path: save the file to disk and insert
        // a native `.image` inline via the block model. Post-processors
        // (ImageAttachmentHydrator, PDFAttachmentProcessor,
        // QuickLookAttachmentProcessor) handle display for each type.
        // Any file with an extension is accepted — QuickLook previews
        // everything macOS can render (.numbers, .pages, .docx, etc.).
        if documentProjection != nil, !ext.isEmpty {
            guard let (relPath, _) = note.save(data: data, preferredName: preferredName) else {
                return false
            }
            let encoded = relPath.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? relPath
            let alt = (preferredName as NSString).deletingPathExtension
            breakUndoCoalescing()
            if insertImageViaBlockModel(alt: alt, destination: encoded) {
                breakUndoCoalescing()
                return true
            }
            breakUndoCoalescing()
            // Fall through to legacy path if the block-model insert fails.
        }

        // Legacy source-mode path for images/PDFs
        let isImageOrPDF = EditTextView.imageExtensions.contains(ext)
            || InlineRenderer.renderablePDFExtensions.contains(ext)
            || data.getFileType() != .unknown
        if isImageOrPDF {
            guard let attributed = NSMutableAttributedString.build(data: data, preferredName: preferredName) else { return false }
            breakUndoCoalescing()
            insertText(attributed, replacementRange: selectedRange())
            breakUndoCoalescing()
            return true
        }

        return false
    }

}
