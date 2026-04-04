//
//  ProjectStore.swift
//  FSNotesCore
//  Focused facade for project and folder operations.

import Foundation

public class ProjectStore {
    public init() {}

    public var projects: [Project] {
        return Storage.shared().projects
    }

    public func getSidebarProjects() -> [Project] {
        return Storage.shared().getSidebarProjects()
    }

    public func getDefault() -> Project? {
        return Storage.shared().getDefault()
    }

    public func projectExist(url: URL) -> Bool {
        return Storage.shared().projectExist(url: url)
    }
}
