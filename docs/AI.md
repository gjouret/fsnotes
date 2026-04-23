# AI Chat Integration Spec

## Overview

This document describes the architecture and implementation plan for integrating an AI chat sidebar into FSNotes++. The AI chat uses Ollama as the local LLM provider and exposes an MCP (Model Context Protocol) interface through which the AI can interact with notes, the editor, and application features.

**Current Status:** Partially implemented
- AI button in toolbar exists
- Basic AIChatPanelView with streaming support
- Settings for API key, provider, model, endpoint
- Anthropic and OpenAI providers only

**Goal:** Add Ollama support, implement MCP server, expand AI capabilities

---

## Architecture Principles

Following FSNotes++ architecture patterns:

1. **Unidirectional Data Flow**: AI chat state managed via `AIChatStore` with actions/effects. Editor-mutating effects dispatch through the existing `EditorStore`/`EffectHandler` infrastructure — do not call `EditingOps` directly from UI code.
2. **Protocol-Oriented Design**: `AIProvider` protocol allows pluggable LLM backends; `MCPTool` protocol allows pluggable tools.
3. **MCP as First-Class Interface**: All AI interactions go through MCP tools.
4. **No Direct Storage Access in WYSIWYG**: AI manipulates notes through the Document model (`EditingOps`) or `EditorStore.dispatch`, never by writing `note.content` or `textStorage` directly when `blockModelActive == true`. For closed notes, direct filesystem access is preferred.
5. **Editor Integration**: AI respects the block-model pipeline when editing open notes in WYSIWYG mode. For closed notes or source mode, direct filesystem access is acceptable.

---

## UI Layout

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Sidebar  │  Notes List  │        Note Editor          │  AI Chat Panel │
│           │              │                             │  (320px wide)  │
│  Projects │  Note 1      │  # My Note                  │  ┌──────────┐  │
│  Tags     │  Note 2      │                             │  │ Header   │  │
│  ...      │  Note 3      │  Content here...            │  ├──────────┤  │
│           │              │                             │  │ Messages │  │
│           │              │                             │  │ Scroll   │  │
│           │              │                             │  │ Area     │  │
│           │              │                             │  ├──────────┤  │
│           │              │                             │  │ Input    │  │
│           │              │                             │  │ + Send   │  │
│           │              │                             │  └──────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

The AI chat panel is a sibling view to `editAreaScroll`, positioned on the right side. When visible, it constrains `editAreaScroll.trailingAnchor` to its leading edge.

---

## Data Flow

```
User Input
    │
    ▼
┌─────────────────┐
│ AIChatPanelView │  ──► Message bubbles UI, input handling
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   AIChatStore   │  ──► Redux-style state management
│                 │     (messages, streaming state, error)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   MCP Server    │  ──► Exposes tools to LLM via Ollama
│  (Ollama+Tools) │     (read_note, write_note, search_notes, etc.)
└────────┬────────┘
         │
         ├──────────────────┬──────────────────┐
         ▼                  ▼                  ▼
    ┌─────────┐      ┌──────────┐      ┌──────────┐
    │ Storage │      │ Document │      │   Note   │
    │  Layer  │      │  Model   │      │   Ops    │
    └─────────┘      └──────────┘      └──────────┘
```

**WYSIWYG path**: MCP tools that write open notes in WYSIWYG mode must go through `Document Model` → `EditingOps`. For closed notes or source mode, direct filesystem access is preferred — but always notify the app via `AppBridge`.

---

## Components

### 1. AIChatPanelView (Existing)

**Location:** `FSNotes/Helpers/AIChatPanelView.swift`

**Responsibilities:**
- Render message bubbles (user/assistant)
- Handle user input (textarea + send button)
- Quick actions popup (summarize, fix grammar, etc.)
- Apply button for suggested edits
- Close button to dismiss panel

**Changes Needed:**
- Integrate with `AIChatStore` for state management
- Remove direct `AIServiceFactory` usage (go through MCP)
- Add tool call visualization (when AI uses MCP tools)

### 2. AIChatStore (New)

**Location:** `FSNotes/Helpers/AIChatStore.swift`

```swift
public struct AIChatState {
    public var messages: [ChatMessage]
    public var isStreaming: Bool
    public var error: AIError?
    public var pendingToolCalls: [ToolCall]
}

public enum AIChatAction {
    case sendMessage(String)
    case receiveToken(String)
    case completeResponse(Result<String, Error>)
    case toolCallRequested(ToolCall)
    case toolCallCompleted(ToolCall, Result<ToolOutput, Error>)
    case clearChat
}

public final class AIChatStore {
    public private(set) var state: AIChatState
    public func dispatch(_ action: AIChatAction)
    public func subscribe(_ callback: @escaping (AIChatState) -> Void)
    
    // When editor mutation is needed, dispatch to EditorStore instead of calling EditingOps directly
    public var editorStore: EditorStore?
}
```

### 3. MCPServer (New)

**Location:** `FSNotes/Helpers/MCP/MCPServer.swift`

The MCP server exposes tools to the LLM. Uses Ollama's native tool calling support.

```swift
public protocol MCPTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }
    func execute(input: [String: Any]) async throws -> ToolOutput
}

public final class MCPServer {
    public static let shared = MCPServer()
    
    public func registerTool(_ tool: MCPTool)
    public func handleToolCalls(_ calls: [ToolCall]) async -> [ToolResult]
    
    // Ollama integration
    public func createOllamaChatRequest(
        messages: [ChatMessage],
        model: String,
        tools: [MCPTool]
    ) -> URLRequest
}
```

### 4. MCP Tools (New)

**Location:** `FSNotes/Helpers/MCP/Tools/`

Each tool is a separate file implementing `MCPTool`.

| Tool | Purpose |
|------|---------|
| `ReadNoteTool` | Read note content by title/path (folder-aware for disambiguation) |
| `WriteNoteTool` | Replace note content (optionally create in target folder) |
| `EditNoteTool` | Apply structured edits via `EditingOps` (block/inline coordinates, not line ranges). |
| `SearchNotesTool` | Search notes by query/tags across all folders or scoped to a folder |
| `ListNotesTool` | List notes in a specific folder/project with optional recursive search |
| `ListFoldersTool` | List all folders (directory tree) |
| `GetFolderNotesTool` | List notes in a folder with metadata (title, path, modified date) |
| `MoveNoteTool` | Move a note to a different folder |
| `DeleteNoteTool` | Delete a note (requires confirmation, folder-aware) |
| `CreateNoteTool` | Create new note with content (optionally in a target folder) |
| `GetCurrentNoteTool` | Get the currently open note (respects WYSIWYG vs source mode, includes folder path) |
| `ExportPDFTool` | Export note as PDF |
| `GetTagsTool` | List all tags |
| `GetProjectsTool` | List all projects (top-level storage containers) |
| `ApplyFormattingTool` | Apply markdown formatting via `EditingOps` in WYSIWYG, or direct attribute manipulation in source mode. |
| `AppendToNoteTool` | Append text to end of note (uses `EditingOps.append` in WYSIWYG). |

## Folders and TextBundle Awareness

FSNotes organizes notes in a folder hierarchy. Notes may also be stored as **TextBundles** (`.textbundle` directories containing `text.md`, `info.json`, and assets). The MCP tools must handle both structures correctly.

### Folder Path Semantics

| Concept | Representation | Example |
|---------|---------------|---------|
| **Project** | Top-level storage root | `default`, `iCloud Drive/FSNotes` |
| **Folder** | Relative path within project | `Work/Meetings`, `Journal/2026` |
| **Note** | File name (with or without `.md` extension) | `Standup Notes`, `Ideas.textbundle` |
| **Full path** | `folder/note` | `Work/Meetings/Standup Notes` |

**Ambiguity rule**: If `title` alone matches multiple notes across folders, the tool must return a disambiguation error listing the matching `(folder, title)` pairs. The LLM should then retry with an explicit `folder` parameter.

### TextBundle Handling

When a note is stored as a TextBundle:
- Reading: Read `text.md` inside the bundle. Return the markdown content.
- Writing: Write to `text.md` inside the bundle. Preserve `info.json` and the `assets/` directory.
- Creating: If the user enables TextBundle by default, create a `.textbundle` directory with `text.md` and `info.json`.
- Moving: Move the entire `.textbundle` directory.

### Tool Input Schema Updates

All note-targeting tools accept an optional `folder` parameter:

```swift
public var inputSchema: [String: Any] {
    [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Title of the note"],
            "folder": ["type": "string", "description": "Optional relative folder path (e.g. 'Work/Meetings')"],
            "path": ["type": "string", "description": "Optional full relative path (folder/title)"]
        ],
        "required": ["title"]
    ]
}
```

The tool resolves the note in this order:
1. If `path` is provided, use it directly (`folder/title`).
2. If `folder` + `title` are provided, resolve within that folder.
3. If only `title` is provided, search all folders. If exactly one match, use it. If multiple matches, return disambiguation error.

### Example: Folder-Aware ReadNoteTool

```swift
public struct ReadNoteTool: MCPTool {
    public let name = "read_note"
    public let description = "Read the content of a note by its title and optional folder path"
    
    public func execute(input: [String: Any]) async throws -> ToolOutput {
        let title = input["title"] as? String
        let folder = input["folder"] as? String
        let path = input["path"] as? String
        
        guard let title = title else {
            return ToolOutput.error("Missing 'title' parameter")
        }
        
        let note: Note?
        if let path = path {
            note = Storage.shared().getBy(path: path)
        } else if let folder = folder {
            note = Storage.shared().getBy(title: title, inFolder: folder)
        } else {
            let matches = Storage.shared().getAllBy(title: title)
            if matches.count == 1 {
                note = matches.first
            } else if matches.count > 1 {
                let disambiguation = matches.map { "- \($0.folder)/\($0.title)" }.joined(separator: "\n")
                return ToolOutput.error("Multiple notes found with title '\(title)'. Specify a folder:\n\(disambiguation)")
            } else {
                note = nil
            }
        }
        
        guard let note = note else {
            return ToolOutput.error("Note not found: \(title)")
        }
        
        // Respect block-model pipeline: serialize Document in WYSIWYG mode
        let content: String
        if let projection = note.editTextView?.documentProjection {
            content = MarkdownSerializer.serialize(projection.document)
        } else {
            content = note.content.string
        }
        
        return ToolOutput.success([
            "title": note.title,
            "folder": note.folder,
            "path": note.url.path,
            "content": content,
            "tags": note.tags,
            "isTextBundle": note.url.pathExtension == "textbundle"
        ])
    }
}
```

### New Tools for Folder Navigation

**ListFoldersTool**
```swift
public struct ListFoldersTool: MCPTool {
    public let name = "list_folders"
    public let description = "List all folders in the storage hierarchy"
    
    public func execute(input: [String: Any]) async throws -> ToolOutput {
        let recursive = input["recursive"] as? Bool ?? false
        let folders = Storage.shared().listFolders(recursive: recursive)
        return ToolOutput.success(["folders": folders])
    }
}
```

**GetFolderNotesTool**
```swift
public struct GetFolderNotesTool: MCPTool {
    public let name = "get_folder_notes"
    public let description = "List all notes in a specific folder"
    
    public func execute(input: [String: Any]) async throws -> ToolOutput {
        guard let folder = input["folder"] as? String else {
            return ToolOutput.error("Missing 'folder' parameter")
        }
        let recursive = input["recursive"] as? Bool ?? false
        let notes = Storage.shared().getNotes(inFolder: folder, recursive: recursive)
        let summaries = notes.map { [
            "title": $0.title,
            "folder": $0.folder,
            "modified": $0.modifiedDate,
            "isTextBundle": $0.url.pathExtension == "textbundle"
        ]}
        return ToolOutput.success(["notes": summaries])
    }
}
```

**MoveNoteTool**
```swift
public struct MoveNoteTool: MCPTool {
    public let name = "move_note"
    public let description = "Move a note to a different folder"
    
    public func execute(input: [String: Any]) async throws -> ToolOutput {
        guard let title = input["title"] as? String,
              let destination = input["destination_folder"] as? String else {
            return ToolOutput.error("Missing 'title' or 'destination_folder'")
        }
        
        let sourceFolder = input["source_folder"] as? String
        guard let note = resolveNote(title: title, folder: sourceFolder) else {
            return ToolOutput.error("Note not found")
        }
        
        try Storage.shared().moveNote(note, toFolder: destination)
        return ToolOutput.success(["status": "moved", "newPath": "\(destination)/\(note.title)"])
    }
}
```

**Write tools** (e.g., `WriteNoteTool`, `EditNoteTool`) must follow the inverse path:

```swift
public struct WriteNoteTool: MCPTool {
    public let name = "write_note"
    
    public func execute(input: [String: Any]) async throws -> ToolOutput {
        guard let title = input["title"] as? String,
              let markdown = input["content"] as? String else {
            return ToolOutput.error("Missing parameters")
        }
        
        let folder = input["folder"] as? String
        let note = resolveNote(title: title, folder: folder)
        
        guard let note = note else {
            return ToolOutput.error("Note not found: \(title)")
        }
        
        if let projection = note.editTextView?.documentProjection {
            // WYSIWYG: parse markdown into Document, replace, re-render
            let newDoc = try MarkdownParser.parse(markdown)
            projection.document = newDoc
            let fullRange = NSRange(location: 0, length: note.textStorage.length)
            note.editTextView?.syncTextStorageWithDocument(fullRange: fullRange)
        } else {
            // Source mode: direct string replacement
            note.content = NSMutableAttributedString(string: markdown)
        }
        
        note.save()
        return ToolOutput.success(["status": "saved", "path": "\(note.folder)/\(note.title)"])
    }
}
```

### 5. AIProvider Protocol (Existing - Extended)

**Location:** `FSNotes/Helpers/AIService.swift`

Add Ollama provider:

```swift
class OllamaProvider: AIProvider {
    private let host: String
    private let model: String
    private let mcpserver: MCPServer
    
    func sendMessage(
        messages: [ChatMessage],
        noteContent: String,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        // 1. Build system prompt with available tools
        // 2. Send request to Ollama with tools schema
        // 3. Handle streaming response
        // 4. If tool calls are requested, execute them via MCPServer
        //    - Tools must respect WYSIWYG/source mode (see Block-Model Pipeline Integration)
        // 5. Continue conversation with tool results
    }
}
```

### 6. PreferencesAIViewController (New)

**Location:** `FSNotes/Preferences/PreferencesAIViewController.swift`

**Tab Icon:** `brain` (SF Symbols)

**UI Elements:**
- Provider selection: Ollama / Anthropic / OpenAI
- For Ollama:
  - Host URL (default: http://localhost:11434)
  - Model selection dropdown (populated from `ollama list`)
  - "Refresh Models" button
  - Status indicator (Ollama reachable/not reachable)
- For Anthropic/OpenAI:
  - API Key field (secure)
  - Model name field
  - Endpoint URL (optional, for custom proxies)

**Integration:**
- Add `aiTabViewItem` to `PrefsViewController.swift`
- Add constants to `UserDefaultsManagement.Constants`:
  - `AIProvider` (already exists)
  - `AIModel` (already exists)
  - `AIEndpoint` (already exists)
  - `AIOllamaHost` (new)

---

## Ollama Integration

### Requirements

- Ollama must be installed and running locally
- Models must be pulled via `ollama pull <model>`
- Recommended models: `llama3.2`, `mistral`, `qwen2.5`

### Model Selection

```swift
class OllamaClient {
    static func listModels(host: String) async throws -> [OllamaModel] {
        let url = URL(string: "\(host)/api/tags")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return response.models
    }
    
    static func checkReachability(host: String) async -> Bool {
        guard let url = URL(string: "\(host)/api/version") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
```

### Tool Calling

Ollama supports native tool calling via the `/api/chat` endpoint:

```json
{
  "model": "llama3.2",
  "messages": [...],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_note",
        "description": "Read note content",
        "parameters": { ... }
      }
    }
  ],
  "stream": true
}
```

When the model requests a tool call, the response includes:

```json
{
  "message": {
    "role": "assistant",
    "tool_calls": [
      {
        "function": {
          "name": "read_note",
          "arguments": {"title": "Meeting Notes"}
        }
      }
    ]
  }
}
```

The client executes the tool and sends the result back as a `tool` message:

```json
{
  "role": "tool",
  "content": "{...note content...}"
}
```

---

## System Prompt

The system prompt exposes FSNotes++ context to the AI. It must inform the AI about the block-model pipeline so it does not suggest direct textStorage manipulation:

```
You are an AI assistant integrated into FSNotes++, a markdown note-taking app for macOS.

Current context:
- Active note: {{note.title}}
- Folder: {{note.folder}}
- Note content: {{note.content}}
- Project: {{note.project.name}}
- Available tags: {{all_tags}}
- Editor mode: {{wysiwyg ? "WYSIWYG (Document model)" : "Source mode"}}
- Storage format: {{note.isTextBundle ? "TextBundle" : "Plain markdown"}}

You have access to tools for interacting with notes. Use them when appropriate:
- read_note: Get content of any note (specify folder if ambiguous)
- search_notes: Find notes by content or tags across all folders or a specific folder
- write_note: Replace entire note content (preserves WYSIWYG invariants)
- edit_note: Apply specific edits via Document operations (not line ranges)
- create_note: Create new notes (optionally in a target folder)
- delete_note: Delete notes (requires confirmation)
- move_note: Move a note to a different folder
- list_folders: List all folders in the hierarchy
- get_folder_notes: List notes in a specific folder
- list_notes: List notes in a project
- get_tags: List all available tags
- export_pdf: Export note as PDF
- apply_formatting: Apply markdown formatting through the editor pipeline

Guidelines:
- Be concise and helpful
- When suggesting edits, explain what you'll change before doing so
- Use write_note for large rewrites, edit_note for small changes
- Always confirm destructive actions (delete_note) with the user
- Respect the user's existing writing style and formatting
- In WYSIWYG mode, never suggest raw text or attributed string manipulation — always use the provided tools
```

---

## Block-Model Pipeline Integration

When the AI edits notes, it must respect the block-model pipeline. **Critical**: There are two completely separate editing pipelines. AI tools must detect which mode is active and route through the correct path.

### WYSIWYG vs Source Mode

| Mode | Detect | Read Path | Write Path |
|------|--------|-----------|------------|
| **WYSIWYG** | `editTextView.documentProjection != nil` | `MarkdownSerializer.serialize(document)` | Parse → `EditingOps` → splice |
| **Source** | `editTextView.documentProjection == nil` | `note.content.string` | `note.content = ...` |

**Never** write directly to `textStorage` or `note.content` in WYSIWYG mode. This breaks the storage invariant and corrupts the Document model.

### Reading Notes

```swift
func readNoteMarkdown(_ note: Note) -> String {
    if let projection = note.editTextView?.documentProjection {
        // WYSIWYG mode: serialize Document tree to markdown
        return MarkdownSerializer.serialize(projection.document)
    } else {
        // Source mode: raw markdown is in storage
        return note.content.string
    }
}
```

### Writing Notes (WYSIWYG Mode)

For full replacement, parse the AI-generated markdown into a Document and replace the projection's document, then trigger a full re-render:

```swift
func replaceNoteContent(note: Note, markdown: String) throws {
    guard let projection = note.editTextView?.documentProjection else {
        // Source mode fallback
        note.content = NSMutableAttributedString(string: markdown)
        note.save()
        return
    }

    // WYSIWYG mode: parse into Document, replace, re-render
    let newDocument = try MarkdownParser.parse(markdown)
    projection.document = newDocument
    let fullRange = NSRange(location: 0, length: note.textStorage.length)
    note.editTextView?.syncTextStorageWithDocument(fullRange: fullRange)
    note.save()
}
```

### Structured Edits (WYSIWYG Mode)

For targeted edits, use the existing `EditingOps` primitives (`insert`, `delete`, `split`, `merge`, `format`) or inline re-parsing:

```swift
func applyStructuredEdit(
    note: Note,
    blockIndex: Int,
    inlineRange: NSRange,
    newText: String
) throws {
    guard let projection = note.editTextView?.documentProjection else {
        throw EditorError.unsupportedBlockType(.paragraph) // source mode
    }

    // Use EditingOps.insert or delete+insert for the target block
    // Then reparse inlines if delimiters were affected
    let result = try EditingOps.insert(
        text: newText,
        at: inlineRange.location,
        in: projection
    )
    note.editTextView?.applyEditResult(result)
    note.editTextView?.reparseInlinesIfNeeded(blockIndex: blockIndex)
}
```

**Why no line-based edits?** The Document model has no concept of "lines" — it has blocks and inline trees. Line indices in rendered text don't map 1:1 to block indices because of blank lines, list markers, and folded content. Always use block/inline coordinates.

### Blank Lines and Zero-Length Blocks

AI structural operations must handle `Block.blankLine` correctly:

- **Zero-length spans**: `blankLine` renders to `""` with `length == 0`. Range overlap checks like `span.location < rangeEnd && spanEnd > range.location` return `false` for zero-length spans. Use `blockContaining(storageIndex:)` instead.
- **Cursor on blank lines**: After splitting a paragraph with Return, the cursor lands on a zero-length blank line. AI edits targeting "the current block" must special-case `span.length == 0`.
- **Separators**: Blank lines exist visually only as the `\n` between adjacent blocks. Do not insert extra blank lines between blocks — the renderer and serializer already handle spacing.

When generating markdown for insertion, let the serializer handle blank separators between non-blank siblings. Do not manually inject `\n\n` between blocks.

---

## Alternative: Direct Filesystem Access

Since FSNotes++ stores notes as TextBundles in a standard iCloud folder hierarchy, the MCP server can read and write files directly from the filesystem rather than routing through app code. This is simpler and faster, but requires coordination with the app to handle open notes.

### Comparison

| Aspect | Through App Code | Direct Filesystem |
|--------|-----------------|-------------------|
| **Read performance** | Medium (serialize Document or read storage) | Fast (direct file I/O) |
| **Write performance** | Slow (parse → Document → splice → render) | Fast (write `text.md` directly) |
| **Complexity** | High (WYSIWYG/source mode branching) | Low (uniform file operations) |
| **Encrypted notes** | Automatic (app handles decryption) | Must detect and skip `.etp` / encrypted bundles |
| **Open note sync** | Automatic (app owns the state) | Requires file watcher or explicit notification |
| **Conflict handling** | Automatic (app serialization queue) | Requires last-write-wins or manual merge |
| **Git integration** | Automatic (app commits on save) | Bypassed unless MCP also triggers git |
| **Works app-closed** | No | Yes |

### Recommended Hybrid

Use **direct filesystem access** for:
- Read tools (`read_note`, `search_notes`, `list_folders`, `get_folder_notes`)
- Create tools (`create_note` in a closed folder)
- Bulk operations (move, delete when note is not open)

Use **app-code routing** for:
- Writes to the **currently open note** (to avoid overwriting unsaved app state)
- `apply_formatting` (needs cursor position and WYSIWYG inline attributes)
- Any operation where the user has **unsaved changes** in the editor

### Filesystem Layout

```
iCloud Drive/FSNotes/          ← Storage root (configurable)
├── Work/
│   ├── Meetings/
│   │   ├── Standup Notes.textbundle/
│   │   │   ├── text.md          ← Markdown content
│   │   │   ├── info.json        ← Metadata (UUID, modified, etc.)
│   │   │   └── assets/
│   │   │       └── diagram.png
│   │   └── Sprint Planning.textbundle/
│   └── Ideas.md                   ← Plain markdown (non-TextBundle)
├── Journal/
│   └── 2026/
│       └── April.textbundle/
└── .git/                          ← Optional git repo
```

### Direct Read Implementation

```swift
public struct ReadNoteTool: MCPTool {
    public let name = "read_note"
    
    private let storageRoot: URL  // e.g. ~/Library/Mobile Documents/iCloud~co~fluder~fsnotes/Documents
    
    public func execute(input: [String: Any]) async throws -> ToolOutput {
        guard let path = resolvePath(input) else {
            return ToolOutput.error("Could not resolve note path")
        }
        
        let fileURL = storageRoot.appendingPathComponent(path)
        
        // Detect TextBundle
        let isTextBundle = fileURL.pathExtension == "textbundle"
        let markdownURL = isTextBundle 
            ? fileURL.appendingPathComponent("text.md")
            : fileURL
        
        guard FileManager.default.fileExists(atPath: markdownURL.path) else {
            return ToolOutput.error("Note not found at \(path)")
        }
        
        // Skip encrypted notes
        if isEncrypted(at: fileURL) {
            return ToolOutput.error("Note is encrypted: \(path)")
        }
        
        let content = try String(contentsOf: markdownURL, encoding: .utf8)
        return ToolOutput.success([
            "title": path.lastPathComponent,
            "folder": path.deletingLastPathComponent,
            "content": content,
            "isTextBundle": isTextBundle
        ])
    }
}
```

### Direct Write Implementation

```swift
public struct WriteNoteTool: MCPTool {
    public let name = "write_note"
    
    public func execute(input: [String: Any]) async throws -> ToolOutput {
        guard let path = input["path"] as? String,
              let markdown = input["content"] as? String else {
            return ToolOutput.error("Missing 'path' or 'content'")
        }
        
        let fileURL = storageRoot.appendingPathComponent(path)
        let isTextBundle = fileURL.pathExtension == "textbundle"
        let markdownURL = isTextBundle
            ? fileURL.appendingPathComponent("text.md")
            : fileURL
        
        // Skip encrypted notes
        if isEncrypted(at: fileURL) {
            return ToolOutput.error("Cannot write encrypted note")
        }
        
        // Write directly
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        
        // Notify app if this note is currently open
        AppBridge.shared.notifyFileChanged(path: path)
        
        return ToolOutput.success(["status": "saved", "path": path])
    }
}
```

### App Bridge (Lightweight Coordination)

Even with direct filesystem access, the MCP needs to know:
1. **Which note is open** — for "in this note..." user queries
2. **Editor mode** — so the AI knows whether to suggest formatting tools
3. **Unsaved changes** — to avoid overwriting dirty editor state
4. **Cursor position** — for insert-at-cursor operations

```swift
public protocol AppBridge {
    /// Returns the currently open note's path, or nil if none
    func currentNotePath() -> String?
    
    /// Returns true if the open note has unsaved changes
    func hasUnsavedChanges(path: String) -> Bool
    
    /// Returns "wysiwyg" or "source" for the given path
    func editorMode(for path: String) -> String
    
    /// Returns cursor position / selection range in the open note
    func cursorState(for path: String) -> CursorState?
    
    /// Called by MCP after writing a file; app reloads if note is open
    func notifyFileChanged(path: String)
    
    /// Called by MCP before writing; app may prompt user if note is dirty
    func requestWriteLock(path: String) -> Bool
}

public struct CursorState {
    public let location: Int
    public let length: Int  // 0 if no selection
}
```

**Implementation**: The bridge is a simple in-process protocol. `AppBridge` is implemented by `ViewController` (or a lightweight coordinator) and passed to `MCPServer` on startup. No networking needed — just a shared object reference.

### Write Safety Rules

When using direct filesystem writes:

1. **Check `requestWriteLock`** before writing. If the note is open and dirty, either:
   - Force-save the app's current state first, then write
   - Return an error asking the user to save
   - Queue the write until the user saves

2. **Always notify after writing** via `notifyFileChanged`. The app must:
   - Reload the file from disk if the note is open but clean
   - Ignore the notification if the note is open and dirty (already has newer state)
   - Refresh the notes list if the folder is visible

3. **Never write encrypted notes**. Detect `.etp` extension or encrypted TextBundle metadata and return an error.

4. **Preserve TextBundle structure**. Only write to `text.md`. Never delete `info.json` or the `assets/` directory.

### When to Use Which Approach

| Operation | Best Path | Reason |
|-----------|-----------|--------|
| Read closed note | Filesystem | Faster, simpler |
| Read open note | Filesystem or App | Same result; filesystem is fine |
| Write closed note | Filesystem | No app state to corrupt |
| Write open note (source mode, clean) | Filesystem + notify | App reloads from disk |
| Write open note (source mode, dirty) | App code | Avoid overwriting user's unsaved changes |
| Write open note (WYSIWYG mode) | App code | App owns Document model; filesystem write breaks invariants |
| Format/insert at cursor | App code | Needs cursor position and WYSIWYG inline tree |
| Create note | Filesystem | No existing state |
| Delete note | Filesystem | Simple file deletion |
| Move note | Filesystem | Rename/move file/directory |

---

## Error Handling

Use typed errors aligned with `EditorError` rather than string-based errors:

| Scenario | Error Type | User Experience |
|----------|------------|-----------------|
| Ollama not running | `AIError.providerUnavailable` | Show "Start Ollama" button in chat panel |
| Model not found | `AIError.modelNotFound` | Suggest `ollama pull <model>` command |
| Tool execution fails | `EditorError` or `MCPError` | Show error in chat, allow retry |
| Network timeout | `AIError.networkTimeout` | Show "Connection timeout" with retry |
| Invalid tool input | `EditorError.invalidStorageIndex` | Log error, continue without tool result |
| WYSIWYG edit on source-only note | `EditorError.unsupportedBlockType` | Fallback to source-mode path |
| Note title ambiguous across folders | `AIError.ambiguousNoteTitle([(folder, title)])` | LLM retries with explicit `folder` parameter |
| TextBundle asset missing | `AIError.assetNotFound(path)` | Log error, continue without image |
| Folder not found | `AIError.folderNotFound(path)` | LLM retries with `list_folders` first |

**Tool output contract**: All tools return `ToolOutput.success([String: Any])` or `ToolOutput.error(String)`. Never throw uncaught exceptions from tools — the `MCPServer` wraps them in `ToolOutput.error` before returning to the LLM.

---

## Security Considerations

1. **Local-only by default**: Ollama runs locally, no data leaves the machine
2. **No API keys for Ollama**: No secrets to manage for local usage
3. **Sandboxed file access**: AI can only access notes within the configured storage path. Folders outside the project root are inaccessible.
4. **Confirmation for destructive ops**: Delete and move operations require user confirmation
5. **Rate limiting**: Prevent AI from making too many tool calls in rapid succession
6. **Storage invariant protection**: AI tools must never write to `textStorage` directly in WYSIWYG mode. All edits go through `EditingOps` or `EditorStore.dispatch` to preserve the Document model.
7. **TextBundle integrity**: When writing to a TextBundle, the tool must preserve `info.json` and the `assets/` directory. Never delete or overwrite the bundle structure.

---

## Implementation Phases

### Phase 1: Ollama Support
- [ ] Add `OllamaProvider` implementing `AIProvider`
- [ ] Create `PreferencesAIViewController` with Ollama settings
- [ ] Add model listing from Ollama API
- [ ] Add reachability check
- [ ] Update `AIServiceFactory` to support "ollama" provider

### Phase 2: MCP Foundation
- [ ] Create `MCPServer` framework
- [ ] Define `MCPTool` protocol
- [ ] Implement filesystem-based tools: `read_note`, `search_notes`, `list_folders`, `get_folder_notes`
- [ ] Add folder-aware resolution (title + folder disambiguation)
- [ ] Add `list_folders`, `get_folder_notes`, `move_note`
- [ ] Handle TextBundle read/write correctly
- [ ] Implement `AppBridge` protocol for app-MCP coordination
- [ ] Add `currentNotePath`, `hasUnsavedChanges`, `notifyFileChanged`
- [ ] Add encrypted note detection and skipping
- [ ] Integrate MCP with `OllamaProvider`
- [ ] Add tool call visualization in chat UI
- [ ] **Test filesystem reads with closed notes**
- [ ] **Test filesystem writes with source-mode open notes**
- [ ] **Test with duplicate titles across folders**
- [ ] **Test TextBundle notes (read, write, move)**

### Phase 3: Advanced Tools
- [ ] `edit_note` with Document-level operations (block/inline coordinates)
- [ ] `create_note`, `delete_note`
- [ ] `list_notes`, `get_projects`
- [ ] `export_pdf`
- [ ] `apply_formatting` via `EditingOps.toggleBold`, etc.

### Phase 4: Polish
- [ ] Streaming tool execution status
- [ ] Tool call confirmation UI for destructive ops
- [ ] Conversation history persistence
- [ ] Keyboard shortcuts (Cmd+Shift+A to toggle AI panel)

---

## File Structure

```
FSNotes/
├── Helpers/
│   ├── AIChatPanelView.swift          (existing - modify)
│   ├── AIChatStore.swift              (new)
│   ├── AIService.swift                (existing - add OllamaProvider)
│   ├── MCP/
│   │   ├── MCPServer.swift
│   │   ├── MCPTool.swift
│   │   ├── ToolOutput.swift
│   │   └── Tools/
│   │       ├── ReadNoteTool.swift
│   │       ├── WriteNoteTool.swift
│   │       ├── EditNoteTool.swift
│   │       ├── SearchNotesTool.swift
│   │       ├── ListNotesTool.swift
│   │       ├── ListFoldersTool.swift
│   │       ├── GetFolderNotesTool.swift
│   │       ├── MoveNoteTool.swift
│   │       ├── CreateNoteTool.swift
│   │       ├── DeleteNoteTool.swift
│   │       ├── GetCurrentNoteTool.swift
│   │       ├── ExportPDFTool.swift
│   │       ├── GetTagsTool.swift
│   │       └── GetProjectsTool.swift
│   └── Ollama/
│       ├── OllamaClient.swift
│       └── OllamaModel.swift
├── Preferences/
│   ├── PrefsViewController.swift      (modify - add AI tab)
│   └── PreferencesAIViewController.swift (new)
└── ViewController+Events.swift        (existing - toggleAIChat)

FSNotesCore/
└── UserDefaultsManagement.swift       (modify - add OllamaHost)
```

---

## Questions & Answers

1. Should the AI have access to the entire note history (undo stack)? Yes, I think that should be possible.
2. How should the AI handle encrypted notes? No access. Return `ToolOutput.error("Note is encrypted")`.
3. Should there be a way to disable specific tools per-conversation? No, I think that's too complicated
4. What's the UX for multi-step tool calls (e.g., "find all TODOs and create a summary note")? I think the AI should output a 'consolidated answer' with some context, e.g. "250 TODOs found across 45 notes. Consolidated answer is in note "Consolidated Todos - 25-April-2026".
5. Should the AI respect Git integration (commit after edits)? Yes. same as what the user would do (if using Git)
6. What if the AI generates invalid markdown? `MarkdownParser.parse()` may throw. Tools must catch parsing errors and return `ToolOutput.error("Invalid markdown: ...")` to the LLM so it can retry.
7. How does the AI know whether to use Document ops or direct string edits? The system prompt includes the editor mode. Read tools return the same markdown regardless, but write tools automatically detect `documentProjection` and route correctly. For closed notes, filesystem access is always used.
8. What if two notes have the same title in different folders? The `read_note` tool returns a disambiguation error listing the matching folders. The LLM retries with an explicit `folder` parameter.
9. How should the AI handle TextBundle assets (images, attachments)? The AI can reference attached images in markdown (`![](assets/image.png)`). The `read_note` tool returns `isTextBundle: true` so the AI knows the base path for asset resolution. Writing images back requires a separate `AddAssetTool` (future work).
10. Why not always use filesystem access? For open notes in WYSIWYG mode, the app holds a parsed Document model and rendered textStorage. Writing directly to disk would desync the app. Use app-code routing for open WYSIWYG notes, filesystem for everything else.

---

## References

- [Ollama API Docs](https://github.com/ollama/ollama/blob/main/docs/api.md)
- [MCP Specification](https://modelcontextprotocol.io/specification)
- FSNotes++ ARCHITECTURE.md (block-model pipeline)
