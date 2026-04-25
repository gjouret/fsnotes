//
//  CreateNoteTool.swift
//  FSNotes
//
//  Create a new plain-markdown note (no TextBundle wrapper) on disk.
//  Refuses to overwrite an existing note. The destination folder
//  must already exist — auto-creating deep paths would mask LLM
//  mistakes silently. Notifies the AppBridge on success so the
//  notes list can refresh.
//
//  TextBundle creation is intentionally out of scope for this Phase
//  3 slice. The spec (`docs/AI.md` "TextBundle Handling") says it is
//  optional and gated on a user preference; we add a follow-up TODO
//  rather than guessing at the user's preference here.
//

import Foundation

public struct CreateNoteTool: MCPTool {
    public let name = "create_note"
    public let description = "Create a new markdown note in the given folder. Refuses to overwrite an existing file. The destination folder must already exist."

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
                    "description": "Title of the note. Used as the filename (sans extension). Must be non-empty."
                ],
                "folder": [
                    "type": "string",
                    "description": "Storage-relative folder path. Empty string means the storage root. The folder must exist."
                ],
                "content": [
                    "type": "string",
                    "description": "Initial markdown content. Defaults to '# <title>\\n' when omitted."
                ],
                "extension": [
                    "type": "string",
                    "description": "File extension to use. Defaults to 'md'. Allowed: 'md', 'markdown', 'txt'."
                ]
            ],
            "required": ["title", "folder"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        guard let title = input["title"] as? String, !title.isEmpty else {
            return .error("Missing or empty 'title' parameter")
        }
        guard let folder = input["folder"] as? String else {
            return .error("Missing 'folder' parameter")
        }
        let ext = (input["extension"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "md"
        guard NotePathResolver.markdownExtensions.contains(ext.lowercased()) else {
            return .error("Unsupported extension '\(ext)'. Use 'md', 'markdown', or 'txt'.")
        }

        // Reject path-traversal-ish titles. Filename-only.
        if title.contains("/") || title.contains("\\") || title.hasPrefix(".") {
            return .error("Title may not contain slashes or start with a dot")
        }

        let folderURL: URL
        if folder.isEmpty {
            folderURL = storageRoot
        } else {
            folderURL = storageRoot.appendingPathComponent(folder)
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            return .error("Folder does not exist: \(folder)")
        }

        let filename = title + "." + ext
        let destURL = folderURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destURL.path) {
            return .error("Note already exists: \(folder.isEmpty ? filename : folder + "/" + filename)")
        }

        // Bonus check: if the same title exists as a TextBundle, the
        // LLM is likely confused — surface that explicitly rather than
        // silently creating a parallel `.md` next to a `.textbundle`.
        let bundleURL = folderURL.appendingPathComponent(title + ".textbundle")
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            return .error("A TextBundle named '\(title)' already exists in '\(folder)'. Use a different title or move/delete the existing bundle first.")
        }

        let content = (input["content"] as? String) ?? "# \(title)\n"

        do {
            try content.write(to: destURL, atomically: true, encoding: .utf8)
        } catch {
            return .error("Create failed: \(error.localizedDescription)")
        }

        let relPath = folder.isEmpty ? filename : folder + "/" + filename
        server.appBridge.notifyFileChanged(path: destURL.path)

        return .success([
            "status": "created",
            "title": title,
            "folder": folder,
            "path": relPath,
            "isTextBundle": false
        ])
    }
}
