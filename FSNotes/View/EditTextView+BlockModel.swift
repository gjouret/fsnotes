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

func bmLog(_ message: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "[\(df.string(from: Date()))] \(message)\n"
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
    private func applyEditResultWithUndo(
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

        // Mark that the user has made an edit — enables save().
        hasUserEdits = true

        textStorageProcessor?.isRendering = true
        storage.beginEditing()
        storage.replaceCharacters(
            in: result.spliceRange,
            with: result.spliceReplacement
        )
        storage.endEditing()
        
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

        // Notify NSTextView that text changed so the layout manager
        // updates, the display refreshes, and the delegate saves.
        didChangeText()

        // Force the layout manager to re-evaluate attributes and redraw.
        // Use changeInLength: 0 because the storage has already been
        // modified — the layout manager processed the length change
        // during replaceCharacters. Passing it again double-counts it,
        // corrupting glyph positions after the edit.
        if let lm = layoutManager {
            let fullRange = NSRange(location: 0, length: storage.length)
            lm.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            lm.ensureLayout(forCharacterRange: fullRange)
            let glyphRange = lm.glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
            lm.invalidateDisplay(forGlyphRange: glyphRange)
        }

        needsDisplay = true

        // Clean up orphaned inline PDF subviews after edits that may
        // have removed attachment characters from the text storage.
        removeOrphanedInlinePDFViews()
        removeOrphanedInlineQuickLookViews()

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
                if !traits.isEmpty && replacement != "\n" {
                    // Apply pending inline traits to the inserted text.
                    // Suppress trait clearing during our cursor update.
                    suppressPendingTraitClear = true
                    bmLog("➡️ Calling EditingOps.insertWithTraits('\(replacement)', traits: \(traits), at: \(range.location))")
                    result = try EditingOps.insertWithTraits(replacement, traits: traits, at: range.location, in: projection)
                } else {
                    bmLog("➡️ Calling EditingOps.insert('\(replacement)', at: \(range.location))")
                    result = try EditingOps.insert(replacement, at: range.location, in: projection)
                    // Clear pending traits on newline.
                    if replacement == "\n" {
                        pendingInlineTraits = []
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
        // Only intercept single-char backspace at the start of inline content.
        guard range.length == 1 else { return false }

        let cursorPos = range.location + range.length
        guard ListEditingFSM.isAtHomePosition(storageIndex: cursorPos, in: projection) else {
            return false
        }

        let state = ListEditingFSM.detectState(storageIndex: cursorPos, in: projection)
        guard case .listItem = state else { return false }

        let transition = ListEditingFSM.transition(state: state, action: .deleteAtHome)
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

    /// Update `typingAttributes` to reflect the pending inline traits.
    /// This ensures the toolbar shows the correct formatting state and
    /// the user gets visual feedback that bold/italic/etc is active.
    private func updateTypingAttributesForPendingTraits() {
        var attrs = typingAttributes
        let traits = pendingInlineTraits
        let baseFont = (attrs[.font] as? NSFont) ?? UserDefaultsManagement.noteFont

        // Reset font traits first, then apply pending ones.
        var descriptor = baseFont.fontDescriptor
        var symbolicTraits = descriptor.symbolicTraits

        if traits.contains(.bold) {
            symbolicTraits.insert(.bold)
        }
        if traits.contains(.italic) {
            symbolicTraits.insert(.italic)
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
            if traits.contains(trait) {
                traits.remove(trait)
            } else {
                traits.insert(trait)
            }
            pendingInlineTraits = traits
            bmLog("🎨 pendingInlineTraits toggled \(trait): now \(traits)")
            // Update typing attributes to reflect the pending trait visually.
            updateTypingAttributesForPendingTraits()
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
    /// Returns true if handled.
    func changeHeadingLevelViaBlockModel(_ level: Int) -> Bool {
        guard let projection = documentProjection else { return false }
        let cursorPos = selectedRange().location

        do {
            let result = try EditingOps.changeHeadingLevel(
                level, at: cursorPos, in: projection
            )
            bmLog("📝 changeHeadingLevel(\(level)): splice \(result.spliceRange)")
            applyBlockModelResult(result, actionName: "Heading")
            return true
        } catch {
            bmLog("⚠️ changeHeadingLevel failed: \(error)")
            return false
        }
    }

    /// Toggle list via the block model.
    func toggleListViaBlockModel(marker: String = "-") -> Bool {
        guard let projection = documentProjection else { return false }
        let cursorPos = selectedRange().location

        do {
            let result = try EditingOps.toggleList(
                marker: marker, at: cursorPos, in: projection
            )
            bmLog("📋 toggleList(\(marker)): splice \(result.spliceRange)")
            applyBlockModelResult(result, actionName: "List")
            return true
        } catch {
            bmLog("⚠️ toggleList failed: \(error)")
            return false
        }
    }

    /// Toggle blockquote via the block model.
    func toggleBlockquoteViaBlockModel() -> Bool {
        guard let projection = documentProjection else { return false }
        let cursorPos = selectedRange().location

        do {
            let result = try EditingOps.toggleBlockquote(
                at: cursorPos, in: projection
            )
            bmLog("💬 toggleBlockquote: splice \(result.spliceRange)")
            applyBlockModelResult(result, actionName: "Blockquote")
            return true
        } catch {
            bmLog("⚠️ toggleBlockquote failed: \(error)")
            return false
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
    /// Converts paragraph → todo list, regular list ↔ todo list.
    func toggleTodoViaBlockModel() -> Bool {
        guard let projection = documentProjection else { return false }
        let cursorPos = selectedRange().location

        do {
            let result = try EditingOps.toggleTodoList(
                at: cursorPos, in: projection
            )
            bmLog("☐ toggleTodoList: splice \(result.spliceRange)")
            applyBlockModelResult(result, actionName: "Todo List")
            return true
        } catch {
            bmLog("⚠️ toggleTodoList failed: \(error)")
            return false
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

                    // Force full-document layout invalidation. The replacement
                    // changes storage length dramatically (e.g., 472 chars → 1),
                    // and without explicit invalidation the layout manager may
                    // position subsequent glyphs at stale offsets, causing the
                    // attachment's background to visually overlap adjacent blocks.
                    if let lm = self.layoutManager {
                        let fullRange = NSRange(location: 0, length: storage.length)
                        lm.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
                        lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
                        lm.ensureLayout(forCharacterRange: fullRange)
                    }

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
                    // It may have shifted due to earlier replacements.
                    var currentRange: NSRange?
                    storage.enumerateAttribute(.inlineMathSource, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
                        if let val = value as? String, val == source {
                            currentRange = range
                            stop.pointee = true
                        }
                    }

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

                    // Layout invalidation (same pattern as code block replacement).
                    if let lm = self.layoutManager {
                        let fullRange = NSRange(location: 0, length: storage.length)
                        lm.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
                        lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
                        lm.ensureLayout(forCharacterRange: fullRange)
                    }

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
                    var currentRange: NSRange?
                    storage.enumerateAttribute(.displayMathSource, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
                        if let val = value as? String, val == source {
                            currentRange = range
                            stop.pointee = true
                        }
                    }

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

                    // Layout invalidation
                    if let lm = self.layoutManager {
                        let fullRange = NSRange(location: 0, length: storage.length)
                        lm.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
                        lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
                        lm.ensureLayout(forCharacterRange: fullRange)
                    }

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