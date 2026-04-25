//
//  ExportPDFTool.swift
//  FSNotes
//
//  Render a note to PDF on disk. The file is written to a path
//  the LLM provides (or, when omitted, alongside the source note
//  with the markdown extension swapped for `.pdf`). We refuse to
//  overwrite an existing file unless the LLM passes `overwrite: true`.
//
//  Routing:
//
//  - **Open in WYSIWYG**: route through `AppBridge.exportPDF` so the
//    on-screen `EditTextView` (with its TK2 layout) is the source.
//    The bridge calls the existing `PDFExporter` helper.
//  - **Closed, or open in source mode**: surface a clear error
//    saying that high-fidelity PDF export needs the note open in
//    WYSIWYG. We deliberately do *not* render headlessly — that
//    would require parsing the note into a Document, building a
//    transient TK2 stack, and rendering, which is well outside
//    Phase 3 scope. The MCP server has the option of a future
//    `BackgroundPDFRenderer` that does this; the spec leaves it
//    open.
//

import Foundation

public struct ExportPDFTool: MCPTool {
    public let name = "export_pdf"
    public let description = "Export a note to PDF on disk. Currently requires the note to be open in WYSIWYG mode (the renderer reuses the live editor's TK2 layout). Closed-note headless export is a future enhancement."

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
                "outputPath": [
                    "type": "string",
                    "description": "Absolute filesystem path for the output PDF. When omitted the tool writes alongside the source note (e.g. 'foo.md' → 'foo.pdf')."
                ],
                "overwrite": [
                    "type": "boolean",
                    "description": "If true, overwrite an existing file at outputPath. Defaults to false."
                ]
            ],
            "required": []
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let storageRoot = server.storageRoot else {
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
            return .error("Cannot export encrypted note: \(note.relativePath)")
        }

        // Compute output URL. Default: alongside the source note with
        // a `.pdf` extension. For TextBundles, drop the
        // `.textbundle` and use the bare title.
        let outputURL: URL
        if let raw = input["outputPath"] as? String, !raw.isEmpty {
            outputURL = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            let parent = note.url.deletingLastPathComponent()
            outputURL = parent.appendingPathComponent(note.title + ".pdf")
        }

        let overwrite = (input["overwrite"] as? Bool) ?? false
        if FileManager.default.fileExists(atPath: outputURL.path) && !overwrite {
            return .error("File already exists: \(outputURL.path). Pass overwrite=true to replace it.")
        }

        // Routing: WYSIWYG note open and matching → bridge.
        let bridge = server.appBridge
        let notePath = note.url.standardizedFileURL.path
        var routedThroughBridge = false
        if let openPathRaw = bridge.currentNotePath() {
            let openPath = URL(fileURLWithPath: openPathRaw).standardizedFileURL.path
            if openPath == notePath, bridge.editorMode(for: openPathRaw) == "wysiwyg" {
                switch bridge.exportPDF(forPath: openPathRaw, to: outputURL) {
                case .applied(let info):
                    routedThroughBridge = true
                    var payload: [String: Any] = [
                        "status": "exported",
                        "path": note.relativePath,
                        "outputPath": outputURL.path,
                        "viaBridge": true
                    ]
                    for (k, v) in info { payload[k] = v }
                    return .success(payload)
                case .failed(let reason):
                    return .error("PDF export failed: \(reason)")
                case .notImplemented:
                    // Fall through to the headless-not-supported error.
                    break
                }
            }
        }

        // routedThroughBridge is left as a marker for future
        // headless-render expansion; today every bridge-applied path
        // returns above, so any miss falls through to the
        // "open in WYSIWYG" error.
        _ = routedThroughBridge
        return .error("export_pdf currently requires the note to be open in WYSIWYG mode (the renderer reuses the live TK2 layout). Open the note and retry. Closed-note headless rendering is a Phase 3 follow-up.")
    }
}
