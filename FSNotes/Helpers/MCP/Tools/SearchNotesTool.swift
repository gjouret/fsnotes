//
//  SearchNotesTool.swift
//  FSNotes
//
//  Filesystem-backed full-text search across notes. Walks the
//  storage tree under `MCPServer.shared.storageRoot` and returns
//  every note whose title or content contains the query string.
//  Optionally scoped to a single folder.
//
//  Search is intentionally simple: case-insensitive substring,
//  no tokenisation, no stemming, no ranking. The LLM is the
//  ranker — we just hand it candidate matches with snippets so it
//  can decide which note(s) to read in full.
//

import Foundation

public struct SearchNotesTool: MCPTool {
    public let name = "search_notes"
    public let description = "Search note titles and content for a query string. Returns up to 50 matches with surrounding-text snippets. Optionally scoped to a folder."

    private weak var server: MCPServer?

    /// Cap on returned hits — protects the LLM context window from a
    /// pathological query that matches every note in the vault.
    private let maxResults: Int

    /// Snippet width on each side of the match. Total snippet length
    /// is roughly `2 * snippetRadius + query.length`.
    private let snippetRadius: Int

    public init(
        server: MCPServer = .shared,
        maxResults: Int = 50,
        snippetRadius: Int = 60
    ) {
        self.server = server
        self.maxResults = maxResults
        self.snippetRadius = snippetRadius
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Substring to search for (case-insensitive)"
                ],
                "folder": [
                    "type": "string",
                    "description": "Optional storage-relative folder to limit the search to"
                ]
            ],
            "required": ["query"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = (server ?? MCPServer.shared).storageRoot else {
            return .error("FSNotes++ storage root is not configured")
        }
        guard let rawQuery = input["query"] as? String, !rawQuery.isEmpty else {
            return .error("Missing or empty 'query' parameter")
        }

        let scopeURL: URL
        if let folder = input["folder"] as? String, !folder.isEmpty {
            scopeURL = storageRoot.appendingPathComponent(folder)
            if !FileManager.default.fileExists(atPath: scopeURL.path) {
                return .error("Folder not found: \(folder)")
            }
        } else {
            scopeURL = storageRoot
        }

        let needle = rawQuery.lowercased()
        let candidates = NotePathResolver.listNotes(
            in: scopeURL,
            storageRoot: storageRoot,
            recursive: true
        )

        var hits: [[String: Any]] = []
        for note in candidates {
            if hits.count >= maxResults { break }
            if NotePathResolver.isEncrypted(at: note.url) { continue }

            let titleMatch = note.title.lowercased().contains(needle)
            let content = (try? String(contentsOf: note.markdownURL, encoding: .utf8)) ?? ""
            let lowered = content.lowercased()
            let bodyRange = lowered.range(of: needle)
            if !titleMatch && bodyRange == nil { continue }

            let snippet: String
            if let bodyRange = bodyRange {
                snippet = makeSnippet(
                    in: content,
                    matchLowercased: lowered,
                    matchRange: bodyRange
                )
            } else {
                // Title-only hit: show the start of the body.
                let prefix = content.prefix(snippetRadius * 2)
                snippet = String(prefix)
            }

            hits.append([
                "title": note.title,
                "folder": note.folder,
                "path": note.relativePath,
                "snippet": snippet,
                "isTextBundle": note.isTextBundle
            ])
        }

        return .success([
            "query": rawQuery,
            "scope": (input["folder"] as? String) ?? "",
            "matchCount": hits.count,
            "matches": hits
        ])
    }

    /// Build a single-line snippet around the match. Newlines are
    /// collapsed to spaces so the snippet is one readable line in
    /// the chat UI.
    private func makeSnippet(
        in content: String,
        matchLowercased: String,
        matchRange: Range<String.Index>
    ) -> String {
        let startOffset = max(
            content.distance(from: content.startIndex, to: matchRange.lowerBound) - snippetRadius,
            0
        )
        let endOffset = min(
            content.distance(from: content.startIndex, to: matchRange.upperBound) + snippetRadius,
            content.count
        )
        let start = content.index(content.startIndex, offsetBy: startOffset)
        let end = content.index(content.startIndex, offsetBy: endOffset)
        var snippet = String(content[start..<end])
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
        snippet = snippet.replacingOccurrences(of: "\r", with: " ")
        return snippet
    }
}
