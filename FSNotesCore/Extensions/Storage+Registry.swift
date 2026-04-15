//
//  Storage+Registry.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation

extension Storage {
    public func insertProject(project: Project) {
        if projectExist(url: project.url) {
            print("Project exist: \(project.label)")
            return
        }

        projects.append(project)
    }

    public func loadNotesContent() {
        // Parallelize note loading (Perf plan item #4b). Each `Note.load()`
        // reads its own file from disk and populates its own `content` /
        // `title` / `preview` / `tags` fields — no shared mutable state
        // (tag aggregation happens later in `sidebarOutlineView.loadAllTags`).
        // `concurrentPerform` caps concurrency at `activeProcessorCount`
        // automatically so disk I/O doesn't thrash.
        let notes = noteList
        DispatchQueue.concurrentPerform(iterations: notes.count) { i in
            notes[i].load()
        }
    }

    public func assignBookmarks() {
        let bookmarksManager = SandboxBookmark.sharedInstance()
        let bookmarks = bookmarksManager.getRestoredUrls()

        for url in bookmarks {
            if url.pathExtension == "css" || projectExist(url: url) || UserDefaultsManagement.gitStorage == url {
                continue
            }

            let project = Project(storage: self, url: url, isBookmark: true)
            insertProject(project: project)
        }
    }

    func getTrash(url: URL) -> URL? {
        return try? FileManager.default.url(for: .trashDirectory, in: .allDomainsMask, appropriateFor: url, create: false)
    }

    public func resetCacheAttributes() {
        for note in self.noteList {
            note.cacheHash = nil
        }
    }

    public func getProjects() -> [Project] {
        return projects
    }

    public func getProjectBy(element: Int) -> Project? {
        if projects.indices.contains(element) {
            return projects[element]
        }

        return nil
    }

    public func findAllProjectsExceptDefault() -> [Project] {
        return projects.filter({ !$0.isDefault })
    }

    public func getNonSystemProjects() -> [Project] {
        return projects.filter({
            !$0.isDefault && !$0.isTrash
        })
    }

    public func getAvailableProjects() -> [Project] {
        return projects.filter({
            !$0.isDefault && !$0.isTrash && $0.settings.showInSidebar
        })
    }

    public func getProjectPaths() -> [String] {
        var pathList = [String]()
        let projects = getProjects()

        for project in projects {
            pathList.append(NSString(string: project.url.path).expandingTildeInPath)
        }

        return pathList
    }

    public func getProjectByNote(url: URL) -> Project? {
        let projectURL = url.deletingLastPathComponent()

        return projects.first(where: {
            $0.url == projectURL
        })
    }

    public func getProjectBy(url: URL) -> Project? {
        return projects.first(where: {
            $0.url == url
        })
    }

    public func isValidNote(url: URL) -> Bool {
        if allowedExtensions.contains(url.pathExtension) || isValidUTI(url: url) {
            let qty = url.pathComponents.count
            if qty > 1 {
                return !url.pathComponents[qty - 2].startsWith(string: ".")
            }

            return true
        }

        return false
    }

    public func isValidUTI(url: URL) -> Bool {
        guard url.fileSize < 100000000 else { return false }
        guard let typeIdentifier = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier else { return false }

        let type = typeIdentifier as CFString
        if type == kUTTypeFolder {
            return false
        }

        return UTTypeConformsTo(type, kUTTypeText)
    }

    func add(_ note: Note) {
        if !noteList.contains(where: { $0.name == note.name && $0.project == note.project }) {
            noteList.append(note)
        } else {
            print("Note already exists: \(note.name) (\(note.url))")
        }
    }

    public func contains(note: Note) -> Bool {
        if noteList.contains(where: { $0.name == note.name && $0.project == note.project }) {
            return true
        }

        return false
    }

    func removeBy(note: Note) {
        if let i = noteList.firstIndex(where: { $0 === note }) {
            noteList.remove(at: i)
        }
    }

    func getNextId() -> Int {
        return noteList.count
    }

    func getBy(url: URL, caseSensitive: Bool = false) -> Note? {
        let standardized = url.standardized

        if caseSensitive {
            return noteList.first(where: {
                $0.url.path == standardized.path
            })
        }

        return noteList.first(where: {
            $0.url.path.lowercased() == standardized.path.lowercased()
        })
    }

    func getBy(name: String) -> Note? {
        return noteList.first(where: {
            $0.name == name
        })
    }

    func getBy(title: String, exclude: Note? = nil) -> Note? {
        return noteList.first(where: {
            $0.title.lowercased() == title.lowercased()
                && !$0.isTrash()
                && (exclude == nil || $0 != exclude)
        })
    }

    func getBy(fileName: String, exclude: Note? = nil) -> Note? {
        return noteList.first(where: {
            $0.fileName.lowercased() == fileName.lowercased()
                && !$0.isTrash()
                && (exclude == nil || $0 != exclude)
        })
    }

    func getBy(titleOrName: String) -> Note? {
        return getBy(fileName: titleOrName) ?? getBy(title: titleOrName)
    }

    func getBy(startWith: String) -> [Note]? {
        return noteList.filter {
            $0.title.lowercased().starts(with: startWith.lowercased())
        }
    }

    func getByUrl(endsWith: String) -> Note? {
        for note in noteList {
            if note.url.path.hasSuffix(endsWith) {
                return note
            }
        }

        return nil
    }

    func getBy(contains: String) -> [Note]? {
        return noteList.filter {
            !$0.project.isTrash && $0.title.localizedCaseInsensitiveContains(contains)
        }
    }

    public func getTitles(by word: String? = nil) -> [String]? {
        var notes = noteList
        if let word = word {
            notes = notes
                .filter {
                    $0.title.range(of: word, options: .caseInsensitive) != nil && $0.project.settings.isFirstLineAsTitle()
                        || $0.fileName.range(of: word, options: .caseInsensitive) != nil && !$0.project.settings.isFirstLineAsTitle()
                }
                .filter({ !$0.isTrash() })

            guard notes.count > 0 else { return nil }
            var titles = notes.map { String($0.project.settings.isFirstLineAsTitle() ? $0.title : $0.fileName) }

            titles = Array(Set(titles))
            titles = titles
                .filter({ !$0.starts(with: "![](") && !$0.starts(with: "[[") })
                .sorted { first, second in
                    let firstStarts = first.range(of: word, options: [.caseInsensitive, .anchored]) != nil
                    let secondStarts = second.range(of: word, options: [.caseInsensitive, .anchored]) != nil

                    if firstStarts && secondStarts || !firstStarts && !secondStarts {
                        return first.localizedCaseInsensitiveCompare(second) == .orderedAscending
                    }

                    return firstStarts && !secondStarts
                }

            if titles.count > 100 {
                return Array(titles[0..<100])
            }

            return titles
        }

        guard notes.count > 0 else { return nil }
        notes = notes.sorted { first, second in
            return first.modifiedLocalAt > second.modifiedLocalAt
        }

        let titles = notes
            .filter({ !$0.isTrash() })
            .map { String($0.project.settings.isFirstLineAsTitle() ? $0.title : $0.fileName) }
            .filter({ $0.count > 0 })
            .filter({ !$0.starts(with: "![](") })
            .prefix(100)

        return Array(titles)
    }

    func getDemoSubdirURL() -> URL? {
#if os(OSX)
        if let project = projects.first {
            return project.url
        }

        return nil
#else
        if let icloud = UserDefaultsManagement.iCloudDocumentsContainer {
            return icloud
        }

        return UserDefaultsManagement.storageUrl
#endif
    }

    func removeNotes(notes: [Note], fsRemove: Bool = true, completely: Bool = false, completion: @escaping ([URL: URL]?) -> ()) {
#if !SHARE_EXT
        guard notes.count > 0 else {
            completion(nil)
            return
        }

        for note in notes {
            note.removeCacheForPreviewImages()
            removeBy(note: note)
        }

        var removed = [URL: URL]()

        if fsRemove {
            for note in notes {
                if let trashURLs = note.removeFile(completely: completely) {
                    removed[trashURLs[0]] = trashURLs[1]
                }
            }
        }

        if removed.count > 0 {
            completion(removed)
        } else {
            completion(nil)
        }
#endif
    }

    public func getCurrentProject() -> Project? {
        return projects.first
    }

    public func getAllTrash() -> [Note] {
        return noteList.filter {
            $0.isTrash()
        }
    }

    public func remove(project: Project) {
        if let index = projects.firstIndex(of: project) {
            projects.remove(at: index)

            cleanCachedTree(url: project.url)
        }

        removeBy(project: project)
    }

    public func getNotesBy(project: Project) -> [Note] {
        return noteList.filter({ $0.project == project })
    }

    public func loadProjects(from urls: [URL]) {
        var result = [URL]()
        for url in urls {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                result.append(url)
            } catch {
                print(error)
            }
        }

        let projects = result.compactMap({ Project(storage: self, url: $0) })

        guard projects.count > 0 else {
            return
        }

        self.projects.removeAll()

        for project in projects {
            if project == projects.first {
                project.isDefault = true
                project.label = NSLocalizedString("Inbox", comment: "")
            }

            insertProject(project: project)
        }
    }

    public func importNote(url: URL) -> Note? {
        if !FileManager.default.fileExists(atPath: url.path) {
            return nil
        }

        guard getBy(url: url) == nil,
              let project = self.getProjectByNote(url: url)
        else { return nil }

        let note = Note(url: url, with: project)

        if note.isTextBundle() && !note.isFullLoadedTextBundle() {
            return nil
        }

        note.load()
        note.loadModifiedLocalAt()
        note.loadCreationDate()

        loadPins(notes: [note])
        add(note)

        print("FSWatcher import note: \"\(note.name)\"")

        return note
    }

    public func findParent(url: URL) -> Project? {
        let parentURL = url.deletingLastPathComponent()

        if let foundParent = projects.first(where: { $0.url == parentURL }) {
            return foundParent
        }

        return nil
    }

    public func getProjectBy(settingsKey: String) -> Project? {
        return projects.first(where: {
            $0.settingsKey == settingsKey
        })
    }

    public func hasOrigins() -> Bool {
        return projects.first(where: {
            $0.settings.gitOrigin != nil && $0.settings.gitOrigin!.count > 0
        }) != nil
    }

    public func getGitProjects() -> [Project]? {
        return projects.filter({
            $0.settings.gitOrigin != nil && $0.settings.gitOrigin!.count > 0
        })
    }

    public func getSortedProjects() -> [Project] {
        return self.projects.sorted(by: { $0.url.path < $1.url.path })
    }

    public func addNote(url: URL) -> Note {
        let projectURL = url.deletingLastPathComponent()
        var project: Project?

        if let unwrappedProject = getProjectBy(url: projectURL) {
            project = unwrappedProject
        } else {
            project = Project(storage: self, url: projectURL)
            insertProject(project: project!)
        }

        let note = Note(url: url, with: project!)
        add(note)

        return note
    }
}
