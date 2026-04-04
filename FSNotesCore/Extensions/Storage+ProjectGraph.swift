//
//  Storage+ProjectGraph.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation

extension Storage {
    public func loadNonSystemProject() {
        guard let main = getDefault() else { return }

        let projectURLs = getAllSubUrls(for: main.url)
        for projectURL in projectURLs {
            let project = Project(storage: self, url: projectURL)
            insertProject(project: project)
        }

        let bookmarkURLs = fetchBookmarkUrls()
        for url in bookmarkURLs where !projectURLs.contains(url) {
            let project = Project(storage: self, url: url)
            insertProject(project: project)
        }
    }

    public func fetchBookmarkUrls() -> [URL] {
        guard let main = getDefault()?.url else { return [] }

        var projectURLs = [URL]()
        let bookmarkUrls = SandboxBookmark.sharedInstance().getRestoredUrls()
        let trash = getDefaultTrash()?.url.standardized

        for url in bookmarkUrls where !projectURLs.contains(url) && url != main && url.standardized != trash {
            projectURLs.append(url)

            if let subUrls = fetchAllDirectories(url: url) {
                for subUrl in subUrls where !projectURLs.contains(subUrl) {
                    projectURLs.append(subUrl)
                }
            }
        }

        return projectURLs
    }

    public func getProjectDiffs() -> ([Project], [Project], [Note], [Note]) {
        var insert = [Project]()
        var remove = [Project]()

        if let defaultProject = getDefault() {
            let defaultResults = defaultProject.getProjectsFSAndMemoryDiff()
            remove.append(contentsOf: defaultResults.0)
            insert.append(contentsOf: defaultResults.1)
        }

        let externalProjects = projects.filter({ $0.isBookmark })
        for project in externalProjects {
            let results = project.getProjectsFSAndMemoryDiff()
            remove.append(contentsOf: results.0)
            insert.append(contentsOf: results.1)
        }

        for insertItem in insert {
            insertProject(project: insertItem)
        }

        loadProjectRelations()
        saveCachedTree()

        var insertNotes = [Note]()
        for insertItem in insert {
            let append = insertItem.loadNotes()
            insertNotes.append(contentsOf: append)
        }

        var removeNotes = [Note]()
        for removeItem in remove {
            let append = getNotesBy(project: removeItem)
            removeNotes.append(contentsOf: append)
        }

        return (remove, insert, removeNotes, insertNotes)
    }

    public func loadProjectRelations() {
        for project in projects {
            if let parent = getProjectBy(url: project.url.deletingLastPathComponent()) {
                if project.isTrash { continue }

                project.parent = parent

                if parent.child.filter({ $0.url == project.url }).isEmpty {
                    parent.child.append(project)
                }

                parent.child = parent.child.sorted(by: { $0.settings.priority < $1.settings.priority })
            }
        }
    }

    public func saveCachedTree() {
        guard let cacheDir = getCacheDir() else { return }

        var urls = getNonSystemProjects()
            .sorted(by: {
                $0.url.path.components(separatedBy: "/").count < $1.url.path.components(separatedBy: "/").count
            })
            .map(\.url)

        let deduplicatedUrls = urls.reduce(into: [String: URL]()) { result, object in
            result[object.path] = object
        }.values

        urls = Array(deduplicatedUrls)

        CachedSidebarTreeStore.save(urls, to: cacheDir)
    }

    public func getCachedTree() -> [URL]? {
        guard let cacheDir = getCacheDir() else { return nil }
        return CachedSidebarTreeStore.load(from: cacheDir)
    }

    public func removeCachedTree() {
        guard let cacheDir = getCacheDir() else { return }
        CachedSidebarTreeStore.remove(from: cacheDir)
    }

    public func cleanCachedTree(url: URL) {
        guard let urls = getCachedTree() else { return }
        let cleanList = urls.filter({ !$0.path.startsWith(string: url.path) })

        guard let cacheDir = getCacheDir() else { return }
        CachedSidebarTreeStore.save(cleanList, to: cacheDir)
    }

    private func getAllSubUrls(for rootUrl: URL) -> [URL] {
        let trash = getDefaultTrash()?.url.standardized

        var projectURLs = [URL]()
        if let urls = fetchAllDirectories(url: rootUrl) {
            for url in urls {
                let standardizedURL = (url as URL).standardized
                if standardizedURL == trash || standardizedURL == rootUrl {
                    continue
                }
                projectURLs.append(standardizedURL)
            }
        }

        return projectURLs
    }
}
