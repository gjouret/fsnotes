//
//  MCPTestFixture.swift
//  FSNotesTests
//
//  Shared filesystem-fixture helper for MCP tool tests. Each test
//  case creates a fresh temp directory rooted at
//  `NSTemporaryDirectory()/MCPTests_<UUID>/` and tears it down in
//  tearDown.  Notes are seeded via plain `String.write` calls — the
//  MCP read tools don't go through `Storage`, so we don't need any
//  app state to test them.
//

import Foundation
import XCTest
@testable import FSNotes

final class MCPTestFixture {
    /// Absolute URL of the storage root for this fixture.
    let root: URL

    init(label: String = "MCPTests") {
        let id = UUID().uuidString
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(label)_\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        self.root = url
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Write a plain-markdown note. Path is storage-relative;
    /// missing intermediate folders are created.
    @discardableResult
    func makeNote(at relPath: String, content: String = "# Untitled\n") -> URL {
        let url = root.appendingPathComponent(relPath)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Write a TextBundle. Returns the bundle directory URL.
    @discardableResult
    func makeTextBundle(
        at relPath: String,
        markdown: String = "# Bundled\n",
        info: [String: Any] = ["version": 2, "type": "net.daringfireball.markdown"]
    ) -> URL {
        let bundleURL = root.appendingPathComponent(relPath)
        try? FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let textURL = bundleURL.appendingPathComponent("text.md")
        try? markdown.write(to: textURL, atomically: true, encoding: .utf8)
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
            let infoURL = bundleURL.appendingPathComponent("info.json")
            try? data.write(to: infoURL)
        }
        return bundleURL
    }

    /// Write an encrypted-note marker. Either a `.etp` plain file
    /// or a TextBundle with `encrypted: true` in info.json.
    @discardableResult
    func makeEncryptedNote(at relPath: String) -> URL {
        if relPath.hasSuffix(".etp") {
            return makeNote(at: relPath, content: "ENCRYPTED")
        }
        return makeTextBundle(
            at: relPath,
            markdown: "ciphertext",
            info: ["version": 2, "encrypted": true]
        )
    }

    /// Build an MCPServer rooted at this fixture, with an
    /// optional bridge override.
    func makeServer(bridge: AppBridge = NoOpAppBridge()) -> MCPServer {
        return MCPServer(storageRoot: root, appBridge: bridge)
    }
}

/// Tiny synchronous bridge to a tool's async execute(). All tools
/// are filesystem-bound and complete in a single hop, so a
/// semaphore-based wait is fine for tests.
extension MCPTool {
    func executeSync(input: [String: Any]) -> ToolOutput {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: ToolOutput = .error("test never completed")
        Task.detached {
            captured = await self.execute(input: input)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5.0)
        return captured
    }
}

/// Bridge stub used across the MCP test suite. Each test mutates
/// the public fields (openPath, dirty, mode, …) before calling the
/// tool to simulate the editor state.
///
/// The Phase 3 hooks (appendMarkdown / applyStructuredEdit /
/// applyFormatting / exportPDF) default to .notImplemented; tests
/// that exercise the bridge-routed branches override the
/// corresponding `<hook>Outcome` field to control the response and
/// inspect `<hook>Calls` to verify the dispatch.
final class TestAppBridge: AppBridge {
    var openPath: String?
    var dirty: Bool = false
    var grantWriteLock: Bool = true
    var mode: String = "wysiwyg"
    var cursor: CursorState? = nil

    var lockRequests: [String] = []
    var notifications: [String] = []

    // Phase 3 dispatch capture.
    struct AppendCall { let path: String; let markdown: String }
    struct EditCall { let path: String; let request: BridgeEditRequest }
    struct FormattingCall { let path: String; let command: BridgeFormattingCommand }
    struct ExportCall { let path: String; let outputURL: URL }

    var appendCalls: [AppendCall] = []
    var editCalls: [EditCall] = []
    var formattingCalls: [FormattingCall] = []
    var exportCalls: [ExportCall] = []

    var appendOutcome: BridgeEditOutcome = .notImplemented
    var editOutcome: BridgeEditOutcome = .notImplemented
    var formattingOutcome: BridgeEditOutcome = .notImplemented
    var exportOutcome: BridgeEditOutcome = .notImplemented

    func currentNotePath() -> String? { openPath }
    func hasUnsavedChanges(path: String) -> Bool {
        return openPath == path && dirty
    }
    func editorMode(for path: String) -> String? {
        return openPath == path ? mode : nil
    }
    func cursorState(for path: String) -> CursorState? {
        return openPath == path ? cursor : nil
    }
    func notifyFileChanged(path: String) { notifications.append(path) }
    func requestWriteLock(path: String) -> Bool {
        lockRequests.append(path)
        return grantWriteLock
    }

    func appendMarkdown(toPath path: String, markdown: String) -> BridgeEditOutcome {
        appendCalls.append(AppendCall(path: path, markdown: markdown))
        return appendOutcome
    }
    func applyStructuredEdit(toPath path: String, request: BridgeEditRequest) -> BridgeEditOutcome {
        editCalls.append(EditCall(path: path, request: request))
        return editOutcome
    }
    func applyFormatting(toPath path: String, command: BridgeFormattingCommand) -> BridgeEditOutcome {
        formattingCalls.append(FormattingCall(path: path, command: command))
        return formattingOutcome
    }
    func exportPDF(forPath path: String, to outputURL: URL) -> BridgeEditOutcome {
        exportCalls.append(ExportCall(path: path, outputURL: outputURL))
        return exportOutcome
    }
}
