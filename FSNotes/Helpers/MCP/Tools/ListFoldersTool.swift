//
//  ListFoldersTool.swift
//  FSNotes
//
//  List the folder hierarchy under the storage root. Optionally
//  recursive. TextBundle directories are NOT included — they are
//  notes from the user's perspective.
//

import Foundation

public struct ListFoldersTool: MCPTool {
    public let name = "list_folders"
    public let description = "List subfolders under the storage root. By default returns top-level folders only; pass recursive=true for the full tree."

    private let server: MCPServer

    public init(server: MCPServer = .shared) {
        self.server = server
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [
                "recursive": [
                    "type": "boolean",
                    "description": "If true, return every folder in the tree. Default false (top-level only)."
                ]
            ],
            "required": []
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        let recursive = (input["recursive"] as? Bool) ?? false
        let folders = NotePathResolver.listFolders(
            in: storageRoot,
            storageRoot: storageRoot,
            recursive: recursive
        )
        return .success([
            "folders": folders,
            "recursive": recursive
        ])
    }
}
