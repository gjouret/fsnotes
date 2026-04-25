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
}
