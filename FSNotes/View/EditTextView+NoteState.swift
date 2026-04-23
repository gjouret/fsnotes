//
//  EditTextView+NoteState.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import Foundation
import AppKit

extension EditTextView {
    func getSelectedNote() -> Note? {
        return ViewController.shared()?.notesTableView?.getSelectedNote()
    }

    public func isEditable(note: Note) -> Bool {
        if note.container == .encryptedTextPack { return false }
        return editorViewController?.vcEditor != nil
    }

    public func getVC() -> EditorViewController {
        return self.window?.contentViewController as! EditorViewController
    }

    public func getEVC() -> EditorViewController? {
        return self.window?.contentViewController as? EditorViewController
    }

    /// Debounce window (seconds) for autosave during typing. The
    /// `textDidChange` hook calls `save()` on every keystroke; the
    /// debounce coalesces those into at most one disk write per window.
    /// Trade-off: up to this many seconds of un-persisted work on crash
    /// or unexpected quit — acceptable because note switches, app quit,
    /// and window close all call `flushPendingSave()` to force a flush.
    private static let saveDebounceInterval: TimeInterval = 0.8

    /// Schedule a debounced save. Called from `textDidChange` so typing
    /// in long notes doesn't write megabytes of markdown per minute of
    /// typing (Perf plan item #12). The save still runs through the same
    /// `save()` entry point — only the scheduling changes.
    public func scheduleDebouncedSave() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.saveDebounceInterval,
            repeats: false
        ) { [weak self] _ in
            self?.save()
        }
    }

    /// Force-flush any pending debounced save. Call from note switch,
    /// app termination, window close — anywhere where losing the
    /// pending edit would be worse than the small autosave pause.
    public func flushPendingSave() {
        if saveDebounceTimer?.isValid == true {
            saveDebounceTimer?.invalidate()
            saveDebounceTimer = nil
            save()
        }
    }

    public func save() {
        guard let note = self.note else { return }
        // Safety: only save when the user has actually edited the note.
        // Display-only operations (fill, hydration, async rendering) must
        // never write to disk — that would corrupt notes with stale or
        // partial rendered state.
        guard hasUserEdits else {
            bmLog("⏭️ save skipped (no user edits): \(note.title)")
            return
        }
        // Cancel any pending debounced save — we're saving right now.
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        // Block-model pipeline: serialize Document to markdown
        // directly, bypassing the attribute-stripping save path.
        if let markdown = serializeViaBlockModel() {
            bmLog("💾 save (block-model): \(note.title) — \(markdown.prefix(60))")
            note.save(markdown: markdown)
            // Preserve the cached Document from the current projection.
            // save(markdown:) invalidates `note.cachedDocument`, but the
            // projection's document IS the post-edit state for every
            // block type now — including tables, which route through
            // `EditingOps.replaceTableCell` on every cell edit. No
            // live-table walk exception any more.
            if let doc = documentProjection?.document {
                note.cachedDocument = doc
            }
            cleanupOrphanedAttachmentsIfNeeded(note: note, markdown: markdown)
            hasUserEdits = false
            return
        }
        let saving = attributedStringForSaving()
        bmLog("💾 save (source-mode): \(note.title) — \(saving.string.prefix(60))")
        note.save(attributed: saving)
        hasUserEdits = false
        // NOTE: Do NOT run orphan cleanup here. The source-mode fallback
        // fires when documentProjection is temporarily nil (e.g. during
        // clearBlockModelAndRefill). The plain text contains ￼ attachment
        // characters, not ![alt](path) markdown, so the orphan checker
        // would flag every image as orphaned. Orphan cleanup only runs
        // in the block-model path above, where we have real markdown.
    }

    // MARK: - Orphaned attachment cleanup on save

    /// Filenames the user has already been prompted about (and chose to
    /// keep) in this editing session. Reset when switching notes.
    private static var _dismissedOrphans: Set<String> = []

    /// Filenames currently being inserted via an async workflow (e.g.
    /// thumbnail generation). Suppresses orphan detection until the
    /// markdown reference has been inserted. Cleared per-file when the
    /// async insertion completes.
    private static var _pendingInsertions: Set<String> = []

    /// Find orphaned assets for a single note and prompt for removal.
    /// Encrypted notes have orphans permanently deleted; unencrypted
    /// notes have them moved to the Trash.
    private func cleanupOrphanedAttachmentsIfNeeded(note: Note, markdown: String) {
        guard note.isTextBundle() else { return }
        let fm = FileManager.default
        let assetsURL = note.url.appendingPathComponent("assets")
        guard fm.fileExists(atPath: assetsURL.path) else { return }

        guard let assetFiles = try? fm.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Find assets not referenced in the markdown content.
        // Skip any the user already dismissed this session or that are
        // still being inserted via an async workflow.
        // Check both the raw filename and its percent-encoded form, since
        // markdown image/link references use percent-encoded paths.
        var orphans: [(url: URL, name: String, size: UInt64)] = []
        for file in assetFiles {
            let name = file.lastPathComponent
            if EditTextView._dismissedOrphans.contains(name) { continue }
            if EditTextView._pendingInsertions.contains(name) { continue }
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            if !markdown.contains(name) && (encodedName == name || !markdown.contains(encodedName)) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
                orphans.append((url: file, name: name, size: size))
            }
        }

        guard !orphans.isEmpty else { return }

        let totalSize = orphans.reduce(UInt64(0)) { $0 + $1.size }
        let sizeMB = Double(totalSize) / 1_048_576.0
        let encrypted = note.isEncrypted()

        let fileList = orphans.prefix(10).map { "  • \($0.name)" }.joined(separator: "\n")
        let moreText = orphans.count > 10 ? "\n  … and \(orphans.count - 10) more" : ""
        let actionVerb = encrypted ? "permanently delete" : "move to Trash"

        let alert = NSAlert()
        alert.messageText = "Orphaned Attachment\(orphans.count == 1 ? "" : "s") Found"
        alert.informativeText = """
            \(orphans.count) attachment\(orphans.count == 1 ? " is" : "s are") no longer referenced in "\(note.getTitle() ?? note.fileName)" (\(String(format: "%.1f", sizeMB)) MB):

            \(fileList)\(moreText)

            Would you like to \(actionVerb) \(orphans.count == 1 ? "it" : "them")?
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: encrypted ? "Delete" : "Move to Trash")
        alert.addButton(withTitle: "Keep")
        // Map Esc key to the "Keep" button so users can dismiss with Esc.
        alert.buttons[1].keyEquivalent = "\u{1b}"

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            for orphan in orphans {
                do {
                    if encrypted {
                        try fm.removeItem(at: orphan.url)
                    } else {
                        try fm.trashItem(at: orphan.url, resultingItemURL: nil)
                    }
                } catch {
                    bmLog("⚠️ Failed to remove orphaned attachment \(orphan.name): \(error)")
                }
            }
        } else {
            // User chose to keep — remember so we don't re-prompt this session
            for orphan in orphans {
                EditTextView._dismissedOrphans.insert(orphan.name)
            }
        }
    }

    /// Reset the dismissed-orphan tracker (call when switching notes).
    static func resetDismissedOrphans() {
        _dismissedOrphans.removeAll()
        _pendingInsertions.removeAll()
    }

    /// Mark a filename as pending insertion (suppresses orphan detection).
    static func addPendingInsertion(_ name: String) {
        _pendingInsertions.insert(name)
    }

    /// Remove a filename from the pending-insertion set after its
    /// markdown reference has been inserted.
    static func removePendingInsertion(_ name: String) {
        _pendingInsertions.remove(name)
    }

    func fill(note: Note, highlight: Bool = false, force: Bool = false) {
        bmLog("📋 fill() called: \(note.title)")
        // Flush any pending debounced save from the OUTGOING note
        // before we replace `self.note`. Otherwise the save would
        // either be lost (timer cancelled) or fire against the new
        // note by mistake. (Perf plan #12.)
        flushPendingSave()

        // Clear any image selection carried over from the previous
        // note — ranges don't survive a note swap.
        selectedImageRange = nil

        isScrollPositionSaverLocked = true

        // Reset orphan-tracking when switching notes.
        EditTextView.resetDismissedOrphans()

        // Clear block-model state BEFORE touching textStorage.
        // This prevents any textDidChange triggered by the
        // storage-clearing below from seeing stale block-model state.
        documentProjection = nil
        textStorageProcessor?.blockModelActive = false
        textStorageProcessor?.sourceRendererActive = false
        textStorageProcessor?.blocks = []

        if !note.isLoaded {
            note.load()
        }

        viewDelegate?.updateCounters(note: note)

        textStorage?.setAttributedString(NSAttributedString(string: ""))

        if let length = textStorage?.length {
            textStorage?.layoutManagers.first?.invalidateDisplay(forGlyphRange: NSRange(location: 0, length: length))
            invalidateLayout()
        }

        undoManager?.removeAllActions(withTarget: self)
        registerHandoff(note: note)
        viewDelegate?.breakUndoTimer.invalidate()

        unregisterDraggedTypes()
        registerForDraggedTypes([
            NSPasteboard.note,
            NSPasteboard.PasteboardType.fileURL,
            NSPasteboard.PasteboardType.URL,
            NSPasteboard.PasteboardType.string
        ])

        if let label = editorViewController?.vcNonSelectedLabel {
            label.isHidden = true

            if note.container == .encryptedTextPack {
                label.stringValue = NSLocalizedString("Locked", comment: "")
                label.isHidden = false
            } else {
                label.stringValue = NSLocalizedString("None Selected", comment: "")
                label.isHidden = true
            }
        }

        self.note = note
        note.cacheHash = nil
        UserDefaultsManagement.lastSelectedURL = note.url

        editorViewController?.updateTitle(note: note)
        isEditable = isEditable(note: note)
        editorViewController?.editorUndoManager = note.undoManager

        typingAttributes.removeAll()
        typingAttributes[.font] = UserDefaultsManagement.noteFont

        // Ensure left margin includes gutter width when in WYSIWYG mode.
        // This prevents the "narrow left margin on startup" bug where
        // configure() ran before hideSyntax was set.
        updateTextContainerInset()

        guard let storage = textStorage else { return }

        hasUserEdits = false

        if note.isMarkdown(), let content = note.content.mutableCopy() as? NSMutableAttributedString {
            pendingRenderBlockRange = nil
            removeAllInlinePDFViews()
            removeAllInlineQuickLookViews()

            // Block-model renderer (WYSIWYG): parses markdown → Document →
            // rendered attributed string. Phase 4.4 adds the source-mode
            // fallback (`fillViaSourceRenderer`) which renders through
            // `SourceRenderer` so markers are visible + colored via
            // `SourceLayoutFragment`. The old
            // `storage.setAttributedString(note.content)` path is kept
            // as a safety fallback for the edge case where both the
            // block-model and source-mode renderers decline.
            if !fillViaBlockModel(note: note) {
                if !fillViaSourceRenderer(note: note) {
                    storage.setAttributedString(content)
                }
            }
        } else {
            // Unreachable today: `NoteType` has exactly one case
            // (`.Markdown`), so `note.isMarkdown()` is always true.
            // Kept as a safety fallback in case the type system grows
            // a new primary-content format later.
            documentProjection = nil
            storage.setAttributedString(note.content)
        }

        if highlight {
            textStorage?.highlightKeyword(search: getSearchText())
        }

        // When the block-model pipeline rendered this note, all styling
        // (paragraph styles, syntax hiding, code block rendering) is
        // already handled — skip source-mode post-processing.
        //
        // IMPORTANT: All async work (tables, PDFs) that can change layout
        // must complete BEFORE we restore scroll position. We batch them
        // into a single async block and restore scroll position at the
        // end, keeping the scroll lock held throughout.
        if documentProjection == nil {
            // Source-mode path
            if NotesTextProcessor.hideSyntax {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                          let storage = self.textStorage,
                          let processor = self.textStorageProcessor else { return }
                    let codeRanges = processor.codeBlockRanges
                    if !codeRanges.isEmpty {
                        processor.renderSpecialCodeBlocks(textStorage: storage, codeBlockRanges: codeRanges)
                    }
                    self.renderPDFsAndRestoreScroll(note: note)
                }
            } else {
                viewDelegate?.restoreScrollPosition()
            }
        } else {
            // Block-model path.
            //
            // Phase 2e T2-f (Batch N+2): `renderTables()` and the initial
            // TK2 layout pass now happen **synchronously** inside
            // `fillViaBlockModel` — before the first paint — so table
            // attachments and checkbox view providers are wired up from
            // frame 0. The remaining async work is the genuinely-heavy
            // stuff: mermaid/math bitmap generation, PDF hydration, and
            // remote image loading. Keep those async to avoid freezing
            // the UI on large notes.
            if NotesTextProcessor.hideSyntax {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    // Render mermaid/math code blocks via Document model
                    // (source-mode renderSpecialCodeBlocks can't detect
                    // language from text storage because fences are absent).
                    self.renderSpecialBlocksViaBlockModel()
                    self.renderPDFsAndRestoreScroll(note: note)
                }
            } else {
                viewDelegate?.restoreScrollPosition()
            }
        }

        needsDisplay = true
    }

    public func lockEncryptedView() {
        textStorage?.setAttributedString(NSAttributedString())
        isEditable = false

        if let label = editorViewController?.vcNonSelectedLabel {
            label.stringValue = NSLocalizedString("Locked", comment: "")
            label.isHidden = false
        }
    }

    public func clear() {
        textStorage?.setAttributedString(NSAttributedString())
        isEditable = false
        window?.title = AppDelegate.appTitle

        if let label = editorViewController?.vcNonSelectedLabel {
            label.stringValue = NSLocalizedString("None Selected", comment: "")
            label.isHidden = false
            editorViewController?.dropTitle()
        }

        self.note = nil

        if let vc = viewDelegate {
            vc.updateCounters()
        }
    }

    func getParagraphRange() -> NSRange? {
        guard let storage = textStorage else { return nil }
        let range = selectedRange()
        return storage.mutableString.paragraphRange(for: range)
    }

    func saveSelectedRange() {
        guard let note = self.note else { return }
        note.setSelectedRange(range: self.selectedRange)
    }

    func getCursorScrollFraction() -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        return CGFloat(selectedRange().location) / CGFloat(storage.length)
    }

    func loadSelectedRange() {
        guard let storage = textStorage else { return }

        if let range = self.note?.getSelectedRange(), range.upperBound <= storage.length {
            setSelectedRange(range)
            scrollToCursor()
        }
    }

    func getSearchText() -> String {
        guard let search = ViewController.shared()?.search else { return String() }

        if let editor = search.currentEditor(), editor.selectedRange.length > 0 {
            return (search.stringValue as NSString).substring(with: NSRange(0..<editor.selectedRange.location))
        }

        return search.stringValue
    }

    /// Render PDF and file attachments then restore scroll position.
    /// Called at the end of fill()'s async pipeline to ensure scroll
    /// restoration happens AFTER all layout-affecting work is done.
    private func renderPDFsAndRestoreScroll(note: Note) {
        if let storage = self.textStorage {
            let containerWidth = self.textContainer?.size.width ?? self.frame.width
            PDFAttachmentProcessor.renderPDFAttachments(
                in: storage,
                note: note,
                containerWidth: containerWidth
            )
            // Hydrate block-model image attachments (async). Harmless in
            // source mode — there are no block-model image placeholders
            // to find, so the walk is a no-op.
            ImageAttachmentHydrator.hydrate(
                textStorage: storage,
                editor: self
            )
            // Render QuickLook previews for non-image/non-PDF files
            // (.numbers, .pages, .docx, etc.)
            QuickLookAttachmentProcessor.renderQuickLookAttachments(
                in: storage,
                containerWidth: containerWidth
            )
        }
        viewDelegate?.restoreScrollPosition()
    }

    public func scrollToCursor() {
        // Phase 4.5: TK1 `ensureLayout` hint removed with the custom
        // layout-manager subclass. TK2's `NSTextLayoutManager` handles
        // viewport layout lazily — `scrollRangeToVisible` realizes the
        // fragments it needs on the fly.
        let cursorRange = NSMakeRange(self.selectedRange().location, 0)
        scrollRangeToVisible(cursorRange)
    }

    public func hasFocus() -> Bool {
        if let fr = self.window?.firstResponder, fr.isKind(of: EditTextView.self) {
            return true
        }

        return false
    }

    func removeAllInlinePDFViews() {
        for subview in subviews {
            if subview is InlinePDFView {
                subview.removeFromSuperview()
            }
        }
    }

    func removeAllInlineQuickLookViews() {
        for subview in subviews {
            if subview is InlineQuickLookView {
                subview.removeFromSuperview()
            }
        }
    }

    // Note: `removeOrphanedInlinePDFViews` and
    // `removeOrphanedInlineQuickLookViews` were deleted when
    // `InlinePDFView` / `InlineQuickLookView` migrated from the
    // TK1 `NSTextAttachmentCell.draw(...)` pattern to the TK2
    // `NSTextAttachmentViewProvider` pattern. Under view providers,
    // AppKit owns the view lifecycle — views are added and removed
    // automatically as attachments enter/leave the viewport, so
    // manual orphan cleanup is no longer necessary (and could race
    // with views Apple just attached). The legacy `InlineTableView`
    // widget that used the cell pattern was deleted in Phase 2e-T2-h;
    // tables now render via `TableLayoutFragment`, which has no
    // attachment / subview lifecycle to manage.
}
