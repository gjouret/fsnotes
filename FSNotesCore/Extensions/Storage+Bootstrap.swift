//
//  Storage+Bootstrap.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation
import CoreServices

#if os(OSX)
import Cocoa
#else
import UIKit
#endif

extension Storage {
    func bootstrapStorageState() {
#if CLOUD_RELATED_BLOCK
        NSUbiquitousKeyValueStore.default.synchronize()
#endif

        print("A. Bookmarks loading is started")
        let bookmarksManager = SandboxBookmark.sharedInstance()
        bookmarksManager.load()

        let storageType = UserDefaultsManagement.storageType
        guard let url = getRoot() else { return }

        removeCachesIfCrashed()

#if os(OSX)
        if storageType == .local && UserDefaultsManagement.storageType == .iCloudDrive {
            shouldMovePrompt = true
        }
#endif

        let name = getDefaultName(url: url)
        let project = Project(
            storage: self,
            url: url,
            label: name,
            isDefault: true
        )

        insertProject(project: project)
        assignTrash(by: project.url)
        assignBookmarks()
    }

    public func loadInboxAndTrash() {
        _ = getDefault()?.loadNotes()
        _ = getDefaultTrash()?.loadNotes()

        for project in projects where project.isBookmark {
            _ = project.loadNotes()
        }

        if let urls = getCachedTree() {
            for url in urls {
                _ = insert(url: url, cacheOnly: true)
            }
        }

        loadProjectRelations()

        plainWriter.maxConcurrentOperationCount = 1
        plainWriter.qualityOfService = .userInteractive

        ciphertextWriter.maxConcurrentOperationCount = 1
        ciphertextWriter.qualityOfService = .userInteractive

    #if os(iOS)
        checkWelcome()

        let revHistory = getRevisionsHistory()
        let revHistoryDS = getRevisionsHistoryDocumentsSupport()

        if FileManager.default.directoryExists(atUrl: revHistory) {
            try? FileManager.default.moveItem(at: revHistory, to: revHistoryDS)
        }

        if !FileManager.default.directoryExists(atUrl: revHistoryDS) {
            try? FileManager.default.createDirectory(at: revHistoryDS, withIntermediateDirectories: true, attributes: nil)
        }
    #endif

    #if os(macOS)
        self.restoreUploadPaths()
    #endif
    }

    func getDefaultName(url: URL) -> String {
        var name = url.lastPathComponent
        if let iCloudURL = getCloudDrive(), iCloudURL == url {
            name = "iCloud Drive"
        }
        return name
    }

    public func getRoot() -> URL? {
    #if targetEnvironment(simulator) || os(OSX)
        return UserDefaultsManagement.storageUrl
    #else
        guard UserDefaultsManagement.iCloudDrive,
              let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents")
                .standardized else {
            return getLocalDocuments()
        }

        if !FileManager.default.fileExists(atPath: iCloudDocumentsURL.path, isDirectory: nil) {
            do {
                try FileManager.default.createDirectory(at: iCloudDocumentsURL, withIntermediateDirectories: true, attributes: nil)
                return iCloudDocumentsURL.standardized
            } catch {
                print("Home directory creation: \(error)")
            }
            return nil
        }

        return iCloudDocumentsURL.standardized
    #endif
    }

    public func getLocalDocuments() -> URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardized
    }

    func removeCachesIfCrashed() {
        if UserDefaultsManagement.crashedLastTime {
            removeCachedTree()

            if let cache = getCacheDir(), let files = try? FileManager.default.contentsOfDirectory(atPath: cache.path) {
                for file in files {
                    let url = cache.appendingPathComponent(file)
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        isCrashedLastTime = UserDefaultsManagement.crashedLastTime
        UserDefaultsManagement.crashedLastTime = true
    }

    public func getCacheDir() -> URL? {
        guard let cacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first,
              let url = URL(string: "file://" + cacheDir) else { return nil }

        return url
    }

    public func makeTempEncryptionDirectory() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Encryption")
            .appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return url
        } catch {
            return nil
        }
    }

    public func getChildProjects(project: Project) -> [Project] {
        return projects.filter({ $0.parent == project }).sorted(by: { $0.label.lowercased() < $1.label.lowercased() })
    }

    public func getDefault() -> Project? {
        return projects.first(where: { $0.isDefault })
    }

    public func getSidebarProjects() -> [Project] {
        return projects
            .filter({ $0.isBookmark || $0.parent?.isDefault == true })
            .sorted(by: { $0.label.lowercased() < $1.label.lowercased() })
            .sorted(by: { $0.settings.priority < $1.settings.priority })
    }

    public func getDefaultTrash() -> Project? {
        return projects.first(where: { $0.isTrash })
    }

    public func insert(url: URL, bookmark: Bool = false, cacheOnly: Bool = false) -> [Project]? {
        if projectExist(url: url)
            || url.lastPathComponent == "i"
            || url.lastPathComponent == "files"
            || url.lastPathComponent == "assets"
            || url.lastPathComponent == ".icloud"
            || url.path.contains(".git")
            || url.path.contains(".revisions")
            || url.path.contains(".Trash")
            || url.path.contains(".cache")
            || url.path.contains("Trash")
            || url.path.contains("/.")
            || url.path.contains(".textbundle") {
            return nil
        }

        let project = Project(storage: self, url: url, isBookmark: bookmark)
        var insert = [project]

        let results = project.getProjectsFSAndMemoryDiff()
        insert.append(contentsOf: results.1)

        for item in insert where !projectExist(url: item.url) {
            insertProject(project: item)
            _ = item.loadNotes(cacheOnly: cacheOnly)
        }

        return insert
    }

    func assignTrash(by url: URL) {
        var trashURL = url.appendingPathComponent("Trash", isDirectory: true)

    #if os(OSX)
        if let trash = UserDefaultsManagement.trashURL {
            trashURL = trash
        }
    #endif

        do {
            try FileManager.default.contentsOfDirectory(atPath: trashURL.path)
        } catch {
            var isDir = ObjCBool(false)
            if !FileManager.default.fileExists(atPath: trashURL.path, isDirectory: &isDir) && !isDir.boolValue {
                do {
                    try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: false, attributes: nil)
                    print("New trash created: \(trashURL)")
                } catch {
                    print("Trash dir error: \(error)")
                }
            }
        }

        guard !projectExist(url: trashURL) else { return }

        let project = Project(storage: self, url: trashURL, isTrash: true)
        insertProject(project: project)
        self.trashURL = trashURL
    }

    func getCloudDrive() -> URL? {
        if let iCloudDocumentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
            .standardized {
            var isDirectory = ObjCBool(true)
            if FileManager.default.fileExists(atPath: iCloudDocumentsURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return iCloudDocumentsURL
            }
        }

        return nil
    }

    func projectExist(url: URL) -> Bool {
        return projects.contains(where: { $0.url == url })
    }

    public func removeBy(project: Project) {
        self.noteList.removeAll(where: { $0.project.url == project.url })
        projects.removeAll(where: { $0.url == project.url })
    }

    func fetchAllDirectories(url: URL) -> [URL]? {
        let maxDirs = UserDefaultsManagement.maxChildDirs

        var extensions = self.allowedExtensions
        extensions.append(contentsOf: [
            "jpg", "png", "gif", "jpeg", "json", "JPG",
            "PNG", ".icloud", ".cache", ".Trash", "i"
        ])

        guard let urls = DirectoryScanFilter.candidateDirectories(
            in: url,
            allowedExtensions: extensions,
            excludedPaths: ["/assets", "/.cache", "/files", "/.Trash", "/Trash", ".textbundle", ".revisions", "/.git"]
        ) else {
            return nil
        }

        var result = [URL]()
        var count = 0

        for url in urls {
            do {
                var isDirectoryResourceValue: AnyObject?
                try (url as NSURL).getResourceValue(&isDirectoryResourceValue, forKey: URLResourceKey.isDirectoryKey)

                var isPackageResourceValue: AnyObject?
                try (url as NSURL).getResourceValue(&isPackageResourceValue, forKey: URLResourceKey.isPackageKey)

                if isDirectoryResourceValue as? Bool == true, isPackageResourceValue as? Bool == false {
                    count += 1
                    result.append(url)
                }
            } catch let error as NSError {
                print("Error: ", error.localizedDescription)
            }

            if count > maxDirs {
                break
            }
        }

        return result
    }

    public func trashItem(url: URL) -> URL? {
        guard let trashURL = Storage.shared().getDefaultTrash()?.url else { return nil }

        let fileName = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension

        var destination = trashURL.appendingPathComponent(url.lastPathComponent)
        var index = 0

        while FileManager.default.fileExists(atPath: destination.path) {
            let nextName = "\(fileName)_\(index).\(fileExtension)"
            destination = trashURL.appendingPathComponent(nextName)
            index += 1
        }

        return destination
    }

    public func getCache(key: String) -> Data? {
        guard let cacheDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first,
              let url = URL(string: "file://" + cacheDir) else { return nil }

        let cacheURL = url.appendingPathComponent(key + ".cache")
        return try? Data(contentsOf: cacheURL)
    }

    public func checkWelcome() {
    #if os(OSX)
        guard let storageUrl = getDefault()?.url else { return }
        guard UserDefaultsManagement.showWelcome else { return }
        guard let bundlePath = Bundle.main.path(forResource: "Welcome", ofType: ".bundle") else { return }

        let bundle = URL(fileURLWithPath: bundlePath)
        let url = storageUrl.appendingPathComponent("Welcome", isDirectory: true)

        if FileManager.default.fileExists(atPath: url.path) {
            return
        }

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)

        do {
            var files = try FileManager.default.contentsOfDirectory(atPath: bundle.path)
            files = files.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending })

            var index = 0
            for file in files {
                index += 1

                let dstPath = "\(url.path)/\(file)"
                try? FileManager.default.copyItem(atPath: "\(bundle.path)/\(file)", toPath: dstPath)

                let mdPath = "\(url.path)/\(file)/text.markdown"
                if let attributes = try? FileManager.default.attributesOfItem(atPath: mdPath),
                   let creationDate = attributes[.creationDate] as? Date {
                    let newDate = creationDate.addingTimeInterval(TimeInterval(index))
                    try? FileManager.default.setAttributes([.creationDate: newDate], ofItemAtPath: mdPath)
                }
            }
        } catch {
            print("Initial copy error: \(error)")
        }

        let project = Project(storage: self, url: url, label: "Welcome")
        insertProject(project: project)

        let notes = project.loadNotes()
        _ = notes.compactMap({ $0.load() })

        welcomeProject = project
        welcomeNote = notes.first(where: { $0.fileName == "1. Introduction" })
    #else
        guard UserDefaultsManagement.showWelcome else { return }
        guard noteList.isEmpty else { return }

        let welcomeFileName = "Meet FSNotes 7.textbundle"
        guard let src = Bundle.main.resourceURL?.appendingPathComponent(welcomeFileName) else { return }
        guard let dst = getDefault()?.url.appendingPathComponent(welcomeFileName) else { return }

        do {
            if !FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.copyItem(atPath: src.path, toPath: dst.path)

                if let project = getDefault() {
                    let note = Note(url: dst, with: project)
                    add(note)
                }
            }
        } catch {
            print("Initial copy error: \(error)")
        }

        UserDefaultsManagement.showWelcome = false
    #endif
    }

    public func getNewsDate() -> Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.date(from: lastNewsDate)
    }

    public func isReadedNewsOutdated() -> Bool {
        guard let date = UserDefaultsManagement.lastNews, let newsDate = getNewsDate() else {
            return true
        }

        return newsDate > date
    }

    public func getNews() -> URL? {
        return Bundle.main.resourceURL?.appendingPathComponent("Meet FSNotes 7.textbundle")
    }

    public func hideImages(directory: String, srcPath: String) {
        if !relativeInlineImagePaths.contains(directory) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            relativeInlineImagePaths.append(directory)

            if !url.isHidden(),
               FileManager.default.directoryExists(atUrl: url),
               srcPath.contains("/"),
               !srcPath.contains("..") {
                if let contentList = try? FileManager.default.contentsOfDirectory(atPath: url.path), containsTextFiles(contentList) {
                    return
                }

                if let data = "true".data(using: .utf8) {
                    try? url.setExtendedAttribute(data: data, forName: "es.fsnot.hidden.dir")
                }
            }
        }
    }

    func containsTextFiles(_ list: [String]) -> Bool {
        for item in list {
            let ext = (item as NSString).pathExtension.lowercased()
            if allowedExtensions.contains(ext) {
                return true
            }
        }

        return false
    }

    public func getRevisionsHistory() -> URL {
        let documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documentDir.appendingPathComponent(".revisions")
    }

    public func getRevisionsHistoryDocumentsSupport() -> URL {
        let documentDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documentDir.appendingPathComponent(".revisions")
    }

    public func getGitKeysDir() -> URL? {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Keys", isDirectory: true) else { return nil }

        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        return url
    }

    public func migrationAPIIds() {
        guard let key = UserDefaultsManagement.deprecatedUploadKey else {
            return
        }

        UserDefaultsManagement.uploadKey = key
        UserDefaultsManagement.deprecatedUploadKey = nil

        guard let data = UserDefaultsManagement.apiBookmarksData,
              let uploadBookmarks = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSDictionary.self, NSURL.self, NSString.self],
                from: data
              ) as? [URL: String] else { return }

        for bookmark in uploadBookmarks {
            if let note = getBy(url: bookmark.key), note.apiId == nil {
                note.apiId = bookmark.value
                note.project.saveWebAPI()
            }
        }

        UserDefaultsManagement.apiBookmarksData = nil
    }
}
