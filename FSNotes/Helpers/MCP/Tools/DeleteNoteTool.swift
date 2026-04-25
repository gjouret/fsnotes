//
//  DeleteNoteTool.swift
//  FSNotes
//
//  Delete a note (or TextBundle directory) from disk. Per
//  `docs/AI.md` "Write Safety Rules":
//   1. Refuse to delete encrypted notes.
//   2. Require an explicit `confirm: true` flag — guards the LLM
//      against runaway deletes.
//   3. If the note is open and dirty, ask for a write lock; abort
//      if it is denied.
//   4. Notify the AppBridge on success so the editor and notes list
//      can react.
//
//  TextBundles are removed as a unit (the wrapper directory and
//  everything inside).
//

import Foundation

public struct DeleteNoteTool: MCPTool {
    public let name = "delete_note"
    public let description = "Delete a note from disk. Requires `confirm: true`. Refuses to delete encrypted notes or to overwrite the editor's unsaved changes."

    private let server: MCPServer

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
                    "description": "Optional storage-relative folder. Required when the title is ambiguous."
                ],
                "path": [
                    "type": "string",
                    "description": "Optional full storage-relative path; takes precedence over title/folder."
                ],
                "confirm": [
                    "type": "boolean",
                    "description": "Must be true. The tool refuses to delete without explicit confirmation."
                ]
            ],
            "required": ["confirm"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        let confirm = (input["confirm"] as? Bool) ?? false
        if !confirm {
            return .error("Refusing to delete without explicit `confirm: true`.")
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

        let note: ResolvedNote
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
            return .error("Multiple notes match. Specify folder:\n\(listing)")
        case .found(let resolved):
            note = resolved
        }

        if NotePathResolver.isEncrypted(at: note.url) {
            return .error("Cannot delete encrypted note: \(note.relativePath)")
        }

        // Coordinate with the editor when the note is open and dirty.
        // We compare on standardized paths (the resolver returns URLs
        // without the /private/var symlink prefix, the bridge may not).
        let bridge = server.appBridge
        let notePath = note.url.standardizedFileURL.path
        if let openPathRaw = bridge.currentNotePath() {
            let openPath = URL(fileURLWithPath: openPathRaw).standardizedFileURL.path
            if openPath == notePath, bridge.hasUnsavedChanges(path: openPathRaw) {
                if !bridge.requestWriteLock(path: openPathRaw) {
                    return .error("Note has unsaved changes; the editor declined the write lock. Save first and retry.")
                }
            }
        }

        do {
            try FileManager.default.removeItem(at: note.url)
        } catch {
            return .error("Delete failed: \(error.localizedDescription)")
        }

        bridge.notifyFileChanged(path: note.url.path)

        return .success([
            "status": "deleted",
            "title": note.title,
            "folder": note.folder,
            "path": note.relativePath,
            "isTextBundle": note.isTextBundle
        ])
    }
}
