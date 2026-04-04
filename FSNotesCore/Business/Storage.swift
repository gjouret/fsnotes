//
//  NotesCollection.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 8/9/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

class Storage {
    public static var instance: Storage? = nil

    public var noteList = [Note]()
    public var projects = [Project]()
    public var tags = [String]()

    var notesDict: [String: Note] = [:]

    public var allowedExtensions = [
        "md",
        "markdown",
        "txt",
        "fountain",
        "textbundle",
        "etp" // Encrypted Text Pack
    ]

    public var shouldMovePrompt = false

    // NOTE: These properties are `internal` (not `private`) only because Storage
    // extensions live in separate files. External callers should use accessor methods
    // (getDefaultTrash, getSortBy, buildSortBy, overrideSortBy) instead of direct access.
    var trashURL = URL(string: String())
    var relativeInlineImagePaths = [String]()
    var sortByState: SortBy = .modificationDate
    var sortDirectionState: SortDirection = .asc

    let lastNewsDate = "2026-01-10"
    public var isCrashedLastTime = false

    public var plainWriter = OperationQueue.init()
    public var ciphertextWriter = OperationQueue.init()

    public var searchQuery: SearchQuery = SearchQuery()

    // Virtual projects
    public var allNotesProject: Project?
    public var todoProject: Project?
    public var untaggedProject: Project?
    
    public var welcomeProject: Project?
    public var welcomeNote: Note?

    init() {
        bootstrapStorageState()
    }

    public static func shared() -> Storage {
        guard let storage = self.instance else {
            self.instance = Storage()
            return self.instance!
        }
        return storage
    }

}

extension String: Error {}
