//
//  Storage+Sort.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation

extension Storage {
    public func sortNotes(noteList: [Note], operation: BlockOperation? = nil) -> [Note] {
        var noteList = noteList

        if !searchQuery.filter.isEmpty {
            noteList = noteList.sorted(by: {
                if let operation, operation.isCancelled {
                    return false
                }

                return sortQuery(note: $0, next: $1)
            })
        }

        return noteList.sorted(by: {
            if let operation, operation.isCancelled {
                return false
            }

            if !searchQuery.filter.isEmpty {
                if $0.title == searchQuery.filter && $1.title != searchQuery.filter {
                    return true
                }

                if $0.fileName == searchQuery.filter && $1.fileName != searchQuery.filter {
                    return true
                }

                if ($0.title.startsWith(string: searchQuery.filter) || $0.fileName.startsWith(string: searchQuery.filter))
                    && (!$1.title.startsWith(string: searchQuery.filter) && !$1.fileName.startsWith(string: searchQuery.filter)) {
                    return true
                }

                return false
            }

            return sortQuery(note: $0, next: $1)
        })
    }

    private func sortQuery(note: Note, next: Note) -> Bool {
        if note.isPinned == next.isPinned {
            switch self.sortByState {
            case .none:
                return false
            case .creationDate:
                if let prevDate = note.creationDate, let nextDate = next.creationDate {
                    return self.sortDirectionState == .asc && prevDate < nextDate
                        || self.sortDirectionState == .desc && prevDate > nextDate
                }
            case .modificationDate:
                return self.sortDirectionState == .asc && note.modifiedLocalAt < next.modifiedLocalAt
                    || self.sortDirectionState == .desc && note.modifiedLocalAt > next.modifiedLocalAt
            case .title:
                var title = note.title
                var nextTitle = next.title
                if note.isEncryptedAndLocked() {
                    title = note.fileName
                }
                if next.isEncryptedAndLocked() {
                    nextTitle = next.fileName
                }

                let comparisonResult = title.localizedStandardCompare(nextTitle)
                return self.sortDirectionState == .asc
                    ? comparisonResult == .orderedAscending
                    : comparisonResult == .orderedDescending
            }
        }

        return note.isPinned && !next.isPinned
    }

    public func setSearchQuery(value: SearchQuery) {
        self.searchQuery = value
        buildSortBy()
    }

    public func getSortByState() -> SortBy {
        return self.sortByState
    }

    public func getSortDirectionState() -> SortDirection {
        return self.sortDirectionState
    }

    public func overrideSortBy(sortBy: SortBy, sortDirection: SortDirection) {
        self.sortByState = sortBy
        self.sortDirectionState = sortDirection
    }

    public func buildSortBy() {
        if let project = self.searchQuery.projects.first {
            if project.settings.sortBy == .none {
                self.sortByState = .none
                return
            }
            self.sortByState = project.settings.sortBy
            self.sortDirectionState = project.settings.sortDirection
            return
        }

        if self.searchQuery.projects.count == 0 {
            var project: Project?

            switch self.searchQuery.type {
            case .All:
                project = self.allNotesProject
            case .Untagged:
                project = self.untaggedProject
            case .Todo:
                project = self.todoProject
            default:
                project = self.allNotesProject
            }

            if let project, project.settings.sortBy != .none {
                self.sortByState = project.settings.sortBy
                self.sortDirectionState = project.settings.sortDirection
                return
            }
        }

        self.sortByState = UserDefaultsManagement.sort
        self.sortDirectionState = UserDefaultsManagement.sortDirection ? .desc : .asc
    }
}
