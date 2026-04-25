//
//  AppBridge.swift
//  FSNotes
//
//  Lightweight in-process protocol that lets the MCP server query
//  app-side state (which note is open, editor mode, dirty flag,
//  cursor) and notify the app after a filesystem write. See
//  docs/AI.md "App Bridge" section.
//
//  The implementing object is `ViewController` (or a future
//  coordinator) and is wired into `MCPServer.shared.appBridge`. Until
//  Phase 2 follow-up wires that, the server uses `NoOpAppBridge`,
//  which means filesystem reads work everywhere and writes proceed
//  without coordination.
//

import Foundation

/// Cursor / selection in the currently open note, in storage indices.
public struct CursorState {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// The protocol the app implements so the MCP server can coordinate
/// with the live editor. All methods take a `path` so the bridge can
/// in principle support a future multi-window world; today only the
/// single front-most note is open at a time.
public protocol AppBridge: AnyObject {
    /// Absolute filesystem path of the currently open note, or nil if
    /// no editor is showing a note. The path matches what tools see
    /// when walking `storageRoot`.
    func currentNotePath() -> String?

    /// True when the open note has user edits not yet flushed to
    /// disk. MCP write tools must consult this before overwriting the
    /// file (see `requestWriteLock`).
    func hasUnsavedChanges(path: String) -> Bool

    /// `"wysiwyg"` or `"source"` for the given path. Returns nil if
    /// the path is not currently open in the editor.
    func editorMode(for path: String) -> String?

    /// Cursor / selection in the open note, or nil if the path is not
    /// currently open.
    func cursorState(for path: String) -> CursorState?

    /// Called by the MCP server after a successful filesystem write.
    /// The app reloads the file if the note is open and clean,
    /// ignores the notification if the note is open and dirty, and
    /// refreshes the notes list when the affected folder is visible.
    func notifyFileChanged(path: String)

    /// Called by the MCP server before a filesystem write. The app
    /// may force-save or refuse the lock. Returning `false` aborts
    /// the write; the tool surfaces a "note is dirty" error to the
    /// LLM.
    func requestWriteLock(path: String) -> Bool

    // MARK: - Phase 3 structured-edit hooks
    //
    // These let the MCP server route a structured edit through
    // EditingOps + DocumentEditApplier when the target note is open
    // in WYSIWYG mode (Invariant A: single write path into TK2
    // content storage). The default `NoOpAppBridge` returns
    // `.notImplemented`, so tools can detect the path is not yet
    // wired and surface a clear error to the LLM rather than
    // bypassing the block-model pipeline. ViewController will adopt
    // these in a Phase 3 follow-up.
    //
    // The editing API is intentionally narrow: the MCP server does
    // not know about Document or EditingOps. It hands the bridge a
    // `BridgeEditRequest` and the bridge is responsible for parsing,
    // dispatching, and saving. This keeps the MCP layer free of any
    // FSNotesCore dependency that would couple it to the editor's
    // internals.

    /// Append plain markdown to the end of the note at `path`.
    /// In WYSIWYG mode the bridge parses the appended markdown,
    /// drives EditingOps, and routes through DocumentEditApplier. In
    /// source mode it appends to `note.content`. The default no-op
    /// implementation returns `.notImplemented`.
    func appendMarkdown(toPath path: String, markdown: String) -> BridgeEditOutcome

    /// Apply structured edits (block-level replace / insert / delete)
    /// to the note at `path`. The wire format is intentionally
    /// minimal — the bridge translates it into one or more
    /// EditingOps calls. The default no-op returns `.notImplemented`.
    func applyStructuredEdit(toPath path: String, request: BridgeEditRequest) -> BridgeEditOutcome

    /// Apply a single inline-formatting toggle (bold, italic, code, …)
    /// to the note's current selection. The default no-op returns
    /// `.notImplemented`. The bridge needs the selection to do
    /// anything meaningful, which is why this requires a live editor.
    func applyFormatting(toPath path: String, command: BridgeFormattingCommand) -> BridgeEditOutcome

    /// Render the note at `path` to a PDF at `outputURL`. Default
    /// returns `.notImplemented`. The live implementation routes
    /// through `PDFExporter` on the EditTextView.
    func exportPDF(forPath path: String, to outputURL: URL) -> BridgeEditOutcome
}

/// A coarse-grained edit request sent by the MCP server to the
/// AppBridge. Block coordinates are 0-indexed; line/inline
/// coordinates are intentionally absent — the spec ("Why no
/// line-based edits?") prohibits them because the document model
/// has no concept of lines.
public struct BridgeEditRequest {
    public enum Kind {
        /// Replace block N with the given markdown. The markdown is
        /// parsed into a Document and spliced via DocumentEditApplier.
        case replaceBlock(index: Int, markdown: String)
        /// Insert blocks before block N. `index == blockCount`
        /// appends to the end.
        case insertBefore(index: Int, markdown: String)
        /// Delete block N.
        case deleteBlock(index: Int)
        /// Replace the entire document with the given markdown.
        case replaceDocument(markdown: String)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

/// A formatting command issued via `applyFormatting`.
public enum BridgeFormattingCommand {
    case toggleBold
    case toggleItalic
    case toggleStrikethrough
    case toggleInlineCode
    case toggleHeading(level: Int)
    case toggleBlockquote
    case toggleUnorderedList
    case toggleOrderedList
    case toggleTodoList
    case insertHorizontalRule
}

/// Result of a bridge edit / formatting / export request.
public enum BridgeEditOutcome {
    /// The request succeeded. `info` carries arbitrary metadata for
    /// the LLM (bytes written, new block count, …).
    case applied(info: [String: Any])
    /// The request failed for a reason the LLM should see verbatim.
    case failed(reason: String)
    /// The bridge does not yet implement this hook. Tools translate
    /// this into a clear "feature not yet wired" error.
    case notImplemented
}

/// Default implementations for the Phase 3 hooks so legacy bridges
/// (Phase 2 `TestAppBridge`, future stubs) keep compiling without
/// needing to implement four extra methods up front. Concrete
/// implementations override what they support; callers must always
/// handle `.notImplemented`.
public extension AppBridge {
    func appendMarkdown(toPath path: String, markdown: String) -> BridgeEditOutcome {
        return .notImplemented
    }
    func applyStructuredEdit(toPath path: String, request: BridgeEditRequest) -> BridgeEditOutcome {
        return .notImplemented
    }
    func applyFormatting(toPath path: String, command: BridgeFormattingCommand) -> BridgeEditOutcome {
        return .notImplemented
    }
    func exportPDF(forPath path: String, to outputURL: URL) -> BridgeEditOutcome {
        return .notImplemented
    }
}

/// Default no-op implementation used until `ViewController` adopts
/// `AppBridge`. Behaviourally: there is no open note, nothing is
/// dirty, write locks are always granted, and notifications are
/// dropped on the floor. This keeps the MCP server functional for
/// tests and for the closed-note read paths.
public final class NoOpAppBridge: AppBridge {
    public init() {}

    public func currentNotePath() -> String? { return nil }
    public func hasUnsavedChanges(path: String) -> Bool { return false }
    public func editorMode(for path: String) -> String? { return nil }
    public func cursorState(for path: String) -> CursorState? { return nil }
    public func notifyFileChanged(path: String) {}
    public func requestWriteLock(path: String) -> Bool { return true }
    // Phase 3 edit hooks fall through to the default protocol-extension
    // implementations, which all return `.notImplemented`.
}
