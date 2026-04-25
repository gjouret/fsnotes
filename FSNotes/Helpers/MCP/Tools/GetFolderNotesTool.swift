//
//  GetFolderNotesTool.swift
//  FSNotes
//
//  List notes inside a specific folder. Returns title / folder /
//  path / modified-date / TextBundle metadata for each note. The
//  LLM uses this output to pick a note to read in full via
//  read_note.
//

import Foundation

public struct GetFolderNotesTool: MCPTool {
    public let name = "get_folder_notes"
    public let description = "List notes in a specific folder. Returns title, folder, path, modified date, and isTextBundle for each note."

    private let server: MCPServer

    public init(server: MCPServer = .shared) {
        self.server = server
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [
                "folder": [
                    "type": "string",
                    "description": "Storage-relative folder path. Empty string means the storage root."
                ],
                "recursive": [
                    "type": "boolean",
                    "description": "If true, include notes in subfolders. Default false."
                ]
            ],
            "required": ["folder"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        guard let folder = input["folder"] as? String else {
            return .error("Missing 'folder' parameter")
        }
        let recursive = (input["recursive"] as? Bool) ?? false

        let folderURL: URL
        if folder.isEmpty {
            folderURL = storageRoot
        } else {
            folderURL = storageRoot.appendingPathComponent(folder)
        }
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            return .error("Folder not found: \(folder)")
        }

        let notes = NotePathResolver.listNotes(
            in: folderURL,
            storageRoot: storageRoot,
            recursive: recursive
        )

        let summaries: [[String: Any]] = notes.map { note in
            let modified: Date? = (try? note.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            var entry: [String: Any] = [
                "title": note.title,
                "folder": note.folder,
                "path": note.relativePath,
                "isTextBundle": note.isTextBundle
            ]
            if let modified = modified {
                entry["modified"] = modified
            }
            return entry
        }

        return .success([
            "folder": folder,
            "recursive": recursive,
            "noteCount": summaries.count,
            "notes": summaries
        ])
    }
}
