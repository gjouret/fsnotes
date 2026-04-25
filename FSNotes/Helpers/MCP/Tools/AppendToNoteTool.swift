//
//  AppendToNoteTool.swift
//  FSNotes
//
//  Append markdown to the end of an existing note. Routing matrix:
//
//    | Note state                         | Path                       |
//    |------------------------------------|----------------------------|
//    | Closed                             | direct file append         |
//    | Open in source mode (clean)        | direct file append + reload|
//    | Open in source mode (dirty)        | requestWriteLock + append  |
//    | Open in WYSIWYG (any state)        | appBridge.appendMarkdown   |
//
//  The WYSIWYG branch goes through the AppBridge so the edit folds
//  through `EditingOps` + `DocumentEditApplier` (Invariant A —
//  single write path into TK2 content storage). When the bridge
//  returns `.notImplemented` we surface a clear error rather than
//  reaching past it into `textStorage`.
//

import Foundation

public struct AppendToNoteTool: MCPTool {
    public let name = "append_to_note"
    public let description = "Append markdown to the end of an existing note. In WYSIWYG mode the append routes through the block-model pipeline; in source mode or for closed notes it writes the file directly. Refuses to delete or replace existing content."

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
                "content": [
                    "type": "string",
                    "description": "Markdown to append. The tool inserts a single newline between the existing content and the appended text if needed."
                ]
            ],
            "required": ["content"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        guard let appendText = input["content"] as? String, !appendText.isEmpty else {
            return .error("Missing or empty 'content' parameter")
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
            return .error("Cannot append to encrypted note: \(note.relativePath)")
        }

        // Routing decision.
        let bridge = server.appBridge
        let notePath = note.url.standardizedFileURL.path
        let openPathRaw = bridge.currentNotePath()
        let isOpen: Bool
        let mode: String?
        if let openPathRaw = openPathRaw {
            let openPath = URL(fileURLWithPath: openPathRaw).standardizedFileURL.path
            isOpen = (openPath == notePath)
            mode = isOpen ? bridge.editorMode(for: openPathRaw) : nil
        } else {
            isOpen = false
            mode = nil
        }

        if isOpen, let mode = mode, mode == "wysiwyg" {
            // WYSIWYG must route through the bridge to honour
            // Invariant A. If the bridge has not been wired up we
            // surface a precise error rather than corrupting the
            // Document model.
            switch bridge.appendMarkdown(toPath: openPathRaw ?? notePath, markdown: appendText) {
            case .applied(let info):
                var payload: [String: Any] = [
                    "status": "appended",
                    "path": note.relativePath,
                    "mode": "wysiwyg",
                    "viaBridge": true
                ]
                for (k, v) in info { payload[k] = v }
                return .success(payload)
            case .failed(let reason):
                return .error("Append failed in WYSIWYG mode: \(reason)")
            case .notImplemented:
                return .error("Editing the open WYSIWYG note via append_to_note requires the AppBridge editing API, which is a Phase 3 follow-up. Switch to source mode or close the note and retry.")
            }
        }

        // Source mode (open or closed): direct file append.
        if isOpen, bridge.hasUnsavedChanges(path: openPathRaw ?? notePath) {
            if !bridge.requestWriteLock(path: openPathRaw ?? notePath) {
                return .error("Note has unsaved changes; the editor declined the write lock. Save first and retry.")
            }
        }

        let mdURL = note.markdownURL
        let existing = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        let separator: String
        if existing.isEmpty || existing.hasSuffix("\n\n") {
            separator = ""
        } else if existing.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        let combined = existing + separator + appendText
            + (appendText.hasSuffix("\n") ? "" : "\n")

        do {
            try combined.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return .error("Append failed: \(error.localizedDescription)")
        }

        bridge.notifyFileChanged(path: note.url.path)

        return .success([
            "status": "appended",
            "path": note.relativePath,
            "mode": mode ?? "closed",
            "viaBridge": false,
            "bytesWritten": combined.utf8.count
        ])
    }
}
