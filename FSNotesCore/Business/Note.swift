//
//  NoteMO+CoreDataClass.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 9/24/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//
//

import Foundation
import RNCryptor
import SSZipArchive
import LocalAuthentication

public class Note: NSObject  {
    @objc var title: String = ""
    var project: Project
    var container: NoteContainer = .none
    var type: NoteType = .Markdown
    var url: URL

    /// Storage reference used for note-level persistence operations.
    lazy var sharedStorage: Storage = Storage.shared()

    var content: NSMutableAttributedString = NSMutableAttributedString()

    /// Cached parsed Document for the block-model pipeline. Invalidated
    /// on any content mutation (save, load, reload). Lazily populated
    /// by `fillViaBlockModel()` on first access after invalidation.
    public var cachedDocument: Document?

    var creationDate: Date? = Date()

    let dateFormatter = DateFormatter()
    let undoManager = UndoManager()

    public var tags = [String]()
    public var originalExtension: String?
    
    public var isBlocked: Bool = false

    /*
     Filename with extension ie "example.textbundle"
     */
    public var name = String()

    /*
     Filename "example"
     */
    public var fileName = String()
    public var preview: String = ""

    public var isPinned: Bool = false
    public var modifiedLocalAt = Date()

    public var imageUrl: [URL]?
    public var attachments: [URL]?
    public var isParsed = false

    var decryptedTemporarySrc: URL?

    public var isLoaded = false
    public var isLoadedFromCache = false

    public var password: String?

    public var cacheLock: Bool = false
    public var cacheHash: UInt64?
    
    public var uploadPath: String?
    public var apiId: String?
    
    private var selectedRange: NSRange?
    
    public var contentOffset = CGPoint()
    public var contentOffsetWeb = CGPoint()
    
    public var scrollPosition: Int?
    public var scrollOffset: CGFloat?
    public var cursorScrollFraction: CGFloat = 0

    public var codeBlockRangesCache: [NSRange]?

    // Load exist
    
    init(url: URL, with project: Project, modified: Date? = nil, created: Date? = nil) {
        if let modified = modified {
            modifiedLocalAt = modified
        }
        
        if let created = created {
            creationDate = created
        }

        self.url = url.standardized
        self.project = project
        super.init()

        self.parseURL(loadProject: false)
    }
    
    // Make new
    
    init(name: String? = nil, project: Project? = nil, type: NoteType? = nil, cont: NoteContainer? = nil) {
        let project = project ?? Storage.shared().getDefault()!
        
        let name = name ?? String()

        self.project = project
        self.name = name
        
        self.container = cont ?? UserDefaultsManagement.fileContainer
        self.type = type ?? UserDefaultsManagement.fileFormat
        
        let ext = container == .none
            ? self.type.getExtension(for: container)
            : "textbundle"
                
        url = NameHelper.getUniqueFileName(name: name, project: project, ext: ext)

        super.init()

        self.parseURL()
    }

    init(meta: NoteMeta, project: Project) {
        isLoadedFromCache = true
        
        if meta.title.count > 0 || (meta.imageUrl != nil && meta.imageUrl!.count > 0) {
            isParsed = true
        }
        
        url = meta.url
        attachments = meta.attachments
        imageUrl = meta.imageUrl
        title = meta.title
        preview = meta.preview
        modifiedLocalAt = meta.modificationDate
        creationDate = meta.creationDate
        isPinned = meta.pinned
        tags = meta.tags
        selectedRange = meta.selectedRange
        self.project = project

        super.init()

        parseURL(loadProject: false)
    }
    
    public func fileSize(atPath path: String) -> Int64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? Int64 {
                return fileSize
            }
        } catch {
            print("Error retrieving file size: \(error.localizedDescription)")
        }
        return nil
    }
    
    public func isValidForCaching() -> Bool {
        return isLoaded || title.count > 0 || isEncrypted() || imageUrl != nil
    }

    func getMeta() -> NoteMeta {
        let date = creationDate ?? Date()
        return NoteMeta(
            url: url,
            attachments: attachments,
            imageUrl: imageUrl,
            title: title,
            preview: preview,
            modificationDate: modifiedLocalAt,
            creationDate: date,
            pinned: isPinned,
            tags: tags, 
            selectedRange: selectedRange
        )
    }

    /// Important for decrypted temporary containers
    public func getURL() -> URL {
        if let url = self.decryptedTemporarySrc {
            return url
        }

        return self.url
    }
    
    public func loadProject() {
        let sharedStorage = sharedStorage
        
        if let project = sharedStorage.getProjectByNote(url: url) {
            self.project = project
        }
    }

    public func forceLoad(skipCreateDate: Bool = false, loadTags: Bool = true) {
        invalidateCache()
        load(tags: loadTags)

        if !skipCreateDate {
            loadCreationDate()
        }
        
        loadModifiedLocalAt()
    }

    public func setCreationDate(string: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let userDate = formatter.date(from: string)
        let attributes = [FileAttributeKey.creationDate: userDate]

        do {
            try FileManager.default.setAttributes(attributes as [FileAttributeKey : Any], ofItemAtPath: url.path)

            creationDate = userDate
            
            if isTextBundle() {
                writeTextBundleInfo(url: getURL())
            }
            return true
        } catch {
            print(error)
            return false
        }
    }

    public func setCreationDate(date: Date) -> Bool {
        let attributes = [FileAttributeKey.creationDate: date]

        do {
            try FileManager.default.setAttributes(attributes as [FileAttributeKey : Any], ofItemAtPath: url.path)

            creationDate = date
            
            if isTextBundle() {
                writeTextBundleInfo(url: getURL())
            }
            
            return true
        } catch {
            return false
        }
    }
    
    private func readTitleAndPreview() -> (String?, String?) {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            print("Can not open the file.")
            return (nil, nil)
        }
        defer { fileHandle.closeFile() }
        
        var saveChars = false
        var title = String()
        var preview = String()
        
        while let char = String(data: fileHandle.readData(ofLength: 1), encoding: .utf8) {
            if char == "\n" {
                if saveChars {
                    preview += " "
                } else {
                    saveChars = true
                }
                continue
            }
            
            if saveChars {
                preview += char
                if preview.count >= 100 {
                    break
                }
            } else {
                title += char
            }
        }
        
        preview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (title, preview)
    }


    public func uiLoad() {
        if let size = fileSize(atPath: self.url.path), size > 100000 {
            loadFileName()
            
            let data = readTitleAndPreview()
            if let title = data.0 {
                self.title = title.trimMDSyntax()
            }
            
            if let preview = data.1 {
                self.preview = preview.trimMDSyntax()
            }
            
            return
        }
        
        load(tags: true)
    }
    
    func load(tags: Bool = true) {
        #if SHARE_EXT
            return
        #endif

        if let attributedString = getContent() {
            cacheHash = nil
            cachedDocument = nil  // Invalidate — content loaded from disk
            content = attributedString.loadAttachments(self)
        }

        loadFileName()
        loadPreviewInfo()
        
        if !isTrash() && tags {
            loadTags()
        }

        isLoaded = true
    }

    func reload() -> Bool {
        guard let modifiedAt = getFileModifiedDate() else { return false }

        if (modifiedAt != modifiedLocalAt) {
            if let attributedString = getContent() {
                cacheHash = nil
                cachedDocument = nil  // Invalidate — content reloaded
                content = attributedString.loadAttachments(self)
                cacheCodeBlocks()
            }

            loadModifiedLocalAt()
            return true
        }
        
        return false
    }

    public func forceReload() {
        if container != .encryptedTextPack, let attributedString = getContent() {
            cacheHash = nil
            content = attributedString.loadAttachments(self)
        }
    }
    
    public func loadModifiedLocalAt() {
        modifiedLocalAt = getFileModifiedDate() ?? Date.distantPast
    }

    public func loadCreationDate() {
        creationDate = getFileCreationDate() ?? Date.distantPast
    }
    
    public func isTextBundle() -> Bool {
        return (container == .textBundle || container == .textBundleV2)
    }

    public func isFullLoadedTextBundle() -> Bool {
        return getContentFileURL() != nil
    }
    
    public func getExtensionForContainer() -> String {
        return type.getExtension(for: container)
    }

    public func getFileModifiedDate() -> Date? {
        let url = getURL()

        if isUnlocked() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: self.url.path)
                return attr[FileAttributeKey.modificationDate] as? Date
            } catch {/*_*/}
        }

        if UserDefaultsManagement.useTextBundleMetaToStoreDates && isTextBundle() {
            let textBundleURL = url
            let json = textBundleURL.appendingPathComponent("info.json")

            if let jsonData = try? Data(contentsOf: json),
               let info = try? JSONDecoder().decode(TextBundleInfo.self, from: jsonData),
               let modified = info.modified {

                return Date(timeIntervalSince1970: TimeInterval(modified))
            }
        }

        if let contentUrl = getContentFileURL() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: contentUrl.path)

                return attr[FileAttributeKey.modificationDate] as? Date
            } catch {
                NSLog("Note modification date load error: \(error.localizedDescription)")
            }
        }

        return
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
    }

    public func getFileCreationDate() -> Date? {
        let url = getURL()

        if isUnlocked() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: self.url.path)
                return attr[FileAttributeKey.creationDate] as? Date
            } catch {/*_*/}
        }

        if UserDefaultsManagement.useTextBundleMetaToStoreDates && isTextBundle() {
            let textBundleURL = url
            let json = textBundleURL.appendingPathComponent("info.json")

            if let jsonData = try? Data(contentsOf: json),
               let info = try? JSONDecoder().decode(TextBundleInfo.self, from: jsonData),
               let created = info.created {
                
                return Date(timeIntervalSince1970: TimeInterval(created))
            }
        }

        if let contentUrl = getContentFileURL() {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: contentUrl.path)

                return attr[FileAttributeKey.creationDate] as? Date
            } catch {
                NSLog("Note creation date load error: \(error.localizedDescription)")
            }
        }

        return
            (try? url.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate
    }
    
    // File operations (move, rename, delete, moveImages) extracted to Note+FileOps.swift
        
    public func getPreviewLabel(with text: String? = nil) -> String {
        var preview: String = ""
        let content = text ?? self.content.string
        let length = text?.count ?? self.content.string.count

        if length > 250 {
            if text == nil {
                let startIndex = content.index((content.startIndex), offsetBy: 0)
                let endIndex = content.index((content.startIndex), offsetBy: 250)
                preview = String(content[startIndex...endIndex])
            } else {
                preview = String(content.prefix(250))
            }
        } else {
            preview = content
        }
        
        preview = preview.replacingOccurrences(of: "\n", with: " ")
        if (
            UserDefaultsManagement.horizontalOrientation
                && content.hasPrefix(" – ") == false
            ) {
            preview = " – " + preview
        }

        preview = preview.condenseWhitespace()

        if preview.starts(with: "![") {
            return ""
        }

        return preview
    }
    
    @objc func getDateForLabel() -> String {
        guard !UserDefaultsManagement.hideDate else { return String() }

        let date = self.project.storage.getSortByState() == .creationDate
            ? creationDate
            : modifiedLocalAt

        guard let date = date else { return String() }

        if NSCalendar.current.isDateInToday(date) {
            return dateFormatter.formatTimeForDisplay(date)
        } else {
            return dateFormatter.formatDateForDisplay(date)
        }
    }

    @objc func getCreationDateForLabel() -> String? {
        guard let creationDate = self.creationDate else { return nil }
        guard !UserDefaultsManagement.hideDate else { return nil }

        let calendar = NSCalendar.current
        if calendar.isDateInToday(creationDate) {
            return dateFormatter.formatTimeForDisplay(creationDate)
        }
        else {
            return dateFormatter.formatDateForDisplay(creationDate)
        }
    }
    
    func getContent() -> NSMutableAttributedString? {
        guard container != .encryptedTextPack, let url = getContentFileURL() else { return nil }

        do {
            return try NSMutableAttributedString(url: url, options: [
                .documentType : NSAttributedString.DocumentType.plain,
                .characterEncoding : NSNumber(value: String.Encoding.utf8.rawValue)
            ], documentAttributes: nil)
        } catch {
            if let data = try? Data(contentsOf: url) {
                let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: nil, usedLossyConversion: nil)

                return try? NSMutableAttributedString(url: url, options: [
                    .documentType : NSAttributedString.DocumentType.plain,
                    .characterEncoding : NSNumber(value: encoding)
                ], documentAttributes: nil)
            }
        }
        
        return nil
    }
    
    func isMarkdown() -> Bool {
        return type == .Markdown
    }
    
    func addPin(cloudSave: Bool = true) {
        isPinned = true
        
        if cloudSave {
            sharedStorage.saveCloudPins()
        }
    }

    func removePin(cloudSave: Bool = true) {
        if isPinned {
            isPinned = false
            
            if cloudSave {
                sharedStorage.saveCloudPins()
            }
        }
    }
    
    func togglePin() {
        if !isPinned {
            addPin()
        } else {
            removePin()
        }
    }
    
    func cleanMetaData(content: String) -> String {
        var extractedTitle = String()
        var author = String()
        var date = String()
        
        if (content.hasPrefix("---\n")) {
            var list = content.components(separatedBy: "---")
            
            if (list.count > 2) {
                let headerList = list[1].components(separatedBy: "\n")
                for header in headerList {
                    if header.hasPrefix("title:") {
                        extractedTitle = header.replacingOccurrences(of: "title:", with: "").trim()
                        
                        if extractedTitle.hasPrefix("\"") && extractedTitle.hasSuffix("\""){
                            extractedTitle = String(extractedTitle.dropFirst(1))
                            extractedTitle = String(extractedTitle.dropLast(1))
                        }
                    }
                    
                    if header.hasPrefix("author:") {
                        author = header.replacingOccurrences(of: "author:", with: "").trim()
                        
                        if author.hasPrefix("\"") && author.hasSuffix("\""){
                            author = String(author.dropFirst(1))
                            author = String(author.dropLast(1))
                        }
                    }
                    
                    if header.hasPrefix("date:") {
                        date = header.replacingOccurrences(of: "date:", with: "").trim()
                        
                        if date.hasPrefix("\"") && date.hasSuffix("\""){
                            date = String(date.dropFirst(1))
                            date = String(date.dropLast(1))
                        }
                    }
                }
                
                list.removeSubrange(Range(0...1))
                
                var result = String()
                
                if (extractedTitle.count > 0) {
                    result = "<h1 class=\"no-border\">" + extractedTitle + "</h1>\n\n"
                }
                
                if (author.count > 0) {
                    result += "_" + author + "_\n\n"
                }
                
                if (date.count > 0) {
                    result += "_" + date + "_\n\n"
                }
                
                if result.count > 0 {
                    result += "<hr>\n\n"
                }
                
                result += list.joined(separator: "---")
                
                return result
            }
        }
        
        return content
    }
    
    func getPrettifiedContent() -> String {
        #if IOS_APP || os(OSX)
            let prepared = NoteSerializer.prepareForSave(NSMutableAttributedString(attributedString: self.content))
            let mutable = NotesTextProcessor.convertAppTags(in: prepared, codeBlockRanges: codeBlockRangesCache)
        let content = NotesTextProcessor.convertAppLinks(in: mutable, codeBlockRanges: codeBlockRangesCache)
            let cleaned = cleanMetaData(content: content.string)
            let result = Note.replaceHorizontalRulesOutsideCodeBlocks(cleaned)

            return result
        #else
            return cleanMetaData(content: self.content.string)
        #endif
    }

    /// Replace `\n---\n` with `\n<hr>\n` only outside fenced code blocks,
    /// so that `---` inside e.g. mermaid YAML frontmatter is preserved.
    private static func replaceHorizontalRulesOutsideCodeBlocks(_ text: String) -> String {
        let pattern = "(?<=\\n|\\A)```[^\\n]*\\n[\\s\\S]*?\\n```(?=\\n|\\Z)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.replacingOccurrences(of: "\n---\n", with: "\n<hr>\n")
        }

        let nsText = text as NSString
        let codeRanges = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { $0.range }

        var result = ""
        var currentIndex = 0

        for codeRange in codeRanges {
            let beforeRange = NSRange(location: currentIndex, length: codeRange.location - currentIndex)
            result += nsText.substring(with: beforeRange).replacingOccurrences(of: "\n---\n", with: "\n<hr>\n")
            result += nsText.substring(with: codeRange)
            currentIndex = codeRange.location + codeRange.length
        }

        let remainingRange = NSRange(location: currentIndex, length: nsText.length - currentIndex)
        result += nsText.substring(with: remainingRange).replacingOccurrences(of: "\n---\n", with: "\n<hr>\n")

        return result
    }

    public func overwrite(url: URL) {
        self.url = url

        parseURL()
    }

    func parseURL(loadProject: Bool = true) {
        if (url.pathComponents.count > 0) {
            container = .withExt(rawValue: url.pathExtension)
            name = url.lastPathComponent
            
            if isTextBundle() {
                type = .Markdown
                container = .textBundle

                let infoUrl = url.appendingPathComponent("info.json")

                if FileManager.default.fileExists(atPath: infoUrl.path) {
                    do {
                        let jsonData = try Data(contentsOf: infoUrl)
                        let info = try JSONDecoder().decode(TextBundleInfo.self, from: jsonData)

                        if info.version == 0x02 {
                            type = NoteType.withUTI(rawValue: info.type)
                            container = .textBundleV2
                            originalExtension = info.flatExtension

                            if UserDefaultsManagement.useTextBundleMetaToStoreDates {
                                if let created = info.created {
                                    creationDate = Date(timeIntervalSince1970: TimeInterval(created))
                                }

                                if let modified = info.modified {
                                    modifiedLocalAt = Date(timeIntervalSince1970: TimeInterval(modified))
                                }
                            }
                        }
                    } catch {
                        print("TB loading error \(error)")
                    }
                }
            }
            
            if container == .none {
                type = .withExt(rawValue: url.pathExtension)
            }
            
            loadTitle()
            loadFileName()
        }

        if loadProject {
            self.loadProject()
        }
    }

    func loadTitle() {
        if !project.settings.isFirstLineAsTitle() {
            title = url
                .deletingPathExtension()
                .pathComponents
                .last!
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "/", with: "")
        }
    }

    func loadFileName() {
        fileName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")
    }

    public func getFileName() -> String {
        return fileName
    }

    /// Per-note pending write operation. Cancelling this only affects THIS note's save.
    private var pendingWriteOperation: BlockOperation?

    public func save(attributed: NSAttributedString) {
        if container == .encryptedTextPack { return }

        guard let copy = attributed.copy() as? NSAttributedString else {
            return
        }

        modifiedLocalAt = Date()

        // Cancel only THIS note's pending save — not all notes' saves
        pendingWriteOperation?.cancel()

        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self] in
            guard let self = self, !operation.isCancelled else { return }

            let mutable = NSMutableAttributedString(attributedString: copy)
            self.save(content: mutable)

            if !operation.isCancelled {
                self.isBlocked = false
            }
        }

        pendingWriteOperation = operation
        sharedStorage.plainWriter.addOperation(operation)
    }

    /// Save raw markdown directly to disk, bypassing NoteSerializer.
    /// Used by the block-model pipeline which already produces clean
    /// markdown via MarkdownSerializer — no attachment unloading or
    /// rendered-block restoration needed.
    public func save(markdown: String) {
        // Update the in-memory content cache
        self.content = NSMutableAttributedString(string: markdown)
        self.cachedDocument = nil  // Invalidate — content changed

        // SAFETY: reject empty content from non-empty input
        if markdown.isEmpty {
            NSLog("SAVE BLOCKED: empty markdown for: \(title)")
            return
        }

        modifiedLocalAt = Date()

        let attrStr = NSAttributedString(string: markdown)
        if write(attributedString: attrStr) {
            sharedStorage.add(self)
        }

        // Reset isBlocked so the file system watcher can detect
        // external changes. (Source-mode save resets this in its
        // async BlockOperation; block-model save is synchronous.)
        isBlocked = false
    }

    public func save(content: NSMutableAttributedString) {
        self.content = content
        self.cachedDocument = nil  // Invalidate — content changed

        // Full serialization pipeline: bullet restore + rendered block restore + attachment unload
        let copy = NoteSerializer.prepareForSave(
            NSMutableAttributedString(attributedString: content)
        )

        // SAFETY: If serialization produced empty content from non-empty input, abort.
        // This catches bugs in the serialization pipeline that would wipe the file.
        if copy.length == 0 && content.length > 0 {
            NSLog("SAVE BLOCKED: serialization produced empty content from \(content.length)-char input for: \(title)")
            return
        }

        modifiedLocalAt = Date()

        if write(attributedString: copy) {
            sharedStorage.add(self)
        }
    }

    public func replace(tag: String, with string: String) {
        content.replaceTag(name: tag, with: string)
        _ = save()
    }

    public func delete(tag: String) {
        content.replaceTag(name: tag, with: "")
        _ = save()
    }
        
    public func save() -> Bool {
        let attributedString = NoteSerializer.prepareForSave(
            NSMutableAttributedString(attributedString: self.content)
        )
        return write(attributedString: attributedString)
    }

    private func write(attributedString: NSAttributedString) -> Bool {
        let url = getURL()
        let attributes = getFileAttributes()

        do {
            let fileWrapper = try getFileWrapper(attributedString: attributedString)

            if isTextBundle() {
                let jsonUrl = url.appendingPathComponent("info.json")
                let fileExist = FileManager.default.fileExists(atPath: jsonUrl.path)

                if !fileExist {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
                }

                if UserDefaultsManagement.useTextBundleMetaToStoreDates || !fileExist {
                    self.writeTextBundleInfo(url: url)
                }
            }

            let contentSrc: URL? = getContentFileURL()
            let dst = contentSrc ?? getContentSaveURL()

            var originalContentsURL: URL? = nil
            if let contentSrc = contentSrc {
                originalContentsURL = contentSrc
            }

            try fileWrapper.write(to: dst, options: .atomic, originalContentsURL: originalContentsURL)
            try FileManager.default.setAttributes(attributes, ofItemAtPath: dst.path)

            if decryptedTemporarySrc != nil {
                sharedStorage.ciphertextWriter.cancelAllOperations()
                sharedStorage.ciphertextWriter.addOperation { [self] in
                    guard self.sharedStorage.ciphertextWriter.operationCount == 1 else { return }
                    self.writeEncrypted()
                }
            }
        } catch {
            NSLog("SAVE ERROR (content preserved on disk): \(error)")
            return false
        }

        return true
    }

    private func getContentSaveURL() -> URL {
        let url = getURL()

        if isTextBundle() {
            let ext = getExtensionForContainer()
            return url.appendingPathComponent("text.\(ext)")
        }

        return url
    }

    public func getContentFileURL() -> URL? {
        var url = getURL()

        if isTextBundle() {
            let ext = getExtensionForContainer()
            url = url.appendingPathComponent("text.\(ext)")

            if !FileManager.default.fileExists(atPath: url.path) {
                url = url.deletingLastPathComponent()

                if let dirList = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                    let first = dirList.first(where: { $0.starts(with: "text.") })
                {
                    url = url.appendingPathComponent(first)

                    return url
                }

                return nil
            }

            return url
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        return nil
    }
    
    private func getTextBundleJsonInfo() -> String {
        var data = [
            "transient": "true",
            "type": "\"\(type.uti)\"",
            "creatorIdentifier": "\"co.fluder.fsnotes\"",
            "version": "2"
        ]

        if let originalExtension = originalExtension {
            data["flatExtension"] = "\"\(originalExtension)\""
        }

        if UserDefaultsManagement.useTextBundleMetaToStoreDates {
            let creationDate = self.creationDate ?? Date()
            let modificationDate = self.modifiedLocalAt

            data["created"] = "\(Int(creationDate.timeIntervalSince1970))"
            data["modified"] = "\(Int(modificationDate.timeIntervalSince1970))"
        }

        var result = [String]()

        for key in [
            "transient",
            "type",
            "creatorIdentifier",
            "version",
            "flatExtension",
            "created",
            "modified"
        ] {
            if let value = data[key] {
                result.append("    \"\(key)\" : \(value)")
            }
        }

        return "{\n" + result.joined(separator: ",\n") + "\n}"
    }

    private func getAssetsFileWrapper() -> FileWrapper {
        let wrapper = FileWrapper.init(directoryWithFileWrappers: [:])
        wrapper.preferredFilename = "assets"

        do {
            let assets = url.appendingPathComponent("assets")

            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: assets.path, isDirectory: &isDir) && isDir.boolValue {
                let files = try FileManager.default.contentsOfDirectory(atPath: assets.path)
                for file in files {
                    let fileData = try Data(contentsOf: assets.appendingPathComponent(file))
                    wrapper.addRegularFile(withContents: fileData, preferredFilename: file)
                }
            }
        } catch {
            print(error)
        }

        return wrapper
    }
    
    private func writeTextBundleInfo(url: URL) {
        let url = url.appendingPathComponent("info.json")
        let info = getTextBundleJsonInfo()

        try? info.write(to: url, atomically: true, encoding: String.Encoding.utf8)
    }
        
    func getFileAttributes() -> [FileAttributeKey: Any] {
        let url = getContentFileURL() ?? url
        var attributes: [FileAttributeKey: Any] = [:]
        
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {}

        attributes[.modificationDate] = modifiedLocalAt
        return attributes
    }
    
    func getFileWrapper(attributedString: NSAttributedString, forcePlain: Bool = false) throws -> FileWrapper {
        let range = NSRange(location: 0, length: attributedString.length)

        return try attributedString.fileWrapper(from: range, documentAttributes: [
            .documentType : NSAttributedString.DocumentType.plain,
            .characterEncoding : NSNumber(value: String.Encoding.utf8.rawValue)
        ])
    }
        
    func getTitleWithoutLabel() -> String {
        let title = url.deletingPathExtension().pathComponents.last!
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "/", with: "")

        if title.isValidUUID {
            return ""
        }

        return title
    }
    
    func isTrash() -> Bool {
        return project.isTrash
    }
    
    public func contains<S: StringProtocol>(terms: [S]) -> Bool {
        return name.localizedStandardContains(terms) || content.string.localizedStandardContains(terms)
    }

    public func loadTags() {
        if UserDefaultsManagement.inlineTags {
            _ = scanContentTags()
        }
    }
    
    public func scanContentTags() -> ([String], [String]) {
        var added = [String]()
        var removed = [String]()

        let matchingOptions = NSRegularExpression.MatchingOptions(rawValue: 0)
        let options: NSRegularExpression.Options = [
            .allowCommentsAndWhitespace,
            .anchorsMatchLines
        ]

        var tags = [String]()
        
        do {
            let range = NSRange(location: 0, length: content.string.count)
            let re = try NSRegularExpression(pattern: FSParser.tagsPattern, options: options)
            
            re.enumerateMatches(
                in: content.string,
                options: matchingOptions,
                range: range,
                using: { (result, flags, stop) -> Void in
                    
                    guard var range = result?.range(at: 1) else { return }
                    let cleanTag = content.mutableString.substring(with: range)
                    
                    range = NSRange(location: range.location - 1, length: range.length + 1)

                    if let codeBlockRangesCache = codeBlockRangesCache {
                        for codeRange in codeBlockRangesCache {
                            if NSIntersectionRange(codeRange, range).length > 0 {
                                return
                            }
                        }
                    }

                    let spanBlock = FSParser.getSpanCodeBlockRange(content: content, range: range)
                    
                    if spanBlock == nil && isValid(tag: cleanTag) {
                        
                        let parRange = content.mutableString.paragraphRange(for: range)
                        let par = content.mutableString.substring(with: parRange)
                        if par.starts(with: "    ") || par.starts(with: "\t") {
                            return
                        }
                        
                        if cleanTag.last == "/" {
                            tags.append(String(cleanTag.dropLast()))
                        } else {
                            tags.append(cleanTag)
                        }
                    }
                }
            )
        } catch {
            print("Tags parsing: \(error)")
        }

        if tags.contains("notags") {
            removed = self.tags

            self.tags.removeAll()
            return (added, removed)
        }

        for noteTag in self.tags {
            if !tags.contains(noteTag) {
                removed.append(noteTag)
            }
        }
        
        for tag in tags {
            if !self.tags.contains(tag) {
                added.append(tag)
            }
        }

        self.tags = tags

        return (added, removed)
    }

    private var excludeRanges = [NSRange]()

    public func isValid(tag: String) -> Bool {
        if tag.isNumber {
            return false
        }

        if tag.isHexColor() {
            return false
        }

        return true
    }
    
    public func getAttachmentFileUrl(name: String) -> URL? {
        if name.count == 0 {
            return nil
        }

        if name.starts(with: "http://") || name.starts(with: "https://") {
            return URL(string: name)
        }

        if isEncrypted() && (
            name.starts(with: "/i/") || name.starts(with: "i/")
        ) {
            return project.url.appendingPathComponent(name)
        }
        
        if isTextBundle() {
            return getURL().appendingPathComponent(name)
        }

        return project.url.appendingPathComponent(name)
    }

    #if os(OSX)
    public func getDupeName() -> String? {
        var url = self.url
        let ext = url.pathExtension
        url.deletePathExtension()

        var name = url.lastPathComponent
        url.deleteLastPathComponent()

        let regex = try? NSRegularExpression(pattern: "(.+)\\sCopy\\s(\\d)+$", options: .caseInsensitive)
        if let result = regex?.firstMatch(in: name, range: NSRange(0..<name.count)) {
            if let range = Range(result.range(at: 1), in: name) {
                name = String(name[range])
            }
        }

        var endName = name
        if !endName.hasSuffix(" Copy") {
            endName += " Copy"
        }

        let dstUrl = NameHelper.getUniqueFileName(name: endName, project: project, ext: ext)

        return dstUrl.deletingPathExtension().lastPathComponent
    }
    #endif

    public func loadPreviewInfo() {
        guard !isParsed || title.isEmpty && (imageUrl?.isEmpty ?? true) else { return }
        
        defer {
            imageUrl = getImagesFromContent()
            isParsed = true
        }
        
        if content.string.hasPrefix("---") {
            if parseYAMLBlock() {
                return
            }
        }
        
        if project.settings.isFirstLineAsTitle() {
            let lines = getNonEmptyLines()
            if !lines.isEmpty {
                title = lines.first!.trim()
                
                let result = lines.dropFirst()
                preview =
                    result.joined(separator: " ")
                        .trimMDSyntax()
                        .condenseWhitespace()
                
                return
            }
        }
        
        loadTitleFromFileName()
        preview = getPreviewLabel()
    }

    public func getImagesFromContent() -> [URL] {
        var urls = [URL]()

        let range = NSRange(location: 0, length: content.length)
        content.enumerateAttribute(.attachment, in: range) { (value, vRange, _) in
            guard let meta = content.getMeta(at: vRange.location) else { return }

            if meta.url.isMedia {
                urls.append(meta.url)
            }
        }

        return urls
    }

    public func invalidateCache() {
        self.imageUrl = nil
        self.preview = String()
        self.title = String()
        self.isParsed = false
    }

    public func isEqualURL(url: URL) -> Bool {
        return url.path == self.url.path
    }

    public func append(string: NSMutableAttributedString) {
        content.append(string)
    }

    public func append(image data: Data, url: URL? = nil) {
        guard let path = ImagesProcessor.writeFile(data: data, url: url, note: self) else { return }

        var prefix = "\n\n"
        if content.length == 0 {
            prefix = String()
        }

        let markdown = NSMutableAttributedString(string: "\(prefix)![](\(path))")
        append(string: markdown)
    }

    @objc public func getName() -> String {
        if title.isValidUUID {
            return "Untitled Note"
        }

        return title
    }

    public func getCacheForPreviewImage(at url: URL) -> URL? {
        var temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            temporary.appendPathComponent("Preview")

        if let filePath = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {

            return temporary.appendingPathComponent(filePath)
        }

        return nil
    }

    public func removeCacheForPreviewImages() {
        loadPreviewInfo()

        guard let imageURLs = imageUrl else { return }

        for url in imageURLs {
            if let imageURL = getCacheForPreviewImage(at: url) {
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    try? FileManager.default.removeItem(at: imageURL)
                }
            }
        }
    }

    func convertFlatToTextBundle() -> URL {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        let temporaryProject = Project(storage: project.storage, url: temporary)

        let currentName = url.deletingPathExtension().lastPathComponent
        let note = Note(name: currentName, project: temporaryProject, type: type, cont: .textBundleV2)

        note.originalExtension = url.pathExtension
        note.content = content

        let imagesMeta = content.getImagesAndFiles()
        let mutableContent = NoteSerializer.prepareForSave(NSMutableAttributedString(attributedString: content))

        // write textbundle body
        guard note.write(attributedString: mutableContent) else { return note.url }

        for imageMeta in imagesMeta {
            moveFilesFlatToAssets(attributedString: mutableContent, from: imageMeta.url, imagePath: imageMeta.path, to: note.url)
        }

        // write updated image pathes
        guard note.write(attributedString: mutableContent) else {
            return note.url
        }

        return note.url
    }

    private func convertTextBundleToFlat(name: String) {
        let textBundleURL = url
        let json = textBundleURL.appendingPathComponent("info.json")

        if let jsonData = try? Data(contentsOf: json),
            let info = try? JSONDecoder().decode(TextBundleInfo.self, from: jsonData) {
                        
            let ext = NoteType.withUTI(rawValue: info.type).getExtension(for: .textBundleV2)
            let flatExtension = info.flatExtension ?? ext
            
            let fileName = "text.\(ext)"

            let uniqueURL = NameHelper.getUniqueFileName(name: name, project: project, ext: flatExtension)
            let flatURL = url.appendingPathComponent(fileName)

            url = uniqueURL
            type = .withExt(rawValue: flatExtension)
            container = .none

            try? FileManager.default.moveItem(at: flatURL, to: uniqueURL)

            moveFilesAssetsToFlat(src: textBundleURL, project: project)

            try? FileManager.default.removeItem(at: textBundleURL)
        }
    }

    private func moveFilesFlatToAssets(attributedString: NSMutableAttributedString, from imageURL: URL, imagePath: String, to dest: URL) {
        let dest = dest.appendingPathComponent("assets")

        guard let fileName = imageURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }

        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false, attributes: nil)
        }

        do {
            try FileManager.default.moveItem(at: imageURL, to: dest.appendingPathComponent(fileName))

            let prefix = "]("
            let postfix = ")"

            let find = prefix + imagePath + postfix
            let replace = prefix + "assets/" + imageURL.lastPathComponent + postfix

            guard find != replace else { return }

            while attributedString.mutableString.contains(find) {
                let range = attributedString.mutableString.range(of: find)
                attributedString.replaceCharacters(in: range, with: replace)
            }
        } catch {
            print("Enc error: \(error)")
        }
    }

    private func moveFilesAssetsToFlat(src: URL, project: Project) {
        let mutableContent = NoteSerializer.prepareForSave(NSMutableAttributedString(attributedString: content))

        let imagesMeta = content.getImagesAndFiles()
        for imageMeta in imagesMeta {
            let fileName = imageMeta.url.lastPathComponent
            var dst: URL?
            var prefix = "files/"

            if imageMeta.url.isImage {
                prefix = "i/"
            }

            dst = project.url.appendingPathComponent(prefix + fileName)

            guard let moveTo = dst else { continue }

            let dstDir = project.url.appendingPathComponent(prefix)
            let moveFrom = src.appendingPathComponent("assets/" + fileName)

            do {
                if !FileManager.default.fileExists(atPath: dstDir.path) {
                    try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: false, attributes: nil)
                }

                try FileManager.default.moveItem(at: moveFrom, to: moveTo)

            } catch {
                if let fileName = ImagesProcessor.getFileName(from: moveTo, to: dstDir, ext: moveTo.pathExtension) {

                    let moveTo = dstDir.appendingPathComponent(fileName)
                    try? FileManager.default.moveItem(at: moveFrom, to: moveTo)
                }
            }

            guard let escapedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }

            let find = "](assets/" + escapedFileName + ")"
            let replace = "](" + prefix + escapedFileName + ")"

            guard find != replace else { return }

            while mutableContent.mutableString.contains(find) {
                let range = mutableContent.mutableString.range(of: find)
                mutableContent.replaceCharacters(in: range, with: replace)
            }
        }

        content = mutableContent.loadAttachments(self)
        _ = save()
    }

    func loadTextBundle() -> Bool {
        do {
            let url = getURL()
            let json = url.appendingPathComponent("info.json")
            let jsonData = try Data(contentsOf: json)
            let info = try JSONDecoder().decode(TextBundleInfo.self, from: jsonData)

            type = .withUTI(rawValue: info.type)

            if info.version == 1 {
                container = .textBundle
                return true
            }

            container = .textBundleV2
            return true
        } catch {
            print("Can not load TextBundle: \(error)")
        }

        return false
    }

    private func writeEncrypted() {
        guard let baseTextPack = self.decryptedTemporarySrc else { return }

        let textPackURL = baseTextPack.appendingPathExtension("textpack")
        var password = self.password

        SSZipArchive.createZipFile(atPath: textPackURL.path, withContentsOfDirectory: baseTextPack.path)

        do {
            if password == nil {
                let item = KeychainPasswordItem(service: KeychainConfiguration.serviceName, account: "Master Password")
                password = try item.readPassword()
            }

            guard let unwrappedPassword = password else { return }

            let data = try Data(contentsOf: textPackURL)
            let encryptedData = RNCryptor.encrypt(data: data, withPassword: unwrappedPassword)
            try encryptedData.write(to: self.url)

            let attributes = getFileAttributes()
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)

            print("FSNotes successfully writed encrypted data for: \(title)")

            try FileManager.default.removeItem(at: textPackURL)
        } catch {
            return
        }
    }


    public func showIconInList() -> Bool {
        return (isPinned || isEncrypted() || isPublished())
    }

    public func getShortTitle() -> String {
        let fileName = getFileName()

        if fileName.isValidUUID {
            return "▽"
        }

        return fileName
    }

    public func getTitle() -> String? {
        if isEncrypted() && !isUnlocked() {
            return getFileName()
        }

        #if os(iOS)
        if !project.settings.isFirstLineAsTitle() {
            return getFileName()
        }
        #endif

        if title.count > 0 {
            if title.isValidUUID && project.settings.isFirstLineAsTitle() {
                return nil
            }

            if title.starts(with: "![") {
                return nil;
            }
            
            return title
        }

        if getFileName().isValidUUID {
            let previewCharsQty = preview.count
            if previewCharsQty > 0 {
                return "Untitled Note"
            }
        }

        return nil
    }

    // rename() extracted to Note+FileOps.swift

    public func getCursorPosition() -> Int? {
        var position: Int?

        if let data = try? url.extendedAttribute(forName: "co.fluder.fsnotes.cursor") {
            position = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                ptr.load(as: Int.self)
            }

            return position
        }

        return nil
    }

    public func addTag(_ name: String) {
        guard !tags.contains(name) else { return }

        let lastParRange = content.mutableString.paragraphRange(for: NSRange(location: content.length, length: 0))
        let string = content.attributedSubstring(from: lastParRange).string.trim()

        if string.count != 0 && (
            !string.starts(with: "#") || string.starts(with: "# ")
        ) {
            let newLine = NSAttributedString(string: "\n\n")
            content.append(newLine)
        }

        var prefix = String()
        if string.starts(with: "#") {
            prefix += " "
        }

        content.append(NSAttributedString(string: prefix + "#" + name))
        if save() {
            sharedStorage.add(self)
        }
    }

    public func resetAttributesCache() {
        cacheHash = nil
    }
    
    public func getLatinName() -> String {
        let name = (self.fileName as NSString)
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? self.fileName
        
        return name.replacingOccurrences(of: " ", with: "_")
    }
    
    public func isPublished() -> Bool {
        return apiId != nil || uploadPath != nil
    }
    
    public func convertContainer(to: NoteContainer) {
        if to == .textBundleV2 {
            let tempUrl = convertFlatToTextBundle()
            
            let name = url.deletingPathExtension().lastPathComponent
            let uniqueURL = NameHelper.getUniqueFileName(name: name, project: project, ext: "textbundle")

            do {
                let oldUrl = url
                url = uniqueURL
                try FileManager.default.moveItem(at: tempUrl, to: uniqueURL)
                try FileManager.default.removeItem(at: oldUrl)
            } catch {/*_*/}
        } else {
            let name = url.deletingPathExtension().lastPathComponent
            
            convertTextBundleToFlat(name: name)
        }
        
        invalidateCache()
        load()
        parseURL()
    }

    public func getAutoRenameTitle() -> String? {
        if UserDefaultsManagement.naming != .autoRename && UserDefaultsManagement.naming != .autoRenameNew {
            return nil
        }
        
        if UserDefaultsManagement.naming == .autoRenameNew && isOlderThan30Seconds(from: creationDate) {
            return nil
        }
        
        if content.string.startsWith(string: "---") {
            loadPreviewInfo()
        }

        let title = title.trunc(length: 64)

        if fileName == title || title.count == 0 || isEncrypted() {
            return nil
        }

        if project.fileExist(fileName: title, ext: url.pathExtension) {
            return nil
        }

        return title
    }

    public func setSelectedRange(range: NSRange? = nil) {
        selectedRange = range
    }

    public func getSelectedRange() -> NSRange? {
        return selectedRange
    }

    public func setContentOffset(contentOffset: CGPoint) {
        self.contentOffset = contentOffset
    }

    public func getContentOffset() -> CGPoint {
        return contentOffset
    }

    public func getRelatedPath() -> String {
        return project.getNestedPath() + "/" + name
    }
    

    func isOlderThan30Seconds(from date: Date? = nil) -> Bool {
        guard let date = date else { return false }

        let thirtySecondsAgo = Date().addingTimeInterval(-30)
        return date < thirtySecondsAgo //Returns false if date is not older than 30 seconds
    }
    
    public func cacheCodeBlocks() {
    #if !SHARE_EXT
        let ranges = CodeBlockDetector.shared.findCodeBlocks(in: content)
        codeBlockRangesCache = ranges
    #endif
    }

    public func isInCodeBlockRange(range: NSRange) -> Bool {
        guard let codeBlockRangesCache = codeBlockRangesCache else { return false }

        for codeRange in codeBlockRangesCache {
            if NSIntersectionRange(range, codeRange).length > 0 {
                return true
            }
        }

        return false
    }

    public func save(data: Data, preferredName: String? = nil) -> (String, URL)? {
        // Get attach dir
        let attachDir = getAttachDirectory(data: data)

        // Create if not exist
        if !FileManager.default.fileExists(atPath: attachDir.path, isDirectory: nil) {
            try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true, attributes: nil)
        }

        guard let fileName = getFileName(dst: attachDir, preferredName: preferredName) else { return nil }

        let fileUrl = attachDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            print("Attachment error: \(error)")
            return nil
        }

        let lastTwo = fileUrl.deletingLastPathComponent().lastPathComponent + "/" + fileUrl.lastPathComponent

        return (lastTwo, fileUrl)
    }

    public func getAttachDirectory(data: Data) -> URL {
        if isTextBundle() {
            return getURL().appendingPathComponent("assets", isDirectory: true)
        }

        let prefix = data.getFileType() != .unknown ? "i" : "files"

        return project.url.appendingPathComponent(prefix, isDirectory: true)
    }

    public func getFileName(dst: URL, preferredName: String? = nil) -> String? {
        var name = preferredName ?? UUID().uuidString.lowercased()
        let ext = (name as NSString).pathExtension

        while true {
            let destination = dst.appendingPathComponent(name)
            let icloud = destination.appendingPathExtension("icloud")

            if FileManager.default.fileExists(atPath: destination.path) || FileManager.default.fileExists(atPath: icloud.path) {
                let newBase = UUID().uuidString.lowercased()
                if ext.isEmpty {
                    name = newBase
                } else {
                    name = "\(newBase).\(ext)"
                }
                continue
            }

            return name
        }
    }

    public func saveSimple() -> Bool {
        return write(attributedString: content)
    }

    #if os(macOS)
    public func cache() {
        if cacheLock { return }

        let hash = content.string.fnv1a
        cacheLock = true

        if let copy = content.mutableCopy() as? NSMutableAttributedString {
            NotesTextProcessor.highlight(attributedString: copy)
            cacheCodeBlocks()

            if content.string.fnv1a == copy.string.fnv1a {
                content = copy
                cacheHash = hash
            }
        }

        cacheLock = false
    }
    #endif
}
