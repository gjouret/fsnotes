//
//  EditTextView+Input.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import AppKit
import Carbon.HIToolbox

extension EditTextView {
    override func keyDown(with event: NSEvent) {
        defer {
            saveSelectedRange()
        }

        // Escape clears an image selection (handles drawn by
        // ImageSelectionHandleDrawer). Fall through to super if there's
        // no selection to clear so other consumers still see the key.
        if event.keyCode == 53 /* kVK_Escape */, selectedImageRange != nil {
            selectedImageRange = nil
            return
        }

        if let characters = event.characters, characters == "`" {
            // Route through insertText (not super) so that
            // shouldChangeText → block model can intercept.
            insertText("`", replacementRange: selectedRange())
            return
        }

        guard !(
            event.modifierFlags.contains(.shift) &&
            [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow].contains(Int(event.keyCode))
        ) else {
            super.keyDown(with: event)
            return
        }

        guard let note = self.note else { return }

        if UserDefaultsManagement.autocloseBrackets,
           handleAutocloseBrackets(for: event) {
            return
        }

        if event.keyCode == kVK_Tab && !hasMarkedText() {
            breakUndoCoalescing()

            // Phase 2e-T2-d — when the cursor is in a TableElement,
            // Tab / Shift-Tab must move to the next / previous cell
            // via `doCommand(by:)` → `handleTableNavCommand`, NOT be
            // consumed by the list FSM or the indent-spaces path.
            // Let super.keyDown dispatch the `insertTab:` /
            // `insertBacktab:` selector so our doCommand override
            // picks it up.
            if cursorIsInTableElement() {
                super.keyDown(with: event)
                return
            }

            // Block-model pipeline: route Tab/Shift-Tab through
            // the list editing FSM when the cursor is in a list block.
            if let projection = documentProjection {
                let cursorPos = selectedRange().location
                let state = ListEditingFSM.detectState(storageIndex: cursorPos, in: projection)
                
                // DEBUG
                let logPath = "/tmp/fsnotes_tab_debug.log"
                let debugMsg = "TAB DEBUG: cursorPos=\(cursorPos), state=\(state)\n"
                try? debugMsg.write(toFile: logPath, atomically: true, encoding: .utf8)
                
                if case .listItem = state {
                    let action: ListEditingFSM.Action = NSEvent.modifierFlags.contains(.shift) ? .shiftTab : .tab
                    let transition = ListEditingFSM.transition(state: state, action: action)
                    
                    // DEBUG
                    if let handle = FileHandle(forWritingAtPath: logPath) {
                        handle.seekToEndOfFile()
                        handle.write("TAB DEBUG: action=\(action), transition=\(transition)\n".data(using: .utf8)!)
                        handle.closeFile()
                    }
                    
                    if handleListTransition(transition, at: cursorPos) {
                        // DEBUG
                        if let handle = FileHandle(forWritingAtPath: logPath) {
                            handle.seekToEndOfFile()
                            handle.write("TAB DEBUG: handled successfully\n".data(using: .utf8)!)
                            handle.closeFile()
                        }
                        breakUndoCoalescing()
                        return
                    }
                    
                    // DEBUG
                    if let handle = FileHandle(forWritingAtPath: logPath) {
                        handle.seekToEndOfFile()
                        handle.write("TAB DEBUG: handleListTransition returned false\n".data(using: .utf8)!)
                        handle.closeFile()
                    }
                }
            }

            let formatter = TextFormatter(textView: self, note: note)
            if formatter.isListParagraph() {
                if NSEvent.modifierFlags.contains(.shift) {
                    formatter.unTab()
                } else {
                    formatter.tab()
                }

                breakUndoCoalescing()
                return
            }

            if UserDefaultsManagement.indentUsing == 0x01 {
                let tab = TextFormatter.getAttributedCode(string: "  ")
                insertText(tab, replacementRange: selectedRange())
                breakUndoCoalescing()
                return
            }

            if UserDefaultsManagement.indentUsing == 0x02 {
                let tab = TextFormatter.getAttributedCode(string: "    ")
                insertText(tab, replacementRange: selectedRange())
                breakUndoCoalescing()
                return
            }

            super.keyDown(with: event)
            return
        }

        if event.keyCode == kVK_Return && !hasMarkedText() && isEditable {
            breakUndoCoalescing()

            // Phase 2e-T2-d — Return inside a TableElement is a no-op
            // at this slice (T2-e wires `<br>` insertion). Let
            // super.keyDown dispatch `insertNewline:` so our
            // `doCommand(by:)` override can swallow it with a log.
            if cursorIsInTableElement() {
                super.keyDown(with: event)
                return
            }

            // Block-model pipeline: route Return through EditingOps
            // which handles paragraph splits, list continuation, and
            // empty-item exit via the FSM — all as Document operations.
            if documentProjection != nil {
                if handleEditViaBlockModel(
                    in: selectedRange(),
                    replacementString: "\n"
                ) {
                    breakUndoCoalescing()
                    return
                }
            }

            let formatter = TextFormatter(textView: self, note: note)
            formatter.newLine()
            breakUndoCoalescing()
            return
        }

        if event.characters?.unicodeScalars.first == "o" && event.modifierFlags.contains(.command) {
            guard let storage = textStorage else { return }

            var location = selectedRange().location
            if location == storage.length && location > 0 {
                location -= 1
            }

            if storage.length > location,
               let link = textStorage?.attribute(.link, at: location, effectiveRange: nil) as? String {
                if link.isValidEmail(), let mail = URL(string: "mailto:\(link)") {
                    NSWorkspace.shared.open(mail)
                } else if let url = URL(string: link) {
                    _ = try? NSWorkspace.shared.open(url, options: .default, configuration: [:])
                }
            }
            return
        }

        super.keyDown(with: event)
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard let note = self.note else {
            return super.shouldChangeText(in: range, replacementString: replacementString)
        }

        // Block-model pipeline: intercept the edit and apply it via
        // EditingOps. Returns false to prevent NSTextView from doing
        // its own mutation (we've already applied the splice).
        if handleEditViaBlockModel(in: range, replacementString: replacementString) {
            return false
        }

        // Block model is active but couldn't handle this specific edit
        // (e.g. nil replacementString from a click). Don't fall through
        // to source-mode processing — that would corrupt the rendered state.
        if textStorageProcessor?.blockModelActive == true {
            return super.shouldChangeText(in: range, replacementString: replacementString)
        }

        // Source/markdown mode: source-mode processing path.
        hasUserEdits = true
        note.resetAttributesCache()
        scheduleTagScan(for: note)
        deleteUnusedImages(checkRange: range)
        resetTypingAttributes()

        return super.shouldChangeText(in: range, replacementString: replacementString)
    }

    // MARK: - Delete commands — Phase 5a bypass fix
    //
    // AppKit's default `deleteBackward:` / `deleteForward:` call through
    // the private `-[NSTextView _userReplaceRange:withString:]` path,
    // which mutates `NSTextContentStorage` directly *without* calling
    // `shouldChangeText(in:replacementString:)`. That means the block-
    // model gatekeeper at line 187 never runs, `handleEditViaBlockModel`
    // never fires, and no `StorageWriteGuard` scope is active when the
    // storage character delta hits `TextStorageProcessor.didProcessEditing`
    // — tripping the Phase 5a DEBUG assertion (commit `c11e06c`).
    //
    // Fix: override both delete commands and route them through
    // `handleEditViaBlockModel` with an empty replacement string. For
    // multi-byte graphemes (emoji, combining accents, regional indicator
    // sequences) we use `rangeOfComposedCharacterSequence` so the delete
    // target is the full grapheme cluster, matching AppKit's default
    // behaviour byte-for-byte.
    //
    // If `documentProjection` is nil (source mode or pre-load state) or
    // `handleEditViaBlockModel` refuses the edit, we fall through to
    // `super` — which still executes the bypass in edge cases, but at
    // least the common WYSIWYG path is covered. Post-5e, the IME
    // composition exemption wraps this too (composition deletes run
    // inside `compositionSession.isActive`, which the assertion allows).

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        let deleteRange: NSRange
        if sel.length > 0 {
            deleteRange = sel
        } else if sel.location > 0,
                  let storage = textStorage {
            // Grapheme-cluster boundary: NSString's
            // rangeOfComposedCharacterSequence(at:) returns the full
            // composed range containing the character at the given
            // index. Passing `sel.location - 1` picks up the character
            // immediately before the caret, widened to its grapheme.
            let ns = storage.string as NSString
            deleteRange = ns.rangeOfComposedCharacterSequence(at: sel.location - 1)
        } else {
            // Caret at document start — nothing to delete.
            return
        }

        if documentProjection != nil,
           handleEditViaBlockModel(in: deleteRange, replacementString: "") {
            return
        }

        // Source mode or refused — fall through to default.
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        let deleteRange: NSRange
        let storageLen = textStorage?.length ?? 0
        if sel.length > 0 {
            deleteRange = sel
        } else if sel.location < storageLen,
                  let storage = textStorage {
            let ns = storage.string as NSString
            deleteRange = ns.rangeOfComposedCharacterSequence(at: sel.location)
        } else {
            // Caret at document end — nothing to delete.
            return
        }

        if documentProjection != nil,
           handleEditViaBlockModel(in: deleteRange, replacementString: "") {
            return
        }

        super.deleteForward(sender)
    }

    private func handleAutocloseBrackets(for event: NSEvent) -> Bool {
        let brackets: [String: String] = [
            "(": ")",
            "[": "]",
            "{": "}",
            "\"": "\""
        ]

        guard let character = event.characters else {
            return false
        }

        let closingBrackets = Array(brackets.values)
        if closingBrackets.contains(character) {
            let currentRange = selectedRange()
            if currentRange.length == 0,
               let storage = textStorage,
               currentRange.location < storage.length {
                let nextCharRange = NSRange(location: currentRange.location, length: 1)
                let nextCharString = storage.attributedSubstring(from: nextCharRange).string

                if nextCharString == character {
                    setSelectedRange(NSMakeRange(currentRange.location + 1, 0))
                    return true
                }
            }
        }

        guard let closingBracket = brackets[character] else {
            return false
        }

        if selectedRange().length > 0 {
            let before = NSMakeRange(selectedRange().lowerBound, 0)
            self.insertText(character, replacementRange: before)
            let after = NSMakeRange(selectedRange().upperBound, 0)
            self.insertText(closingBracket, replacementRange: after)
        } else {
            // Insert both brackets via insertText (not super.keyDown)
            // so that shouldChangeText → block model can intercept.
            let pair = character + closingBracket
            self.insertText(pair, replacementRange: selectedRange())
            self.moveBackward(self)
        }

        return true
    }

    // MARK: - Phase 5e: IME / composition overrides
    //
    // AppKit's default `NSTextView` implements `NSTextInputClient` and
    // handles marked-text composition by writing directly to
    // `NSTextContentStorage` — a path that bypasses `shouldChangeText`
    // and `applyDocumentEdit`. In WYSIWYG block-model mode this trips
    // the Phase 5a DEBUG assertion on every marked-text update because
    // no `StorageWriteGuard` scope is active.
    //
    // The clean fix is a single, sanctioned architectural exemption:
    // while a `CompositionSession` is active AND the mutation lands
    // inside `markedRange`, the 5a assertion's `compositionAllows`
    // clause lets the write through. Commit / abort of the session
    // produces exactly one `EditContract` that flows through the
    // canonical `applyEditResultWithUndo` path — so the `Document`
    // sees one atomic edit per composition, not one per keystroke.
    //
    // Three override sites:
    //   1. `setMarkedText(_:selectedRange:replacementRange:)` — AppKit
    //      invokes this for every marked-text update. We drive session
    //      entry/update from here.
    //   2. `unmarkText()` — standard commit path. IME has selected a
    //      final candidate; we build ONE `EditingOps.replace` contract
    //      and route through `applyEditResultWithUndo`.
    //   3. `insertText(_:replacementRange:)` — if `replacementRange`
    //      targets the marked range (or is `{NSNotFound, 0}`) during an
    //      active session, same commit path as #2. Otherwise standard
    //      typing path.
    //
    // Commits 2, 4, 5 land the overrides, commit flow, and edge-case
    // hardening respectively. Commit 2 (this commit) wires entry /
    // update / placeholder commit stubs that delegate to super for the
    // actual storage mutation — commit 4 replaces the stubs with the
    // full `applyEditResultWithUndo`-backed flow. The 5a DEBUG
    // assertion still trips during Kotoeri on this commit; commit 3
    // relaxes the assertion.

    /// Called by AppKit every time the input method updates the marked
    /// (uncommitted) run. A marked string is visually rendered at the
    /// insertion point / over the selection; the user has not yet
    /// committed a final character sequence.
    ///
    /// Behaviour:
    ///   - First call with non-empty `string` and no active session →
    ///     enter composition: capture `anchorCursor`, snapshot fold
    ///     state, call `super` to let AppKit do the marked-text storage
    ///     write, then record the post-call marked range (which is what
    ///     `super` produced via `markedRange()`).
    ///   - Subsequent calls while active → update: call `super`, then
    ///     refresh `markedRange`. Anchor cursor does not move.
    ///   - Empty `string` while active → abort (delegated to
    ///     `unmarkText()` via `super`).
    ///
    /// Precondition: main thread only (NSTextInputClient is documented
    /// main-thread-only).
    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        let markedString = (string as? NSAttributedString)?.string
            ?? (string as? String) ?? ""

        // Entry path: no active session, non-empty marked string.
        if !compositionSession.isActive && !markedString.isEmpty {
            beginCompositionSession(replacementRange: replacementRange)
        }

        super.setMarkedText(
            string, selectedRange: selectedRange,
            replacementRange: replacementRange
        )

        // Refresh the recorded marked range to match what AppKit actually
        // wrote. `super` may have normalized `replacementRange` (e.g.
        // `{NSNotFound, 0}` → current selection) before committing it to
        // storage; `markedRange()` reports the authoritative post-call
        // range.
        if compositionSession.isActive {
            var session = compositionSession
            session.markedRange = markedRange()
            compositionSession = session
        }
    }

    /// Called by AppKit when the user commits the marked run (return /
    /// space / candidate click / non-accent key after dead-key, etc.).
    ///
    /// Commit 2 stub: delegates to `super` and clears the session. The
    /// session-clear path will be replaced in commit 4 with the
    /// `applyEditResultWithUndo`-backed commit that produces one
    /// `EditContract` for the final text.
    override func unmarkText() {
        if compositionSession.isActive {
            super.unmarkText()
            endCompositionSessionStubbed()
        } else {
            super.unmarkText()
        }
    }

    /// Called by AppKit for the standard typing path AND as one of the
    /// commit entry points for composition (when the IME delivers a
    /// finalized string that should replace the marked run).
    ///
    /// While composition is active with a `replacementRange` targeting
    /// the marked range (or `{NSNotFound, 0}`, per NSTextInputClient
    /// convention for "use the current marked range"), treat this as a
    /// commit and delegate to `unmarkText`-equivalent flow. Otherwise
    /// fall through to `super` — the normal typing path.
    ///
    /// Commit 2 stub: delegates to `super`. Commit 4 routes the commit
    /// path through `applyEditResultWithUndo`.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if compositionSession.isActive {
            let targetsMarkedRange =
                replacementRange.location == NSNotFound ||
                NSEqualRanges(replacementRange, compositionSession.markedRange)
            if targetsMarkedRange {
                super.insertText(string, replacementRange: replacementRange)
                endCompositionSessionStubbed()
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Session-entry helper. Capture pre-composition state (anchor
    /// cursor, fold snapshot) and mark the session active with a
    /// provisional `markedRange` derived from `replacementRange`
    /// (refreshed from `markedRange()` post-super-call by the caller).
    private func beginCompositionSession(replacementRange: NSRange) {
        let currentSel = selectedRange()
        let provisionalMarked: NSRange
        if replacementRange.location == NSNotFound {
            // NSTextInputClient convention: {NSNotFound, 0} means "use
            // the current selection as the replacement range."
            provisionalMarked = currentSel
        } else {
            provisionalMarked = replacementRange
        }

        let anchorCursor: DocumentCursor
        if let projection = documentProjection {
            anchorCursor = projection.cursor(
                atStorageIndex: provisionalMarked.location
            )
        } else {
            // No projection — fall back to a zero-origin anchor. Source
            // mode doesn't use the composition machinery for its
            // storage-is-truth contract, so the anchor here is
            // diagnostic only.
            anchorCursor = DocumentCursor(blockIndex: 0, inlineOffset: 0)
        }

        // Snapshot fold state so commit 5's edge-case handler can
        // restore folds that IME placement ignored.
        if let cachedFolds = note?.cachedFoldState {
            preSessionFoldState = cachedFolds
        }

        compositionSession = CompositionSession(
            anchorCursor: anchorCursor,
            markedRange: provisionalMarked,
            isActive: true,
            pendingEdits: [],
            sessionStart: Date()
        )
    }

    /// Commit-2 stub end-of-session. Clears `isActive` and resets the
    /// session to `.inactive`. Commit 4 replaces this with the full
    /// `applyEditResultWithUndo`-backed commit path that builds one
    /// `EditContract` from the final string and drains `pendingEdits`.
    private func endCompositionSessionStubbed() {
        compositionSession = .inactive
        preSessionFoldState = nil
    }
}
