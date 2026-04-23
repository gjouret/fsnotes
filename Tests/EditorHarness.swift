//
//  EditorHarness.swift
//  FSNotesTests
//
//  Phase 0 test harness that drives real edits through the live editor.
//  Consolidates the `makeFullPipelineEditor` / `runFullPipeline` helpers
//  that were duplicated in NewLineTransitionTests.swift and HeaderTests.swift
//  and the seeded editor + EditStep DSL in EditorHTMLParityTests.swift.
//
//  Input entry points: the harness routes scripted inputs through
//  `EditTextView.handleEditViaBlockModel` (typing / return / backspace) and
//  toolbar-level ViaBlockModel primitives. This is the same path that
//  NSTextView's delegate chain ultimately invokes on user input, so the
//  harness exercises the projection → renderer → view chain the same way
//  the app does — while avoiding the offscreen-window crashes we saw when
//  calling `insertText(_:replacementRange:)` during pipeline boot.
//
//  The harness is deliberately *not* a reimplementation of EditingOps —
//  it is a thin shim that exposes (a) scripted input (b) live state as
//  value-typed snapshots. Tests own their assertions.
//

import XCTest
import AppKit
@testable import FSNotes

/// Drives real edits against an offscreen EditTextView + Note + window,
/// exposing the resulting state as value-typed snapshots (string,
/// selectedRange, document, saved markdown, HTML rendition).
///
/// Lifetime: owns its window. Call `teardown()` explicitly or let
/// `deinit` handle it. The temp `.md` file on disk is deleted on
/// teardown.
final class EditorHarness {

    // MARK: - Stored state

    private var window: NSWindow?
    private(set) var editor: EditTextView
    private var tmpURL: URL
    private var torndown = false

    // MARK: - Initialization

    /// Creates a fully-wired offscreen editor + window + Note, and seeds
    /// the editor with the given markdown via the same projection install
    /// that `EditTextView.fillViaBlockModel` uses at runtime.
    init(markdown: String = "") {
        // `hideSyntax = true` matches the setting the WYSIWYG pipeline
        // relies on. Tests that need source mode should override.
        NotesTextProcessor.hideSyntax = true

        // Use the proven `EditorHTMLParityTests.makeEditor` shape: the
        // frame-only init lets EditTextView own its own NSTextContainer
        // and LayoutManager, which `initTextStorage()` then swaps into
        // the custom LayoutManager subclass. Pre-building a text
        // container and handing it to the init triggered dangling
        // references in `initTextStorage()` on macOS 26 — tests crashed
        // in teardown with EXC_BAD_ACCESS.
        let frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let editor = EditTextView(frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(editor)
        editor.initTextStorage()

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness_\(UUID().uuidString).md")
        let project = Project(
            storage: Storage.shared(),
            url: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let note = Note(url: tmpURL, with: project)
        note.type = .Markdown
        note.content = NSMutableAttributedString(string: "")
        editor.isEditable = true
        editor.allowsUndo = true
        editor.note = note

        self.window = window
        self.editor = editor
        self.tmpURL = tmpURL

        seed(markdown: markdown)
    }

    deinit {
        // deinit is nonisolated. Best-effort temp cleanup only.
        try? FileManager.default.removeItem(at: tmpURL)
    }

    /// Install the block-model projection for `markdown` directly on the
    /// editor, bypassing `TextStorageProcessor.process()`. Mirrors
    /// `EditorHTMLParityTests.fill`, the path that is proven to work in
    /// an offscreen test context. The TextStorageProcessor is toggled
    /// through `isRendering=true` so our setAttributedString does not
    /// trigger the full pipeline recursively.
    private func seed(markdown: String) {
        guard let storage = editor.textStorage else { return }
        let doc = MarkdownParser.parse(markdown)
        let proj = DocumentProjection(
            document: doc,
            bodyFont: NSFont.systemFont(ofSize: 14),
            codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        )
        editor.textStorageProcessor?.isRendering = true
        storage.setAttributedString(proj.attributed)
        editor.textStorageProcessor?.isRendering = false
        editor.documentProjection = proj
        editor.textStorageProcessor?.blockModelActive = true
        editor.note?.content = NSMutableAttributedString(string: markdown)
        editor.note?.cachedDocument = doc
    }

    /// Explicit teardown: remove the temp file. Safe to call multiple
    /// times.
    ///
    /// NOTE: we deliberately do NOT call `window.close()` here. On
    /// macOS 26, closing a borderless offscreen window during test
    /// teardown caused an over-release crash in
    /// `XCTMemoryChecker._assertInvalidObjectsDeallocatedAfterScope`
    /// (`objc_autoreleasePoolPop` → EXC_BAD_ACCESS). The proven pattern
    /// in `EditorHTMLParityTests.makeEditor` does not close windows
    /// either — the autorelease pool drains them at scope exit. We
    /// match that pattern exactly.
    func teardown() {
        guard !torndown else { return }
        torndown = true
        try? FileManager.default.removeItem(at: tmpURL)
    }

    // MARK: - Scripted input
    //
    // Every method routes through `handleEditViaBlockModel`, the shared
    // splice entry point that both the NSTextView delegate chain and
    // toolbar actions funnel into. This exercises the real block-model
    // edit path the app uses.

    /// Type text at the current selection.
    ///
    /// No newlines — use `pressReturn()` for those. `handleEditViaBlockModel`
    /// is the same primitive called from `EditTextView.textView(
    /// _:shouldChangeTextIn:replacementString:)`.
    ///
    /// - Parameters:
    ///   - text: The text to type.
    ///   - file / line: Propagated to any contract-failure assertion
    ///     so test failures point at the harness call site.
    func type(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        precondition(
            !text.contains("\n"),
            "EditorHarness.type: must not contain newlines; use pressReturn()"
        )
        _ = editor.handleEditViaBlockModel(
            in: editor.selectedRange(),
            replacementString: text
        )
        assertLastContract(file: file, line: line)
    }

    /// Press Return — routes through the same primitive with `\n`.
    /// Triggers the newLine state machine.
    func pressReturn(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = editor.handleEditViaBlockModel(
            in: editor.selectedRange(),
            replacementString: "\n"
        )
        assertLastContract(file: file, line: line)
    }

    /// Backspace: delete the character before the cursor, or the current
    /// selection if one exists.
    func pressDelete(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sel = editor.selectedRange()
        let range: NSRange
        if sel.length > 0 {
            range = sel
        } else if sel.location > 0 {
            range = NSRange(location: sel.location - 1, length: 1)
        } else {
            return
        }
        _ = editor.handleEditViaBlockModel(
            in: range,
            replacementString: ""
        )
        assertLastContract(file: file, line: line)
    }

    /// Forward-delete: delete the character after the cursor, or the
    /// current selection if one exists.
    func pressForwardDelete(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sel = editor.selectedRange()
        let len = editor.textStorage?.length ?? 0
        let range: NSRange
        if sel.length > 0 {
            range = sel
        } else if sel.location < len {
            range = NSRange(location: sel.location, length: 1)
        } else {
            return
        }
        _ = editor.handleEditViaBlockModel(
            in: range,
            replacementString: ""
        )
        assertLastContract(file: file, line: line)
    }

    /// Paste markdown at the current selection. Goes through the same
    /// handleEditViaBlockModel path — the paste integration in the live
    /// app funnels multi-char replacements through this primitive.
    func paste(
        markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = editor.handleEditViaBlockModel(
            in: editor.selectedRange(),
            replacementString: markdown
        )
        assertLastContract(file: file, line: line)
    }

    // MARK: - Contract enforcement

    /// Phase 1 exit criterion: every scripted input that lands a
    /// block-model edit is auto-checked against the primitive's declared
    /// `EditContract`. When the edit path doesn't populate a contract
    /// (pre-Batch-H legacy primitives, non-block-model pipeline), this
    /// is a silent no-op — contract retrofits are enabled one primitive
    /// at a time, not gated here.
    ///
    /// The harness reads `editor.preEditProjection` + `editor.lastEditContract`,
    /// both populated inside `EditTextView.applyEditResultWithUndo`, and
    /// the current `editor.documentProjection` as the "after" side. Calls
    /// `Invariants.assertContract` directly — same helper every
    /// `EditContractTests` case uses, so harness-driven and pure-function
    /// tests share one enforcement mechanism.
    private func assertLastContract(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let contract = editor.lastEditContract,
              let before = editor.preEditProjection,
              let after = editor.documentProjection else {
            return
        }
        Invariants.assertContract(
            before: before,
            after: after,
            contract: contract,
            file: file,
            line: line
        )
    }

    /// Move the cursor (zero-length selection) to the given offset.
    func moveCursor(to location: Int) {
        let safe = min(max(location, 0), editor.textStorage?.length ?? 0)
        editor.setSelectedRange(NSRange(location: safe, length: 0))
    }

    /// Select the given range.
    func selectRange(_ range: NSRange) {
        editor.setSelectedRange(range)
    }

    // MARK: - Live state

    /// Full text currently in the editor's textStorage.
    var contentString: String {
        editor.textStorage?.string ?? ""
    }

    /// Current selection range.
    var selectedRange: NSRange {
        editor.selectedRange()
    }

    /// The block-model Document if the editor is in block-model mode,
    /// otherwise nil.
    var document: Document? {
        editor.documentProjection?.document
    }

    /// Markdown that a save() would produce right now, without touching
    /// disk. For block-model notes this is the canonical serialization
    /// of the Document projection; for source-mode notes we fall back to
    /// the raw textStorage string.
    var savedMarkdown: String {
        if let doc = document {
            return MarkdownSerializer.serialize(doc)
        }
        return contentString
    }

    /// HTML rendition of the current block-model document, or the
    /// empty string if the editor is not in block-model mode.
    var htmlRendition: String {
        guard let doc = document else { return "" }
        return DocumentHTMLRenderer.render(doc)
    }
}
