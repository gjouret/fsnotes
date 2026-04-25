//
//  GetCurrentNoteTool.swift
//  FSNotes
//
//  Return metadata about the note currently open in the editor —
//  path, folder, editor mode, dirty flag, cursor position. The
//  payload is sourced entirely from `MCPServer.shared.appBridge`;
//  when the bridge is the no-op default (e.g. tests, headless
//  startup, no editor on screen) the tool returns
//  `{ "open": false }` so the LLM can branch.
//
//  See docs/AI.md "MCP Tools" → `GetCurrentNoteTool`. The "respects
//  WYSIWYG vs source mode" wording maps to the `mode` field.
//

import Foundation

public struct GetCurrentNoteTool: MCPTool {
    public let name = "get_current_note"
    public let description = "Return metadata about the note currently open in the FSNotes++ editor (path, folder, title, mode, dirty flag, cursor). Returns open=false when no note is open."

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
        let bridge = server.appBridge
        guard let openPath = bridge.currentNotePath() else {
            return .success([
                "open": false
            ])
        }

        var payload: [String: Any] = [
            "open": true,
            "path": openPath,
            "hasUnsavedChanges": bridge.hasUnsavedChanges(path: openPath)
        ]

        if let mode = bridge.editorMode(for: openPath) {
            payload["mode"] = mode
        }
        if let cursor = bridge.cursorState(for: openPath) {
            payload["cursor"] = [
                "location": cursor.location,
                "length": cursor.length
            ]
        }

        // Resolve title / folder against the storage root when we can.
        // The bridge returns an absolute path; the LLM gets a clean
        // storage-relative summary for everything filesystem-bound it
        // wants to do next.
        if let storageRoot = server.storageRoot {
            let absURL = URL(fileURLWithPath: openPath).standardizedFileURL
            let rootPath = storageRoot.standardizedFileURL.path
            var prefix = rootPath
            if !prefix.hasSuffix("/") { prefix += "/" }
            if absURL.path.hasPrefix(prefix) {
                let rel = String(absURL.path.dropFirst(prefix.count))
                let last: String
                let folder: String
                if let slash = rel.lastIndex(of: "/") {
                    folder = String(rel[..<slash])
                    last = String(rel[rel.index(after: slash)...])
                } else {
                    folder = ""
                    last = rel
                }
                let title = (last as NSString).deletingPathExtension
                let isBundle = NotePathResolver.textBundleExtensions.contains(
                    absURL.pathExtension.lowercased()
                )
                payload["relativePath"] = rel
                payload["folder"] = folder
                payload["title"] = title
                payload["isTextBundle"] = isBundle
            }
        }

        return .success(payload)
    }
}
