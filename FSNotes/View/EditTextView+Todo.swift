//
//  EditTextView+Todo.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 15.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

extension EditTextView {
    func clearCompletedTodos() {
        // Block-model path: remove checked items from the Document.
        if let projection = documentProjection {
            clearCompletedTodosViaBlockModel(projection)
            return
        }

        // Legacy path: scan textStorage for raw markdown checkbox syntax.
        guard let textStorage = textStorage else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string as NSString

        // Phase 5f: the legacy source-mode path (no documentProjection)
        // groups multiple textStorage.replaceCharacters calls into one
        // undo unit. Each `replaceCharacters` call here flows through
        // `shouldChangeText` → AppKit's default undo registration →
        // journal.record (via `applyEditResultWithUndo`). The
        // begin/endUndoGrouping pair is retired because (a) the
        // journal's coalescing FSM groups adjacent structural edits
        // by timestamp + class, and (b) commit 6's grep-gate
        // requires zero remaining grouping calls.
        var linesToRemove: [NSRange] = []
        text.enumerateSubstrings(in: fullRange, options: .byParagraphs) { value, _, enclosingRange, _ in
            guard let value = value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("* [x] ") || trimmed.hasPrefix("+ [x] ") {
                if !linesToRemove.contains(where: { $0.intersection(enclosingRange) != nil }) {
                    linesToRemove.append(enclosingRange)
                }
            }
        }

        for lineRange in linesToRemove.sorted(by: { $0.location > $1.location }) {
            if shouldChangeText(in: lineRange, replacementString: "") {
                textStorage.replaceCharacters(in: lineRange, with: "")
                didChangeText()
            }
        }

        undoManager?.setActionName("Remove TODO Lines")
    }

    private func clearCompletedTodosViaBlockModel(_ projection: DocumentProjection) {
        var newDoc = projection.document

        // Walk blocks and remove checked items from lists.
        var modified = false
        for (i, block) in newDoc.blocks.enumerated().reversed() {
            guard case .list(let items, _) = block else { continue }
            let filtered = removeCheckedItems(from: items)
            if filtered.count != countAllItems(items) {
                modified = true
                if filtered.isEmpty {
                    newDoc.removeBlock(at: i)
                } else {
                    newDoc.replaceBlock(at: i, with: .list(items: filtered))
                }
            }
        }

        guard modified else { return }

        // Re-render and replace textStorage entirely.
        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        guard let storage = textStorage else { return }

        // Phase 5a: route through the single WYSIWYG write primitive.
        // We have both prior (`projection.document`) and new
        // (`newDoc`) documents — `applyDocumentEdit` computes the
        // minimal block-bounded splice and wraps it in the authorized
        // `performingApplyDocumentEdit` scope. On TK1 (no
        // `NSTextContentStorage`), fall back to a direct write wrapped
        // in `performingFill` — the fallback is whole-doc anyway.
        if let tlm = self.textLayoutManager,
           let contentStorage = tlm.textContentManager as? NSTextContentStorage {
            _ = DocumentEditApplier.applyDocumentEdit(
                priorDoc: projection.document,
                newDoc: newDoc,
                contentStorage: contentStorage,
                bodyFont: projection.bodyFont,
                codeFont: projection.codeFont,
                note: projection.note
            )
        } else {
            let fullRange = NSRange(location: 0, length: storage.length)
            StorageWriteGuard.performingFill {
                storage.replaceCharacters(in: fullRange, with: newProjection.attributed)
            }
        }
        // Phase 4.6: setter auto-syncs `processor.blocks`.
        documentProjection = newProjection

        // Save the updated document.
        save()
    }

    /// Recursively remove checked items from a list item tree.
    private func removeCheckedItems(from items: [ListItem]) -> [ListItem] {
        var result: [ListItem] = []
        for item in items {
            if item.isChecked { continue }
            if !item.children.isEmpty {
                let filteredChildren = removeCheckedItems(from: item.children)
                result.append(ListItem(
                    indent: item.indent, marker: item.marker,
                    afterMarker: item.afterMarker, checkbox: item.checkbox,
                    inline: item.inline, children: filteredChildren
                ))
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// Count total items in a list tree (including children).
    private func countAllItems(_ items: [ListItem]) -> Int {
        return items.reduce(0) { $0 + 1 + countAllItems($1.children) }
    }
}
