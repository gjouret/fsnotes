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

            // Block-model pipeline: route Tab/Shift-Tab through
            // the list editing FSM when the cursor is in a list block.
            if let projection = documentProjection {
                let cursorPos = selectedRange().location
                let state = ListEditingFSM.detectState(storageIndex: cursorPos, in: projection)
                if case .listItem = state {
                    let action: ListEditingFSM.Action = NSEvent.modifierFlags.contains(.shift) ? .shiftTab : .tab
                    let transition = ListEditingFSM.transition(state: state, action: action)
                    if handleListTransition(transition, at: cursorPos) {
                        breakUndoCoalescing()
                        return
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

        note.resetAttributesCache()
        scheduleTagScan(for: note)
        deleteUnusedImages(checkRange: range)
        resetTypingAttributes()

        return super.shouldChangeText(in: range, replacementString: replacementString)
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
}
