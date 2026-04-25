//
//  MoveNoteTool.swift
//  FSNotes
//
//  Move a note (or TextBundle directory) to a different folder.
//  This is the only Phase 2 write tool: it touches the filesystem,
//  so it must coordinate with the live app via AppBridge.
//
//  Safety rules (docs/AI.md "Write Safety Rules"):
//   1. Refuse to move encrypted notes.
//   2. Refuse to overwrite an existing destination.
//   3. Ask the AppBridge for a write lock if the source note is
//      currently open and dirty; abort if the lock is denied.
//   4. Notify the AppBridge after the move completes so the editor
//      can re-resolve the open-note path / refresh the notes list.
//

import Foundation

public struct MoveNoteTool: MCPTool {
    public let name = "move_note"
    public let description = "Move a note to a different folder. Works on plain markdown files and TextBundle directories. Refuses to overwrite an existing destination or move encrypted notes."

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
                "source_folder": [
                    "type": "string",
                    "description": "Optional source folder (relative to storage root). Required when the title is ambiguous."
                ],
                "destination_folder": [
                    "type": "string",
                    "description": "Destination folder (relative to storage root). Empty string means the storage root."
                ],
                "path": [
                    "type": "string",
                    "description": "Optional full source path; takes precedence over title/source_folder."
                ]
            ],
            "required": ["destination_folder"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        let serverRef = server
        guard let storageRoot = serverRef.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        guard let destinationFolder = input["destination_folder"] as? String else {
            return .error("Missing 'destination_folder' parameter")
        }

        let title = input["title"] as? String
        let sourceFolder = input["source_folder"] as? String
        let path = input["path"] as? String

        let resolution = NotePathResolver.resolve(
            title: title,
            folder: sourceFolder,
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
            return .error("Multiple notes match. Specify source_folder:\n\(listing)")
        case .found(let resolved):
            note = resolved
        }

        if NotePathResolver.isEncrypted(at: note.url) {
            return .error("Cannot move encrypted note: \(note.relativePath)")
        }

        // Build the destination URL. The destination folder must
        // already exist; we don't auto-create deep paths because
        // that masks LLM mistakes silently.
        let destFolderURL: URL
        if destinationFolder.isEmpty {
            destFolderURL = storageRoot
        } else {
            destFolderURL = storageRoot.appendingPathComponent(destinationFolder)
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destFolderURL.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            return .error("Destination folder does not exist: \(destinationFolder)")
        }

        let destURL = destFolderURL.appendingPathComponent(note.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destURL.path) {
            return .error("Destination already exists: \(relativePath(of: destURL, under: storageRoot) ?? destURL.path)")
        }

        // If the note is currently open and dirty, ask the bridge.
        // Compare on standardized paths because the resolver returns
        // URLs without the /private/var symlink prefix while the
        // bridge may report the raw path it received from the editor.
        let bridge = serverRef.appBridge
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
            try FileManager.default.moveItem(at: note.url, to: destURL)
        } catch {
            return .error("Move failed: \(error.localizedDescription)")
        }

        let newRel = relativePath(of: destURL, under: storageRoot) ?? destURL.path
        bridge.notifyFileChanged(path: destURL.path)
        bridge.notifyFileChanged(path: note.url.path)

        return .success([
            "status": "moved",
            "oldPath": note.relativePath,
            "newPath": newRel,
            "isTextBundle": note.isTextBundle
        ])
    }

    private func relativePath(of child: URL, under root: URL) -> String? {
        let childPath = child.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        var prefix = rootPath
        if !prefix.hasSuffix("/") { prefix += "/" }
        guard childPath.hasPrefix(prefix) else { return nil }
        return String(childPath.dropFirst(prefix.count))
    }
}
