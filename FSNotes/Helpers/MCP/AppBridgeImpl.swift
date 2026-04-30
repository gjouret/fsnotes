//
//  AppBridgeImpl.swift
//  FSNotes
//
//  Production AppBridge implementation. Wires the MCP layer to the
//  live editor so write tools (EditNoteTool, AppendToNoteTool,
//  ApplyFormattingTool, ExportPDFTool) can route through the
//  block-model pipeline (Invariant A: single write path into TK2
//  content storage) instead of bypassing it.
//
//  Lookup pattern: a `resolveViewController` closure is supplied at
//  construction time. The bridge calls it on every method invocation
//  rather than holding a hard reference; this keeps the bridge alive
//  across window-controller swaps without pinning a stale
//  ViewController. The default resolver walks `ViewController.shared()`,
//  matching the AppDelegate convention used everywhere else.
//
//  Threading: the bridge expects to be invoked on the main thread —
//  it touches AppKit-only state (`textStorage`, `applyEditResultWithUndo`,
//  `Note.save`, `PDFExporter`). The MCP dispatch path is `async`, so
//  the OllamaProvider tool-call loop must marshal onto `MainActor.run`
//  before invoking `MCPServer.handleToolCalls`. Tests that go through
//  `MCPTool.executeSync` block the main thread on a semaphore, so the
//  bridge must NOT itself try to hop to main — it deadlocks. We document
//  the precondition and rely on the caller to honour it.
//

import AppKit
import Foundation

/// Concrete `AppBridge` for the live FSNotes++ editor. Holds no
/// editor state of its own — every method re-resolves the current
/// `ViewController` on demand. See file header for the rationale.
///
/// Internal class because it depends on `ViewController` (internal).
/// MCPServer takes `AppBridge` (the public protocol), so the
/// implementation type can stay app-private.
final class AppBridgeImpl: AppBridge {

    /// Closure that returns the current main-window `ViewController`
    /// (or nil if no main window). The default resolver matches
    /// the existing `AppDelegate.mainWindowController` convention.
    private let resolveViewController: () -> ViewController?

    init(resolveViewController: @escaping () -> ViewController? = { ViewController.shared() }) {
        self.resolveViewController = resolveViewController
    }

    /// Convenience: the editor of the currently open note, or nil.
    private var editor: EditTextView? { resolveViewController()?.editor }

    /// Convenience: the open Note, or nil.
    private var openNote: Note? { editor?.note }

    /// Convenience: the standardized filesystem path of the open
    /// note. Matches what `MCPServer` tools use for comparison.
    private var openNotePath: String? {
        guard let url = openNote?.url else { return nil }
        return url.standardizedFileURL.path
    }

    /// True when `path` standardises to the same path as the open
    /// note. Hides the standardisation dance from every method.
    private func isOpen(_ path: String) -> Bool {
        guard let openPath = openNotePath else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == openPath
    }

    // MARK: - Read-only protocol methods

    func currentNotePath() -> String? {
        return openNotePath
    }

    func hasUnsavedChanges(path: String) -> Bool {
        guard isOpen(path), let editor = editor else { return false }
        return editor.hasUserEdits
    }

    func editorMode(for path: String) -> String? {
        guard isOpen(path), let editor = editor else { return nil }
        // WYSIWYG path: the block-model pipeline owns storage.
        // Source mode: the renderer paints markers but the
        // projection isn't installed (or `hideSyntax == false`).
        if editor.documentProjection != nil,
           editor.textStorageProcessor?.blockModelActive == true {
            return "wysiwyg"
        }
        return "source"
    }

    func cursorState(for path: String) -> CursorState? {
        guard isOpen(path), let editor = editor else { return nil }
        let range = editor.selectedRange()
        return CursorState(location: range.location, length: range.length)
    }

    // MARK: - Notification + write-lock

    func notifyFileChanged(path: String) {
        guard isOpen(path), let editor = editor else {
            // Note isn't open — nothing to reload.
            return
        }
        // If the editor has unsaved changes, the on-disk file is
        // stale relative to the editor; reloading would clobber
        // the user's pending edits. Skip the reload — the docs/AI.md
        // contract is explicit: "Ignore the notification if the
        // note is open and dirty".
        if editor.hasUserEdits { return }
        editor.editorViewController?.refillEditArea(force: true)
    }

    func requestWriteLock(path: String) -> Bool {
        // Closed notes: always grant. Open + clean: grant. Open + dirty: deny.
        // Future enhancement could prompt the user or force-save; for
        // now a clean refusal lets the tool surface the error verbatim.
        guard isOpen(path), let editor = editor else { return true }
        return !editor.hasUserEdits
    }

    // MARK: - IME composition guard

    /// Returns a `.failed(...)` outcome if the editor is currently
    /// mid-IME-composition (CJK candidate selection, dead-key accent,
    /// emoji picker). During composition `setMarkedText` writes
    /// directly to `NSTextContentStorage` — this is the single
    /// sanctioned exemption to Invariant A (see ARCHITECTURE.md
    /// "IME Composition" / `CompositionSession`). If we let an MCP
    /// tool dispatch into `applyEditResultWithUndo` while a session
    /// is active, the structural splice races with the IME's marked-
    /// range writes and corrupts the composition.
    ///
    /// Returns nil when no composition is in flight (or no editor),
    /// so the caller can proceed normally.
    private func refuseDuringIMEComposition(_ method: String) -> BridgeEditOutcome? {
        guard let editor = resolveViewController()?.editor else { return nil }
        if editor.compositionSession.isActive {
            return .failed(reason: "\(method) refused while IME composition is active")
        }
        return nil
    }

    // MARK: - Phase 3 edit hooks

    func appendMarkdown(toPath path: String, markdown: String) -> BridgeEditOutcome {
        if let refusal = refuseDuringIMEComposition("appendMarkdown") {
            return refusal
        }
        guard isOpen(path),
              let editor = editor,
              let note = openNote else {
            return .failed(reason: "appendMarkdown: target note is not open")
        }
        // WYSIWYG path: parse the appended markdown and route via
        // EditingOps + DocumentEditApplier. Implementation: the
        // simplest correct route is `replaceDocument(serialize +
        // appended)` so we exercise the full pipeline (no
        // partial splice with reflowing trailing newlines).
        // This matches the structured-edit `replaceDocument`
        // branch — same pure primitive, same applier dispatch.
        if let projection = editor.documentProjection,
           editor.textStorageProcessor?.blockModelActive == true {
            let existing = MarkdownSerializer.serialize(projection.document)
            let separator = bridgeAppendSeparator(for: existing)
            let combined = existing + separator + markdown
                + (markdown.hasSuffix("\n") ? "" : "\n")
            return performReplaceDocument(
                markdown: combined,
                editor: editor,
                projection: projection,
                actionName: "Append"
            )
        }
        // Source mode (or fall-through): write directly to disk
        // and let the editor reload via notifyFileChanged. Avoids
        // a parallel "edit attributed string in source mode"
        // pathway that would re-implement source-mode editing.
        let mdURL = note.url
        let existing = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        let separator = bridgeAppendSeparator(for: existing)
        let combined = existing + separator + markdown
            + (markdown.hasSuffix("\n") ? "" : "\n")
        do {
            try combined.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed(reason: "appendMarkdown: write failed: \(error.localizedDescription)")
        }
        // Re-load from disk so the editor reflects the change.
        editor.editorViewController?.refillEditArea(force: true)
        return .applied(info: ["bytesWritten": combined.utf8.count, "mode": "source"])
    }

    func applyStructuredEdit(toPath path: String, request: BridgeEditRequest) -> BridgeEditOutcome {
        if let refusal = refuseDuringIMEComposition("applyStructuredEdit") {
            return refusal
        }
        guard isOpen(path),
              let editor = editor,
              let note = openNote else {
            return .failed(reason: "applyStructuredEdit: target note is not open")
        }
        // WYSIWYG: dispatch via EditingOps. We use the same
        // markdown-block model the EditNoteTool's filesystem
        // branch uses (split on blank lines, splice block array,
        // re-serialise) and then route through replaceDocument.
        // This keeps the wire format stable across the WYSIWYG
        // and closed-note branches.
        if let projection = editor.documentProjection,
           editor.textStorageProcessor?.blockModelActive == true {
            let existing = MarkdownSerializer.serialize(projection.document)
            let newMarkdown: String
            do {
                newMarkdown = try applyKindToMarkdown(request.kind, existing: existing)
            } catch let err as BridgeEditError {
                return .failed(reason: err.message)
            } catch {
                return .failed(reason: "applyStructuredEdit: \(error.localizedDescription)")
            }
            return performReplaceDocument(
                markdown: newMarkdown,
                editor: editor,
                projection: projection,
                actionName: "Edit"
            )
        }
        // Source mode (or fall-through): direct file rewrite.
        let mdURL = note.url
        let existing = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        let newMarkdown: String
        do {
            newMarkdown = try applyKindToMarkdown(request.kind, existing: existing)
        } catch let err as BridgeEditError {
            return .failed(reason: err.message)
        } catch {
            return .failed(reason: "applyStructuredEdit: \(error.localizedDescription)")
        }
        do {
            try newMarkdown.write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed(reason: "applyStructuredEdit: write failed: \(error.localizedDescription)")
        }
        editor.editorViewController?.refillEditArea(force: true)
        return .applied(info: ["bytesWritten": newMarkdown.utf8.count, "mode": "source"])
    }

    func applyFormatting(toPath path: String, command: BridgeFormattingCommand) -> BridgeEditOutcome {
        if let refusal = refuseDuringIMEComposition("applyFormatting") {
            return refusal
        }
        guard isOpen(path),
              let editor = editor,
              let projection = editor.documentProjection,
              editor.textStorageProcessor?.blockModelActive == true else {
            return .failed(reason: "applyFormatting: requires the note open in WYSIWYG mode")
        }
        let selection = editor.selectedRange()
        let result: EditResult
        do {
            switch command {
            case .toggleBold:
                guard let r = try EditingOps.toggleInlineTraitAcrossSelection(.bold, range: selection, in: projection) else {
                    return .failed(reason: "applyFormatting: selection does not cover editable text")
                }
                result = r
            case .toggleItalic:
                guard let r = try EditingOps.toggleInlineTraitAcrossSelection(.italic, range: selection, in: projection) else {
                    return .failed(reason: "applyFormatting: selection does not cover editable text")
                }
                result = r
            case .toggleStrikethrough:
                guard let r = try EditingOps.toggleInlineTraitAcrossSelection(.strikethrough, range: selection, in: projection) else {
                    return .failed(reason: "applyFormatting: selection does not cover editable text")
                }
                result = r
            case .toggleInlineCode:
                guard let r = try EditingOps.toggleInlineTraitAcrossSelection(.code, range: selection, in: projection) else {
                    return .failed(reason: "applyFormatting: selection does not cover editable text")
                }
                result = r
            case .toggleHeading(let level):
                guard let r = try EditingOps.changeHeadingLevelAcrossSelection(level, range: selection, in: projection) else {
                    return .failed(reason: "applyFormatting: selection does not cover heading-compatible blocks")
                }
                result = r
            case .toggleBlockquote:
                guard editor.toggleBlockquoteViaBlockModel() else {
                    return .failed(reason: "applyFormatting: selection does not cover quote-compatible blocks")
                }
                _ = openNote?.save()
                return .applied(info: ["command": describe(command)])
            case .toggleUnorderedList:
                guard editor.toggleListViaBlockModel(marker: "-") else {
                    return .failed(reason: "applyFormatting: selection does not cover list-compatible blocks")
                }
                _ = openNote?.save()
                return .applied(info: ["command": describe(command)])
            case .toggleOrderedList:
                guard editor.toggleListViaBlockModel(marker: "1.") else {
                    return .failed(reason: "applyFormatting: selection does not cover list-compatible blocks")
                }
                _ = openNote?.save()
                return .applied(info: ["command": describe(command)])
            case .toggleTodoList:
                guard editor.toggleTodoViaBlockModel() else {
                    return .failed(reason: "applyFormatting: selection does not cover todo-compatible blocks")
                }
                _ = openNote?.save()
                return .applied(info: ["command": describe(command)])
            case .insertHorizontalRule:
                result = try EditingOps.insertHorizontalRule(at: selection.location, in: projection)
            }
        } catch {
            return .failed(reason: "applyFormatting: \(error.localizedDescription)")
        }
        editor.applyEditResultWithUndo(result, actionName: "Format")
        // Persist the change so the file on disk matches the
        // editor's projection. Without this, an MCP-driven
        // formatting toggle would live only in the editor and
        // be lost on reload-from-disk.
        _ = openNote?.save()
        return .applied(info: ["command": describe(command)])
    }

    func exportPDF(forPath path: String, to outputURL: URL) -> BridgeEditOutcome {
        if let refusal = refuseDuringIMEComposition("exportPDF") {
            return refusal
        }
        guard isOpen(path), let editor = editor else {
            return .failed(reason: "exportPDF: target note is not open")
        }
        // PDFExporter.export uses NSView.dataWithPDF on the live
        // EditTextView. The view does not need to be on-screen
        // (NSView can render off-screen via dataWithPDF), but it
        // does need its TK2 layout populated — `measureUsedRectTK2`
        // walks fragments with `.ensuresLayout` so a freshly
        // filled but un-displayed editor still produces a usable
        // PDF.
        guard let url = PDFExporter.export(textView: editor, to: outputURL) else {
            return .failed(reason: "exportPDF: PDFExporter returned nil")
        }
        return .applied(info: ["outputPath": url.path])
    }

    // MARK: - Markdown block helpers (shared with EditNoteTool)

    /// Apply a kind to a markdown string by splitting on blank-line
    /// block separators. Mirrors `EditNoteTool.applyOperation` —
    /// they share the wire contract so the WYSIWYG and closed-note
    /// branches give identical results for the same input.
    func applyKindToMarkdown(_ kind: BridgeEditRequest.Kind, existing: String) throws -> String {
        switch kind {
        case .replaceDocument(let md):
            return md.hasSuffix("\n") ? md : md + "\n"
        default:
            break
        }
        var blocks = splitIntoBlocks(existing)
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
            throw BridgeEditError(message: "Block index \(idx) out of range for '\(op)' (note has \(blocks.count) blocks).")
        }
    }

    /// Split markdown into top-level blocks separated by blank lines.
    /// Fenced code blocks are preserved intact. Mirrors
    /// `EditNoteTool.splitIntoBlocks`.
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

    private func normaliseBlock(_ payload: String) -> String {
        var block = payload
        while block.hasSuffix("\n") || block.hasSuffix("\r") {
            block.removeLast()
        }
        return block
    }

    private func leadingFenceMarker(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    // MARK: - Pipeline glue

    /// Apply a full-document replacement through the WYSIWYG pipeline.
    /// Builds a `replaceBlockRange` over every block (or, for an
    /// empty document, parses + assigns directly) so the splice goes
    /// through `applyEditResultWithUndo` → `DocumentEditApplier`.
    private func performReplaceDocument(
        markdown: String,
        editor: EditTextView,
        projection: DocumentProjection,
        actionName: String
    ) -> BridgeEditOutcome {
        let normalised = markdown.hasSuffix("\n") ? markdown : markdown + "\n"
        let newDoc = MarkdownParser.parse(normalised)
        let newBlocks = newDoc.blocks
        guard !newBlocks.isEmpty else {
            return .failed(reason: "performReplaceDocument: parsed document has no blocks")
        }
        let result: EditResult
        do {
            if projection.document.blocks.isEmpty {
                // Empty starting projection: synthesise an insert at 0
                // by replacing block 0 after a sentinel insert. The
                // simplest correct path is to install the new
                // projection directly via fillViaBlockModel — but
                // that bypasses applyEditResultWithUndo and the
                // contract assertion. For symmetry we route through
                // EditingOps.insert which has an empty-document
                // special-case branch that uses the same applier.
                let firstSerialised = MarkdownSerializer.serialize(newDoc)
                result = try EditingOps.insert(firstSerialised, at: 0, in: projection)
            } else {
                let lastIdx = projection.document.blocks.count - 1
                result = try EditingOps.replaceBlockRange(0...lastIdx, with: newBlocks, in: projection)
            }
        } catch {
            return .failed(reason: "performReplaceDocument: \(error.localizedDescription)")
        }
        editor.applyEditResultWithUndo(result, actionName: actionName)
        // Persist so the on-disk file matches the new projection.
        _ = openNote?.save()
        return .applied(info: [
            "blockCount": newBlocks.count,
            "bytesSerialised": normalised.utf8.count
        ])
    }

    // MARK: - Helpers

    /// Pick the right separator to splice `appended` markdown onto
    /// `existing` so the result has exactly one blank line between
    /// the prior content and the appended payload.
    private func bridgeAppendSeparator(for existing: String) -> String {
        if existing.isEmpty || existing.hasSuffix("\n\n") { return "" }
        if existing.hasSuffix("\n") { return "\n" }
        return "\n\n"
    }

    /// Stable string identifier for a formatting command. Used in the
    /// applied-info payload so the LLM can verify the dispatch.
    private func describe(_ command: BridgeFormattingCommand) -> String {
        switch command {
        case .toggleBold: return "bold"
        case .toggleItalic: return "italic"
        case .toggleStrikethrough: return "strikethrough"
        case .toggleInlineCode: return "inline_code"
        case .toggleHeading(let level): return "heading_\(level)"
        case .toggleBlockquote: return "blockquote"
        case .toggleUnorderedList: return "unordered_list"
        case .toggleOrderedList: return "ordered_list"
        case .toggleTodoList: return "todo_list"
        case .insertHorizontalRule: return "horizontal_rule"
        }
    }
}

/// Locally-scoped error used by `applyKindToMarkdown` to surface a
/// human-readable reason. Lifted into `.failed(reason:)` at the
/// dispatch site.
struct BridgeEditError: Error {
    let message: String
}
