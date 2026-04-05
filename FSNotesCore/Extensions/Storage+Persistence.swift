//
//  Storage+Persistence.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation

private enum CloudPinStore {
    static let key = "co.fluder.fsnotes.pins.shared"

    static func save(_ relatedPaths: [String]) {
        // Persist to UserDefaults (synchronous, crash-safe) so pins survive app restarts.
        UserDefaults.standard.set(relatedPaths, forKey: key)
        UserDefaults.standard.synchronize()

        #if CLOUD_RELATED_BLOCK
        let keyStore = NSUbiquitousKeyValueStore.default
        keyStore.set(relatedPaths, forKey: key)
        keyStore.synchronize()
        #endif
    }

    static func load() -> [String]? {
        #if CLOUD_RELATED_BLOCK
        let keyStore = NSUbiquitousKeyValueStore.default
        keyStore.synchronize()
        if let cloudPaths = keyStore.array(forKey: key) as? [String] {
            return cloudPaths
        }
        #endif

        return UserDefaults.standard.array(forKey: key) as? [String]
    }
}

private enum ProjectExpandStateStore {
    static let fileName = "projects.state"

    static func save(_ urls: [URL]) {
        guard var documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        documentDir.appendPathComponent(fileName)

        if let data = try? NSKeyedArchiver.archivedData(withRootObject: urls, requiringSecureCoding: true) {
            try? data.write(to: documentDir)
        }
    }

    static func load() -> [URL] {
        guard var documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        documentDir.appendPathComponent(fileName)

        guard let data = FileManager.default.contents(atPath: documentDir.path),
              let urls = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSURL.self], from: data) as? [URL] else {
            return []
        }

        return urls
    }
}

private enum UploadBookmarkStore {
    static func save(_ bookmarks: [URL: String]) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: bookmarks, requiringSecureCoding: true) {
            UserDefaultsManagement.sftpUploadBookmarksData = data
        }
    }

    static func load() -> [URL: String] {
        guard let data = UserDefaultsManagement.sftpUploadBookmarksData,
              let uploadBookmarks = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSURL.self, NSString.self], from: data) as? [URL: String] else {
            return [:]
        }

        return uploadBookmarks
    }
}

extension Storage {
    public func saveProjectsCache() {
        for project in projects {
            project.saveCache()
        }

        saveCachedTree()
    }

    public func saveCloudPins() {
        guard let pinned = getPinned() else { return }
        let relatedPaths = pinned.map { $0.getRelatedPath() }
        CloudPinStore.save(relatedPaths)

        #if CLOUD_RELATED_BLOCK
        print("Pins successfully saved: \(relatedPaths)")
        #endif
    }

    public func loadPins(notes: [Note]) {
        guard let relatedPaths = CloudPinStore.load() else { return }

        for note in notes where relatedPaths.contains(note.getRelatedPath()) {
            note.addPin(cloudSave: false)
        }
    }

    public func restoreCloudPins() -> (removed: [Note]?, added: [Note]?) {
        var added = [Note]()
        var removed = [Note]()

        if let relatedPaths = CloudPinStore.load() {
            if let pinned = getPinned() {
                for note in pinned where !relatedPaths.contains(note.getRelatedPath()) {
                    note.removePin(cloudSave: false)
                    removed.append(note)
                }
            }

            for note in noteList where !note.isPinned && relatedPaths.contains(note.getRelatedPath()) {
                note.addPin(cloudSave: false)
                added.append(note)
            }
        }

        return (removed, added)
    }

    public func getPinned() -> [Note]? {
        return noteList.filter({ $0.isPinned })
    }

    #if os(OSX)
    public func saveProjectsExpandState() {
        let expandedProjectURLs = projects.compactMap { $0.isExpanded ? $0.url : nil }
        ProjectExpandStateStore.save(expandedProjectURLs)
    }

    public func restoreProjectsExpandState() {
        let expandedProjectURLs = ProjectExpandStateStore.load()

        for project in projects where expandedProjectURLs.contains(project.url) {
            project.isExpanded = true
        }
    }
    #endif

    public func saveUploadPaths() {
        let bookmarks = noteList.reduce(into: [URL: String]()) { result, note in
            if let path = note.uploadPath, path.count > 1 {
                result[note.url] = path
            }
        }

        UploadBookmarkStore.save(bookmarks)
    }

    public func restoreUploadPaths() {
        let uploadBookmarks = UploadBookmarkStore.load()

        for (noteURL, uploadPath) in uploadBookmarks {
            if let note = getBy(url: noteURL) {
                note.uploadPath = uploadPath
            }
        }
    }
}
