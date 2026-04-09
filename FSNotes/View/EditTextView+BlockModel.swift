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

        // Use cached Document if available, otherwise parse from raw markdown.
        let document: Document
        if let cached = note.cachedDocument {
            document = cached
        } else {
            let markdown = note.content.string
            document = MarkdownParser.parse(markdown)
            note.cachedDocument = document
        }

        // Render via the block-model pipeline.
        let bodyFont = UserDefaultsManagement.noteFont
        let codeFont = UserDefaultsManagement.codeFont
        let projection = DocumentProjection(
            document: document,
            bodyFont: bodyFont,
            codeFont: codeFont
        )

        // Set the rendered attributed string into textStorage.
        // Use isRendering to prevent the source-mode pipeline from
        // processing this setAttributedString.
        textStorageProcessor?.isRendering = true
        storage.setAttributedString(projection.attributed)
        textStorageProcessor?.isRendering = false

        documentProjection = projection
        textStorageProcessor?.blockModelActive = true
        // Populate the source-mode blocks array so fold/unfold works
        textStorageProcessor?.syncBlocksFromProjection(projection)
        bmLog("✅ fillViaBlockModel: \(document.blocks.count) blocks, rendered \(projection.attributed.length) chars — \(note.title)")
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
        guard let storage = textStorage else { return }

        // Capture state for undo BEFORE mutating.
        guard let oldProjection = documentProjection else { return }
        let oldCursorRange = selectedRange()

        // Validate splice range against current storage.
        let spliceEnd = result.spliceRange.location + result.spliceRange.length
        guard spliceEnd <= storage.length else {
            bmLog("⚠️ splice range \(result.spliceRange) exceeds storage.length \(storage.length)")
            return
        }

        textStorageProcessor?.isRendering = true
        storage.beginEditing()
        storage.replaceCharacters(
            in: result.spliceRange,
            with: result.spliceReplacement
        )
        storage.endEditing()

        // Update projection.
        documentProjection = result.newProjection
        textStorageProcessor?.syncBlocksFromProjection(result.newProjection)

        // Set cursor without triggering an implicit scroll.
        // The 1-arg setSelectedRange(_:) calls scrollRangeToVisible;
        // the 3-arg variant does not.
        let cursorPos = min(result.newCursorPosition, storage.length)
        setSelectedRange(NSRange(location: cursorPos, length: 0), affinity: .downstream, stillSelecting: false)

        // Notify NSTextView that text changed so the layout manager
        // updates and the display refreshes. Keep isRendering = true
        // through this call to suppress scrollRangeToVisible — the
        // layout manager triggers implicit scrolls during didChangeText.
        didChangeText()
        textStorageProcessor?.isRendering = false

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
            return false
        }

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
                result = try EditingOps.insert(replacement, at: range.location, in: projection)
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
                // Replacement: delete then insert.
                let afterDelete = try EditingOps.delete(range: range, in: projection)
                projection = afterDelete.newProjection
                result = try EditingOps.insert(replacement, at: range.location, in: projection)
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

    // MARK: - Block-model formatting operations

    /// Apply an EditResult splice to textStorage and update the
    /// projection. Shared by all block-model formatting operations.
    /// The actionName parameter is used for undo menu labeling.
    func applyBlockModelResult(_ result: EditResult, actionName: String = "Format") {
        guard textStorage != nil, documentProjection != nil else { return }
        applyEditResultWithUndo(result, actionName: actionName)
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

    private func toggleInlineTraitViaBlockModel(_ trait: EditingOps.InlineTrait) -> Bool {
        guard let projection = documentProjection else { return false }
        let sel = selectedRange()
        guard sel.length > 0 else { return false }

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
}
