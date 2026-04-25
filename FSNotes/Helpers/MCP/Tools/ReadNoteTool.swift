//
//  ReadNoteTool.swift
//  FSNotes
//
//  Filesystem-backed note reader. Resolves a `title` / `folder` /
//  `path` argument trio to a single note on disk and returns its
//  markdown content. TextBundle-aware: reads `text.md` from inside
//  the bundle and surfaces `isTextBundle: true` so the LLM knows
//  the asset base path.
//
//  See docs/AI.md "Direct Filesystem Access" for the design
//  rationale and "Folders and TextBundle Awareness" for the
//  resolution rules.
//

import Foundation

public struct ReadNoteTool: MCPTool {
    public let name = "read_note"
    public let description = "Read the content of a note by its title, optional folder, or full path. Returns markdown plus folder/path metadata."

    /// Reference back to the server so the tool can resolve
    /// `storageRoot` lazily and pick up test overrides without
    /// recompiling the registry.
    private weak var server: MCPServer?

    public init(server: MCPServer = .shared) {
        self.server = server
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Title of the note without extension"
                ],
                "folder": [
                    "type": "string",
                    "description": "Optional storage-relative folder path (e.g. 'Work/Meetings')"
                ],
                "path": [
                    "type": "string",
                    "description": "Optional full storage-relative path (e.g. 'Work/Meetings/Standup.md')"
                ]
            ],
            "required": []
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = (server ?? MCPServer.shared).storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }

        let title = input["title"] as? String
        let folder = input["folder"] as? String
        let path = input["path"] as? String

        let resolution = NotePathResolver.resolve(
            title: title,
            folder: folder,
            path: path,
            storageRoot: storageRoot
        )

        switch resolution {
        case .invalidArguments(let reason):
            return .error(reason)
        case .notFound:
            return .error("Note not found: \(title ?? path ?? "<unspecified>")")
        case .ambiguous(let matches):
            let listing = matches.map { match -> String in
                if match.folder.isEmpty {
                    return "- \(match.title)"
                }
                return "- \(match.folder)/\(match.title)"
            }.joined(separator: "\n")
            return .error(
                "Multiple notes match. Specify a folder:\n\(listing)"
            )
        case .found(let note):
            if NotePathResolver.isEncrypted(at: note.url) {
                return .error("Note is encrypted: \(note.relativePath)")
            }
            do {
                let content = try String(contentsOf: note.markdownURL, encoding: .utf8)
                return .success([
                    "title": note.title,
                    "folder": note.folder,
                    "path": note.relativePath,
                    "content": content,
                    "isTextBundle": note.isTextBundle
                ])
            } catch {
                return .error("Failed to read note '\(note.relativePath)': \(error.localizedDescription)")
            }
        }
    }
}
