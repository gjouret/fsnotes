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
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        super.keyDown(with: event)
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        // Phase 5e: during `setMarkedText`, AppKit routes its storage
        // write through `shouldChangeText` → `insertText`. Do NOT
        // fold marked-text writes into the block model — they are
        // transient composition state that gets committed as ONE
        // EditContract in `commitCompositionSession`. Returning true
        // lets super do its default marked-text storage write; the
        // 5a DEBUG assertion's `compositionAllows` clause permits
        // the write because the session is active and the range is
        // inside `markedRange`.
        if setMarkedTextInFlight {
            return super.shouldChangeText(in: range, replacementString: replacementString)
        }

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
        let markedUTF16Length = (markedString as NSString).length

        // Entry path: no active session, non-empty marked string.
        if !compositionSession.isActive && !markedString.isEmpty {
            beginCompositionSession(replacementRange: replacementRange)
        }

        // Capture the start location of the eventual write BEFORE super
        // runs. Rationale: `markedRange()` is unreliable in offscreen
        // test contexts (returns NSNotFound) and in some TK2 layouts;
        // we track the range ourselves so commit/abort have an
        // authoritative range to revert. The start location is the
        // session's markedRange.location (held stable across updates),
        // or the current selection if session just started with a
        // `{NSNotFound, 0}` replacementRange.
        let sessionStart: Int
        if compositionSession.isActive {
            sessionStart = compositionSession.markedRange.location
        } else {
            // About to become inactive — empty marked string while
            // already inactive; nothing to track.
            sessionStart = selectedRange.location
        }

        // Re-entrance guard: AppKit's default `NSTextView.setMarkedText`
        // may internally call `insertText(_:replacementRange:)` to do
        // the actual storage write. Our `insertText` override must not
        // interpret that internal call as a commit.
        let priorFlag = setMarkedTextInFlight
        setMarkedTextInFlight = true
        defer { setMarkedTextInFlight = priorFlag }

        // Expand `session.markedRange` to cover the full run super is
        // about to write, so the 5a `compositionAllows` exemption
        // permits the intermediate storage writes that fire during
        // super's internal insertText. The length reflects what
        // super will leave in storage; location stays at sessionStart.
        if compositionSession.isActive {
            var session = compositionSession
            session.markedRange = NSRange(
                location: sessionStart, length: markedUTF16Length
            )
            compositionSession = session
        }

        super.setMarkedText(
            string, selectedRange: selectedRange,
            replacementRange: replacementRange
        )

        // Refresh the recorded marked range. We compute the range
        // ourselves (`sessionStart` + `markedUTF16Length`) rather than
        // reading `markedRange()`:
        //
        //   - In the live app, NSTextView has already performed the
        //     storage replace via its NSTextInputClient plumbing
        //     before returning from super. Our computed range matches
        //     what was just written.
        //
        //   - In offscreen test contexts, `markedRange()` returns
        //     unreliable values (NSNotFound, or a stale {0, 0}) because
        //     the NSTextInputContext is not hooked up. Computing the
        //     range ourselves keeps the session authoritative without
        //     requiring a real input context.
        //
        // The anchor location for a composition stays stable across
        // updates (`sessionStart` = the location captured at session
        // entry); only the length changes as the user refines the
        // marked run.
        if compositionSession.isActive {
            var session = compositionSession
            session.markedRange = NSRange(
                location: sessionStart, length: markedUTF16Length
            )
            compositionSession = session
        }
    }

    /// Called by AppKit when the user commits the marked run (return /
    /// space / candidate click / non-accent key after dead-key, etc.).
    /// The committed final characters are already in storage at
    /// `session.markedRange` after `super.unmarkText()` returns.
    ///
    /// Flow:
    ///   1. Capture `session` (so we can read its markedRange after
    ///      super potentially mutates `markedRange()`).
    ///   2. Read `finalString` = storage substring at markedRange.
    ///   3. Call super (unmarks — keeps the committed characters as
    ///      plain text).
    ///   4. Route through the canonical commit path: revert storage
    ///      to the pre-marked state, clear the session, then apply
    ///      the committed text via `EditingOps.insert` +
    ///      `applyEditResultWithUndo` — one atomic undo step.
    override func unmarkText() {
        guard compositionSession.isActive else {
            super.unmarkText()
            return
        }
        let session = compositionSession
        // Capture finalString BEFORE super runs — super's behavior is
        // implementation-defined, but in practice it leaves the marked
        // characters in storage and clears only the "marked" flag.
        let finalString = readFinalString(at: session.markedRange)
        super.unmarkText()
        commitCompositionSession(session: session, finalString: finalString)
    }

    /// Called by AppKit for the standard typing path AND as the
    /// commit entry point when the IME delivers a finalized string
    /// that should replace the marked run (candidate click, dead-key
    /// + next letter).
    ///
    /// While composition is active with a `replacementRange` targeting
    /// the marked range (or `{NSNotFound, 0}`, per NSTextInputClient
    /// convention for "use the current marked range"), treat this as
    /// a commit: finalString comes from the `string` argument, not
    /// from storage. We intercept BEFORE super runs so AppKit doesn't
    /// do its own marked-text-replace storage write (that would trip
    /// 5a once the session is cleared below).
    ///
    /// Normal typing (no active session) flows unchanged through super.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Re-entrance: AppKit's `setMarkedText` may internally call
        // `insertText` to perform the marked-text storage write.
        // During setMarkedText the `setMarkedTextInFlight` flag is
        // set; pass through to super so it can do its work without
        // us mistakenly interpreting the write as a commit.
        if setMarkedTextInFlight {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        if compositionSession.isActive {
            let targetsMarkedRange =
                replacementRange.location == NSNotFound ||
                NSEqualRanges(replacementRange, compositionSession.markedRange)
            if targetsMarkedRange {
                let session = compositionSession
                let finalString = (string as? NSAttributedString)?.string
                    ?? (string as? String) ?? ""
                // Commit path — build the final edit ourselves; don't
                // let super write the final characters into storage
                // directly. `commitCompositionSession` reverts the
                // marked-run storage and routes through the canonical
                // 5a-authorized path.
                commitCompositionSession(session: session, finalString: finalString)
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

    /// Read the final string from storage at `range`. Returns the
    /// empty string when the range is out-of-bounds or storage is
    /// torn down.
    private func readFinalString(at range: NSRange) -> String {
        guard let storage = textStorage else { return "" }
        let end = range.location + range.length
        guard range.location >= 0, end <= storage.length else { return "" }
        if range.length == 0 { return "" }
        return (storage.string as NSString).substring(with: range)
    }

    /// End-of-session canonical commit.
    ///
    /// Steps:
    ///   1. Revert the marked-run storage back to empty at
    ///      `session.markedRange`, so `NSTextContentStorage` matches
    ///      `documentProjection` (which never saw the marked updates
    ///      — Document is still in its pre-composition state).
    ///   2. Clear the composition session (both `compositionSession`
    ///      and `preSessionFoldState`).
    ///   3. If `finalString` is non-empty, route one
    ///      `EditingOps.insert` call through `applyEditResultWithUndo`
    ///      — the canonical Phase 5a-authorized path. One `EditContract`,
    ///      one undo entry, one journaled edit per committed composition.
    ///   4. Drain `session.pendingEdits` (no-op in commit 4 — the
    ///      queue is populated only if external writers are deferred,
    ///      which requires commit 4's applyEditResultWithUndo-entry
    ///      guard).
    ///
    /// Abort case (`finalString.isEmpty`): steps 1 + 2 only. Document
    /// is unchanged, so no undo entry is created. Matches the
    /// "composition abort leaves no undo trace" contract in the 5e
    /// brief §5.3.
    private func commitCompositionSession(
        session: CompositionSession,
        finalString: String
    ) {
        guard let storage = textStorage else {
            compositionSession = .inactive
            preSessionFoldState = nil
            return
        }

        let revertRange = clampedRange(session.markedRange, to: storage.length)
        let insertLocation = revertRange.location

        // Step 1: revert marked-run storage. This edit lands inside
        // `session.markedRange` while composition is still active, so
        // the 5a `compositionAllows` exemption permits it. We don't
        // wrap in `StorageWriteGuard.performingLegacyStorageWrite` —
        // this is the sanctioned exemption path, not a legacy bypass.
        if revertRange.length > 0 {
            storage.beginEditing()
            storage.replaceCharacters(in: revertRange, with: "")
            storage.endEditing()
        }

        // Step 2: clear session BEFORE the applyEditResultWithUndo
        // call below. The canonical edit path runs under
        // `StorageWriteGuard.performingApplyDocumentEdit` — composition
        // must no longer be active, or the storage-writer would be
        // "allowed twice" and the DEBUG semantics get murky.
        compositionSession = .inactive
        preSessionFoldState = nil

        // Step 3: canonical commit. Empty finalString = abort;
        // Document unchanged, no undo entry.
        guard !finalString.isEmpty else { return }
        guard let projection = documentProjection else {
            bmLog("⛔ commitComposition: no projection after revert")
            return
        }

        do {
            let result = try EditingOps.insert(
                finalString, at: insertLocation, in: projection
            )
            applyEditResultWithUndo(result, actionName: "Type")
        } catch {
            bmLog("⛔ commitComposition insert failed: \(error)")
        }
    }

    /// Clamp `range` to `[0, storageLength]` so out-of-bounds input
    /// doesn't crash `replaceCharacters`. Defensive — should not
    /// happen under normal flow, but AppKit has been known to pass
    /// stale ranges during view tear-down.
    private func clampedRange(_ range: NSRange, to storageLength: Int) -> NSRange {
        let loc = max(0, min(range.location, storageLength))
        let maxLen = max(0, storageLength - loc)
        let len = max(0, min(range.length, maxLen))
        return NSRange(location: loc, length: len)
    }
}
