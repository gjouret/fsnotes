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
//  the legacy pipeline runs unchanged.
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

    /// The active block-model projection, or nil if using the legacy
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
        // Use isRendering to prevent the old pipeline from processing
        // this setAttributedString.
        textStorageProcessor?.isRendering = true
        storage.setAttributedString(projection.attributed)
        textStorageProcessor?.isRendering = false

        documentProjection = projection
        textStorageProcessor?.blockModelActive = true
        // Populate the legacy blocks array so fold/unfold works
        textStorageProcessor?.syncBlocksFromProjection(projection)
        bmLog("✅ fillViaBlockModel: \(document.blocks.count) blocks, rendered \(projection.attributed.length) chars — \(note.title)")
        return true
    }

    // MARK: - Edit interception

    /// Handle a text edit through the block-model pipeline. Returns
    /// true if the edit was handled (caller should NOT proceed with
    /// the default NSTextView mutation), false if the caller should
    /// fall through to legacy behavior.
    func handleEditViaBlockModel(
        in range: NSRange,
        replacementString: String?
    ) -> Bool {
        guard var projection = documentProjection,
              let storage = textStorage,
              let replacement = replacementString else {
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

            // Apply the splice to textStorage. Guard against re-entrant
            // processing by the old pipeline.
            textStorageProcessor?.isRendering = true
            storage.beginEditing()
            storage.replaceCharacters(
                in: result.spliceRange,
                with: result.spliceReplacement
            )
            storage.endEditing()
            textStorageProcessor?.isRendering = false

            // Update projection.
            documentProjection = result.newProjection
            // Keep legacy blocks in sync so fold/unfold works
            textStorageProcessor?.syncBlocksFromProjection(result.newProjection)

            // Set cursor position.
            let cursorPos = min(result.newCursorPosition, storage.length)
            setSelectedRange(NSRange(location: cursorPos, length: 0))

            // Mark note as modified.
            note?.cacheHash = nil

            return true

        } catch {
            bmLog("⚠️ edit failed, falling back to legacy: \(error)")
            // The editing operation threw (unsupported block type,
            // cross-inline-range, etc.). Fall back to legacy pipeline
            // by clearing the projection and letting the note re-render
            // via the old path.
            clearBlockModelAndRefill()
            return false
        }
    }

    // MARK: - Save

    /// Serialize the Document back to markdown for saving. Returns
    /// the markdown string, or nil if no projection is active (caller
    /// should use the legacy save path).
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
        guard var projection = documentProjection,
              let storage = textStorage else { return false }

        do {
            let result: EditResult
            switch transition {
            case .indent:
                result = try EditingOps.indentListItem(at: storageIndex, in: projection)
            case .unindent:
                result = try EditingOps.unindentListItem(at: storageIndex, in: projection)
            case .exitToBody:
                result = try EditingOps.exitListItem(at: storageIndex, in: projection)
            case .newItem:
                // newItem is handled by the normal Return key path
                // (splitListOnNewline), not here.
                return false
            case .noOp:
                return true // Consumed the keystroke, but no mutation.
            }

            bmLog("📋 list FSM: \(transition) → splice \(result.spliceRange) → \(result.spliceReplacement.length) chars")

            textStorageProcessor?.isRendering = true
            storage.beginEditing()
            storage.replaceCharacters(in: result.spliceRange, with: result.spliceReplacement)
            storage.endEditing()
            textStorageProcessor?.isRendering = false

            documentProjection = result.newProjection
            textStorageProcessor?.syncBlocksFromProjection(result.newProjection)
            let cursorPos = min(result.newCursorPosition, storage.length)
            setSelectedRange(NSRange(location: cursorPos, length: 0))
            note?.cacheHash = nil

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

    // MARK: - Block-model formatting operations

    /// Apply an EditResult splice to textStorage and update the
    /// projection. Shared by all block-model formatting operations.
    private func applyBlockModelResult(_ result: EditResult) {
        guard let storage = textStorage else { return }

        textStorageProcessor?.isRendering = true
        storage.beginEditing()
        storage.replaceCharacters(
            in: result.spliceRange,
            with: result.spliceReplacement
        )
        storage.endEditing()
        textStorageProcessor?.isRendering = false

        documentProjection = result.newProjection
        textStorageProcessor?.syncBlocksFromProjection(result.newProjection)

        let cursorPos = min(result.newCursorPosition, storage.length)
        setSelectedRange(NSRange(location: cursorPos, length: 0))
        note?.cacheHash = nil
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
            applyBlockModelResult(result)
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
            applyBlockModelResult(result)
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
            applyBlockModelResult(result)
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
            applyBlockModelResult(result)
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
            applyBlockModelResult(result)
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
            applyBlockModelResult(result)
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
            applyBlockModelResult(result)
            return true
        } catch {
            bmLog("⚠️ toggleTodoCheckbox failed: \(error)")
            return false
        }
    }

    // MARK: - Fallback

    /// Clear the block-model projection and re-fill the note via the
    /// legacy pipeline. Used when the block-model pipeline encounters
    /// an unsupported operation.
    private func clearBlockModelAndRefill() {
        documentProjection = nil
        textStorageProcessor?.blockModelActive = false
        if let note = self.note {
            // Re-set textStorage to raw markdown and let the old
            // pipeline process it.
            textStorageProcessor?.isRendering = true
            if let content = note.content.mutableCopy() as? NSMutableAttributedString {
                textStorage?.setAttributedString(content)
            }
            textStorageProcessor?.isRendering = false
            // Trigger legacy processing.
            textStorageProcessor?.isRendering = false
        }
    }
}
