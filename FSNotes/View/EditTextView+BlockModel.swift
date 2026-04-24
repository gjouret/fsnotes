//
//  EditTextView+BlockModel.swift
//  FSNotes
//
//  Integration layer: wires the block-model rendering pipeline
//  (Document → DocumentProjection → EditingOps) into EditTextView.
//
//  When `documentProjection` is non-nil, the editor operates in
//  "block-model mode":
//    - fill() parses markdown → Document → rendered attributed string
//    - User edits route through EditingOps (shouldChangeText returns
//      false; we apply the splice ourselves)
//    - Save serializes Document back to markdown
//    - The old TextStorageProcessor pipeline is bypassed
//
//  When `documentProjection` is nil (source mode, non-markdown notes),
//  the source-mode pipeline runs unchanged.
//

import Foundation
import AppKit

// MARK: - File-based diagnostic logging

/// Diagnostic log file for the block-model pipeline.
///
/// Debug-only developer aid. Writes to `<project-root>/logs/block-model.log`
/// so the user's `~/Documents/` is not polluted by a log that only exists
/// to debug the block-model pipeline on this developer's machine. The
/// project root is derived at compile time from `#filePath` — this file
/// lives at `<project-root>/FSNotes/View/EditTextView+BlockModel.swift`,
/// three levels deep. Release builds should never hit this path (bmLog
/// is only called from diagnostic probes), but even if they did, the
/// compile-time path is stable and the `logs/` directory is gitignored.
let blockModelLogURL: URL = {
    let sourceFile = URL(fileURLWithPath: #filePath)
    let projectRoot = sourceFile
        .deletingLastPathComponent()  // .../FSNotes/View/
        .deletingLastPathComponent()  // .../FSNotes/
        .deletingLastPathComponent()  // .../<project root>/
    let logsDir = projectRoot.appendingPathComponent("logs")
    try? FileManager.default.createDirectory(
        at: logsDir, withIntermediateDirectories: true)
    return logsDir.appendingPathComponent("block-model.log")
}()

private let bmLogDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return df
}()

func bmLog(_ message: String) {
    let line = "[\(bmLogDateFormatter.string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: blockModelLogURL.path) {
        if let handle = try? FileHandle(forWritingTo: blockModelLogURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    } else {
        try? data.write(to: blockModelLogURL)
    }
}

extension EditTextView {

    // MARK: - Projection property

    /// The active block-model projection, or nil if using the source-mode
    /// pipeline. Stored via objc_getAssociatedObject so we don't need
    /// to modify the EditTextView class definition.
    var documentProjection: DocumentProjection? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.projection) as? DocumentProjection
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.projection, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // Phase 4.6: auto-sync `textStorageProcessor.blocks` from the
            // new projection so fold/unfold + gutter-draw see the current
            // block list without an explicit call. Callers used to invoke
            // `syncBlocksFromProjection(_:)` manually after every
            // projection update — that public API has been retired.
            if let proj = newValue {
                textStorageProcessor?.rebuildBlocksFromProjection(proj)
            }
        }
    }

    private enum AssociatedKeys {
        static var projection = 0
        static var pendingTraits = 1
        static var suppressTraitClear = 2
        static var coalescedLayoutPending = 3
        static var explicitlyOffTraits = 4
        static var lastEditContract = 5
        static var preEditProjection = 6
        static var editingCodeBlocks = 7
        static var compositionSession = 8
        static var preSessionFoldState = 9
        static var setMarkedTextInFlight = 10
    }

    // MARK: - Phase 5e composition session

    /// Transient IME composition state for this editor. Never nil —
    /// defaults to `.inactive` when no composition is in flight.
    /// `NSTextInputClient` overrides on `EditTextView` (setMarkedText,
    /// unmarkText, insertText) read/write this; the 5a DEBUG assertion
    /// in `TextStorageProcessor.didProcessEditing` reads it via
    /// `compositionAllowsEdit` to decide whether a storage mutation is
    /// a sanctioned marked-range write.
    public var compositionSession: CompositionSession {
        get {
            return (objc_getAssociatedObject(
                self, &AssociatedKeys.compositionSession
            ) as? CompositionSession) ?? .inactive
        }
        set {
            objc_setAssociatedObject(
                self, &AssociatedKeys.compositionSession, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Fold state captured at composition start. IME placement
    /// doesn't know about collapsed blocks, so the composition
    /// override unfolds the containing block on entry and re-folds
    /// on commit using this snapshot. Nil when no composition is
    /// active or no fold state was captured.
    public var preSessionFoldState: Set<Int>? {
        get {
            return objc_getAssociatedObject(
                self, &AssociatedKeys.preSessionFoldState
            ) as? Set<Int>
        }
        set {
            objc_setAssociatedObject(
                self, &AssociatedKeys.preSessionFoldState, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Re-entrance guard for `setMarkedText`. AppKit's default
    /// `NSTextView.setMarkedText` may internally call `insertText`
    /// while it writes the marked characters into storage. Without
    /// this guard our `insertText` override would mistake that
    /// internal call for a commit (replacementRange matches the
    /// marked range we just recorded) and fire the canonical commit
    /// flow from inside super.setMarkedText — double-committing.
    /// When this flag is true, `insertText` falls through to super
    /// unchanged.
    var setMarkedTextInFlight: Bool {
        get {
            return (objc_getAssociatedObject(
                self, &AssociatedKeys.setMarkedTextInFlight
            ) as? Bool) ?? false
        }
        set {
            objc_setAssociatedObject(
                self, &AssociatedKeys.setMarkedTextInFlight, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Phase 8 — Code-Block Edit Toggle (Slice 3).
    ///
    /// The set of `BlockRef`s whose backing code blocks are currently
    /// in EDITING form (raw fenced source, not rendered preview /
    /// syntax-highlighted). Toggled by clicking the hover `</>` button
    /// that `CodeBlockEditToggleOverlay` paints over each code block.
    ///
    /// Per-editor session state — not persisted. The set is threaded
    /// through `DocumentRenderer.render(editingCodeBlocks:)` and
    /// `DocumentEditApplier.applyDocumentEdit(priorEditingBlocks:
    /// newEditingBlocks:)`; the Slice-1 `promoteToggledBlocksToModified`
    /// post-LCS pass re-renders just the toggled block's span on each
    /// flip.
    ///
    /// Slice 4 (`collapseEditingCodeBlocksOutsideSelection`) drops
    /// blocks from this set whenever the selection leaves their span.
    /// Call sites: the outer `textViewDidChangeSelection` delegate
    /// methods in `ViewController+Events.swift` and
    /// `NoteViewController.swift`.
    public var editingCodeBlocks: Set<BlockRef> {
        get {
            return (objc_getAssociatedObject(
                self, &AssociatedKeys.editingCodeBlocks
            ) as? Set<BlockRef>) ?? []
        }
        set {
            objc_setAssociatedObject(
                self, &AssociatedKeys.editingCodeBlocks, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// The `EditContract` from the most recent `applyEditResultWithUndo`
    /// call. Used by `EditorHarness` (and by live-pipeline invariant
    /// tests) to assert that the contract the primitive declared
    /// matches what actually happened to the projection. Nil when the
    /// primitive did not declare a contract (pre-Batch-H paths) or when
    /// no edit has fired yet.
    ///
    /// Phase 1 exit criterion ("Harness runs contracts as invariants"):
    /// Bucket B/C tests that drive the live editor through
    /// `EditorHarness` pick this up automatically — every scripted
    /// input records its contract here, and the harness's assertion
    /// helper verifies the pre/post projection pair against it.
    var lastEditContract: EditContract? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.lastEditContract) as? EditContract
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.lastEditContract, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Snapshot of the projection as it was just before the most recent
    /// `applyEditResultWithUndo`. Paired with `lastEditContract` so the
    /// harness can call `Invariants.assertContract(before:after:contract:)`
    /// without threading a pre/post pair manually through every scripted
    /// input.
    var preEditProjection: DocumentProjection? {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.preEditProjection) as? DocumentProjection
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.preEditProjection, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Inline traits the user JUST toggled OFF on an empty selection.
    /// Reading flow:
    ///  - `toggleInlineTraitViaBlockModel` populates this when removing
    ///    a trait that had been pending (so the user explicitly intends
    ///    "no bold from here on", not "inherit from surrounding").
    ///  - `handleEditViaBlockModel` consumes it on the next insert: if
    ///    set, the insert routes through `insertWithTraits([], ...)`
    ///    which uses `splitInlines`, so the inserted text becomes a
    ///    sibling of any surrounding styled run instead of being spliced
    ///    INTO it (fix for bug 26 "CMD+B stuck on").
    ///  - `textViewDidChangeSelection` clears it (via the same suppress
    ///    flag that protects `pendingInlineTraits`) so cursor movement
    ///    away from the toggle point returns to default inheritance.
    var explicitlyOffTraits: Set<EditingOps.InlineTrait> {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.explicitlyOffTraits) as? Set<EditingOps.InlineTrait> ?? []
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.explicitlyOffTraits, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Whether a coalesced layout pass is already scheduled.
    private var coalescedLayoutPending: Bool {
        get { objc_getAssociatedObject(self, &AssociatedKeys.coalescedLayoutPending) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &AssociatedKeys.coalescedLayoutPending, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Schedule a single ensureLayout call that coalesces multiple
    /// attachment replacements (mermaid, math). Instead of calling
    /// ensureLayout after each replacement, we schedule one call on
    /// the next run loop iteration. Multiple calls to this method
    /// within the same event cycle result in a single layout pass.
    func scheduleCoalescedLayout() {
        guard !coalescedLayoutPending else { return }
        coalescedLayoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.coalescedLayoutPending = false
            // Phase 2a: do NOT read `self.layoutManager` under TextKit 2.
            // AppKit silently instantiates a TK1 shim on first access,
            // permanently tearing down `textLayoutManager`.
            if self.textLayoutManager == nil,
               let lm = self.layoutManager,
               let storage = self.textStorage {
                let fullRange = NSRange(location: 0, length: storage.length)
                lm.ensureLayout(forCharacterRange: fullRange)
            }
            self.needsDisplay = true
        }
    }

    /// Pending inline traits toggled while the selection is empty.
    /// Characters typed next will be wrapped in these traits.
    var pendingInlineTraits: Set<EditingOps.InlineTrait> {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.pendingTraits) as? Set<EditingOps.InlineTrait> ?? []
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.pendingTraits, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Flag to prevent `textViewDidChangeSelection` from clearing
    /// pending traits during our own cursor updates (e.g., after insertion).
    var suppressPendingTraitClear: Bool {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.suppressTraitClear) as? Bool ?? false
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.suppressTraitClear, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    // MARK: - Fill (note load)

    /// Attempt to load a note via the block-model renderer. Returns
    /// true if the new pipeline handled it, false if the caller should
    /// fall back to the legacy pipeline.
    ///
    /// Prerequisites: `self.note` must be set, textStorage must exist,
    /// and `NotesTextProcessor.hideSyntax` must be true (we don't use
    /// the new renderer in source mode).
    func fillViaBlockModel(note: Note) -> Bool {
        bmLog("🔍 fillViaBlockModel called: hideSyntax=\(NotesTextProcessor.hideSyntax), isMarkdown=\(note.isMarkdown()), hasStorage=\(textStorage != nil) — \(note.title)")
        guard NotesTextProcessor.hideSyntax,
              note.isMarkdown(),
              let storage = textStorage else {
            bmLog("⛔ guard failed, returning false — \(note.title)")
            documentProjection = nil
            textStorageProcessor?.blockModelActive = false
            return false
        }

        // Log initial storage state BEFORE we do anything
        let initialStorageLength = storage.length
        let initialStorageString = storage.string
        bmLog("📊 INITIAL STATE: storage.length=\(initialStorageLength), storage.string='\(initialStorageString)'")

        // Use cached Document if available, otherwise parse from raw markdown.
        // IMPORTANT: note.content.string is UNRELIABLE for the block model
        // because the legacy source-mode pipeline's loadAttachments() replaces
        // ![alt](path) with U+FFFC attachment characters. We must read the
        // raw markdown directly from disk to get the original text.
        let document: Document
        if let cached = note.cachedDocument {
            document = cached
            bmLog("📋 Using cached document with \(cached.blocks.count) blocks")
        } else {
            let markdown: String
            if let fileURL = note.getContentFileURL(),
               let rawMarkdown = try? String(contentsOf: fileURL, encoding: .utf8) {
                markdown = rawMarkdown
            } else {
                bmLog("⚠️ Could not read raw markdown from disk, falling back to note.content (may contain U+FFFC)")
                markdown = note.content.string
            }
            bmLog("📝 Parsing markdown: '\(markdown)' (length=\(markdown.count))")
            document = MarkdownParser.parse(markdown)
            note.cachedDocument = document
            bmLog("📋 Parsed document: \(document.blocks.count) blocks, trailingNewline=\(document.trailingNewline)")
        }

        // Render via the block-model pipeline.
        let bodyFont = UserDefaultsManagement.noteFont
        let codeFont = UserDefaultsManagement.codeFont
        let projection = DocumentProjection(
            document: document,
            bodyFont: bodyFont,
            codeFont: codeFont,
            note: note
        )

        bmLog("🎨 Rendered projection: \(projection.attributed.length) chars, string='\(projection.attributed.string)'")
        bmLog("📐 Block spans: \(projection.blockSpans.map { "[\($0.location),\($0.length)]" }.joined(separator: ", "))")

        // Save fold state from the previous note (if any) before replacing storage.
        if let prevNote = self.note, let processor = textStorageProcessor {
            let collapsed = processor.collapsedBlockIndices
            if !collapsed.isEmpty {
                prevNote.cachedFoldState = collapsed
            }
        }

        // Hydrate the incoming note's fold state from disk before the
        // projection is rendered so the renderer can apply collapsed
        // attributes to the matching headers on first paint. The load
        // is a no-op when the in-memory cache is already populated
        // (e.g., switching back to a note that was open earlier in
        // the same session).
        note.loadFoldStateFromDisk()

        // Set the rendered attributed string into textStorage.
        // Use isRendering to prevent the source-mode pipeline from
        // processing this setAttributedString.
        //
        // On TK2, wrap the replacement in `performEditingTransaction` on
        // the NSTextContentStorage. Without the transaction, TK2's
        // layout fragments can be built from a stale view of the
        // storage on first paint — producing a correctly-attributed
        // but invisibly-rendered list block (the todo "white text on
        // load" bug). Any subsequent splice goes through
        // replaceCharacters which drives the content storage's own
        // change notifications, so the second render is correct. The
        // transaction makes the initial fill take the same fast path
        // the splice would.
        textStorageProcessor?.isRendering = true
        // Phase 5a: initial-fill `setAttributedString` is the whole-
        // document replacement path; mark it authorized so the debug
        // assertion in `TextStorageProcessor.didProcessEditing` sees
        // an active write scope.
        StorageWriteGuard.performingFill {
            storage.setAttributedString(projection.attributed)
        }
        textStorageProcessor?.isRendering = false

        // Verify storage matches projection after setting
        bmLog("✅ AFTER setAttributedString: storage.length=\(storage.length), projection.length=\(projection.attributed.length)")

        documentProjection = projection
        textStorageProcessor?.blockModelActive = true
        // Phase 4.6: the `documentProjection` setter auto-syncs
        // `processor.blocks` from `projection`, so no explicit sync call
        // is needed here.

        // Restore fold state from the note's cache (RC5).
        if let savedFolds = note.cachedFoldState, !savedFolds.isEmpty,
           let processor = textStorageProcessor {
            processor.restoreCollapsedState(savedFolds, textStorage: storage)
        }

        // Force an initial layout pass **synchronously**, before first
        // paint. Previously this ran via `DispatchQueue.main.async` at
        // the fill() call site, which meant checkbox / view-provider
        // attachments didn't draw until the user scrolled or clicked,
        // because TK2's view-provider integration needs a layout pass
        // to wire the hosted views and the first layout pass was
        // deferred to the next user event.
        //
        // Native tables render via `TableLayoutFragment` and need no
        // separate render pass; the layout pass below is sufficient.
        if let tlm = textLayoutManager {
            // Scope the sync layout pass to the visible viewport, not
            // the whole document. A full-doc `ensureLayout` on a
            // 500k-char note blocks the main thread for seconds. We
            // only need first-paint to resolve attachment view
            // providers that intersect the viewport — everything
            // offscreen falls on TK2's normal lazy layout path
            // triggered by scroll. Document-range fallback handles the
            // case where the viewport range can't be derived (e.g. the
            // view hasn't been added to a window yet during tests).
            if let viewport = tlm.textViewportLayoutController.viewportRange {
                tlm.ensureLayout(for: viewport)
            } else {
                tlm.ensureLayout(for: tlm.documentRange)
            }
        }

        bmLog("✅ fillViaBlockModel complete: \(document.blocks.count) blocks, rendered \(projection.attributed.length) chars — \(note.title)")

        return true
    }

    // MARK: - Source-mode rendering (Phase 4.4)

    /// Parse the note's markdown → Document → `SourceRenderer.render(...)`
    /// and set it on `textStorage`. Used for the source-mode view
    /// (hideSyntax == false) — the user sees the raw markdown with
    /// visible markers, and `SourceLayoutFragment` paints those markers
    /// in the theme's marker color.
    ///
    /// Returns true on success, false if the caller should fall back to
    /// the pre-4.4 `storage.setAttributedString(note.content)` path.
    /// Prerequisites: `self.note` must be set and `textStorage` must
    /// exist. This path runs ONLY when `hideSyntax == false` (source
    /// mode); WYSIWYG continues through `fillViaBlockModel`.
    func fillViaSourceRenderer(note: Note) -> Bool {
        guard note.isMarkdown(),
              let storage = textStorage else {
            return false
        }

        // Read the raw markdown from disk — `note.content.string` is
        // unreliable here for the same reason `fillViaBlockModel` reads
        // from disk: `loadAttachments()` replaces `![alt](path)` with
        // U+FFFC attachment characters, which we don't want in the
        // source-mode view.
        let markdown: String
        if let fileURL = note.getContentFileURL(),
           let rawMarkdown = try? String(contentsOf: fileURL, encoding: .utf8) {
            markdown = rawMarkdown
        } else {
            markdown = note.content.string
        }
        let document = MarkdownParser.parse(markdown)
        note.cachedDocument = document

        let rendered = SourceRenderer.render(
            document,
            bodyFont: UserDefaultsManagement.noteFont,
            codeFont: UserDefaultsManagement.codeFont
        )

        // Set the rendered attributed string. Gate the source-mode
        // pipeline (`TextStorageProcessor.process`) off for this paint
        // so the legacy highlight path doesn't clobber our markers.
        textStorageProcessor?.isRendering = true
        // Phase 5a: source-mode fill is also a full-doc replacement;
        // mark it authorized. The 5a debug assertion short-circuits on
        // `sourceRendererActive == true` but we still flag the scope to
        // keep the audit story uniform across fill paths.
        StorageWriteGuard.performingFill {
            storage.setAttributedString(rendered)
        }
        textStorageProcessor?.isRendering = false

        textStorageProcessor?.sourceRendererActive = true
        // WYSIWYG projection is not active — the source-mode view has
        // no block-model projection (edits flow into storage directly
        // and textDidChange re-parses / re-renders).
        documentProjection = nil
        textStorageProcessor?.blockModelActive = false

        return true
    }

    // MARK: - Undo support

    /// Apply an EditResult to textStorage, update the projection, set
    /// the cursor, and register an undo action. This is the SINGLE code
    /// path for all block-model mutations — every edit, formatting
    /// operation, and list FSM transition routes through here.
    ///
    /// - Parameters:
    ///   - result: The EditResult from EditingOps.
    ///   - actionName: Human-readable undo action name (e.g. "Typing", "Bold").
    internal func applyEditResultWithUndo(
        _ result: EditResult,
        actionName: String
    ) {
        guard let storage = textStorage else { 
            bmLog("⛔ applyEditResultWithUndo: no textStorage")
            return 
        }

        // Capture state for undo BEFORE mutating.
        guard let oldProjection = documentProjection else {
            bmLog("⛔ applyEditResultWithUndo: no documentProjection")
            return
        }
        let oldCursorRange = selectedRange()

        // Snapshot the pre-edit projection + the declared contract for
        // harness-level invariant checks. `EditorHarness` reads these
        // after each scripted input to enforce the Phase 1 contract
        // against the live editor's post-edit state. Nil `contract` is
        // preserved as-is (some edit paths predate Batch H or explicitly
        // skip the harness assertion).
        self.preEditProjection = oldProjection
        self.lastEditContract = result.contract

        // Snapshot pending inline traits so ANY selectionDidChange fired
        // during this edit cycle (setSelectedRange below + any layout-
        // driven cursor updates) cannot clear them. The previous
        // consume-once `suppressPendingTraitClear` flag failed when
        // more than one selectionDidChange fired: the first consumed
        // the flag, and a follow-up clear wiped the pending trait, so
        // only the FIRST typed character after Cmd+B was bold.
        let savedPendingTraits = pendingInlineTraits
        let savedOffTraits = explicitlyOffTraits

        // Detailed logging for splice application
        bmLog("🔧 applyEditResultWithUndo BEFORE: storage.length=\(storage.length), storage.string='\(storage.string)'")
        bmLog("🔧 spliceRange=\(result.spliceRange), spliceReplacement='\(result.spliceReplacement.string)' (length=\(result.spliceReplacement.length))")

        // Validate splice range against current storage.
        let spliceEnd = result.spliceRange.location + result.spliceRange.length
        guard spliceEnd <= storage.length else {
            bmLog("⚠️ splice range \(result.spliceRange) exceeds storage.length \(storage.length)")
            return
        }

        // No-op edit guard (Perf plan #5): if the splice replaces a
        // range with a byte-identical attributed string (same text AND
        // same attributes), skip the entire mutation path. This catches
        // phantom NSTextView delegate calls (e.g. spurious
        // `shouldChangeText` from a selection click that doesn't
        // actually type anything) which used to invalidate layout,
        // re-run syncTypingAttributes, and fire didChangeText on every
        // selection change in an image-heavy note.
        //
        // IMPORTANT: must compare attributes, not just .string. Heading
        // level changes and inline trait toggles (bold/italic/etc.)
        // leave the plain-text string unchanged because syntax markers
        // live outside storage in the block model — only attributes
        // differ. A string-only comparison would swallow those edits.
        if result.spliceRange.length == result.spliceReplacement.length {
            let oldSub = storage.attributedSubstring(from: result.spliceRange)
            if oldSub.isEqual(to: result.spliceReplacement) {
                // Still need to update the projection + cursor, but we
                // can skip the storage mutation and layout invalidation.
                documentProjection = result.newProjection
                let cursorPos = min(result.newCursorPosition, storage.length)
                let selLen = min(result.newSelectionLength, storage.length - cursorPos)
                setSelectedRange(NSRange(location: cursorPos, length: selLen),
                                 affinity: .downstream, stillSelecting: false)
                syncTypingAttributesToCursorBlock()
                // Restore pending traits (see end-of-function for rationale).
                pendingInlineTraits = savedPendingTraits
                explicitlyOffTraits = savedOffTraits
                return
            }
        }

        // Mark that the user has made an edit — enables save().
        hasUserEdits = true

        // Lock scroll position observer during mutation to prevent
        // transient layout changes from saving wrong scroll positions.
        isScrollPositionSaverLocked = true

        // Save the scroll origin before the mutation so we can restore
        // it at the end. Typing into a list item (especially a Todo)
        // mid-document triggers AppKit's internal
        // `_enableTextViewResizing` → `_resizeTextViewForTextContainer:`
        // chain, which scrolls the clip view DIRECTLY (bypassing
        // `scrollRangeToVisible`, so overriding that alone can't stop
        // it). The range passed to internal scroll calls spans
        // thousands of characters — far larger than the splice — and
        // AppKit scrolls to the START of that range, which in a long
        // note is well above the cursor. Result: every keystroke scrolls
        // the cursor off-screen downward.
        //
        // The clean fix is to save the scroll origin before any
        // mutation and restore it after all layout work is done.
        // The cursor was visible before the edit (user is typing into
        // it), so restoring the original scroll keeps it visible.
        let savedScrollOrigin: NSPoint? =
            enclosingScrollView?.contentView.bounds.origin

        // Suppress NSTextView's automatic undo registration during the
        // splice. Without this, AppKit registers a TEXT-level undo that
        // replaces only the raw characters (losing rendered attributes
        // from the attributed projection). When the user fires undo,
        // that registration plus our own block-model undo run in the
        // wrong order, stripping all formatting from the note. We
        // register our own structural undo at the end of this function.
        let umSplice = self.undoManager ?? editorViewController?.editorUndoManager
        umSplice?.disableUndoRegistration()
        textStorageProcessor?.isRendering = true

        // Phase 3 wire-in: on TK2, route the storage mutation through
        // the element-level `DocumentEditApplier` primitive. It diffs
        // the prior/new Documents and emits a single element-bounded
        // replaceCharacters inside `performEditingTransaction` — the
        // TK2-native equivalent of beginEditing/endEditing that
        // batches delegate callbacks and layout invalidation across
        // the whole mutation. On TK1 (layoutManager-backed storage),
        // fall back to the legacy character-level splice that
        // `EditingOps.narrowSplice` already minimized.
        if let tlm = self.textLayoutManager,
           let contentStorage = tlm.textContentManager as? NSTextContentStorage {
            _ = DocumentEditApplier.applyDocumentEdit(
                priorDoc: oldProjection.document,
                newDoc: result.newProjection.document,
                contentStorage: contentStorage,
                bodyFont: result.newProjection.bodyFont,
                codeFont: result.newProjection.codeFont,
                note: self.note
            )
        } else {
            // Phase 5a: TK1 splice fallback. Same logical scope as
            // `applyDocumentEdit` — an `EditingOps`-driven mutation
            // with prior/new projections. Mark as the canonical
            // document-edit scope so the debug assertion treats this
            // authorized.
            StorageWriteGuard.performingApplyDocumentEdit {
                storage.beginEditing()
                storage.replaceCharacters(
                    in: result.spliceRange,
                    with: result.spliceReplacement
                )
                storage.endEditing()
            }
        }
        umSplice?.enableUndoRegistration()

        let postSpliceAttachmentCount = countAttachmentCharacters(
            in: result.spliceReplacement
        )

        // Re-apply paragraphStyle attribute from the new projection onto
        // storage. narrowSplice() does CHARACTER-only diffing (intentional
        // — preserves attachment identity across renders). When a structural
        // change happens (e.g. heading Return → [heading, paragraph]),
        // characters that already existed in OLD storage stay put with
        // their OLD attributes — even though the NEW projection assigns
        // them a different paragraphStyle. The classic case: the trailing
        // \n that "moves" by one position and keeps its old heading
        // paragraphStyle, leaving the cursor on the new empty paragraph
        // rendered with heading-line metrics.
        //
        // This is an attribute-only sync — no character mutation, no
        // beginEditing/endEditing required. Iterate the new projection's
        // paragraphStyle runs and apply them to the same storage range.
        let newAttr = result.newProjection.attributed
        if newAttr.length == storage.length {
            // Collect only the runs whose paragraphStyle actually DIFFERS
            // from what's already in storage. Writing every run
            // unconditionally (old implementation) marked every
            // paragraph in the document as "edited" on every keystroke.
            // AppKit's `_enableTextViewResizing` reacts to that edit
            // notification by scrolling the clip view relative to the
            // invalidated range — which in a long note shifted the
            // scroll ~2 lines per keystroke until the layout manager's
            // internal state settled (~5-6 chars later). Skipping
            // identical runs eliminates the notification, and with it
            // the scroll drift.
            //
            // Additionally, narrow the enumeration to the block
            // containing the splice plus one neighbour on each side.
            // Characters outside this band were either untouched (their
            // attributes preserved by NSTextStorage.replaceCharacters)
            // or shifted in bulk (attributes shift with them). Only
            // blocks adjacent to a structural change need re-checking.
            let scanRange = Self.paragraphSyncScanRange(
                for: result.spliceRange,
                projection: result.newProjection,
                storageLength: newAttr.length
            )
            var pendingUpdates: [(NSRange, NSParagraphStyle)] = []
            newAttr.enumerateAttribute(
                .paragraphStyle,
                in: scanRange,
                options: []
            ) { value, range, _ in
                guard let newStyle = value as? NSParagraphStyle else { return }
                // Check whether storage already has this exact style
                // across the full run. If every position in `range`
                // already matches, skip the update.
                var identical = true
                storage.enumerateAttribute(
                    .paragraphStyle, in: range, options: []
                ) { oldValue, _, stop in
                    let oldStyle = oldValue as? NSParagraphStyle
                    if oldStyle == nil || !(oldStyle!.isEqual(newStyle)) {
                        identical = false
                        stop.pointee = true
                    }
                }
                if !identical {
                    pendingUpdates.append((range, newStyle))
                }
            }
            if !pendingUpdates.isEmpty {
                storage.beginEditing()
                for (range, style) in pendingUpdates {
                    storage.addAttribute(.paragraphStyle, value: style, range: range)
                }
                storage.endEditing()
            }
        }

        bmLog("🔧 applyEditResultWithUndo AFTER: storage.length=\(storage.length), storage.string='\(storage.string)'")

        // Update projection.
        // Phase 4.6: setter auto-syncs `processor.blocks` from the new
        // projection — no explicit call needed.
        documentProjection = result.newProjection

        // Set cursor without triggering an implicit scroll.
        // The 1-arg setSelectedRange(_:) calls scrollRangeToVisible;
        // the 3-arg variant does not.
        let cursorPos = min(result.newCursorPosition, storage.length)
        let selLen = min(result.newSelectionLength, storage.length - cursorPos)
        setSelectedRange(NSRange(location: cursorPos, length: selLen), affinity: .downstream, stillSelecting: false)

        // Clear isRendering BEFORE didChangeText() so that the
        // textDidChange delegate fires correctly (it checks isRendering
        // and bails if true). isRendering was only needed during the
        // storage mutation above to prevent process() from running.
        textStorageProcessor?.isRendering = false

        // Sync typingAttributes to the block at the new cursor position
        // BEFORE layout computation. The extra line fragment rectangle
        // (cursor metrics at end of storage) is computed during
        // ensureLayout using the typingAttributes present at that moment.
        // If we update typingAttributes AFTER ensureLayout, the cursor
        // inherits stale metrics from the previous block (e.g. heading
        // height after Return on an H2). syncing here fixes the empty-
        // block inheritance bugs for both "Return on heading" and
        // "list item → Delete → empty paragraph" scenarios.
        syncTypingAttributesToCursorBlock()

        // Notify NSTextView that text changed so the layout manager
        // updates, the display refreshes, and the delegate saves.
        didChangeText()

        // Re-hydrate attachments in the splice replacement.
        //
        // When narrowSplice cannot narrow around attachments (because
        // the attachment COUNT differs between old and new — e.g. a
        // multi-paragraph selection that contained an inline image got
        // wrapped into a list, adding 1 bullet attachment per item
        // while the image attachment is re-rendered mid-splice), the
        // splice replaces the live attachment object with a fresh
        // placeholder emitted by InlineRenderer.makeImageAttachment.
        // That placeholder carries `.attachmentUrl`/`.attachmentPath`
        // metadata but has no loaded image data, no PDFView, no
        // QLPreviewView — so the user sees a 1x1 empty cell where
        // their Numbers/PDF/image preview used to be.
        //
        // The three hydrators are idempotent: each skips attachments
        // whose attachmentCell is already the correct type. Calling
        // them after every splice that introduces attachment chars
        // restores the preview without affecting attachments that
        // were preserved in-place by narrowSplice.
        //
        // Gate: only run when the splice replacement contains
        // attachment characters. Pure-text edits (the hot path for
        // typing) skip the hydrator walk entirely.
        if postSpliceAttachmentCount > 0 {
            let containerWidth = self.textContainer?.size.width ?? self.frame.width
            if let note = self.note {
                PDFAttachmentProcessor.renderPDFAttachments(
                    in: storage, note: note, containerWidth: containerWidth
                )
            }
            ImageAttachmentHydrator.hydrate(textStorage: storage, editor: self)
            QuickLookAttachmentProcessor.renderQuickLookAttachments(
                in: storage, containerWidth: containerWidth
            )
        }

        // Invalidate ONLY the spliced region (the characters that
        // actually changed). The previous implementation invalidated
        // from splice.location to end of storage AND called
        // `ensureLayout` on that huge range, which forced the layout
        // manager to synchronously re-measure every line below the
        // cursor. When the re-measured heights differed from the
        // previously-estimated (non-contiguous) heights, AppKit's
        // auto-scroll followed the cursor's new Y-coordinate,
        // shifting the scroll position by roughly a line per
        // keystroke. Over ~10-15 keystrokes this accumulated into
        // a scroll jump large enough to push the cursor off-screen
        // (see bug: typing in a Todo mid-document caused half-pane
        // scroll drift).
        //
        // Narrow invalidation: the splice already ran through
        // storage.beginEditing/endEditing which correctly notified
        // the layout manager of the edit. We only need to display-
        // invalidate the new region so it repaints. Lazy layout
        // handles the rest as the user scrolls or as AppKit
        // decides to re-measure.
        // Narrow display invalidation for the spliced range.
        //
        // IMPORTANT (Phase 2a): do NOT read `self.layoutManager` under
        // TextKit 2. AppKit's NSTextView lazily instantiates a TK1
        // `NSLayoutManager` compatibility shim on first access to the
        // `layoutManager` property, which permanently tears down the
        // TK2 wiring (`textLayoutManager` becomes nil). That's a silent
        // fallback with no API to detect it after the fact. Gate every
        // TK1-API call on `textLayoutManager == nil`.
        if textLayoutManager == nil, let lm = layoutManager {
            let invalidatedRange = NSRange(
                location: result.spliceRange.location,
                length: result.spliceReplacement.length
            )
            let safeRange = NSRange(
                location: min(invalidatedRange.location, storage.length),
                length: min(invalidatedRange.length,
                            max(0, storage.length - invalidatedRange.location))
            )
            if safeRange.length > 0 {
                let glyphRange = lm.glyphRange(
                    forCharacterRange: safeRange,
                    actualCharacterRange: nil
                )
                lm.invalidateDisplay(forGlyphRange: glyphRange)
            }
        }

        // Restore scroll origin if AppKit's internal resize logic
        // scrolled the clip view during the mutation.
        if let saved = savedScrollOrigin,
           let clipView = enclosingScrollView?.contentView,
           clipView.bounds.origin != saved {
            clipView.scroll(to: saved)
            enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        isScrollPositionSaverLocked = false
        needsDisplay = true

        // `InlinePDFView` / `InlineQuickLookView` use TK2 view providers
        // and are managed by AppKit — no manual orphan cleanup needed.
        // Native tables render via `TableLayoutFragment` (no subview
        // lifecycle to manage), so the pre/post attachment count tracking
        // that previously gated the widget-orphan walk is no longer
        // needed either.

        // Mark note as modified.
        note?.cacheHash = nil

        // Phase 5f: record into the structured journal instead of
        // registering a closure-based undo. The journal's `record`
        // fires ONE `NSUndoManager.registerUndo` so the Edit menu's
        // Undo command continues to work; that registration is the
        // single surviving site outside `applyDocumentEdit` scope
        // (commit 6 grep-gate enforces). The legacy
        // `restoreBlockModelState` closure path is retired below.
        //
        // Phase 5f ↔ 5e composition boundary (brief §5): while an IME
        // composition is active, marked-text writes land directly in
        // storage via `setMarkedText`; we must NOT journal those
        // transient edits. On commit, the editor's
        // `unmarkText`/`insertText` path builds exactly ONE
        // `EditContract.replace` and routes it through this function
        // — at which point `compositionSession.isActive` has already
        // flipped to false and the record proceeds normally. On
        // abort, no `applyEditResultWithUndo` call is made at all.
        if !compositionSession.isActive {
            let postCursor = NSRange(location: cursorPos, length: selLen)
            let coalesce = coalesceClass(forActionName: actionName)
            let entry = makeJournalEntry(
                result: result,
                priorDoc: oldProjection.document,
                cursorBefore: oldCursorRange,
                cursorAfter: postCursor,
                actionName: actionName,
                coalesce: coalesce
            )
            undoJournal.record(entry, on: self)
        }

        // Restore pending inline traits. Any selectionDidChange that
        // fired during the edit may have cleared them (consume-once
        // suppress flag can't guard against >1 fire). Snapshot taken
        // at entry; caller-side logic that intentionally clears traits
        // (e.g. newline case) does so BEFORE calling apply, so the
        // snapshot already reflects the intended post-edit state.
        pendingInlineTraits = savedPendingTraits
        explicitlyOffTraits = savedOffTraits
    }

    /// Count U+FFFC attachment characters in an attributed string.
    /// Used by `applyEditResultWithUndo` to gate the post-splice
    /// attachment-hydrator walk on whether the splice replacement
    /// introduced any attachment characters.
    private func countAttachmentCharacters(in attributed: NSAttributedString) -> Int {
        let s = attributed.string as NSString
        var count = 0
        for i in 0..<s.length {
            if s.character(at: i) == 0xFFFC { count += 1 }
        }
        return count
    }

    // Phase 5f: `restoreBlockModelState` was retired with the
    // UndoJournal wire-in above. The journal's `undo(on:)` /
    // `redo(on:)` methods (with `applyInverseHook` / `applyForwardHook`
    // installed in `EditTextView+UndoJournal.swift`) deliver the
    // inverse splice through `DocumentEditApplier.applyDocumentEdit`
    // — the 5a-authorized single write path. No setAttributedString
    // full-storage swap, no legacy guard wrap, no closure pairing.

    // MARK: - Edit interception

    /// Handle a text edit through the block-model pipeline. Returns
    /// true if the edit was handled (caller should NOT proceed with
    /// the default NSTextView mutation), false if the caller should
    /// fall through to source-mode behavior.
    func handleEditViaBlockModel(
        in range: NSRange,
        replacementString: String?
    ) -> Bool {
        guard var projection = documentProjection,
              let storage = textStorage,
              let replacement = replacementString else {
            bmLog("⛔ handleEditViaBlockModel: guard failed - projection=\(documentProjection != nil), storage=\(textStorage != nil), replacement=\(replacementString != nil)")
            return false
        }

        // Phase 2e-T2-e: cell text editing inside a TableElement. The
        // cursor can be parked in a cell via click / Tab / arrow (T2-d
        // plumbing); character inserts and deletions now route through
        // the cell primitive rather than the generic `EditingOps.insert`
        // path, because the separator-encoded storage is the
        // TableElement's flat projection — splicing characters at
        // arbitrary offsets would corrupt the U+001F / U+001E encoding
        // and there is no generic EditingOps path that preserves it.
        //
        // The cell primitive (`replaceTableCellInline`) takes the cell's
        // full new `[Inline]` tree and the surrounding block-model
        // pipeline rebuilds the separator-encoded storage canonically.
        // Cursor position after the edit is computed here because
        // `replaceBlockFast` (the fast path under the primitive) does
        // not know where the caret should land — the caller owns that.
        if storageOffsetIsInTableElement(range.location) {
            if handleTableCellEdit(range: range, replacement: replacement) {
                return true
            }
            // Fall-through means the edit did NOT target a resolvable
            // cell (e.g. the range straddled a separator, or the table
            // block index couldn't be resolved). Fall through to the
            // generic path so delete-at-boundary, cross-block backspace,
            // and similar edge cases keep their T2-d behaviour.
        }

        // Detailed logging for debugging new note typing issues
        bmLog("🎯 handleEditViaBlockModel: range=\(range), replacement='\(replacement)', storage.length=\(storage.length), projection.length=\(projection.attributed.length)")
        bmLog("📝 storage.string='\(storage.string)'")
        bmLog("🎨 projection.string='\(projection.attributed.string)'")

        // Safety: detect storage/projection mismatch (e.g. from async
        // post-fill processing that modified storage without updating
        // the projection).
        if storage.length != projection.attributed.length {
            bmLog("⚠️ storage/projection mismatch: storage=\(storage.length), projection=\(projection.attributed.length). Re-syncing.")
            clearBlockModelAndRefill()
            return false
        }

        do {
            let result: EditResult

            if range.length == 0 && !replacement.isEmpty {
                // Pure insertion.
                let traits = pendingInlineTraits
                let offTraits = explicitlyOffTraits
                if !traits.isEmpty && replacement != "\n" {
                    // Apply pending inline traits to the inserted text.
                    // Suppress trait clearing during our cursor update.
                    suppressPendingTraitClear = true
                    bmLog("➡️ Calling EditingOps.insertWithTraits('\(replacement)', traits: \(traits), at: \(range.location))")
                    result = try EditingOps.insertWithTraits(replacement, traits: traits, at: range.location, in: projection)
                } else if !offTraits.isEmpty && replacement != "\n" {
                    // User explicitly turned a trait off (bug 26 path).
                    // Route through `insertWithTraits` with empty traits
                    // so the new text becomes a sibling of any surrounding
                    // styled run (via `splitInlines`) instead of being
                    // spliced into it (which the default `insert` path
                    // does via `flatten` + `runAtInsertionPoint`).
                    suppressPendingTraitClear = true
                    bmLog("➡️ Calling EditingOps.insertWithTraits('\(replacement)', traits: [], at: \(range.location)) — explicit off")
                    result = try EditingOps.insertWithTraits(replacement, traits: [], at: range.location, in: projection)
                } else {
                    bmLog("➡️ Calling EditingOps.insert('\(replacement)', at: \(range.location))")
                    // Bug #21 diagnostic: when inserting a newline, log the
                    // containing block type and (for lists) the FSM state so
                    // we can tell if Return-at-home is reaching the exitListItem
                    // routing branch.
                    if replacement == "\n" {
                        if let (bIdx, offsetInBlock) = projection.blockContaining(storageIndex: range.location) {
                            let block = projection.document.blocks[bIdx]
                            let blockKind: String
                            switch block {
                            case .paragraph: blockKind = "paragraph"
                            case .heading: blockKind = "heading"
                            case .codeBlock: blockKind = "codeBlock"
                            case .list: blockKind = "list"
                            case .blockquote: blockKind = "blockquote"
                            case .horizontalRule: blockKind = "horizontalRule"
                            case .blankLine: blockKind = "blankLine"
                            case .table: blockKind = "table"
                            case .htmlBlock: blockKind = "htmlBlock"
                            }
                            bmLog("🔍 RETURN diag: block[\(bIdx)]=\(blockKind), offsetInBlock=\(offsetInBlock)")
                            if case .list = block {
                                let atHome = ListEditingFSM.isAtHomePosition(storageIndex: range.location, in: projection)
                                let state = ListEditingFSM.detectState(storageIndex: range.location, in: projection)
                                bmLog("🔍 RETURN diag (list): isAtHomePosition=\(atHome), detectState=\(state)")
                            }
                        } else {
                            bmLog("🔍 RETURN diag: blockContaining returned nil for storageIndex=\(range.location)")
                        }
                    }
                    result = try EditingOps.insert(replacement, at: range.location, in: projection)
                    // Clear pending traits on newline.
                    if replacement == "\n" {
                        pendingInlineTraits = []
                        explicitlyOffTraits = []
                    }
                }
            } else if range.length > 0 && replacement.isEmpty {
                // Check for delete-at-home in a list item (FSM intercept).
                if handleDeleteAtHomeInList(range: range, in: projection) {
                    return true
                }
                // Check for delete-at-home in a heading (convert to paragraph).
                if handleDeleteAtHomeInHeading(range: range, in: projection) {
                    return true
                }
                // Pure deletion.
                result = try EditingOps.delete(range: range, in: projection)
            } else if range.length > 0 && !replacement.isEmpty {
                // Guard: if the range contains only attachment characters
                // and the replacement is the markdown source for that
                // attachment, this is a spurious NSTextView callback —
                // treat as no-op to prevent data loss.
                if isSpuriousAttachmentReplacement(range: range, replacement: replacement) {
                    bmLog("⛔ Ignoring spurious attachment→markdown replacement at \(range)")
                    return true
                }
                // Replacement: single-operation replace preserves inline
                // formatting context (e.g. typing "x" while bold "hello"
                // is selected produces bold "x").
                do {
                    result = try EditingOps.replace(range: range, with: replacement, in: projection)
                } catch {
                    // Fallback for cross-block or newline replacements:
                    // apply delete first, then insert on the resulting state.
                    let deleteResult = try EditingOps.delete(range: range, in: projection)
                    applyEditResultWithUndo(deleteResult, actionName: "Delete")
                    projection = deleteResult.newProjection
                    do {
                        result = try EditingOps.insert(replacement, at: range.location, in: projection)
                    } catch {
                        // Insert failed after delete — UNDO the delete to
                        // prevent data loss. The undo manager recorded the
                        // delete above, so calling undo restores the block.
                        bmLog("⚠️ replace fallback: insert failed after delete — undoing delete to prevent data loss: \(error)")
                        undoManager?.undo()
                        throw error  // propagate to outer catch → clearBlockModelAndRefill
                    }
                }
            } else {
                // Empty replacement of empty range: no-op.
                return true
            }

            let opDesc: String
            if range.length == 0 && replacement == "\n" {
                opDesc = "RETURN"
            } else if range.length == 0 && !replacement.isEmpty {
                opDesc = "insert '\(replacement.prefix(20))'"
            } else if range.length > 0 && replacement.isEmpty {
                opDesc = "delete \(range.length) chars at \(range.location)"
            } else {
                opDesc = "replace \(range) with '\(replacement.prefix(20))'"
            }
            bmLog("✏️ \(opDesc): splice \(result.spliceRange) → \(result.spliceReplacement.length) chars, cursor → \(result.newCursorPosition)")

            // Determine undo action name.
            let actionName: String
            if range.length == 0 && replacement == "\n" {
                actionName = "Typing"
            } else if range.length == 0 {
                actionName = "Typing"
            } else if replacement.isEmpty {
                actionName = "Delete"
            } else {
                actionName = "Replace"
            }

            applyEditResultWithUndo(result, actionName: actionName)

            // RC4: After insertion, check if the current block's inlines
            // should be re-parsed (e.g. user just completed "[text](url)").
            // Trigger on characters that can close inline patterns. Also
            // trigger for multi-character insertions (toolbar linkMenu /
            // wikiLinks / paste) that may contain a complete pattern,
            // regardless of whether the prior selection was empty.
            if !replacement.isEmpty {
                let last = replacement.last ?? Character(" ")
                let isCloser = ")]}>`*_~".contains(last)
                let isMultiChar = replacement.count > 1
                if isCloser || isMultiChar {
                    reparseCurrentBlockInlines()
                }
            }

            // Auto-convert markdown shortcuts at line start.
            // After typing a space, check if the paragraph matches a
            // shortcut pattern (e.g., "- ", "> ", "1. ", "- [ ] ").
            if range.length == 0 && replacement == " " {
                autoConvertMarkdownShortcut()
            }

            // Schedule auto-rename + tag scan. The block-model edit path
            // bypasses shouldChangeText's source-mode branch, so we must
            // trigger the 2.5s debounced scan ourselves — otherwise the
            // note's filename never tracks its H1 title.
            if let note = self.note {
                note.isParsed = false
                scheduleTagScan(for: note)
            }

            return true

        } catch {
            bmLog("⚠️ edit failed, falling back to source-mode: \(error)")
            // The editing operation threw (unsupported block type,
            // cross-inline-range, etc.). Fall back to source-mode pipeline
            // by clearing the projection and letting the note re-render
            // via the source-mode path.
            clearBlockModelAndRefill()
            return false
        }
    }

    /// Detect when NSTextView (or an internal callback) tries to replace
    /// an attachment character with the markdown source for that same
    /// attachment. This is a spurious operation that would corrupt the
    /// block model — the attachment is already correctly represented in
    /// the Document as an .image inline.
    private func isSpuriousAttachmentReplacement(range: NSRange, replacement: String) -> Bool {
        guard let storage = textStorage,
              range.length == 1,
              range.location < storage.length else { return false }
        // Only applies to single attachment characters (￼).
        let ch = (storage.string as NSString).character(at: range.location)
        guard ch == 0xFFFC else { return false }
        // Check if the replacement is markdown image syntax.
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("![") && trimmed.contains("](")
    }

    // MARK: - Save

    /// Serialize the Document back to markdown for saving. Returns
    /// the markdown string, or nil if no projection is active (caller
    /// should use the source-mode save path).
    func serializeViaBlockModel() -> String? {
        guard let projection = documentProjection else {
            return nil
        }
        // Pure serialization: the Document is the single source of
        // truth at save time. Every mutation (typing, formatting,
        // cell edits) must have already been routed through
        // `EditingOps` primitives, which produce a new Document and
        // a new projection. If a change didn't go through that path,
        // it shouldn't survive a save.
        //
        // This used to walk live `InlineTableView` attachments and
        // rewrite `Block.table.raw` from each widget's current state.
        // That was the post-hoc save-path patch described in
        // CLAUDE.md "Rules That Exist Because I Broke Them" — it was
        // the cautionary tale for why views must never be read back
        // into data. The walk has been deleted along with the
        // `collectCellData` / `notifyChanged` / `generateMarkdown`
        // path in `InlineTableView`.
        return MarkdownSerializer.serialize(projection.document)
    }

    // MARK: - List FSM transition handling

    /// Apply a list FSM transition to the document. Returns true if the
    /// transition was applied, false if it was a no-op or unsupported.
    func handleListTransition(
        _ transition: ListEditingFSM.Transition,
        at storageIndex: Int
    ) -> Bool {
        guard let projection = documentProjection,
              textStorage != nil else { return false }

        do {
            let result: EditResult
            let actionName: String
            switch transition {
            case .indent:
                result = try EditingOps.indentListItem(at: storageIndex, in: projection)
                actionName = "Indent"
            case .unindent:
                result = try EditingOps.unindentListItem(at: storageIndex, in: projection)
                actionName = "Unindent"
            case .exitToBody:
                result = try EditingOps.exitListItem(at: storageIndex, in: projection)
                actionName = "Exit List"
            case .newItem:
                // newItem is handled by the normal Return key path
                // (splitListOnNewline), not here.
                return false
            case .noOp:
                return true // Consumed the keystroke, but no mutation.
            }

            bmLog("📋 list FSM: \(transition) → splice \(result.spliceRange) → \(result.spliceReplacement.length) chars")
            applyEditResultWithUndo(result, actionName: actionName)
            return true
        } catch {
            bmLog("⚠️ list FSM transition failed: \(error)")
            return false
        }
    }

    /// Check if a delete operation is at the home position of a list
    /// item, and if so, handle it via the FSM (unindent or exit).
    /// Returns true if handled.
    func handleDeleteAtHomeInList(
        range: NSRange,
        in projection: DocumentProjection
    ) -> Bool {
        let cursorPos = range.location + range.length
        guard ListEditingFSM.isAtHomePosition(storageIndex: cursorPos, in: projection) else {
            return false
        }
        let state = ListEditingFSM.detectState(storageIndex: cursorPos, in: projection)
        guard case .listItem = state else { return false }

        let transition = ListEditingFSM.transition(state: state, action: .deleteAtHome)
        // Use standard handler for all transitions (exitListItem now always creates a paragraph)
        return handleListTransition(transition, at: cursorPos)
    }

    /// Check if a delete operation is at the home position of a heading,
    /// and if so, convert the heading to a paragraph (removing the # markers)
    /// instead of merging with the previous block. Returns true if handled.
    func handleDeleteAtHomeInHeading(
        range: NSRange,
        in projection: DocumentProjection
    ) -> Bool {
        // Only intercept single-char backspace.
        guard range.length == 1 else { return false }

        let cursorPos = range.location + range.length
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: cursorPos) else {
            return false
        }
        // Must be at offset 0 of the heading's rendered span.
        guard offsetInBlock == 0 else { return false }

        let block = projection.document.blocks[blockIndex]
        guard case .heading = block else { return false }

        // Convert heading to paragraph via changeHeadingLevel(0).
        do {
            var result = try EditingOps.changeHeadingLevel(
                0, at: cursorPos, in: projection
            )
            // Place cursor at start of the new paragraph, not end.
            let newSpan = result.newProjection.blockSpans[blockIndex]
            result.newCursorPosition = newSpan.location
            bmLog("📝 deleteAtHome in heading: converted to paragraph")
            applyEditResultWithUndo(result, actionName: "Delete")
            return true
        } catch {
            bmLog("⚠️ deleteAtHome in heading failed: \(error)")
            return false
        }
    }

    /// RC4: Re-parse the current block's inlines if the serialized
    /// markdown would parse into a different inline tree. This detects
    /// completed inline patterns (links, images, bold, etc.) and
    /// re-renders the block with proper inline structure.
    private func reparseCurrentBlockInlines() {
        guard let projection = documentProjection else { return }
        let cursor = selectedRange().location
        guard let (blockIndex, _) = projection.blockContaining(storageIndex: cursor) else { return }

        do {
            guard let result = try EditingOps.reparseInlinesIfNeeded(
                blockIndex: blockIndex,
                in: projection
            ) else { return }

            bmLog("🔄 inline reparse triggered at block \(blockIndex)")
            applyBlockModelResult(result, actionName: "Reparse")
            // Restore cursor to its previous position.
            let newLen = textStorage?.length ?? 0
            setSelectedRange(NSRange(location: min(cursor, newLen), length: 0))
        } catch {
            bmLog("⚠️ reparseCurrentBlockInlines failed: \(error)")
        }
    }

    /// Detect and auto-convert markdown shortcut patterns typed at the
    /// start of a paragraph. Called after each space insertion.
    ///
    /// Supported patterns:
    /// - `- ` → bullet list
    /// - `* ` → bullet list
    /// - `+ ` → bullet list
    /// - `> ` → blockquote
    /// - `1. ` (or any number) → numbered list (not yet — maps to bullet for now)
    /// - `- [ ] ` or `- [x] ` → todo list
    private func autoConvertMarkdownShortcut() {
        guard let projection = documentProjection else { return }
        let cursor = selectedRange().location
        guard let (blockIndex, offsetInBlock) = projection.blockContaining(storageIndex: cursor) else { return }
        let block = projection.document.blocks[blockIndex]

        // Only convert paragraphs — don't re-convert existing lists/quotes.
        guard case .paragraph(let inline) = block else { return }

        // Get the rendered text of the paragraph.
        let span = projection.blockSpans[blockIndex]
        let rendered = (projection.attributed.string as NSString).substring(
            with: NSRange(location: span.location, length: span.length)
        )

        // Check patterns at the start of the rendered text.
        // The cursor is at `offsetInBlock` (which is right after the space).
        // We need the text from the START of the block to the cursor.
        let prefixEnd = offsetInBlock
        guard prefixEnd <= rendered.count else { return }
        let prefix = String(rendered.prefix(prefixEnd))

        do {
            if prefix == "- " || prefix == "* " || prefix == "+ " {
                // Bullet list: remove the prefix text, then convert to list.
                let contentInline = trimLeadingText(inline, count: prefixEnd)
                let item = ListItem(
                    indent: "", marker: String(prefix.first!),
                    afterMarker: " ", inline: contentInline, children: []
                )
                let newBlock = Block.list(items: [item])
                var result = try EditingOps.replaceBlock(
                    atIndex: blockIndex, with: newBlock, in: projection
                )
                let newSpan = result.newProjection.blockSpans[blockIndex]
                result.newCursorPosition = newSpan.location + 1 // after bullet glyph
                applyEditResultWithUndo(result, actionName: "List")
                bmLog("🔄 Auto-converted '\\(prefix)' to bullet list")
            } else if prefix == "> " {
                // Blockquote: remove prefix, convert.
                let contentInline = trimLeadingText(inline, count: prefixEnd)
                let line = BlockquoteLine(prefix: "> ", inline: contentInline)
                let newBlock = Block.blockquote(lines: [line])
                var result = try EditingOps.replaceBlock(
                    atIndex: blockIndex, with: newBlock, in: projection
                )
                let newSpan = result.newProjection.blockSpans[blockIndex]
                result.newCursorPosition = newSpan.location + newSpan.length
                applyEditResultWithUndo(result, actionName: "Blockquote")
                bmLog("🔄 Auto-converted '> ' to blockquote")
            } else if prefix == "- [ ] " || prefix == "- [x] " {
                // Todo list: remove prefix, convert.
                let checked = prefix == "- [x] "
                let contentInline = trimLeadingText(inline, count: prefixEnd)
                let checkbox = Checkbox(
                    text: checked ? "[x]" : "[ ]", afterText: " "
                )
                let item = ListItem(
                    indent: "", marker: "-", afterMarker: " ",
                    checkbox: checkbox, inline: contentInline, children: []
                )
                let newBlock = Block.list(items: [item])
                var result = try EditingOps.replaceBlock(
                    atIndex: blockIndex, with: newBlock, in: projection
                )
                let newSpan = result.newProjection.blockSpans[blockIndex]
                // Cursor after the checkbox glyph.
                if case .list(let items, _) = result.newProjection.document.blocks[blockIndex] {
                    let entries = EditingOps.flattenList(items)
                    if let first = entries.first {
                        result.newCursorPosition = newSpan.location + first.startOffset + first.prefixLength
                    }
                }
                applyEditResultWithUndo(result, actionName: "Todo")
                bmLog("🔄 Auto-converted todo shortcut")
            } else if let match = prefix.range(of: #"^(\d+)\. $"#, options: .regularExpression) {
                // Numbered list: e.g. "1. "
                let numberStr = String(prefix[match].dropLast(2))
                let contentInline = trimLeadingText(inline, count: prefixEnd)
                let item = ListItem(
                    indent: "", marker: "\(numberStr).",
                    afterMarker: " ", inline: contentInline, children: []
                )
                let newBlock = Block.list(items: [item])
                var result = try EditingOps.replaceBlock(
                    atIndex: blockIndex, with: newBlock, in: projection
                )
                let newSpan = result.newProjection.blockSpans[blockIndex]
                result.newCursorPosition = newSpan.location + 1
                applyEditResultWithUndo(result, actionName: "Numbered List")
                bmLog("🔄 Auto-converted '\\(prefix)' to numbered list")
            }
        } catch {
            bmLog("⚠️ autoConvertMarkdownShortcut failed: \(error)")
        }
    }

    /// Remove the first `count` characters from an inline array.
    /// Returns the remaining inlines with text trimmed.
    private func trimLeadingText(_ inlines: [Inline], count: Int) -> [Inline] {
        guard count > 0 else { return inlines }
        let (_, after) = EditingOps.splitInlines(inlines, at: count)
        return after
    }

    /// Sync `typingAttributes` to the rendered attributes of the block
    /// at the current cursor position. Called after every block-model
    /// edit to ensure NSTextView doesn't inherit stale attributes from
    /// the character before the cursor (which may belong to a different
    /// block type after a split, merge, or conversion).
    private func syncTypingAttributesToCursorBlock() {
        guard let storage = textStorage,
              let projection = documentProjection else { return }

        let cursor = selectedRange().location

        // If there are pending inline traits (user toggled bold/italic
        // before typing), those take precedence over block attributes.
        if !pendingInlineTraits.isEmpty { return }

        // Empty-block special case: when the cursor sits in a block
        // that rendered to a zero-length span (e.g. the empty paragraph
        // produced by exitListItem on an empty list item), there are NO
        // characters in storage carrying that block's paragraph style.
        // Reading from `cursor - 1` would pick up the preceding
        // separator's attributes, which still carry the OLD block's
        // paragraph style (in the list-exit case, the list's hanging
        // indent). That's why the cursor visually stays indented until
        // the user types a character.
        //
        // Synthesize the typing attributes from the block type directly
        // using DocumentRenderer.paragraphStyle, matching what the
        // renderer would apply if the block had content.
        // `blockContaining` returns the earlier block at boundary positions,
        // so a zero-length block that SITS at the cursor is only found when
        // the cursor location equals that block's location AND no preceding
        // block's upper bound equals the same position. We therefore also
        // look forward: if cursor sits at the end of block[i], check whether
        // block[i+1] is zero-length (a freshly-created empty paragraph).
        var emptyBlockIdx: Int? = nil
        if let (idx, offset) = projection.blockContaining(storageIndex: cursor) {
            let span = projection.blockSpans[idx]
            if span.length == 0 {
                emptyBlockIdx = idx
            } else if offset == span.length,
                      idx + 1 < projection.blockSpans.count,
                      projection.blockSpans[idx + 1].length == 0 {
                emptyBlockIdx = idx + 1
            }
        }
        if let blockIndex = emptyBlockIdx {
            let block = projection.document.blocks[blockIndex]
            let bodyFont = projection.bodyFont
            let paraStyle = DocumentRenderer.paragraphStyle(
                for: block,
                isFirst: blockIndex == 0,
                baseSize: bodyFont.pointSize,
                lineSpacing: CGFloat(UserDefaultsManagement.editorLineSpacing)
            )
            var attrs: [NSAttributedString.Key: Any] = [
                .font: bodyFont,
                .paragraphStyle: paraStyle
            ]
            // Preserve the current foreground color if the view has one
            // (respects dark-mode / user customization) — read from
            // existing typingAttributes rather than surrounding storage
            // to avoid picking up the preceding block's attributes.
            if let fg = typingAttributes[.foregroundColor] {
                attrs[.foregroundColor] = fg
            }
            typingAttributes = attrs
            bmLog("🎯 syncTypingAttributes: empty block \(blockIndex) (\(block)) — synthesized paragraphStyle")
            return
        }

        // Read attributes from the rendered output at the cursor position.
        // For cursor mid-block, read at cursor-1 to get the attributes of
        // the preceding character (which is what the user sees at the cursor).
        let readIndex: Int
        if cursor > 0 && cursor <= storage.length {
            // Check if cursor is at the start of a block — if so, read
            // from the block's rendered attributes, not the separator before.
            if let (_, offset) = projection.blockContaining(storageIndex: cursor), offset == 0 {
                // Cursor is at block start. Read from this position if possible.
                readIndex = min(cursor, storage.length - 1)
            } else {
                readIndex = cursor - 1
            }
        } else if storage.length > 0 {
            readIndex = 0
        } else {
            return
        }

        guard readIndex >= 0 && readIndex < storage.length else { return }

        var attrs = storage.attributes(at: readIndex, effectiveRange: nil)

        // Never inherit attachment attributes into typing.
        attrs.removeValue(forKey: .attachment)

        // Preserve the paragraph style from the rendered block.
        // This ensures cursor height, indent, and spacing match.
        typingAttributes = attrs
    }

    /// Update `typingAttributes` to reflect the pending inline traits.
    /// This ensures the toolbar shows the correct formatting state and
    /// the user gets visual feedback that bold/italic/etc is active.
    private func updateTypingAttributesForPendingTraits() {
        var attrs = typingAttributes
        let traits = pendingInlineTraits
        let baseFont = (attrs[.font] as? NSFont) ?? UserDefaultsManagement.noteFont

        // Sync font traits to the pending set: ADD any present in
        // `traits`, REMOVE any not present. The previous version only
        // added — so toggling bold OFF after typing bold text left the
        // current font already-bold and the cursor stayed bold for the
        // next keystroke (bug 26: "CMD+B stuck on").
        var descriptor = baseFont.fontDescriptor
        var symbolicTraits = descriptor.symbolicTraits

        if traits.contains(.bold) {
            symbolicTraits.insert(.bold)
        } else {
            symbolicTraits.remove(.bold)
        }
        if traits.contains(.italic) {
            symbolicTraits.insert(.italic)
        } else {
            symbolicTraits.remove(.italic)
        }

        descriptor = descriptor.withSymbolicTraits(symbolicTraits)
        attrs[.font] = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont

        if traits.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        } else {
            attrs.removeValue(forKey: .strikethroughStyle)
        }

        if traits.contains(.underline) {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            attrs.removeValue(forKey: .underlineStyle)
        }

        if traits.contains(.highlight) {
            attrs[.backgroundColor] = NSColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 0.5)
        } else {
            attrs.removeValue(forKey: .backgroundColor)
        }

        if traits.contains(.code) {
            let size = baseFont.pointSize
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        typingAttributes = attrs
    }

    // MARK: - Block-model formatting operations

    /// Apply an EditResult splice to textStorage and update the
    /// projection. Shared by all block-model formatting operations.
    /// The actionName parameter is used for undo menu labeling.
    func applyBlockModelResult(_ result: EditResult, actionName: String = "Format") {
        guard textStorage != nil, documentProjection != nil else { return }
        applyEditResultWithUndo(result, actionName: actionName)
    }

    // MARK: - Table cell editing

    // NOTE: the former `pushTableBlockToProjection(from: InlineTableView, ...)`,
    // `blockIndex(for: InlineTableView)`, and widget-specific
    // `applyTableCellInlineEdit(from:at:inline:)` entry points were
    // deleted in Phase 2e-T2-h along with the `InlineTableView` widget
    // itself. Native-element cell edits flow through
    // `handleTableCellEdit(range:replacement:)` below, which uses the
    // TK2 layout-manager lookup to resolve the table's block index.
    // Structural mutations (add/remove row / column, alignment change)
    // flow through the `EditingOps.insertTableRow/Column` /
    // `deleteTableRow/Column` / `setTableColumnAlignment` primitives
    // invoked by `TableHandleOverlay`.

    // MARK: - Phase 2e-T2-e: TableElement cell text editing

    /// Handle an insertion / deletion / replacement inside a
    /// `TableElement`'s separator-encoded storage. Returns `true` when
    /// the edit was routed through `EditingOps.replaceTableCellInline`
    /// (caller must not proceed with the generic path); `false` when
    /// the edit can't be expressed as a single-cell mutation and the
    /// caller should fall through.
    ///
    /// Semantics per input:
    ///   * Pure insert of a non-Return, non-newline string → splice the
    ///     characters into the cell's inline tree at the cell-local
    ///     offset corresponding to `range.location`.
    ///   * Pure insert of `"\n"` → treated as the Return key: insert
    ///     `.rawHTML("<br>")` at the cell-local offset. This is the
    ///     convention `InlineRenderer.inlineTreeFromAttributedString`
    ///     uses when decoding a line break in a cell's attributed
    ///     string, and matches the widget path (InlineTableView) which
    ///     stores cell line breaks as `<br>`.
    ///   * Pure deletion (replacement empty) at cell-start (offset 0 of
    ///     cell content) → no-op (documented decision: backspace at
    ///     start of a cell does NOT merge with the previous cell. The
    ///     widget's behaviour is the same — backspace in an empty
    ///     field is a no-op).
    ///   * Pure deletion anywhere else inside the cell → delete the
    ///     characters from the cell's inline tree.
    ///   * Replacement (range.length > 0 and replacement non-empty) →
    ///     delete then insert inside the cell, as a single operation.
    ///
    /// Edge cases that return `false` (caller falls through):
    ///   * Range crosses a cell boundary (a separator is inside the
    ///     range) — the cell primitive can't express this; fall through
    ///     to the generic path, which will no-op or refuse.
    ///   * Cursor sits on a separator itself (between cells) — no cell
    ///     context resolvable; the range is either outside any cell or
    ///     spans two cells.
    private func handleTableCellEdit(
        range: NSRange,
        replacement: String
    ) -> Bool {
        // Resolve the cell context for the edit's start offset. If the
        // offset lies on a separator, try `offset - 1` as well — a
        // cursor at the END of a cell's content sits exactly on the
        // next separator, which the locator (intentionally) rejects
        // as "not inside a cell". For editing purposes, end-of-cell
        // IS inside the preceding cell (that's where the character
        // insert should land). This normalization is the only place
        // in the code base that makes that decision; the nav layer
        // continues to see end-of-cell as a separator offset because
        // nav has no "which side of the separator" question.
        //
        // When we fall back to (offset - 1), we keep the ORIGINAL edit
        // offset (not the probe offset) in the context — the cell row/
        // col comes from the probe but the cell-local clamp is
        // applied below against the cell's actual range.
        var ctx = tableCursorContextForOffset(range.location)
        if ctx == nil, range.location > 0 {
            ctx = tableCursorContextForOffset(range.location - 1)
        }
        guard let ctx = ctx else {
            return false
        }

        // Determine the cell's element-local range, so we can clamp the
        // incoming edit to cell bounds.
        guard let cellLocalRange = ctx.element.cellRange(
            forCellAt: (row: ctx.row, col: ctx.col)
        ) else {
            return false
        }

        // Translate the edit's range from storage coordinates to
        // cell-local coordinates.
        let cellStorageStart = ctx.elementStorageStart + cellLocalRange.location
        let cellStorageEnd = cellStorageStart + cellLocalRange.length
        let editEnd = range.location + range.length

        // Refuse edits that escape the cell — they'd need to touch a
        // separator (cross-cell) or fall outside the table entirely.
        // Fall through so the generic path can decide what to do.
        if range.location < cellStorageStart || editEnd > cellStorageEnd {
            bmLog("⛔ handleTableCellEdit: edit range \(range) escapes cell [\(cellStorageStart)..\(cellStorageEnd)] — fall through")
            return false
        }

        // Backspace at cell-start: no-op. Documented choice — cells are
        // first-class content, deleting at their start does NOT merge
        // into the previous cell (that would lose the structural cell
        // boundary). Mirrors the widget path.
        //
        // The two dead branches that used to live here (empty-range-at-
        // cell-start; length-1-delete-at-cell-start) have been removed.
        // Both are unreachable given the earlier `range.location <
        // cellStorageStart` guard. If the upstream shape of `range`
        // ever changes and this code gets wired up again as reachable,
        // `assertionFailure` in a debug build will catch it loudly.
        assert(
            !(replacement.isEmpty && range.length > 0 &&
              range.location == cellStorageStart && editEnd == cellStorageStart),
            "cell-start empty-replacement with length > 0 — unreachable given the escape-cell guards above; audit the precondition"
        )
        // Backspace that deletes a character strictly inside the cell:
        // allow through. Backspace at cell-start is represented by
        // range.location == cellStorageStart - 1 with length 1, which
        // is already rejected by the escape-cell check above, so we
        // never get here for that case. Delete-forward at cell-end is
        // represented by range.location == cellStorageEnd with length
        // 1 — also already rejected. Both are correctly no-ops.

        // Get the cell's current attributed substring from the element.
        guard let storage = textStorage else { return false }
        let cellRange = NSRange(
            location: cellStorageStart, length: cellLocalRange.length
        )
        let currentAttr = storage.attributedSubstring(from: cellRange)

        // Build the new cell attributed string by applying the edit in
        // cell-local coordinates.
        let mutable = NSMutableAttributedString(
            attributedString: currentAttr
        )
        let localEditRange = NSRange(
            location: range.location - cellStorageStart,
            length: range.length
        )
        // Materialize the replacement string. For a Return keystroke,
        // the replacement is "\n" and we want to land a <br> into the
        // inline tree. We build the replacement as an attributed
        // string here using the cell's base attributes so the inline
        // converter sees a proper attribute run (no font drift).
        let newText: String
        if replacement == "\n" {
            // Store as `\n` in the attributed string — the inline
            // converter translates `\n` → `.rawHTML("<br>")` inside a
            // cell segment (see `InlineRenderer.inlineTreeFromAttributedString`).
            newText = "\n"
        } else {
            newText = replacement
        }
        // Pick attributes for the replacement from the base body font;
        // prefer the existing cell's attributes at the edit location
        // when possible so inline traits (bold/italic) carry across a
        // single-character insert inside a styled run.
        let replacementAttrs: [NSAttributedString.Key: Any]
        if currentAttr.length > 0 {
            let probeLoc = min(
                max(0, localEditRange.location - (localEditRange.location == currentAttr.length ? 1 : 0)),
                currentAttr.length - 1
            )
            replacementAttrs = currentAttr.attributes(at: probeLoc, effectiveRange: nil)
        } else {
            replacementAttrs = [
                .font: UserDefaultsManagement.noteFont
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        }
        let replacementAttr = NSAttributedString(
            string: newText, attributes: replacementAttrs
        )
        mutable.replaceCharacters(in: localEditRange, with: replacementAttr)

        // Decode the new cell content into an inline tree. This is the
        // same converter paragraphs use — the cell stays "a paragraph
        // inside a cell."
        let newInline = InlineRenderer.inlineTreeFromAttributedString(mutable)

        // Locate the table block by inspecting the projection span for
        // the element's storage start.
        guard let projection = documentProjection else { return false }
        guard let (blockIdx, _) = projection.blockContaining(
            storageIndex: ctx.elementStorageStart
        ) else {
            bmLog("⛔ handleTableCellEdit: projection has no block at offset \(ctx.elementStorageStart)")
            return false
        }
        guard case .table(let header, _, _, _) =
                projection.document.blocks[blockIdx] else {
            bmLog("⛔ handleTableCellEdit: block \(blockIdx) is not a table")
            return false
        }

        // Encode (row, col) to the primitive's TableCellLocation.
        // row 0 = header; row 1..N map to body rows 0..N-1.
        let cellLocation: EditingOps.TableCellLocation
        if ctx.row == 0 {
            cellLocation = .header(col: ctx.col)
        } else {
            cellLocation = .body(row: ctx.row - 1, col: ctx.col)
        }

        // Compute the cell's local offset within the NEW cell content
        // for cursor landing. For an insert at localEditRange.location,
        // the cursor lands at localEditRange.location + newText.utf16.count.
        // For a delete, it lands at localEditRange.location.
        let newCellLocalOffset = localEditRange.location + (newText as NSString).length

        // Run the pure primitive.
        let result: EditResult
        do {
            var tmp = try EditingOps.replaceTableCellInline(
                blockIndex: blockIdx,
                at: cellLocation,
                inline: newInline,
                in: projection
            )
            // The primitive leaves `newCursorPosition = 0` — it has no
            // way to know where the caret should land inside the new
            // storage. Compute it here: start of new table block span
            // + cell's new local offset + the cursor offset within the
            // new cell content.
            let newBlockSpan = tmp.newProjection.blockSpans[blockIdx]
            // Find the new cell's element-local start within the
            // re-rendered table. Build a throwaway TableElement from
            // the new block's rendered substring to reuse the locator.
            let newTableAttr = tmp.newProjection.attributed.attributedSubstring(
                from: newBlockSpan
            )
            var cellStartInNewElement: Int = 0
            if case .table = tmp.newProjection.document.blocks[blockIdx],
               let probe = TableElement(
                block: tmp.newProjection.document.blocks[blockIdx],
                attributedString: newTableAttr
               ),
               let s = probe.offset(forCellAt: (row: ctx.row, col: ctx.col)) {
                cellStartInNewElement = s
            }
            // Clamp the cursor to the cell's new length — the new cell
            // may have more or fewer characters than the requested
            // offset. `<br>` encodes as a single `\n` UTF-16 unit in
            // the attributed-string form (see
            // `InlineRenderer.isBrTag`), which matches the `+1`
            // advance computed for a Return keystroke.
            let newCellLen: Int
            if case .table = tmp.newProjection.document.blocks[blockIdx],
               let probe = TableElement(
                block: tmp.newProjection.document.blocks[blockIdx],
                attributedString: newTableAttr
               ),
               let r = probe.cellRange(forCellAt: (row: ctx.row, col: ctx.col)) {
                newCellLen = r.length
            } else {
                newCellLen = 0
            }
            let clampedCellOffset = min(newCellLocalOffset, newCellLen)
            let storageCursor = newBlockSpan.location + cellStartInNewElement + clampedCellOffset
            tmp.newCursorPosition = storageCursor
            result = tmp
        } catch {
            bmLog("⚠️ handleTableCellEdit: replaceTableCellInline threw \(error)")
            // Fall through — let the generic path decide (likely no-op).
            return false
        }

        applyEditResultWithUndo(result, actionName: replacement == "\n" ? "Insert Line Break" : "Typing")
        return true
    }

    /// Like `tableCursorContext()` but resolves at an arbitrary storage
    /// offset, not the current selection. Needed because the edit
    /// range's start offset is not necessarily the selection's location
    /// — e.g. a paste or a range-replace can target a different offset.
    private func tableCursorContextForOffset(
        _ storageOffset: Int
    ) -> TableCursorContext? {
        guard let tlm = self.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage
        else { return nil }
        guard storageOffset >= 0,
              storageOffset <= (textStorage?.length ?? 0)
        else { return nil }

        let docStart = contentStorage.documentRange.location
        guard let loc = contentStorage.location(
            docStart, offsetBy: storageOffset
        ) else { return nil }
        guard let fragment = tlm.textLayoutFragment(for: loc),
              let element = fragment.textElement as? TableElement,
              let elementRange = element.elementRange
        else { return nil }

        let elementStart = contentStorage.offset(
            from: docStart, to: elementRange.location
        )
        let localOffset = storageOffset - elementStart
        guard let (row, col) = element.cellLocation(forOffset: localOffset)
        else { return nil }

        return TableCursorContext(
            element: element,
            elementStorageStart: elementStart,
            localOffset: localOffset,
            row: row,
            col: col
        )
    }


    /// Insert an image (or PDF) attachment block at the current cursor
    /// position via the block model. Returns true if the block-model
    /// path handled it, false if the caller should fall back.
    ///
    /// The image is added as a new paragraph block immediately AFTER
    /// the block containing the cursor. The new cursor position lands
    /// at the end of the image block. After the splice is applied,
    /// `ImageAttachmentHydrator` is invoked so the placeholder
    /// attachment picks up its real image bytes asynchronously.
    ///
    /// - Parameters:
    ///   - alt: alt text for the image.
    ///   - destination: relative path stored in the markdown destination.
    @discardableResult
    func insertImageViaBlockModel(alt: String, destination: String) -> Bool {
        guard let projection = documentProjection else { return false }
        let cursor = selectedRange().location
        do {
            let result = try EditingOps.insertImage(
                alt: alt,
                destination: destination,
                at: cursor,
                in: projection
            )
            bmLog("🖼️ insertImage: dest='\(destination)' splice \(result.spliceRange) → \(result.spliceReplacement.length) chars")
            applyEditResultWithUndo(result, actionName: "Insert Image")
            // Kick off async hydration of the placeholder attachment.
            // Post-processors replace the placeholder attachment with
            // the appropriate viewer for the file type:
            // - PDFAttachmentProcessor → inline PDFKit viewer
            // - ImageAttachmentHydrator → loads real image bytes
            // - QuickLookAttachmentProcessor → QLPreviewView for other files
            if let storage = textStorage {
                let containerWidth = self.textContainer?.size.width ?? self.frame.width
                if let note = self.note {
                    PDFAttachmentProcessor.renderPDFAttachments(
                        in: storage, note: note, containerWidth: containerWidth
                    )
                }
                ImageAttachmentHydrator.hydrate(textStorage: storage, editor: self)
                QuickLookAttachmentProcessor.renderQuickLookAttachments(
                    in: storage, containerWidth: containerWidth
                )
            }
            return true
        } catch {
            bmLog("⚠️ insertImage failed: \(error)")
            return false
        }
    }

    /// Toggle bold on the current selection via the block model.
    /// Returns true if handled, false if block model is not active.
    func toggleBoldViaBlockModel() -> Bool {
        return toggleInlineTraitViaBlockModel(.bold)
    }

    /// Toggle italic on the current selection via the block model.
    func toggleItalicViaBlockModel() -> Bool {
        return toggleInlineTraitViaBlockModel(.italic)
    }

    /// Toggle inline code on the current selection via the block model.
    func toggleCodeViaBlockModel() -> Bool {
        return toggleInlineTraitViaBlockModel(.code)
    }

    /// Toggle strikethrough on the current selection via the block model.
    func toggleStrikethroughViaBlockModel() -> Bool {
        return toggleInlineTraitViaBlockModel(.strikethrough)
    }

    /// Toggle underline on the current selection via the block model.
    func toggleUnderlineViaBlockModel() -> Bool {
        return toggleInlineTraitViaBlockModel(.underline)
    }

    /// Toggle highlight on the current selection via the block model.
    func toggleHighlightViaBlockModel() -> Bool {
        return toggleInlineTraitViaBlockModel(.highlight)
    }

    private func toggleInlineTraitViaBlockModel(_ trait: EditingOps.InlineTrait) -> Bool {
        guard let _ = documentProjection else { return false }
        let sel = selectedRange()

        if sel.length == 0 {
            // Empty selection: toggle pending trait for next typed characters.
            var traits = pendingInlineTraits
            var offTraits = explicitlyOffTraits
            if traits.contains(trait) {
                // Trait was pending → user wants to turn it off. Move it
                // from `pending` to `explicitlyOff` so the next insert
                // routes through `insertWithTraits([], ...)` (which uses
                // splitInlines and produces a sibling node) instead of
                // the default `insert` path that would extend the
                // surrounding bold span.
                traits.remove(trait)
                offTraits.insert(trait)
            } else {
                traits.insert(trait)
                offTraits.remove(trait)
            }
            pendingInlineTraits = traits
            explicitlyOffTraits = offTraits
            bmLog("🎨 pendingInlineTraits toggled \(trait): pending=\(traits) off=\(offTraits)")
            // Update typing attributes to reflect the pending trait visually.
            updateTypingAttributesForPendingTraits()
            // Refresh the toolbar so the button visually toggles too —
            // the toolbar reads `typingAttributes` and only updates on
            // selection change, but this path doesn't move the cursor.
            if let vc = window?.windowController?.contentViewController as? ViewController {
                vc.formattingToolbar?.updateButtonStates(for: self)
            }
            return true
        }

        guard let projection = documentProjection else { return false }
        do {
            let result = try EditingOps.toggleInlineTrait(
                trait, range: sel, in: projection
            )
            bmLog("🔤 toggleInlineTrait(\(trait)): splice \(result.spliceRange) → \(result.spliceReplacement.length) chars")
            let name: String
            switch trait {
            case .bold: name = "Bold"
            case .italic: name = "Italic"
            case .code: name = "Code"
            case .strikethrough: name = "Strikethrough"
            case .underline: name = "Underline"
            case .highlight: name = "Highlight"
            }
            applyBlockModelResult(result, actionName: name)
            return true
        } catch {
            bmLog("⚠️ toggleInlineTrait failed: \(error)")
            return false
        }
    }

    /// Change heading level via the block model.
    /// When multiple blocks are selected, applies to each non-blank block.
    /// Returns true if handled.
    func changeHeadingLevelViaBlockModel(_ level: Int) -> Bool {
        return applyToggleAcrossSelection(actionName: "Heading") { proj, loc in
            try EditingOps.changeHeadingLevel(level, at: loc, in: proj)
        }
    }

    /// Apply a single-block toggle across every block overlapping the
    /// current selection. Blank line blocks are skipped — converting
    /// them to a list item would produce stray empty `<li>` entries and
    /// visually "broken" multi-list output. Runs in reverse order so
    /// earlier splices don't shift later block indices; re-resolves
    /// storage-relative block locations against each updated projection.
    ///
    /// `action` maps a (projection, storageIndex) pair to an `EditResult`
    /// — this keeps the per-primitive differences (`EditingOps.toggleList`
    /// vs `toggleBlockquote` vs `toggleTodoList`) contained to their one
    /// call site, while the iteration scaffolding is shared.
    private func applyToggleAcrossSelection(
        actionName: String,
        action: (DocumentProjection, Int) throws -> EditResult
    ) -> Bool {
        guard var projection = documentProjection else { return false }
        let sel = selectedRange()

        do {
            // Filter blankLine blocks out — but only when there's at
            // least one non-blank block in the selection. When the
            // cursor is on a solitary blank paragraph (common: user
            // presses Return twice then Cmd+T for a new todo), we still
            // want to transform that block, otherwise the caller falls
            // through to source-mode `formatter.todo()` which inserts
            // literal `- [ ]` text into the block-model storage.
            let overlapping = projection.blockIndices(overlapping: sel)
            let nonBlank = overlapping.filter { idx in
                if case .blankLine = projection.document.blocks[idx] { return false }
                return true
            }
            let indices = nonBlank.isEmpty ? overlapping : nonBlank
            guard !indices.isEmpty else { return false }

            for blockIdx in indices.reversed() {
                let span = projection.blockSpans[blockIdx]
                let result = try action(projection, span.location)
                applyEditResultWithUndo(result, actionName: actionName)
                projection = result.newProjection
                documentProjection = projection
            }
            return true
        } catch {
            bmLog("⚠️ \(actionName) failed: \(error)")
            return false
        }
    }

    /// Toggle list via the block model.
    ///
    /// Three dispatch paths, tried in order:
    ///  1. Selection spans ≥2 blocks of paragraphs/blank lines →
    ///     `wrapSelectionInSingleList` collapses them into one list.
    ///  2. Selection spans ≥2 items within a single existing list
    ///     block → `EditingOps.toggleListRange` unwraps ALL touched
    ///     items to paragraphs (bug #59: previously only the first
    ///     item was unwrapped because a whole list is a single block,
    ///     so `applyToggleAcrossSelection` iterated once and ran the
    ///     single-item primitive at the head of the selection).
    ///  3. Otherwise (cursor in a paragraph, or cursor in one list
    ///     item) → `applyToggleAcrossSelection` runs the single-item
    ///     `EditingOps.toggleList` primitive per overlapped block.
    func toggleListViaBlockModel(marker: String = "-") -> Bool {
        if wrapSelectionInSingleList(marker: marker, checkbox: nil) {
            return true
        }
        if unwrapListRangeIfNeeded(marker: marker) {
            return true
        }
        return applyToggleAcrossSelection(actionName: "List") { proj, loc in
            try EditingOps.toggleList(marker: marker, at: loc, in: proj)
        }
    }

    /// Multi-item list-unwrap path (bug #59). Returns true when the
    /// selection spans 2+ items within a single existing list block and
    /// the pure primitive succeeded in converting them all to
    /// paragraphs. Returns false for every other shape — including a
    /// cursor inside a single item — so the caller falls back to the
    /// single-item `toggleList` primitive for those cases.
    private func unwrapListRangeIfNeeded(marker: String) -> Bool {
        guard let projection = documentProjection else { return false }
        let sel = selectedRange()
        do {
            guard let result = try EditingOps.toggleListRange(
                selection: sel, in: projection
            ) else {
                return false
            }
            applyBlockModelResult(result, actionName: "List")
            return true
        } catch {
            bmLog("⚠️ toggleListRange failed: \(error)")
            return false
        }
    }

    /// Wrap all non-blank blocks overlapping the current selection into
    /// a single `.list` block (optionally with checkbox prefix). Returns
    /// true when the wrap was applied; false means the caller should
    /// fall through to per-block toggling (e.g. single-block toggles
    /// still handle their unwrap-list-to-paragraphs case).
    private func wrapSelectionInSingleList(marker: String, checkbox: Checkbox?) -> Bool {
        guard let projection = documentProjection else { return false }
        let sel = selectedRange()
        let overlapping = projection.blockIndices(overlapping: sel)
        guard overlapping.count >= 2 else { return false }

        // Only handle conversion TO a list: all overlapped blocks must
        // be paragraphs or blank lines. If any block is already a list
        // (or quote/heading/code), fall back to per-block toggling so
        // the user can still unwrap one list inside a mixed selection.
        var items: [ListItem] = []
        for idx in overlapping {
            let block = projection.document.blocks[idx]
            switch block {
            case .paragraph(let inline):
                items.append(ListItem(
                    indent: "", marker: marker, afterMarker: " ",
                    checkbox: checkbox, inline: inline, children: []
                ))
            case .blankLine:
                continue
            default:
                return false
            }
        }
        guard !items.isEmpty, let firstIdx = overlapping.first,
              let lastIdx = overlapping.last else {
            return false
        }

        do {
            var result = try EditingOps.replaceBlockRange(
                firstIdx...lastIdx,
                with: [.list(items: items)],
                in: projection
            )
            let newListSpan = result.newProjection.blockSpans[firstIdx]
            result.newCursorPosition = newListSpan.location + 1
            applyBlockModelResult(result, actionName: "List")
            return true
        } catch {
            bmLog("⚠️ wrapSelectionInSingleList failed: \(error)")
            return false
        }
    }

    /// Toggle blockquote via the block model.
    /// When multiple blocks are selected, converts each.
    func toggleBlockquoteViaBlockModel() -> Bool {
        return applyToggleAcrossSelection(actionName: "Blockquote") { proj, loc in
            try EditingOps.toggleBlockquote(at: loc, in: proj)
        }
    }

    /// Insert horizontal rule via the block model.
    func insertHorizontalRuleViaBlockModel() -> Bool {
        guard let projection = documentProjection else { return false }
        let cursorPos = selectedRange().location

        do {
            let result = try EditingOps.insertHorizontalRule(
                at: cursorPos, in: projection
            )
            // Bug #38 diagnostic: log splice replacement bytes (hex) so we can
            // detect any hidden characters between blocks, and log the resulting
            // cursor position + typing attributes after splice settles.
            let replStr = result.spliceReplacement.string
            let hex = replStr.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            bmLog("➖ insertHR diag: cursor=\(cursorPos), splice=\(result.spliceRange) → \(replStr.count) chars [\(hex)], newCursor=\(result.newCursorPosition)")
            applyBlockModelResult(result, actionName: "Horizontal Rule")
            // Inspect storage around the landed cursor.
            if let storage = textStorage {
                let landed = result.newCursorPosition
                let s = storage.string as NSString
                let lo = max(0, landed - 4)
                let hi = min(s.length, landed + 4)
                var ctxHex = ""
                for i in lo..<hi {
                    let ch = s.character(at: i)
                    let marker = (i == landed) ? "▶" : ""
                    ctxHex += "\(marker)U+\(String(format: "%04X", ch)) "
                }
                bmLog("➖ insertHR diag (post): storage[\(lo)..<\(hi)] = \(ctxHex.trimmingCharacters(in: .whitespaces))")
                // Log paragraph style at landed cursor
                if landed < storage.length {
                    let attrs = storage.attributes(at: landed, effectiveRange: nil)
                    if let pStyle = attrs[.paragraphStyle] as? NSParagraphStyle {
                        bmLog("➖ insertHR diag (post): paragraphStyle.firstLineHeadIndent=\(pStyle.firstLineHeadIndent), headIndent=\(pStyle.headIndent)")
                    } else {
                        bmLog("➖ insertHR diag (post): no paragraphStyle at landed cursor")
                    }
                }
                // Log typing attributes after sync
                if let tStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle {
                    bmLog("➖ insertHR diag (post): typingAttrs.firstLineHeadIndent=\(tStyle.firstLineHeadIndent), headIndent=\(tStyle.headIndent)")
                } else {
                    bmLog("➖ insertHR diag (post): no paragraphStyle in typingAttributes")
                }
            }
            return true
        } catch {
            bmLog("⚠️ insertHorizontalRule failed: \(error)")
            return false
        }
    }

    /// Toggle todo list via the block model.
    /// Multi-block selections collapse into a single todo list with one
    /// checkbox item per non-blank block (see `wrapSelectionInSingleList`).
    func toggleTodoViaBlockModel() -> Bool {
        let checkbox = Checkbox(text: "[ ]", afterText: " ")
        guard let proj = documentProjection else {
            bmLog("☑ toggleTodoViaBlockModel: documentProjection==nil, bailing")
            return false
        }
        let sel = selectedRange()
        let overlapping = proj.blockIndices(overlapping: sel)
        let types = overlapping.map { idx -> String in
            switch proj.document.blocks[idx] {
            case .paragraph: return "paragraph"
            case .blankLine: return "blankLine"
            case .list: return "list"
            case .heading: return "heading"
            case .blockquote: return "blockquote"
            case .codeBlock: return "code"
            case .horizontalRule: return "hr"
            case .table: return "table"
            case .htmlBlock: return "html"
            }
        }
        bmLog("☑ toggleTodoViaBlockModel: sel=\(sel) overlapping=\(overlapping) types=\(types)")
        if wrapSelectionInSingleList(marker: "-", checkbox: checkbox) {
            bmLog("☑ toggleTodoViaBlockModel: wrapSelectionInSingleList SUCCEEDED")
            return true
        }
        bmLog("☑ toggleTodoViaBlockModel: wrapSelectionInSingleList returned false, trying applyToggleAcrossSelection")
        let result = applyToggleAcrossSelection(actionName: "Todo List") { proj, loc in
            try EditingOps.toggleTodoList(at: loc, in: proj)
        }
        bmLog("☑ toggleTodoViaBlockModel: applyToggleAcrossSelection returned \(result)")
        return result
    }

    /// Toggle a specific todo checkbox (checked ↔ unchecked) via the block model.
    func toggleTodoCheckboxViaBlockModel(at location: Int? = nil) -> Bool {
        guard let projection = documentProjection else { return false }
        let pos = location ?? selectedRange().location

        do {
            let result = try EditingOps.toggleTodoCheckbox(
                at: pos, in: projection
            )
            bmLog("☑ toggleTodoCheckbox: splice \(result.spliceRange)")
            applyBlockModelResult(result, actionName: "Toggle Checkbox")
            return true
        } catch {
            bmLog("⚠️ toggleTodoCheckbox failed: \(error)")
            return false
        }
    }

    // MARK: - Fallback

    /// Clear the block-model projection and re-fill the note via the
    /// source-mode pipeline. Used when the block-model pipeline encounters
    /// an unsupported operation.
    func clearBlockModelAndRefill() {
        // Instead of dropping to source-mode (which shows raw markdown),
        // re-parse and re-render via the block model. This keeps the
        // WYSIWYG invariant: textStorage never contains raw markdown.
        guard let note = self.note else { return }

        // Serialize the current document to markdown first (preserving edits),
        // then re-parse and re-render.
        if let projection = documentProjection {
            let markdown = MarkdownSerializer.serialize(projection.document)
            // Update note's content with the serialized markdown
            note.content = NSMutableAttributedString(string: markdown)
            note.cachedDocument = nil
        }
        documentProjection = nil

        // Re-fill via block model
        fill(note: note)
    }

    // MARK: - Math rendering for block model
    //
    // Phase 2d: block-level mermaid and block-level math code blocks
    // (```mermaid / ```math / ```latex) are no longer replaced with
    // NSTextAttachment here. Their paragraph ranges are tagged with
    // `.blockModelKind = "mermaid" / "math"` by DocumentRenderer, and
    // the content-storage delegate hands the range to MermaidElement
    // / MathElement → MermaidLayoutFragment / MathLayoutFragment,
    // which call BlockRenderer internally and draw the image over the
    // (still-searchable) source text. No character-stream splice
    // happens for mermaid / math code blocks under TK2.
    //
    // Inline math ($...$) and display math ($$...$$) remain on the
    // attachment path for now — they live at a different layer
    // (inline-within-paragraph and a separate document shape) and
    // are not in 2d's non-table-block-level scope. They will migrate
    // in a follow-up slice.

    /// Render inline/display math via the block-model pipeline.
    /// Called during fill when block-model is active.
    func renderSpecialBlocksViaBlockModel() {
        // --- Inline math ($...$): render inline with text ---
        renderInlineMathViaBlockModel()

        // --- Display math ($$...$$) ---
        // Single-inline paragraphs (the whole paragraph is one `$$…$$`)
        // are tagged `.blockModelKind = "displayMath"` by DocumentRenderer
        // and render via `DisplayMathLayoutFragment` — no storage swap.
        //
        // Mixed-content paragraphs (e.g. "See $$\sum x$$ below") fall
        // through to `.blockModelKind = "paragraph"` and render via the
        // inline-attachment path below, because a custom paragraph
        // fragment embedding display math mid-paragraph would cross-cut
        // the block/inline boundary. The attachment spans the container
        // width and centers the bitmap, visually breaking the paragraph
        // at the equation — matching the conventional LaTeX layout for
        // inline `$$…$$`.
        //
        // The hydrator skips single-inline ranges (detected via the
        // paragraph's `.blockModelKind` attribute) so the two paths
        // don't collide on the same storage range.
        renderDisplayMathViaBlockModel()
    }

    /// Compute the range of characters whose paragraphStyle attribute
    /// may need resyncing after a splice. This is the union of the
    /// block spans overlapping `spliceRange` (in post-splice coords),
    /// expanded by one block on each side to cover structural changes
    /// that alter a neighbour's paragraph style (e.g. heading Return
    /// splitting into heading + paragraph).
    ///
    /// Returns `NSRange(0, storageLength)` as a safe fallback when block
    /// spans are unavailable or the splice can't be localised.
    static func paragraphSyncScanRange(
        for spliceRange: NSRange,
        projection: DocumentProjection,
        storageLength: Int
    ) -> NSRange {
        let spans = projection.blockSpans
        guard !spans.isEmpty else {
            return NSRange(location: 0, length: storageLength)
        }

        // Post-splice storage position of the splice. The old
        // `spliceRange` is a contiguous region replaced in storage.
        // In the NEW projection/storage, the replacement occupies
        // [spliceRange.location, spliceRange.location + ...]. The
        // exact length doesn't matter here — we just need the block
        // indices that overlap the splice's START and END-of-insertion
        // in the new projection. The splice location is stable
        // across the replace (it's where the insertion begins).
        let spliceStart = max(0, min(spliceRange.location, storageLength))

        // Find the block whose span contains `spliceStart`. Linear
        // scan is fine — typical notes have <200 blocks and this
        // isn't per-glyph.
        var firstIdx = 0
        for (i, span) in spans.enumerated() {
            if NSLocationInRange(spliceStart, span) ||
               spliceStart == NSMaxRange(span) {
                firstIdx = i
                break
            }
            if spliceStart < span.location {
                firstIdx = max(0, i - 1)
                break
            }
            firstIdx = i
        }

        // Expand by one block on each side.
        let lo = max(0, firstIdx - 1)
        let hi = min(spans.count - 1, firstIdx + 1)
        let startLoc = spans[lo].location
        // Extend through the inter-block separator following `hi` (if any).
        // Separators are single "\n" chars OUTSIDE block spans but carry
        // the preceding block's paragraph style. When a structural edit
        // (e.g. heading Enter → [heading, paragraph]) shifts a separator
        // into a new role — e.g. the "\n" previously serving as the
        // heading→paragraph separator now serving as the new-paragraph→
        // next-paragraph separator — the character position is reused,
        // but its paragraph style must be rewritten from the new
        // projection. Without including this char, the stale style
        // persists and layout metrics (line height, paragraphSpacing)
        // diverge from the projection for one or more lines below the
        // edit. End-inclusive: +1 if `hi` is not the last block.
        let sepTail = (hi < spans.count - 1) ? 1 : 0
        let endLoc = min(storageLength, NSMaxRange(spans[hi]) + sepTail)
        guard endLoc > startLoc else {
            return NSRange(location: 0, length: storageLength)
        }
        return NSRange(location: startLoc, length: endLoc - startLoc)
    }

    /// Locate a range of characters that carry `attribute` with a value
    /// equal to `matching`, starting from a local window around `near`
    /// and only falling back to a full-storage scan if not found locally.
    ///
    /// Used by the math/mermaid render callbacks which previously did an
    /// unconditional full-storage `enumerateAttribute` every time an image
    /// render completed — O(runs) per callback, N callbacks per note.
    /// Shifts in storage position between the original render and the
    /// callback firing are bounded by the total size of prior attachment
    /// swaps, which in practice is small. A ±2KB local window finds the
    /// target in the common case; the fallback preserves correctness.
    static func findAttributeRange(
        attribute: NSAttributedString.Key,
        matching value: String,
        near originalRange: NSRange,
        in storage: NSTextStorage
    ) -> NSRange? {
        let windowRadius = 2048
        let localStart = max(0, originalRange.location - windowRadius)
        let localEnd = min(storage.length, NSMaxRange(originalRange) + windowRadius)
        guard localEnd > localStart else { return nil }
        let localRange = NSRange(location: localStart, length: localEnd - localStart)

        var found: NSRange?
        storage.enumerateAttribute(attribute, in: localRange, options: []) { val, range, stop in
            if let s = val as? String, s == value {
                found = range
                stop.pointee = true
            }
        }
        if let hit = found { return hit }

        // Local window missed — fall back to full storage (rare).
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(attribute, in: fullRange, options: []) { val, range, stop in
            if let s = val as? String, s == value {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// Tracks inline math ranges currently being rendered to avoid duplicates.
    private static var _renderedInlineMathRanges: Set<NSRange> = []

    private func renderInlineMathViaBlockModel() {
        guard let storage = textStorage else {
            bmLog("🎭 renderInlineMath: no textStorage")
            return
        }

        bmLog("🎭 renderInlineMath: scanning storage length=\(storage.length)")

        // Collect all inline math ranges and their source content.
        var mathEntries: [(range: NSRange, source: String)] = []
        storage.enumerateAttribute(.inlineMathSource, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            if let source = value as? String, !source.isEmpty {
                mathEntries.append((range: range, source: source))
            }
        }

        guard !mathEntries.isEmpty else {
            bmLog("🎭 renderInlineMath: no .inlineMathSource attributes found in storage")
            return
        }
        bmLog("🎭 renderInlineMath: found \(mathEntries.count) inline math spans")

        // Clear stale tracking from previous fill.
        EditTextView._renderedInlineMathRanges.removeAll()

        let maxWidth = textContainer?.containerSize.width ?? 480

        for entry in mathEntries {
            // Skip if already being rendered.
            guard !EditTextView._renderedInlineMathRanges.contains(entry.range) else { continue }
            EditTextView._renderedInlineMathRanges.insert(entry.range)

            let source = entry.source
            let originalRange = entry.range

            bmLog("🎭 inlineMath: rendering '\(source.prefix(30))' at \(originalRange)")

            BlockRenderer.render(source: source, type: .inlineMath, maxWidth: maxWidth) { [weak self] image in
                bmLog("🎭 inlineMath callback: image=\(image != nil ? "\(image!.size)" : "nil") for '\(source.prefix(30))'")
                guard let self = self, let image = image, let storage = self.textStorage else {
                    EditTextView._renderedInlineMathRanges.remove(originalRange)
                    return
                }

                DispatchQueue.main.async {
                    defer { EditTextView._renderedInlineMathRanges.remove(originalRange) }

                    // Find the current range of this math text in storage.
                    // It may have shifted due to earlier replacements, but
                    // the shift is bounded by the cumulative size of prior
                    // attachment swaps. Scan a local window first; only
                    // fall back to full-storage scan if not found locally.
                    let currentRange: NSRange? = Self.findAttributeRange(
                        attribute: .inlineMathSource,
                        matching: source,
                        near: originalRange,
                        in: storage
                    )

                    guard let range = currentRange,
                          range.location < storage.length,
                          NSMaxRange(range) <= storage.length else {
                        bmLog("🎭 inlineMath: range not found for '\(source.prefix(30))'")
                        return
                    }

                    // Scale image to match line height. Inline math should
                    // blend with surrounding text, not tower over it.
                    let lineHeight = (storage.attribute(.font, at: max(0, range.location - 1), effectiveRange: nil) as? NSFont)?.pointSize ?? 14
                    let targetHeight = lineHeight * 1.4  // slightly taller than text
                    let scale = min(targetHeight / image.size.height, 1.0)
                    let scaledSize = NSSize(
                        width: image.size.width * scale,
                        height: image.size.height * scale
                    )

                    bmLog("🎭 inlineMath: replacing \(range) with \(scaledSize) attachment")

                    let attachment = NSTextAttachment()
                    attachment.image = image
                    // Use bounds-based sizing for inline attachments (no cell needed).
                    // y offset centers vertically relative to baseline.
                    attachment.bounds = NSRect(
                        x: 0,
                        y: -(scaledSize.height - lineHeight) / 2,
                        width: scaledSize.width,
                        height: scaledSize.height
                    )

                    let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    attachmentString.addAttributes([
                        .renderedBlockSource: source,
                        .renderedBlockType: RenderedBlockType.math.rawValue,
                    ], range: NSRange(location: 0, length: attachmentString.length))

                    self.textStorageProcessor?.isRendering = true
                    // Phase 5a: async inline-math attachment hydration
                    // swaps source characters for a rendered image
                    // attachment. This runs post-render on the main
                    // thread, outside any `EditingOps` call, so it
                    // can't route through `applyDocumentEdit`
                    // (the `Document` projection already reflects the
                    // source markdown). Flag as legacy.
                    // TODO: make the attachment hydration a pure
                    // attribute-only pass (the U+FFFC character is
                    // already in storage from the initial render)
                    // so storage characters never change.
                    StorageWriteGuard.performingLegacyStorageWrite {
                        storage.beginEditing()
                        storage.replaceCharacters(in: range, with: attachmentString)
                        storage.endEditing()
                    }
                    self.textStorageProcessor?.isRendering = false

                    // Invalidate layout only for the replaced range;
                    // ensureLayout deferred to coalesced call.
                    // Phase 2a: gate on textLayoutManager == nil.
                    if self.textLayoutManager == nil, let lm = self.layoutManager {
                        let replacedRange = NSRange(
                            location: range.location,
                            length: attachmentString.length
                        )
                        lm.invalidateGlyphs(forCharacterRange: replacedRange, changeInLength: 0, actualCharacterRange: nil)
                        lm.invalidateLayout(forCharacterRange: replacedRange, actualCharacterRange: nil)
                    }
                    self.scheduleCoalescedLayout()

                    // Update projection spans for the replacement.
                    if let proj = self.documentProjection {
                        let lengthDelta = attachmentString.length - range.length
                        let patchedAttr = NSMutableAttributedString(attributedString: proj.attributed)
                        patchedAttr.replaceCharacters(in: range, with: attachmentString)
                        var patchedSpans = proj.blockSpans
                        // Find which block span contains this range and adjust.
                        for idx in 0..<patchedSpans.count {
                            let span = patchedSpans[idx]
                            if range.location >= span.location && NSMaxRange(range) <= NSMaxRange(span) {
                                // This span contains the math — shrink it.
                                patchedSpans[idx] = NSRange(location: span.location, length: span.length + lengthDelta)
                                // Shift all subsequent spans.
                                for j in (idx + 1)..<patchedSpans.count {
                                    patchedSpans[j] = NSRange(location: patchedSpans[j].location + lengthDelta, length: patchedSpans[j].length)
                                }
                                break
                            }
                        }
                        let renderedDoc = RenderedDocument(
                            document: proj.document,
                            attributed: patchedAttr,
                            blockSpans: patchedSpans
                        )
                        let newProjection = DocumentProjection(
                            rendered: renderedDoc,
                            bodyFont: proj.bodyFont,
                            codeFont: proj.codeFont,
                            note: proj.note
                        )
                        // Phase 4.6: setter auto-syncs `processor.blocks`.
                        self.documentProjection = newProjection
                    }

                    self.needsDisplay = true
                }
            }
        }
    }

    /// Tracks display math ranges currently being rendered to avoid duplicates.
    private static var _renderedDisplayMathRanges: Set<NSRange> = []

    /// Render display math ($$...$$) as centered block images — like mermaid
    /// but without the gray frame. Uses BlockRenderer with display mode (\[...\]).
    ///
    /// Invoked for **mixed-content paragraphs only** (e.g. "See $$\sum x$$
    /// below"). Paragraphs whose sole inline is `Inline.displayMath` are
    /// tagged `.blockModelKind = "displayMath"` by DocumentRenderer and
    /// render via the TK2 `DisplayMathLayoutFragment` — we must skip
    /// those ranges here to avoid painting the bitmap twice (once via
    /// the fragment, once via the attachment this method would install).
    ///
    /// Detection of the single-inline case reads `.blockModelKind` at
    /// the range's location: DocumentRenderer applies that attribute to
    /// the entire block range, so it's present on the `.displayMathSource`
    /// run for single-inline paragraphs and absent (or a different kind)
    /// for mixed-content paragraphs.
    private func renderDisplayMathViaBlockModel() {
        guard let storage = textStorage else { return }

        var mathEntries: [(range: NSRange, source: String)] = []
        storage.enumerateAttribute(.displayMathSource, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let source = value as? String, !source.isEmpty else { return }
            // Skip ranges inside a single-inline displayMath paragraph.
            // Those render via `DisplayMathLayoutFragment` (fragment-level
            // draw); installing an attachment here would stack a second
            // bitmap on top. Detection: the paragraph's `.blockModelKind`
            // covers the whole block range and equals `.displayMath`.
            let kind = storage.attribute(.blockModelKind, at: range.location, effectiveRange: nil) as? String
            if kind == BlockModelKind.displayMath.rawValue {
                return
            }
            mathEntries.append((range: range, source: source))
        }

        guard !mathEntries.isEmpty else { return }
        bmLog("🎭 renderDisplayMath: found \(mathEntries.count) mixed-content display math spans")

        EditTextView._renderedDisplayMathRanges.removeAll()

        let maxWidth = textContainer?.containerSize.width ?? 480

        for entry in mathEntries {
            guard !EditTextView._renderedDisplayMathRanges.contains(entry.range) else { continue }
            EditTextView._renderedDisplayMathRanges.insert(entry.range)

            let source = entry.source
            let originalRange = entry.range

            bmLog("🎭 displayMath: rendering '\(source.prefix(30))' at \(originalRange)")

            // Use .math type (display mode with \[...\] delimiters in template)
            BlockRenderer.render(source: source, type: .math, maxWidth: maxWidth) { [weak self] image in
                bmLog("🎭 displayMath callback: image=\(image != nil ? "\(image!.size)" : "nil") for '\(source.prefix(30))'")
                guard let self = self, let image = image, let storage = self.textStorage else {
                    EditTextView._renderedDisplayMathRanges.remove(originalRange)
                    return
                }

                DispatchQueue.main.async {
                    defer { EditTextView._renderedDisplayMathRanges.remove(originalRange) }

                    // Find the current range of this display math in storage.
                    // Use the bounded local-scan helper — see inline math for rationale.
                    let currentRange: NSRange? = Self.findAttributeRange(
                        attribute: .displayMathSource,
                        matching: source,
                        near: originalRange,
                        in: storage
                    )

                    guard let range = currentRange,
                          range.location < storage.length,
                          NSMaxRange(range) <= storage.length else {
                        bmLog("🎭 displayMath: range not found for '\(source.prefix(30))'")
                        return
                    }

                    // Scale to fit container width, keeping natural aspect ratio.
                    let scale = min(maxWidth / image.size.width, 1.0)
                    let scaledSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

                    bmLog("🎭 displayMath: replacing \(range) with \(scaledSize) attachment")

                    // To make the attachment *visually* a block (its own
                    // line, image centered horizontally) under BOTH TK1
                    // and TK2, we composite the rendered MathJax bitmap
                    // onto a container-wide transparent canvas, with the
                    // formula centered on it. The resulting image is then
                    // set as `attachment.image` with `attachment.bounds`
                    // matching the canvas size.
                    //
                    // Why the canvas trick instead of a custom view
                    // provider: under TK2 the default view provider just
                    // draws `.image` into `.bounds`; a wider bounds with a
                    // non-wide image would stretch horizontally. Pre-
                    // compositing keeps the image crisp at its natural
                    // size while still giving the attachment the container-
                    // wide footprint that forces the layout engine to
                    // wrap it onto its own line (de facto block-level
                    // rendering — the same trick `CenteredImageCell`
                    // played under TK1 via `cellSize()`).
                    let canvasSize = NSSize(width: maxWidth, height: scaledSize.height)
                    let canvas = NSImage(size: canvasSize)
                    canvas.lockFocus()
                    let targetRect = NSRect(
                        x: (maxWidth - scaledSize.width) / 2.0,
                        y: 0,
                        width: scaledSize.width,
                        height: scaledSize.height
                    )
                    image.draw(
                        in: targetRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0,
                        respectFlipped: true,
                        hints: nil
                    )
                    canvas.unlockFocus()

                    let attachment = NSTextAttachment()
                    attachment.image = canvas
                    attachment.bounds = NSRect(
                        x: 0,
                        y: 0,
                        width: canvasSize.width,
                        height: canvasSize.height
                    )
                    // Keep `CenteredImageCell` as the TK1 fallback — its
                    // `cellSize()` / `draw(withFrame:)` still work under
                    // TK1 and match the TK2 canvas behaviour.
                    let cell = CenteredImageCell(image: image, imageSize: scaledSize, containerWidth: maxWidth)
                    attachment.attachmentCell = cell
                    let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    attachmentString.addAttributes([
                        .renderedBlockSource: source,
                        .renderedBlockType: RenderedBlockType.math.rawValue,
                    ], range: NSRange(location: 0, length: attachmentString.length))

                    self.textStorageProcessor?.isRendering = true
                    // Phase 5a: async display-math / mermaid attachment
                    // hydration — same story as inline math above.
                    // Post-render swap of source characters for an
                    // image attachment; not routable through
                    // `applyDocumentEdit`.
                    // TODO: collapse into an attribute-only pass when
                    // the renderer emits the attachment character up
                    // front.
                    StorageWriteGuard.performingLegacyStorageWrite {
                        storage.beginEditing()
                        storage.replaceCharacters(in: range, with: attachmentString)
                        storage.endEditing()
                    }
                    self.textStorageProcessor?.isRendering = false

                    // Layout invalidation — narrow to the replaced range.
                    // Previously this invalidated the whole document AND
                    // called a blocking ensureLayout over full storage, which
                    // re-measured every line and caused cumulative scroll
                    // drift on every edit. Narrow invalidation + coalesced
                    // deferred layout is sufficient.
                    // Phase 2a: gate on textLayoutManager == nil.
                    if self.textLayoutManager == nil, let lm = self.layoutManager {
                        let replacedRange = NSRange(
                            location: range.location,
                            length: attachmentString.length
                        )
                        lm.invalidateGlyphs(forCharacterRange: replacedRange, changeInLength: 0, actualCharacterRange: nil)
                        lm.invalidateLayout(forCharacterRange: replacedRange, actualCharacterRange: nil)
                    }
                    self.scheduleCoalescedLayout()

                    // Update projection spans.
                    if let proj = self.documentProjection {
                        let lengthDelta = attachmentString.length - range.length
                        let patchedAttr = NSMutableAttributedString(attributedString: proj.attributed)
                        patchedAttr.replaceCharacters(in: range, with: attachmentString)
                        var patchedSpans = proj.blockSpans
                        for idx in 0..<patchedSpans.count {
                            let span = patchedSpans[idx]
                            if range.location >= span.location && NSMaxRange(range) <= NSMaxRange(span) {
                                patchedSpans[idx] = NSRange(location: span.location, length: span.length + lengthDelta)
                                for j in (idx + 1)..<patchedSpans.count {
                                    patchedSpans[j] = NSRange(location: patchedSpans[j].location + lengthDelta, length: patchedSpans[j].length)
                                }
                                break
                            }
                        }
                        let renderedDoc = RenderedDocument(
                            document: proj.document,
                            attributed: patchedAttr,
                            blockSpans: patchedSpans
                        )
                        let newProjection = DocumentProjection(
                            rendered: renderedDoc,
                            bodyFont: proj.bodyFont,
                            codeFont: proj.codeFont,
                            note: proj.note
                        )
                        // Phase 4.6: setter auto-syncs `processor.blocks`.
                        self.documentProjection = newProjection
                    }

                    self.needsDisplay = true
                }
            }
        }
    }

    // MARK: - Image resize commit (Slice 4 — TK2 view-provider path)

    /// Commit a new width for an image attachment through the block-model
    /// pipeline. Called from `InlineImageView`'s `onResizeCommit` closure
    /// (which is wired up by `ImageAttachmentViewProvider.loadView()`).
    ///
    /// Resolves the attachment's storage character index by scanning
    /// `textStorage`, maps that into `(blockIndex, inlineOffset)` via the
    /// live projection, locates the image inline path, and routes the
    /// size update through `EditingOps.setImageSize` and
    /// `applyEditResultWithUndo` — the standard block-model mutation
    /// path. After the splice lands, the hydrator is re-run so the
    /// freshly-rendered placeholder attachment gets its image loaded +
    /// sized according to the new width hint.
    ///
    /// No-op if the attachment can no longer be located in storage, the
    /// projection is nil, the block is not a paragraph containing an
    /// image at the offset, or the setImageSize primitive throws.
    ///
    /// - Parameters:
    ///   - attachment: The `NSTextAttachment` whose view just finished
    ///     being dragged. Must still be present in `textStorage`.
    ///   - newWidth: New width in points (will be rounded to `Int` for
    ///     the markdown width hint).
    public func commitImageResize(
        attachment: NSTextAttachment,
        newWidth: CGFloat
    ) {
        guard let storage = textStorage,
              let projection = documentProjection
        else { return }

        // Locate the attachment in storage by identity. O(n) scan, but
        // only runs once per mouseUp — not on the per-drag hot path.
        var location: Int? = nil
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, stop in
            if let att = value as? NSTextAttachment, att === attachment {
                location = range.location
                stop.pointee = true
            }
        }
        guard let storageIndex = location else {
            bmLog("⚠️ commitImageResize: attachment not found in storage")
            return
        }

        guard let (blockIndex, offsetInBlock) = projection.blockContaining(
            storageIndex: storageIndex
        ) else {
            bmLog("⚠️ commitImageResize: no block at storage index \(storageIndex)")
            return
        }

        let block = projection.document.blocks[blockIndex]
        guard case .paragraph(let inline) = block,
              let inlinePath = EditingOps.findImageInlinePath(
                in: inline, at: offsetInBlock
              )
        else {
            bmLog("⚠️ commitImageResize: no image inline at block=\(blockIndex) offset=\(offsetInBlock)")
            return
        }

        breakUndoCoalescing()
        do {
            let result = try EditingOps.setImageSize(
                blockIndex: blockIndex,
                inlinePath: inlinePath,
                newWidth: Int(newWidth.rounded()),
                in: projection
            )
            applyEditResultWithUndo(result, actionName: "Resize Image")

            // After the splice, the freshly-rendered attachment is a
            // placeholder (1×1, no cell). Re-hydrate so the image loads
            // at the new size from the width hint just written to the
            // markdown. Mirror of the TK1 path in
            // `EditTextView+Interaction.swift`.
            ImageAttachmentHydrator.hydrate(textStorage: storage, editor: self)
        } catch {
            bmLog("⚠️ commitImageResize: setImageSize failed: \(error)")
        }
        breakUndoCoalescing()
    }

    // MARK: - Phase 8 / Slice 4 — Cursor-leaves auto-collapse

    /// Phase 8 — Slice 4. Drop any block from `editingCodeBlocks`
    /// whose span no longer contains the current selection, and
    /// re-render via `DocumentEditApplier`. Called from the outer
    /// `textViewDidChangeSelection` delegate hooks.
    ///
    /// Contract:
    /// - If `editingCodeBlocks` is empty → no-op.
    /// - For each ref in the set, locate the corresponding block in
    ///   the current document (content-hash match). If the block's
    ///   span does NOT contain the current selection, the ref is
    ///   dropped. If the block is no longer present in the document
    ///   (content changed, block deleted), the ref is also dropped.
    /// - If the computed new set equals the old set → no-op (prevents
    ///   the infinite-loop "observer fires on re-render, re-renders,
    ///   fires on re-render" cycle).
    /// - Otherwise: ONE `applyDocumentEdit` call with the old set as
    ///   prior and the new set as new. The `promoteToggledBlocksToModified`
    ///   pass emits one `.modified` change per dropped block — batched,
    ///   not N calls.
    ///
    /// Safe to call repeatedly with the same selection: the
    /// "set == prior set" guard makes the stable-selection case a
    /// true no-op. Also safe when the editor is not in block-model
    /// mode (no projection) — early-returns.
    func collapseEditingCodeBlocksOutsideSelection() {
        let priorSet = editingCodeBlocks
        // Guard 1 — nothing to collapse. Also blocks the infinite
        // re-render loop: after the applier finishes and selection
        // settles on the re-rendered content, this method fires again
        // with an already-empty set and exits here.
        guard !priorSet.isEmpty else { return }

        guard let projection = documentProjection,
              let tlm = textLayoutManager,
              let contentStorage =
                tlm.textContentManager as? NSTextContentStorage
        else { return }

        let selection = selectedRange()
        let currentDoc = projection.document

        // Build a ref → block-index map of the current document so we
        // can answer "is the selection inside block X's span?" in one
        // O(N) pass regardless of how many refs are in `priorSet`.
        var refToIndex: [BlockRef: Int] = [:]
        refToIndex.reserveCapacity(currentDoc.blocks.count)
        for (i, block) in currentDoc.blocks.enumerated() {
            refToIndex[BlockRef(block)] = i
        }

        // Compute the new set: keep refs whose block still exists AND
        // whose span strictly contains the current selection.
        var newSet = Set<BlockRef>()
        newSet.reserveCapacity(priorSet.count)
        for ref in priorSet {
            guard let blockIndex = refToIndex[ref],
                  blockIndex < projection.blockSpans.count else {
                // Block no longer in the document — drop.
                continue
            }
            let span = projection.blockSpans[blockIndex]
            let selEnd = selection.location + selection.length
            let spanEnd = span.location + span.length
            // Strict containment: the entire selection must sit
            // inside the block's span.
            if selection.location >= span.location && selEnd <= spanEnd {
                newSet.insert(ref)
            }
        }

        // Guard 2 — nothing changed. Matches the Slice 3 click path
        // cleanly: if the click flipped a block OUT, `priorSet` here
        // is already the post-click (empty or smaller) set; this
        // method observes no delta and no-ops.
        guard newSet != priorSet else { return }

        // Commit the new set BEFORE applying so any re-entrant
        // observer call (via text-change notifications from the
        // applier) sees the stable state and exits via guard 1 or
        // guard 2.
        editingCodeBlocks = newSet

        _ = DocumentEditApplier.applyDocumentEdit(
            priorDoc: currentDoc,
            newDoc: currentDoc,
            contentStorage: contentStorage,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note,
            priorEditingBlocks: priorSet,
            newEditingBlocks: newSet
        )

        // Rebuild the projection so subsequent edits render against
        // the new editing set. Mirrors the pattern in
        // `CodeBlockEditToggleOverlay.applyToggle`.
        let newRendered = DocumentRenderer.render(
            currentDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note,
            editingCodeBlocks: newSet
        )
        documentProjection = DocumentProjection(
            rendered: newRendered,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        needsDisplay = true

        // Notify the overlay so surviving toggle buttons update
        // their `isActive` state. The overlay observes
        // `NSText.didChangeNotification` — but the applier runs
        // inside a TK2 `performEditingTransaction` that batches
        // delegate callbacks, and in headless test contexts the
        // notification may not fire synchronously. Post an explicit
        // notification so the overlay repositions deterministically
        // under both live and test environments.
        NotificationCenter.default.post(
            name: EditTextView.editingCodeBlocksDidChangeNotification,
            object: self
        )
    }

    /// Phase 8 / Slice 4. Notification posted when
    /// `editingCodeBlocks` changes via the auto-collapse path so the
    /// overlay can re-style surviving buttons (their `isActive` state
    /// may have flipped). Slice 3's click path does not post this —
    /// its `reposition()` call at the end of `applyToggle` already
    /// refreshes button state.
    static let editingCodeBlocksDidChangeNotification =
        Notification.Name("FSNotesEditingCodeBlocksDidChange")
}