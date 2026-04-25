//
//  GetProjectsTool.swift
//  FSNotes
//
//  List "projects" — the top-level folders directly under the storage
//  root. In FSNotes terminology a project is just the first folder
//  level (see docs/AI.md "Folder Path Semantics"); deeper nesting is
//  reachable via list_folders / get_folder_notes.
//
//  This tool is intentionally narrower than list_folders: the LLM
//  uses it to discover the major top-level containers (e.g. "Work",
//  "Personal", "Journal") without being flooded with every nested
//  subfolder.
//

import Foundation

public struct GetProjectsTool: MCPTool {
    public let name = "get_projects"
    public let description = "List the top-level project folders directly under the storage root. Each entry includes the folder name and a count of notes inside it (recursive). Use list_folders for the full nested folder tree."

    private let server: MCPServer

    public init(server: MCPServer = .shared) {
        self.server = server
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [:],
            "required": []
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }

        let topLevel = NotePathResolver.listFolders(
            in: storageRoot,
            storageRoot: storageRoot,
            recursive: false
        )

        var projects: [[String: Any]] = []

        // Implicit "root" project — notes that live directly under the
        // storage root with no folder prefix. Surface it explicitly so
        // the LLM doesn't miss top-of-tree notes.
        let rootNotes = NotePathResolver.listNotes(
            in: storageRoot,
            storageRoot: storageRoot,
            recursive: false
        )
        if !rootNotes.isEmpty {
            projects.append([
                "name": "",
                "path": "",
                "noteCount": rootNotes.count,
                "isRoot": true
            ])
        }

        for folder in topLevel {
            let folderURL = storageRoot.appendingPathComponent(folder)
            let count = NotePathResolver.listNotes(
                in: folderURL,
                storageRoot: storageRoot,
                recursive: true
            ).count
            projects.append([
                "name": folder,
                "path": folder,
                "noteCount": count,
                "isRoot": false
            ])
        }

        return .success([
            "projectCount": projects.count,
            "projects": projects
        ])
    }
}
