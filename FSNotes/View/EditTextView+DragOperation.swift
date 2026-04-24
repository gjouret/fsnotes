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
            let textStorage = self.textStorage
        else { return false }
        
        let title = "[[\(draggableNote.title)]]"
        
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(self)
            
            // Phase 5f: grouping retired — the `shouldChangeText` →
            // `applyEditResultWithUndo` flow journals one entry per
            // call. Note that `textStorage.replaceCharacters` here is
            // a direct storage write that bypasses the block-model
            // pipeline; that's a pre-existing 5a bypass tracked for a
            // future slice (brief §9).
            if self.shouldChangeText(in: replacementRange, replacementString: title) {
                StorageWriteGuard.performingLegacyStorageWrite {
                    textStorage.replaceCharacters(in: replacementRange, with: title)
                }
                self.didChangeText()

                self.setSelectedRange(NSRange(location: replacementRange.location + title.count, length: 0))
            }

            self.undoManager?.setActionName("Insert Note Reference")
        }
        
        return true
    }

    public func handleURLs(_ pasteboard: NSPasteboard, note: Note, replacementRange: NSRange) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return false }

        save()

        let group = DispatchGroup()
        let total = urls.count
        var results = Array<NSAttributedString?>(repeating: nil, count: total)

        for (index, url) in urls.enumerated() {
            group.enter()
            fetchDataFromURL(url: url) { data, error in
                defer { group.leave() }
                guard let data = data, error == nil else { return }
                
                if url.isWebURL {
                    let title = self.getHTMLTitle(from: data) ?? url.lastPathComponent
                    let text = "[\(title)](\(url.absoluteString))"
                    results[index] = NSAttributedString(string: text)
                } else if let filePath = ImagesProcessor.writeFile(data: data, url: url, note: note),
                          let fileURL = note.getAttachmentFileUrl(
                            name: filePath.removingPercentEncoding ?? filePath
                          ) {
                    let attributed = NSMutableAttributedString(
                        url: fileURL,
                        title: "",
                        path: filePath
                    )
                    results[index] = attributed
                }
            }
        }
        
        group.notify(queue: .main) {
            let final = NSMutableAttributedString()
            for i in 0..<total {
                guard let part = results[i] else { continue }
                final.append(part)
                if i < total - 1 {
                    final.append(NSAttributedString(string: "\n\n"))
                }
            }
            
            self.window?.makeFirstResponder(self)
            
            guard let textStorage = self.textStorage else {

                self.insertText(final, replacementRange: replacementRange)
                self.setSelectedRange(
                    NSRange(location: replacementRange.location + final.length, length: 0)
                )
                self.viewDelegate?.notesTableView.reloadRow(note: note)
                return
            }

            // Phase 5f: grouping retired (see "Insert Note Reference"
            // above). Direct storage write is a pre-existing 5a bypass.
            if self.shouldChangeText(in: replacementRange, replacementString: final.string) {
                StorageWriteGuard.performingLegacyStorageWrite {
                    textStorage.replaceCharacters(in: replacementRange, with: final)
                }
                self.didChangeText()

                self.setSelectedRange(
                    NSRange(location: replacementRange.location + final.length, length: 0)
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
