//
//  EditNoteTool.swift
//  FSNotes
//
//  Apply a structured edit to a note. Operations are expressed in
//  block-coordinate terms (per docs/AI.md "Why no line-based
//  edits?"); the tool refuses line/inline coordinates because the
//  Document model has no concept of lines.
//
//  Routing matrix:
//
//    | Note state                    | Path                              |
//    |-------------------------------|-----------------------------------|
//    | Closed                        | direct file rewrite               |
//    | Open in source mode (clean)   | direct file rewrite + reload      |
//    | Open in source mode (dirty)   | requestWriteLock + rewrite        |
//    | Open in WYSIWYG (any state)   | appBridge.applyStructuredEdit     |
//
//  For the closed / source paths the tool re-renders the note
//  by splitting the file's markdown into top-level blocks (separated
//  by blank lines), performing the requested operation on the block
//  array, and serialising back. This is intentionally crude — it
//  is good enough for the LLM's typical use cases (replace section
//  N, insert before section N, delete section N) and avoids pulling
//  in the full FSNotesCore parser at the MCP layer.
//
//  When higher fidelity is needed (e.g. inline edits inside a
//  block, list-item structural ops) the LLM should open the note
//  in WYSIWYG mode and route through the bridge.
//

import Foundation

public struct EditNoteTool: MCPTool {
    public let name = "edit_note"
    public let description = "Apply a block-level edit to a note (replace, insert before, delete, or full replace). Block indices are 0-based; blocks are separated by blank lines. For inline edits inside a block, replace the whole block. WYSIWYG editing of an open note routes through the block-model pipeline."

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
                "operation": [
                    "type": "string",
                    "description": "One of: 'replace_block', 'insert_before', 'delete_block', 'replace_document'.",
                    "enum": ["replace_block", "insert_before", "delete_block", "replace_document"]
                ],
                "blockIndex": [
                    "type": "integer",
                    "description": "0-based block index. Required for replace_block, insert_before, delete_block. Ignored for replace_document."
                ],
                "markdown": [
                    "type": "string",
                    "description": "Markdown payload. Required for replace_block, insert_before, replace_document. Ignored for delete_block."
                ]
            ],
            "required": ["operation"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        guard let opString = input["operation"] as? String else {
            return .error("Missing 'operation' parameter")
        }

        // Parse operation up front so we fail fast on malformed input.
        let request: BridgeEditRequest
        switch opString {
        case "replace_block":
            guard let idx = input["blockIndex"] as? Int else {
                return .error("'blockIndex' is required for replace_block")
            }
            guard let md = input["markdown"] as? String else {
                return .error("'markdown' is required for replace_block")
            }
            request = BridgeEditRequest(kind: .replaceBlock(index: idx, markdown: md))
        case "insert_before":
            guard let idx = input["blockIndex"] as? Int else {
                return .error("'blockIndex' is required for insert_before")
            }
            guard let md = input["markdown"] as? String else {
                return .error("'markdown' is required for insert_before")
            }
            request = BridgeEditRequest(kind: .insertBefore(index: idx, markdown: md))
        case "delete_block":
            guard let idx = input["blockIndex"] as? Int else {
                return .error("'blockIndex' is required for delete_block")
            }
            request = BridgeEditRequest(kind: .deleteBlock(index: idx))
        case "replace_document":
            guard let md = input["markdown"] as? String else {
                return .error("'markdown' is required for replace_document")
            }
            request = BridgeEditRequest(kind: .replaceDocument(markdown: md))
        default:
            return .error("Unsupported operation '\(opString)'. Use replace_block, insert_before, delete_block, or replace_document.")
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
            return .error("Cannot edit encrypted note: \(note.relativePath)")
        }

        // Decide route.
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
            switch bridge.applyStructuredEdit(toPath: openPathRaw ?? notePath, request: request) {
            case .applied(let info):
                var payload: [String: Any] = [
                    "status": "edited",
                    "path": note.relativePath,
                    "operation": opString,
                    "mode": "wysiwyg",
                    "viaBridge": true
                ]
                for (k, v) in info { payload[k] = v }
                return .success(payload)
            case .failed(let reason):
                return .error("Edit failed in WYSIWYG mode: \(reason)")
            case .notImplemented:
                return .error("Editing the open WYSIWYG note via edit_note requires the AppBridge editing API, which is a Phase 3 follow-up. Switch to source mode or close the note and retry.")
            }
        }

        // Source mode (open or closed): direct file rewrite.
        if isOpen, bridge.hasUnsavedChanges(path: openPathRaw ?? notePath) {
            if !bridge.requestWriteLock(path: openPathRaw ?? notePath) {
                return .error("Note has unsaved changes; the editor declined the write lock. Save first and retry.")
            }
        }

        let mdURL = note.markdownURL
        let existing = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        let newContent: String
        do {
            newContent = try applyOperation(request.kind, to: existing)
        } catch let err as EditError {
            return .error(err.message)
        } catch {
            return .error("Edit failed: \(error.localizedDescription)")
        }

        do {
            try newContent.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return .error("Edit failed: \(error.localizedDescription)")
        }

        bridge.notifyFileChanged(path: note.url.path)

        return .success([
            "status": "edited",
            "path": note.relativePath,
            "operation": opString,
            "mode": mode ?? "closed",
            "viaBridge": false,
            "bytesWritten": newContent.utf8.count
        ])
    }

    // MARK: - Block split / join

    private struct EditError: Error {
        let message: String
    }

    /// Apply a kind to a markdown string by splitting on blank-line
    /// block separators. Coarse but predictable — the LLM gets
    /// stable block coordinates without us pulling in the full
    /// MarkdownParser. For richer edits the WYSIWYG branch routes
    /// through the bridge.
    func applyOperation(_ kind: BridgeEditRequest.Kind, to markdown: String) throws -> String {
        switch kind {
        case .replaceDocument(let md):
            return md.hasSuffix("\n") ? md : md + "\n"
        default:
            break
        }

        var blocks = splitIntoBlocks(markdown)

        switch kind {
        case .replaceBlock(let idx, let md):
            try assertIndex(idx, in: blocks, allowEnd: false, op: "replace_block")
            blocks[idx] = normaliseBlock(md)
        case .insertBefore(let idx, let md):
            try assertIndex(idx, in: blocks, allowEnd: true, op: "insert_before")
            blocks.insert(normaliseBlock(md), at: idx)
        case .deleteBlock(let idx):
            try assertIndex(idx, in: blocks, allowEnd: false, op: "delete_block")
            blocks.remove(at: idx)
        case .replaceDocument:
            break
        }

        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    private func assertIndex(_ idx: Int, in blocks: [String], allowEnd: Bool, op: String) throws {
        let upper = allowEnd ? blocks.count : max(blocks.count - 1, -1)
        if idx < 0 || idx > upper {
            throw EditError(message: "Block index \(idx) out of range for '\(op)' (note has \(blocks.count) blocks).")
        }
    }

    /// Split the markdown into top-level blocks. A blank line
    /// (a line whose stripped content is empty) separates blocks.
    /// Fenced code blocks are kept intact — blank lines inside a
    /// fence do not split the block.
    func splitIntoBlocks(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inFence = false
        var fenceMarker: String? = nil

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inFence {
                if let marker = leadingFenceMarker(in: trimmed) {
                    inFence = true
                    fenceMarker = marker
                    current.append(line)
                    continue
                }
                if trimmed.isEmpty {
                    if !current.isEmpty {
                        blocks.append(current.joined(separator: "\n"))
                        current.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                current.append(line)
            } else {
                current.append(line)
                if let marker = fenceMarker, trimmed.hasPrefix(marker), !trimmed.contains(" ") {
                    // Close fence on a matching marker line.
                    inFence = false
                    fenceMarker = nil
                }
            }
        }

        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }

        return blocks
    }

    /// Strip trailing blank lines from a block payload supplied by
    /// the LLM and remove a trailing newline so the joined output
    /// ends with exactly one blank line per block separator.
    private func normaliseBlock(_ payload: String) -> String {
        var block = payload
        while block.hasSuffix("\n") || block.hasSuffix("\r") {
            block.removeLast()
        }
        return block
    }

    /// Return the fence marker (` ``` ` or `~~~`, possibly indented)
    /// if `line` starts a fenced code block, else nil.
    private func leadingFenceMarker(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }
}
