//
//  ListNotesTool.swift
//  FSNotes
//
//  List every note in the storage tree. Optionally scoped to a folder
//  (in which case it is functionally equivalent to GetFolderNotesTool
//  with `recursive: true`, kept distinct so the LLM has a stable
//  spec-named tool when it wants the whole vault inventory).
//
//  See docs/AI.md "MCP Tools" table — `list_notes` lives alongside
//  `get_folder_notes` and the LLM is expected to pick whichever fits.
//

import Foundation

public struct ListNotesTool: MCPTool {
    public let name = "list_notes"
    public let description = "List every note across the vault, or scoped to a single folder. Returns title, folder, path, modified date, and isTextBundle for each note. Use get_folder_notes for non-recursive listing of a single folder."

    private let server: MCPServer

    /// Cap on returned entries so a vault with thousands of notes does
    /// not blow the LLM context window. The LLM can scope by folder
    /// to drill down further.
    private let maxResults: Int

    public init(server: MCPServer = .shared, maxResults: Int = 500) {
        self.server = server
        self.maxResults = maxResults
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [
                "folder": [
                    "type": "string",
                    "description": "Optional storage-relative folder to limit the listing to. Empty string means the storage root. Omit to walk the whole vault."
                ]
            ],
            "required": []
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }

        let folder = input["folder"] as? String
        let scopeURL: URL
        if let folder = folder, !folder.isEmpty {
            scopeURL = storageRoot.appendingPathComponent(folder)
            if !FileManager.default.fileExists(atPath: scopeURL.path) {
                return .error("Folder not found: \(folder)")
            }
        } else {
            scopeURL = storageRoot
        }

        let notes = NotePathResolver.listNotes(
            in: scopeURL,
            storageRoot: storageRoot,
            recursive: true
        )

        let truncated = notes.count > maxResults
        let limited = Array(notes.prefix(maxResults))

        let summaries: [[String: Any]] = limited.map { note in
            let modified: Date? = (try? note.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            var entry: [String: Any] = [
                "title": note.title,
                "folder": note.folder,
                "path": note.relativePath,
                "isTextBundle": note.isTextBundle,
                "isEncrypted": NotePathResolver.isEncrypted(at: note.url)
            ]
            if let modified = modified {
                entry["modified"] = modified
            }
            return entry
        }

        var payload: [String: Any] = [
            "scope": folder ?? "",
            "totalCount": notes.count,
            "returnedCount": summaries.count,
            "notes": summaries
        ]
        if truncated {
            payload["truncated"] = true
            payload["maxResults"] = maxResults
        }
        return .success(payload)
    }
}
