//
//  GetTagsTool.swift
//  FSNotes
//
//  Aggregate every `#tag` referenced across the storage tree. Walks
//  the filesystem and runs `FSParser.tagsPattern` over each note's
//  raw markdown — the same pattern `Note.scanContentTags` uses, so
//  the result matches what the sidebar shows.
//
//  Note: this is a filesystem walk, not a query against the live
//  app's tag cache. It works on closed notes too. The payload
//  carries hit counts so the LLM can rank tags by use.
//

import Foundation

public struct GetTagsTool: MCPTool {
    public let name = "get_tags"
    public let description = "List every #tag referenced across the vault, with a per-tag count of how many notes mention it. Optionally scoped to a folder."

    private let server: MCPServer

    /// Cap on how many notes we are willing to scan in one call. A
    /// vault with tens of thousands of notes can reach this; the
    /// LLM can scope by folder to drill down.
    private let maxNotesScanned: Int

    public init(server: MCPServer = .shared, maxNotesScanned: Int = 2000) {
        self.server = server
        self.maxNotesScanned = maxNotesScanned
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [
                "folder": [
                    "type": "string",
                    "description": "Optional storage-relative folder to scope the scan to. Empty / omitted means the whole vault."
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

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(
                pattern: FSParser.tagsPattern,
                options: [.allowCommentsAndWhitespace, .anchorsMatchLines]
            )
        } catch {
            return .error("Failed to compile tag pattern: \(error.localizedDescription)")
        }

        var counts: [String: Int] = [:]
        var notesWithTag: [String: Set<String>] = [:]
        var scanned = 0

        for note in notes {
            if scanned >= maxNotesScanned { break }
            if NotePathResolver.isEncrypted(at: note.url) { continue }
            guard let content = try? String(contentsOf: note.markdownURL, encoding: .utf8) else {
                continue
            }
            scanned += 1
            let nsContent = content as NSString
            let range = NSRange(location: 0, length: nsContent.length)
            var seenInThisNote: Set<String> = []
            regex.enumerateMatches(in: content, options: [], range: range) { match, _, _ in
                guard let match = match, match.numberOfRanges > 1 else { return }
                let tagRange = match.range(at: 1)
                if tagRange.location == NSNotFound { return }
                let tag = nsContent.substring(with: tagRange)
                if tag.isEmpty { return }
                seenInThisNote.insert(tag)
            }
            for tag in seenInThisNote {
                counts[tag, default: 0] += 1
                notesWithTag[tag, default: []].insert(note.relativePath)
            }
        }

        // Stable, useful ordering: most-used first, then alpha.
        let sorted = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        let entries: [[String: Any]] = sorted.map { (tag, count) in
            [
                "tag": tag,
                "noteCount": count
            ]
        }

        var payload: [String: Any] = [
            "scope": folder ?? "",
            "tagCount": entries.count,
            "scannedNotes": scanned,
            "totalNotes": notes.count,
            "tags": entries
        ]
        if scanned < notes.count {
            payload["truncated"] = true
        }
        return .success(payload)
    }
}
