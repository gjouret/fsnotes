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
/// Uses NSHomeDirectory() which works in both sandboxed and unsandboxed modes.
/// In sandbox: ~/Library/Containers/co.fluder.FSNotes/Data/
/// Without sandbox: ~/
let blockModelLogURL: URL = {
    let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
    return home.appendingPathComponent("block-model.log")
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
        }
    }

    private enum AssociatedKeys {
        static var projection = 0
        static var pendingTraits = 1
        static var suppressTraitClear = 2
        static var coalescedLayoutPending = 3
        static var explicitlyOffTraits = 4
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
            if let lm = self.layoutManager, let storage = self.textStorage {
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
        textStorageProcessor?.isRendering = true
        storage.setAttributedString(projection.attributed)
        textStorageProcessor?.isRendering = false
        
        // Verify storage matches projection after setting
        bmLog("✅ AFTER setAttributedString: storage.length=\(storage.length), projection.length=\(projection.attributed.length)")

        documentProjection = projection
        textStorageProcessor?.blockModelActive = true
        // Populate the source-mode blocks array so fold/unfold works
        textStorageProcessor?.syncBlocksFromProjection(projection)

        // Restore fold state from the note's cache (RC5).
        if let savedFolds = note.cachedFoldState, !savedFolds.isEmpty,
           let processor = textStorageProcessor {
            processor.restoreCollapsedState(savedFolds, textStorage: storage)
        }

        bmLog("✅ fillViaBlockModel complete: \(document.blocks.count) blocks, rendered \(projection.attributed.length) chars — \(note.title)")
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

        // Count attachment characters in the pre-splice range so the
        // orphan sweep below can be gated on whether the splice
        // actually removed any. Typical cell-edit splices touch zero
        // attachment chars, so the sweep becomes a no-op — saving
        // a per-keystroke full-storage attachment walk.
        let preSpliceAttachmentCount = countAttachmentCharacters(
            in: result.spliceRange, of: storage
        )

        textStorageProcessor?.isRendering = true
        storage.beginEditing()
        storage.replaceCharacters(
            in: result.spliceRange,
            with: result.spliceReplacement
        )
        storage.endEditing()

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
        documentProjection = result.newProjection
        textStorageProcessor?.syncBlocksFromProjection(result.newProjection)

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
        if let lm = layoutManager {
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

        // Clean up orphaned inline PDF / QuickLook / table subviews
        // ONLY when the splice actually removed attachment
        // characters. The common per-keystroke cell edit has a
        // splice that doesn't touch any attachment, so this gate
        // skips an O(subviews + storage.length) walk on the hot
        // path. Widgets get added as direct subviews by their
        // attachment cell's draw() method and the splice does not
        // automatically tear them out when the attachment disappears.
        if postSpliceAttachmentCount < preSpliceAttachmentCount {
            removeOrphanedInlinePDFViews()
            removeOrphanedInlineQuickLookViews()
            removeOrphanedInlineTableViews()
        }

        // Mark note as modified.
        note?.cacheHash = nil

        // Register undo. Use the responder-chain undoManager (which
        // MainWindowController.windowWillReturnUndoManager routes to
        // editorUndoManager). Fall back to editorViewController's copy.
        let um = self.undoManager ?? editorViewController?.editorUndoManager
        if let um = um {
            um.registerUndo(withTarget: self) { target in
                target.restoreBlockModelState(
                    projection: oldProjection,
                    cursorRange: oldCursorRange,
                    actionName: actionName
                )
            }
            um.setActionName(actionName)
        }
    }

    /// Count U+FFFC attachment characters in the given range of a
    /// text storage. Used by `applyEditResultWithUndo` to gate the
    /// orphan-view cleanup on whether the splice actually removed
    /// an attachment.
    private func countAttachmentCharacters(in range: NSRange, of storage: NSTextStorage) -> Int {
        let s = storage.string as NSString
        let end = min(NSMaxRange(range), s.length)
        var count = 0
        if range.location < end {
            for i in range.location..<end {
                if s.character(at: i) == 0xFFFC { count += 1 }
            }
        }
        return count
    }

    /// Count U+FFFC attachment characters in an attributed string.
    private func countAttachmentCharacters(in attributed: NSAttributedString) -> Int {
        let s = attributed.string as NSString
        var count = 0
        for i in 0..<s.length {
            if s.character(at: i) == 0xFFFC { count += 1 }
        }
        return count
    }

    /// Restore a previous block-model state (used by undo/redo).
    private func restoreBlockModelState(
        projection: DocumentProjection,
        cursorRange: NSRange,
        actionName: String
    ) {
        guard let storage = textStorage else { return }

        // Capture current state for redo BEFORE restoring.
        guard let currentProjection = documentProjection else { return }
        let currentCursor = selectedRange()

        // Replace textStorage with the old rendered output.
        // Use setAttributedString for a clean full replacement —
        // replaceCharacters can produce garbled output when replacing
        // the entire storage with an attributed string.
        textStorageProcessor?.isRendering = true
        storage.beginEditing()
        storage.setAttributedString(projection.attributed)
        storage.endEditing()
        textStorageProcessor?.isRendering = false

        // Restore projection and cursor.
        documentProjection = projection
        textStorageProcessor?.syncBlocksFromProjection(projection)
        let safeCursor = NSRange(
            location: min(cursorRange.location, storage.length),
            length: min(cursorRange.length, max(0, storage.length - cursorRange.location))
        )
        setSelectedRange(safeCursor)
        scrollRangeToVisible(safeCursor)

        if let lm = layoutManager, let tc = textContainer {
            let glyphRange = lm.glyphRange(for: tc)
            lm.invalidateDisplay(forGlyphRange: glyphRange)
        }
        needsDisplay = true

        removeOrphanedInlinePDFViews()
        removeOrphanedInlineQuickLookViews()
        removeOrphanedInlineTableViews()

        note?.cacheHash = nil

        // Register redo.
        let um = self.undoManager ?? editorViewController?.editorUndoManager
        if let um = um {
            um.registerUndo(withTarget: self) { target in
                target.restoreBlockModelState(
                    projection: currentProjection,
                    cursorRange: currentCursor,
                    actionName: actionName
                )
            }
            um.setActionName(actionName)
        }
    }

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
                    result = try EditingOps.insert(replacement, at: range.location, in: projection)
                    // Clear pending traits on newline.
                    if replacement == "\n" {
                        pendingInlineTraits = []
                        explicitlyOffTraits = []
                    }
                }
            } else if range.length > 0 && replacement.isEmpty {
                // DEBUG: Log all delete operations using NSLog
                NSLog("=== DELETE OPERATION === range: %@", NSStringFromRange(range))
                
                // Check for delete-at-home in a list item (FSM intercept).
                let handled = handleDeleteAtHomeInList(range: range, in: projection)
                
                // DEBUG: Log result
                NSLog("handleDeleteAtHomeInList returned: %@", handled ? "true" : "false")
                
                if handled {
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
        
        // DEBUG using NSLog
        NSLog("=== handleDeleteAtHomeInList === range: %@, cursorPos: %d", NSStringFromRange(range), cursorPos)
        
        // Check if we're at the "home" position (start of inline content in a list item)
        let isAtHome = ListEditingFSM.isAtHomePosition(storageIndex: cursorPos, in: projection)
        
        NSLog("isAtHome: %@", isAtHome ? "true" : "false")
        
        guard isAtHome else {
            NSLog("GUARD FAILED: not at home position")
            return false
        }

        let state = ListEditingFSM.detectState(storageIndex: cursorPos, in: projection)
        
        NSLog("state: %@", String(describing: state))
        
        guard case .listItem = state else {
            NSLog("GUARD FAILED: not in list item")
            return false
        }

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

    /// Push a widget-constructed `Block.table` back into the editor's
    /// projection after a structural mutation (add/remove row,
    /// add/remove column, move, alignment change). Swaps one block
    /// in the Document without calling `storage.replaceCharacters` —
    /// the attachment character's storage position is unchanged
    /// (the table renders as a single attachment char regardless of
    /// shape), so a fresh projection is all that's needed.
    func pushTableBlockToProjection(
        from tableView: InlineTableView,
        newBlock: Block
    ) {
        guard let projection = documentProjection else { return }
        guard let blockIndex = blockIndex(for: tableView) else {
            bmLog("⛔ pushTableBlockToProjection: widget not found in storage")
            return
        }

        var newDoc = projection.document
        newDoc.blocks[blockIndex] = newBlock
        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )
        documentProjection = newProjection
    }

    /// Find the `Document` block index for the table widget by
    /// walking storage's attachment characters. Used by both
    /// `pushTableBlockToProjection` (structural mutations) and
    /// `applyTableCellInlineEdit` (cell content edits) to avoid
    /// duplicating the same attachment → block-index scan.
    private func blockIndex(for tableView: InlineTableView) -> Int? {
        guard let projection = documentProjection,
              let storage = textStorage else { return nil }
        var found: Int? = nil
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, attRange, stop in
            guard let att = value as? NSTextAttachment,
                  let cell = att.attachmentCell as? InlineTableAttachmentCell,
                  cell.inlineTableView === tableView else { return }
            if let (blockIdx, _) = projection.blockContaining(storageIndex: attRange.location) {
                found = blockIdx
                stop.pointee = true
            }
        }
        return found
    }

    /// Stage 3 cell-edit entry point: push an inline tree directly
    /// into the cell at `location` inside `tableView`'s table block.
    /// Called from `controlTextDidChange` on every keystroke and
    /// from the toolbar formatting path after attribute toggles.
    ///
    /// The attachment character in storage stays in place — no
    /// `storage.replaceCharacters` call. The widget receives the
    /// updated block via `applyBlockUpdate`, and save is marked
    /// (but not fired synchronously; the existing periodic save
    /// flushes to disk off the keystroke hot path).
    @discardableResult
    func applyTableCellInlineEdit(
        from tableView: InlineTableView,
        at location: EditingOps.TableCellLocation,
        inline: [Inline]
    ) -> Bool {
        guard let projection = documentProjection else {
            bmLog("⛔ applyTableCellInlineEdit: no projection")
            return false
        }
        guard let blockIndex = blockIndex(for: tableView) else {
            bmLog("⛔ applyTableCellInlineEdit: widget not found in storage")
            return false
        }

        // Early-return when the new inline tree equals the existing
        // cell. Arrow keys and other selection-only events still
        // fire `controlTextDidChange`, so without this check the
        // full primitive + save pipeline runs for every caret move.
        if case .table(let header, _, let rows, _) = projection.document.blocks[blockIndex] {
            let existing: [Inline]?
            switch location {
            case .header(let col):
                existing = col < header.count ? header[col].inline : nil
            case .body(let row, let col):
                existing = (row < rows.count && col < rows[row].count) ? rows[row][col].inline : nil
            }
            if let existing = existing, existing == inline {
                return true
            }
        }

        let result: EditResult
        do {
            result = try EditingOps.replaceTableCellInline(
                blockIndex: blockIndex,
                at: location,
                inline: inline,
                in: projection
            )
        } catch {
            bmLog("⚠️ applyTableCellInlineEdit: replaceTableCellInline threw \(error)")
            return false
        }

        documentProjection = result.newProjection
        hasUserEdits = true

        guard blockIndex < result.newProjection.document.blocks.count,
              case .table = result.newProjection.document.blocks[blockIndex] else {
            bmLog("⛔ applyTableCellInlineEdit: new block at \(blockIndex) is not a table")
            return false
        }
        tableView.applyBlockUpdate(result.newProjection.document.blocks[blockIndex])
        // Intentionally NOT calling save() here — per-keystroke
        // synchronous disk writes are the most expensive thing in the
        // edit hot path. `hasUserEdits` signals the existing periodic
        // save trigger (note-switch, blur, quit) to persist.
        return true
    }

    // NOTE: the former `applyTableCellEdit(from:at:newSourceText:)`
    // entry point — which took a raw markdown string and forwarded
    // to `EditingOps.replaceTableCell` — has been deleted. Stage 3
    // routes every cell edit through `applyTableCellInlineEdit`
    // (which takes an `[Inline]` tree directly), so the raw-string
    // path has zero live callers. The `EditingOps.replaceTableCell`
    // primitive is still retained as a convenience for paste and
    // test paths, and it now forwards to `replaceTableCellInline`.


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

        // DEBUG - write to file
        let debugLog = """
            === applyToggleAcrossSelection ===
            actionName: \(actionName)
            sel: \(sel)
            storage.length: \(textStorage?.length ?? -1)
            blockSpans: \(projection.blockSpans)
            blocks: \(projection.document.blocks.map { String(describing: $0) })
            """
        let logPath = "/tmp/fsnotes_debug.log"
        try? debugLog.write(toFile: logPath, atomically: true, encoding: .utf8)

        do {
            let indices = projection.blockIndices(overlapping: sel).filter { idx in
                if case .blankLine = projection.document.blocks[idx] { return false }
                return true
            }
            
            // Append to debug log
            let indicesLog = "\nindices after filter: \(indices)"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(indicesLog.data(using: .utf8)!)
                handle.closeFile()
            }
            
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
    /// Single-block or cursor-only selection delegates to the existing
    /// single-block primitive. Multi-block selection collapses every
    /// overlapped non-blank block into ONE list block (one item per
    /// block), dropping blank lines between them — otherwise the
    /// serializer would emit N separate `<ul>` blocks with visible
    /// gaps, which is almost never what the user wanted when they
    /// highlighted three paragraphs and clicked the list button.
    func toggleListViaBlockModel(marker: String = "-") -> Bool {
        if wrapSelectionInSingleList(marker: marker, checkbox: nil) {
            return true
        }
        return applyToggleAcrossSelection(actionName: "List") { proj, loc in
            try EditingOps.toggleList(marker: marker, at: loc, in: proj)
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
            bmLog("➖ insertHorizontalRule: splice \(result.spliceRange)")
            applyBlockModelResult(result, actionName: "Horizontal Rule")
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
        if wrapSelectionInSingleList(marker: "-", checkbox: checkbox) {
            return true
        }
        return applyToggleAcrossSelection(actionName: "Todo List") { proj, loc in
            try EditingOps.toggleTodoList(at: loc, in: proj)
        }
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

    // MARK: - Mermaid / MathJax rendering for block model

    /// Set of block indices already rendered or pending render (prevents double-rendering).
    private static var _renderedBlockIndices: Set<Int> = []

    /// Render mermaid/math code blocks to inline images using the Document model.
    /// Called during fill when the block-model pipeline is active.
    func renderSpecialBlocksViaBlockModel() {
        // Clear stale indices from previous notes — prevents blocks at
        // the same index from being skipped when switching notes.
        EditTextView._renderedBlockIndices.removeAll()

        guard let projection = documentProjection,
              let storage = textStorage else { return }

        let doc = projection.document
        let spans = projection.blockSpans

        bmLog("🎭 renderSpecialBlocksViaBlockModel: \(doc.blocks.count) blocks")
        for (i, block) in doc.blocks.enumerated() {
            guard case .codeBlock(let language, let content, _) = block else {
                continue
            }
            guard let lang = language?.lowercased(),
                  i < spans.count else {
                bmLog("🎭 block[\(i)] codeBlock lang=\(language ?? "nil") — skipped (no lang or out of span range)")
                continue
            }

            let blockType: BlockRenderer.BlockType
            if lang == "mermaid" {
                blockType = .mermaid
            } else if lang == "math" || lang == "latex" {
                blockType = .math
            } else {
                bmLog("🎭 block[\(i)] codeBlock lang='\(lang)' — skipped (not mermaid/math)")
                continue
            }

            let source = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else {
                bmLog("🎭 block[\(i)] \(lang) — skipped (empty source)")
                continue
            }

            // Skip already-rendered blocks
            if EditTextView._renderedBlockIndices.contains(i) {
                bmLog("🎭 block[\(i)] \(lang) — skipped (already rendered)")
                continue
            }
            EditTextView._renderedBlockIndices.insert(i)
            bmLog("🎭 block[\(i)] \(lang) — starting render, source='\(source.prefix(50))...'")

            let codeRange = spans[i]
            let maxWidth = textContainer?.containerSize.width ?? 480

            BlockRenderer.render(source: source, type: blockType, maxWidth: maxWidth) { [weak self] image in
                bmLog("🎭 block[\(i)] render callback: image=\(image != nil ? "\(image!.size)" : "nil")")
                guard let self = self, let image = image, let storage = self.textStorage else {
                    bmLog("🎭 block[\(i)] render failed: self=\(self != nil), image=\(image != nil)")
                    EditTextView._renderedBlockIndices.remove(i)
                    return
                }

                DispatchQueue.main.async {
                    defer { EditTextView._renderedBlockIndices.remove(i) }

                    // Re-verify projection hasn't changed and range is valid.
                    guard let currentProjection = self.documentProjection,
                          i < currentProjection.blockSpans.count else {
                        bmLog("🎭 block[\(i)] replacement SKIPPED: projection gone or index out of range")
                        return
                    }
                    let currentSpan = currentProjection.blockSpans[i]
                    guard currentSpan.location < storage.length,
                          NSMaxRange(currentSpan) <= storage.length else {
                        bmLog("🎭 block[\(i)] replacement SKIPPED: span \(currentSpan) out of storage range \(storage.length)")
                        return
                    }

                    bmLog("🎭 block[\(i)] replacing span \(currentSpan) with \(image.size) attachment")
                    let scale = min(maxWidth / image.size.width, 1.0)
                    let scaledSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

                    let attachment = NSTextAttachment()
                    let cell = CenteredImageCell(image: image, imageSize: scaledSize, containerWidth: maxWidth)
                    attachment.attachmentCell = cell

                    let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    let attRange = NSRange(location: 0, length: attachmentString.length)
                    attachmentString.addAttributes([
                        .renderedBlockSource: source,
                        .renderedBlockType: (blockType == .mermaid ? RenderedBlockType.mermaid : RenderedBlockType.math).rawValue,
                    ], range: attRange)

                    // Replace the code block text with the rendered image.
                    self.textStorageProcessor?.isRendering = true
                    storage.beginEditing()
                    storage.replaceCharacters(in: currentSpan, with: attachmentString)
                    storage.endEditing()
                    self.textStorageProcessor?.isRendering = false

                    // Invalidate layout only for the replaced span. The
                    // actual ensureLayout is deferred to a single coalesced
                    // call after all replacements complete.
                    if let lm = self.layoutManager {
                        let replacedRange = NSRange(
                            location: currentSpan.location,
                            length: attachmentString.length
                        )
                        lm.invalidateGlyphs(forCharacterRange: replacedRange, changeInLength: 0, actualCharacterRange: nil)
                        lm.invalidateLayout(forCharacterRange: replacedRange, actualCharacterRange: nil)
                    }
                    self.scheduleCoalescedLayout()

                    // Rebuild projection so subsequent edits see correct spans.
                    // The document model is unchanged (still .codeBlock) — only the
                    // rendered attributed string in the projection needs updating.
                    let lengthDelta = attachmentString.length - currentSpan.length
                    let patchedAttr = NSMutableAttributedString(attributedString: currentProjection.attributed)
                    patchedAttr.replaceCharacters(in: currentSpan, with: attachmentString)
                    var patchedSpans = currentProjection.blockSpans
                    patchedSpans[i] = NSRange(location: currentSpan.location, length: attachmentString.length)
                    for j in (i + 1)..<patchedSpans.count {
                        patchedSpans[j] = NSRange(
                            location: patchedSpans[j].location + lengthDelta,
                            length: patchedSpans[j].length
                        )
                    }
                    let renderedDoc = RenderedDocument(
                        document: currentProjection.document,
                        attributed: patchedAttr,
                        blockSpans: patchedSpans
                    )
                    let newProjection = DocumentProjection(
                        rendered: renderedDoc,
                        bodyFont: currentProjection.bodyFont,
                        codeFont: currentProjection.codeFont,
                        note: currentProjection.note
                    )
                    self.documentProjection = newProjection

                    // Re-sync blocks so LayoutManager draws gray backgrounds
                    // for regular code blocks at their updated (post-replacement) ranges.
                    self.textStorageProcessor?.syncBlocksFromProjection(newProjection)

                    self.needsDisplay = true
                }
            }
        }

        // --- Inline math ($...$): render inline with text ---
        renderInlineMathViaBlockModel()

        // --- Display math ($$...$$): render as centered block image ---
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
                    storage.beginEditing()
                    storage.replaceCharacters(in: range, with: attachmentString)
                    storage.endEditing()
                    self.textStorageProcessor?.isRendering = false

                    // Invalidate layout only for the replaced range;
                    // ensureLayout deferred to coalesced call.
                    if let lm = self.layoutManager {
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
                        self.documentProjection = newProjection
                        self.textStorageProcessor?.syncBlocksFromProjection(newProjection)
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
    private func renderDisplayMathViaBlockModel() {
        guard let storage = textStorage else { return }

        var mathEntries: [(range: NSRange, source: String)] = []
        storage.enumerateAttribute(.displayMathSource, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            if let source = value as? String, !source.isEmpty {
                mathEntries.append((range: range, source: source))
            }
        }

        guard !mathEntries.isEmpty else { return }
        bmLog("🎭 renderDisplayMath: found \(mathEntries.count) display math spans")

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

                    // Use CenteredImageCell for centered display, like mermaid.
                    let attachment = NSTextAttachment()
                    let cell = CenteredImageCell(image: image, imageSize: scaledSize, containerWidth: maxWidth)
                    attachment.attachmentCell = cell

                    let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    attachmentString.addAttributes([
                        .renderedBlockSource: source,
                        .renderedBlockType: RenderedBlockType.math.rawValue,
                    ], range: NSRange(location: 0, length: attachmentString.length))

                    self.textStorageProcessor?.isRendering = true
                    storage.beginEditing()
                    storage.replaceCharacters(in: range, with: attachmentString)
                    storage.endEditing()
                    self.textStorageProcessor?.isRendering = false

                    // Layout invalidation — narrow to the replaced range.
                    // Previously this invalidated the whole document AND
                    // called a blocking ensureLayout over full storage, which
                    // re-measured every line and caused cumulative scroll
                    // drift on every edit. Narrow invalidation + coalesced
                    // deferred layout is sufficient.
                    if let lm = self.layoutManager {
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
                        self.documentProjection = newProjection
                        self.textStorageProcessor?.syncBlocksFromProjection(newProjection)
                    }

                    self.needsDisplay = true
                }
            }
        }
    }
}