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

/// Private `NSWindow` subclass that overrides `canBecomeKeyWindow` to
/// return true. Borderless windows (AppKit's default for sizes without
/// a title bar or close button) normally return false, which prevents
/// `makeKeyAndOrderFront(_:)` from actually keying the window — AppKit
/// logs a runtime warning and silently no-ops. Under the harness's
/// `.keyWindow` activation we want the window to accept key status so
/// the editor can become first responder and TK2's viewport layout
/// controller proceeds past the key-window gate.
private final class HarnessKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

/// Drives real edits against an offscreen EditTextView + Note + window,
/// exposing the resulting state as value-typed snapshots (string,
/// selectedRange, document, saved markdown, HTML rendition).
///
/// Lifetime: owns its window. Call `teardown()` explicitly or let
/// `deinit` handle it. The temp `.md` file on disk is deleted on
/// teardown.
final class EditorHarness {

    // MARK: - Window activation mode

    /// Controls how actively the harness's window participates in the
    /// AppKit event / layout loop. Widget-layer tests that inspect the
    /// editor's subview tree (attachment-host views, overlay views)
    /// need the window to be key + the run loop to pump once so TK2
    /// mounts view-provider views and the overlays attach their
    /// pooled subviews. Pure-pipeline tests don't need this and
    /// should use `.offscreen` to stay fast.
    enum WindowActivation {
        /// Window is created but never made key. TK2 lays out the
        /// viewport but does NOT mount view-provider-backed subviews
        /// (BulletGlyphView, CheckboxGlyphView, InlinePDFView, ...).
        /// The harness does NOT construct
        /// `TableHandleOverlay` / `CodeBlockEditToggleOverlay` — these
        /// normally hang off `ViewController`, which the harness has
        /// no equivalent of. Default: preserves the pre-existing test
        /// environment for ~1,640 pipeline tests.
        case offscreen

        /// Window is made key + front, editor is made first responder,
        /// `NSTextViewportLayoutController.layoutViewport()` runs
        /// synchronously after fill, the run loop pumps once, and the
        /// harness constructs + repositions `TableHandleOverlay` +
        /// `CodeBlockEditToggleOverlay` directly on the editor. These
        /// overlays take `EditTextView` as their only dependency, so
        /// the absence of a `ViewController` is not a blocker.
        ///
        /// Use this for tests that assert on `editor.subviews` —
        /// `TableHandleView`, `CodeBlockEditToggleView`,
        /// `BulletGlyphView`, `CheckboxGlyphView`, and other
        /// attachment-host views that TK2 mounts lazily.
        case keyWindow
    }

    // MARK: - Stored state

    private var window: NSWindow?
    private(set) var editor: EditTextView
    /// The Note owned by this harness. Exposed for tests that need
    /// to re-fill with mutated state (e.g. `cachedFoldState`) or
    /// assert post-edit markdown on save.
    private(set) var note: Note!
    private var tmpURL: URL
    private var torndown = false

    // MARK: - Initialization

    /// Creates a fully-wired offscreen editor + window + Note, and seeds
    /// the editor with the given markdown via the same projection install
    /// that `EditTextView.fillViaBlockModel` uses at runtime.
    ///
    /// - Parameter windowActivation: See `WindowActivation`. Defaults to
    ///   `.offscreen` so existing pipeline tests are unchanged. Widget-
    ///   layer tests (overlay / attachment-host subview assertions)
    ///   must pass `.keyWindow`.
    init(markdown: String = "", windowActivation: WindowActivation = .offscreen) {
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
        // `.borderless` is fine for the default `.offscreen` path, but
        // borderless windows return NO from `canBecomeKeyWindow` — so
        // `.keyWindow` activation would log a warning and fall back
        // silently. Under `.keyWindow` we create the window as a
        // subclass that overrides `canBecomeKeyWindow` to true,
        // keeping the style mask borderless (the window is never
        // presented on screen anyway).
        let window: NSWindow = (windowActivation == .keyWindow)
            ? HarnessKeyableWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            : NSWindow(
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
        self.note = note
        self.tmpURL = tmpURL

        seed(markdown: markdown)

        if windowActivation == .keyWindow {
            activateWindowForWidgetLayer()
        }
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

    /// Activate the harness's window to exercise the widget-layer
    /// mounting paths that are gated on a "live" editor environment.
    /// Borderless offscreen windows — the harness's default — are
    /// never keyed, never first-responder, and never receive the
    /// viewport-layout event loop runway that TK2's
    /// `NSTextViewportLayoutController` uses to mount view-provider
    /// hosted subviews (`BulletGlyphView`, `CheckboxGlyphView`,
    /// `InlinePDFView`, ...). Under the `.offscreen` default, those
    /// subviews simply never exist; widget-layer tests that assert
    /// on them silently pass on a bug they cannot see.
    ///
    /// This method makes the window key, makes the editor first
    /// responder, forces a synchronous viewport layout pass, and
    /// pumps the run loop once so deferred AppKit work (hosted-view
    /// `loadView` callbacks, tracking-area installation, layer-
    /// backed view realization) has a chance to run before any
    /// snapshot reads the subview tree.
    ///
    /// Note on overlay views: `TableHandleOverlay` and
    /// `CodeBlockEditToggleOverlay` hang off `ViewController` in
    /// production via the `owningViewControllerForTableHandleOverlay()`
    /// responder-chain walk inside `fillViaBlockModel`. The harness
    /// has no `ViewController`, so that walk will return nil even
    /// after activation, and the overlays will not construct. That
    /// faithfully reproduces the production-wiring failure class
    /// users have reported — the harness is not papering over it by
    /// constructing overlays directly.
    private func activateWindowForWidgetLayer() {
        guard let window = window else { return }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)

        // TK2's view-provider mount is a two-phase commit. The first
        // `layoutViewport()` pass registers providers (fires
        // `NSTextAttachment.viewProvider(for:location:textContainer:)`);
        // the provider's `loadView()` — the call that actually
        // instantiates the hosted view and adds it under
        // `_NSTextViewportElementView` — is deferred by TK2 to the
        // NEXT layout pass after a run-loop iteration. Do both passes
        // here with pump-between so widget-layer tests observe the
        // fully mounted subview tree.
        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            // Phase 1: register providers.
            tlm.textViewportLayoutController.layoutViewport()
        }

        // First pump: let Phase 1's registrations settle and let any
        // `DispatchQueue.main.async` deferred work enqueued by
        // production code (the fill path's second layoutViewport()
        // call) drain.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // Phase 2: force the provider-view materialization that Phase 1
        // deferred. Without this second pass, `loadView()` never fires
        // even in `.keyWindow` mode — the bug class this harness mode
        // exists to catch.
        if let tlm = editor.textLayoutManager {
            tlm.textViewportLayoutController.layoutViewport()
        }

        // Second pump: let Phase 2's `loadView()` callbacks run and the
        // hosted subviews get inserted before any snapshot reads the
        // subview tree.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
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

    // MARK: - Phase 5e: IME composition

    /// Begin an IME composition session at the current selection with
    /// the given marked string. Routes through the real
    /// `setMarkedText` override — the same NSTextInputClient entry
    /// point a live IME would drive. After this call, the editor's
    /// `compositionSession.isActive` is `true`.
    ///
    /// Offscreen-test caveat: TK2's `setMarkedText` plumbing relies on
    /// a live `NSTextInputContext` + responder chain that borderless
    /// offscreen windows lack. We call our `EditTextView.setMarkedText`
    /// override (which drives the session transition) and then mutate
    /// storage directly under the composition exemption to simulate
    /// the storage-write half that TK2 would do in a live window. This
    /// keeps the test path behaviorally equivalent to the live path
    /// without requiring a real NSTextInputContext.
    func beginComposition(marked: String) {
        let sel = editor.selectedRange()
        simulateSetMarkedText(marked, replacementRange: sel)
    }

    /// Update the marked run during an active composition. Routes
    /// through the same `setMarkedText` override. Marked range is
    /// refreshed from `editor.compositionSession.markedRange` — the
    /// authoritative post-write range.
    func updateComposition(marked: String) {
        let markedRange = editor.compositionSession.markedRange
        simulateSetMarkedText(marked, replacementRange: markedRange)
    }

    /// Offscreen-test equivalent of AppKit's marked-text storage
    /// write. Calls `EditTextView.setMarkedText` to drive session
    /// lifecycle (entry/update), then — because offscreen TK2
    /// doesn't route NSTextInputClient through to storage — performs
    /// the storage `replaceCharacters` directly under the
    /// composition exemption that the 5a assertion recognises.
    private func simulateSetMarkedText(_ marked: String, replacementRange: NSRange) {
        guard let storage = editor.textStorage else { return }

        let beforeLen = storage.length
        let replacedLen = (replacementRange.location == NSNotFound)
            ? 0 : replacementRange.length
        let expectedDelta = (marked as NSString).length - replacedLen

        editor.setMarkedText(
            marked,
            selectedRange: NSRange(location: (marked as NSString).length, length: 0),
            replacementRange: replacementRange
        )

        let actualDelta = storage.length - beforeLen
        let writeLocation: Int
        if replacementRange.location == NSNotFound {
            writeLocation = editor.selectedRange().location
                - (marked as NSString).length
        } else {
            writeLocation = replacementRange.location
        }

        // If super's setMarkedText did the storage write (live path),
        // just refresh the session's markedRange and return. If not
        // (offscreen path), perform the write ourselves under the
        // composition exemption the 5a assertion recognises.
        var session = editor.compositionSession
        session.markedRange = NSRange(
            location: writeLocation, length: (marked as NSString).length
        )
        editor.compositionSession = session

        if actualDelta == expectedDelta {
            return
        }

        let writeRange = (replacementRange.location == NSNotFound)
            ? NSRange(location: editor.selectedRange().location, length: 0)
            : replacementRange
        let clamped = NSRange(
            location: min(max(writeRange.location, 0), storage.length),
            length: min(writeRange.length, max(0, storage.length - writeRange.location))
        )
        storage.beginEditing()
        storage.replaceCharacters(in: clamped, with: marked)
        storage.endEditing()
    }

    /// Commit the active composition with the given final string.
    /// Routes through `insertText(_:replacementRange:)` targeting the
    /// current marked range — the standard commit entry point. After
    /// this call, `compositionSession.isActive` is `false` and the
    /// final text is reflected in both storage and `Document`.
    ///
    /// Asserts the resulting contract via the harness's standard
    /// `assertLastContract` path. Non-empty `final` produces one
    /// `EditContract.modifyInline` (or a block-boundary action if
    /// the commit crosses a block) from
    /// `EditingOps.insert(_:at:in:)`.
    func commitComposition(
        final: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let markedRange = editor.compositionSession.markedRange
        editor.insertText(final, replacementRange: markedRange)
        assertLastContract(file: file, line: line)
    }

    /// Abort the active composition. Equivalent to committing with
    /// an empty string — reverts storage to the pre-marked state,
    /// clears the session, produces NO `EditContract` (Document is
    /// unchanged). The harness's contract assertion is suppressed
    /// by design: abort does not invoke `applyEditResultWithUndo`,
    /// so `lastEditContract` is not refreshed.
    func abortComposition() {
        let markedRange = editor.compositionSession.markedRange
        editor.insertText("", replacementRange: markedRange)
    }

    /// Read-only accessor for tests that need to inspect composition
    /// state (e.g. to assert `isActive == true` mid-session).
    var compositionSession: CompositionSession {
        editor.compositionSession
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

    // MARK: - Mouse input

    /// Simulate a left mouse click at `point` (in the editor's local
    /// coordinate space, not window/screen). Drives
    /// `NSTextView.mouseDown(with:)` via a synthesised `NSEvent` so
    /// hit-testing, cursor placement, fragment click routing, and
    /// selection-change delegate callbacks all fire through the live
    /// widget path — the same code paths a real user click takes.
    ///
    /// - Parameters:
    ///   - point: Click location in the editor's view-local coordinate
    ///     space. Convert from text-container coords with
    ///     `textContainerInset` if you derived the point from layout
    ///     geometry.
    ///   - modifiers: Optional modifier flags on the synthesised event.
    /// - Returns: `editor.selectedRange` after `mouseDown` returns.
    @discardableResult
    public func clickAt(
        point: NSPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSRange {
        guard let window = editor.window else {
            return editor.selectedRange()
        }
        // NSEvent's `location` is in window coordinates; convert from
        // the editor-local point. `convert(_:to: nil)` on a view yields
        // window coords.
        let windowPoint = editor.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            return editor.selectedRange()
        }
        editor.mouseDown(with: event)
        return editor.selectedRange()
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
