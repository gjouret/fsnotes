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
            
            guard let undoManager = self.undoManager else { return }
            undoManager.beginUndoGrouping()
            
            if self.shouldChangeText(in: replacementRange, replacementString: title) {
                textStorage.replaceCharacters(in: replacementRange, with: title)
                self.didChangeText()
                
                self.setSelectedRange(NSRange(location: replacementRange.location + title.count, length: 0))
            }
            
            undoManager.endUndoGrouping()
            undoManager.setActionName("Insert Note Reference")
        }
        
        return true
    }

    public func handleURLs(_ pasteboard: NSPasteboard, note: Note, replacementRange: NSRange) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return false }

        note.save(attributed: attributedStringForSaving())

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
            
            guard let undoManager = self.undoManager,
                  let textStorage = self.textStorage else {
                
                self.insertText(final, replacementRange: replacementRange)
                self.setSelectedRange(
                    NSRange(location: replacementRange.location + final.length, length: 0)
                )
                self.viewDelegate?.notesTableView.reloadRow(note: note)
                return
            }
            
            undoManager.beginUndoGrouping()
            
            if self.shouldChangeText(in: replacementRange, replacementString: final.string) {
                textStorage.replaceCharacters(in: replacementRange, with: final)
                self.didChangeText()
                
                self.setSelectedRange(
                    NSRange(location: replacementRange.location + final.length, length: 0)
                )
            }
            
            undoManager.endUndoGrouping()
            undoManager.setActionName("Insert URLs")
            
            self.viewDelegate?.notesTableView.reloadRow(note: note)
        }

        return true
    }

    func saveFile(url: URL, in note: Note) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let preferredName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        if EditTextView.imageExtensions.contains(ext) || data.getFileType() != .unknown {
            guard let attributed = NSMutableAttributedString.build(data: data, preferredName: preferredName) else { return false }
            breakUndoCoalescing()
            insertText(attributed, replacementRange: selectedRange())
            breakUndoCoalescing()
            return true
        }

        return saveFileWithThumbnail(data: data, preferredName: preferredName, in: note)
    }

    func saveFileWithThumbnail(data: Data, preferredName: String, in note: Note) -> Bool {
        guard let (fileRelPath, fileURL) = note.save(data: data, preferredName: preferredName) else { return false }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 480, height: 480),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )

        let capturedNote = note
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            DispatchQueue.main.async {
                guard let self = self, self.note === capturedNote else { return }
                self.insertThumbnailCard(
                    thumbnail: thumbnail,
                    fileRelPath: fileRelPath,
                    preferredName: preferredName,
                    note: capturedNote
                )
            }
        }

        return true
    }

    private func insertThumbnailCard(
        thumbnail: QLThumbnailRepresentation?,
        fileRelPath: String,
        preferredName: String,
        note: Note
    ) {
        let encodedFilePath = fileRelPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileRelPath
        let displayName = preferredName

        let markdown: String

        if let cgImage = thumbnail?.cgImage {
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            if let pngData = nsImage.PNGRepresentation {
                let thumbName = (preferredName as NSString).deletingPathExtension + "_thumb.png"
                markdown = buildThumbnailCardMarkdown(
                    note: note,
                    imageData: pngData,
                    preferredName: thumbName,
                    imageLabel: thumbName,
                    cardTitle: "Thumbnail",
                    displayName: displayName,
                    encodedFilePath: encodedFilePath
                ) ?? "\n[\(displayName)](\(encodedFilePath))\n"
            } else {
                markdown = "\n[\(displayName)](\(encodedFilePath))\n"
            }
        } else {
            let ext = (preferredName as NSString).pathExtension
            let fileIcon = NSWorkspace.shared.icon(forFileType: ext)
            fileIcon.size = NSSize(width: 128, height: 128)
            if let pngData = fileIcon.PNGRepresentation {
                let iconName = (preferredName as NSString).deletingPathExtension + "_icon.png"
                markdown = buildThumbnailCardMarkdown(
                    note: note,
                    imageData: pngData,
                    preferredName: iconName,
                    imageLabel: iconName,
                    cardTitle: "Attachment",
                    displayName: displayName,
                    encodedFilePath: encodedFilePath
                ) ?? "\n[\(displayName)](\(encodedFilePath))\n"
            } else {
                markdown = "\n[\(displayName)](\(encodedFilePath))\n"
            }
        }

        breakUndoCoalescing()
        insertText(NSMutableAttributedString(string: markdown), replacementRange: selectedRange())
        breakUndoCoalescing()

        note.content = NSMutableAttributedString(attributedString: attributedStringForSaving())
        _ = note.save()
        note.load()
        viewDelegate?.refillEditArea(force: true)
    }

    private func buildThumbnailCardMarkdown(
        note: Note,
        imageData: Data,
        preferredName: String,
        imageLabel: String,
        cardTitle: String,
        displayName: String,
        encodedFilePath: String
    ) -> String? {
        guard let (imageRelPath, imageURL) = note.save(data: imageData, preferredName: preferredName) else {
            return nil
        }

        let encodedImagePath = imageRelPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? imageRelPath
        if note.imageUrl != nil {
            note.imageUrl?.append(imageURL)
        } else {
            note.imageUrl = [imageURL]
        }

        return "\n| \(cardTitle) |\n|:---:|\n| ![\(imageLabel)](\(encodedImagePath)) |\n| [\(displayName)](\(encodedFilePath)) |\n"
    }
}
