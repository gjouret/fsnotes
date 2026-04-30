//
//  EditTextView+UndoJournal.swift
//  FSNotes
//
//  Phase 5f commit 4 — wire `UndoJournal` into the editor.
//
//  Per-editor journal is stored as an associated object (same pattern
//  `documentProjection`, `lastEditContract`, `compositionSession` use
//  on this class). The journal's `applyInverseHook` and
//  `applyForwardHook` are installed on first access — they route
//  undo / redo through `DocumentEditApplier.applyDocumentEdit` on a
//  reconstructed document, so every redo-able state transition also
//  flows through the 5a-authorized single write path.
//

import AppKit
import ObjectiveC

extension EditTextView {

    // MARK: - Associated-object slot

    private struct JournalKeys {
        static var undoJournal = 0
    }

    // MARK: - Accessor

    /// Per-editor undo journal. Lazily instantiated on first access.
    public var undoJournal: UndoJournal {
        if let existing = objc_getAssociatedObject(
            self, &JournalKeys.undoJournal
        ) as? UndoJournal {
            return existing
        }
        let fresh = UndoJournal()
        installHooks(on: fresh)
        objc_setAssociatedObject(
            self, &JournalKeys.undoJournal, fresh,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return fresh
    }

    // MARK: - Hook installation

    /// Wire the journal to the editor's live storage + projection
    /// via `DocumentEditApplier`. The hooks capture `self` weakly so
    /// the editor can outlive the journal during teardown without a
    /// cycle.
    private func installHooks(on journal: UndoJournal) {
        journal.applyInverseHook = { [weak self] entries, _ in
            guard let self = self else { return }
            self.applyJournalInverse(entries: entries)
        }
        journal.applyForwardHook = { [weak self] entries, _ in
            guard let self = self else { return }
            self.applyJournalForward(entries: entries)
        }
    }

    // MARK: - Inverse / forward delivery

    /// Replay inverses for the set of entries that make up one
    /// user-visible undo group. The journal has already incremented
    /// `replayDepth` so the inner `applyDocumentEdit` splice will not
    /// re-enter `record`.
    fileprivate func applyJournalInverse(
        entries: [UndoJournal.UndoEntry]
    ) {
        guard let currentProjection = documentProjection else { return }
        // Entries come in reverse-chronological order — apply each
        // inverse onto the running document.
        var workingDoc = currentProjection.document
        var finalCursor: DocumentRange? = nil
        for entry in entries {
            workingDoc = reconstructPriorDoc(
                entry: entry,
                afterDoc: workingDoc
            )
            finalCursor = entry.selectionBefore
        }
        deliverDocumentChange(
            priorDoc: currentProjection.document,
            newDoc: workingDoc,
            targetCursor: finalCursor
        )
    }

    /// Replay forward for a redo group. Unlike undo, redo advances
    /// the document to the post-edit state encoded by
    /// `selectionAfter`. For Tier B / C strategies, reconstructing
    /// the forward document requires knowing the post-edit state —
    /// which lives on the editor's current projection at redo-time
    /// (after the matching undo already ran, the post-edit doc IS
    /// the document we had before undo). We cached that in the
    /// journal's `future` stack as part of the entry.
    fileprivate func applyJournalForward(
        entries: [UndoJournal.UndoEntry]
    ) {
        guard let currentProjection = documentProjection else { return }
        // Redo applies entries in their original forward order. The
        // journal pushed popped-undo entries onto future in reverse,
        // so `entries` arrives reverse-chronologically; reverse once
        // to get forward order.
        let forward = entries.reversed()
        var workingDoc = currentProjection.document
        var finalCursor: DocumentRange? = nil
        for entry in forward {
            workingDoc = reconstructPostEditDoc(
                entry: entry,
                priorDoc: workingDoc
            )
            finalCursor = entry.selectionAfter
        }
        deliverDocumentChange(
            priorDoc: currentProjection.document,
            newDoc: workingDoc,
            targetCursor: finalCursor
        )
    }

    /// Given an `UndoEntry` whose `strategy` describes how to invert
    /// the recorded edit, reconstruct the pre-edit `Document` from
    /// `afterDoc`.
    private func reconstructPriorDoc(
        entry: UndoJournal.UndoEntry,
        afterDoc: Document
    ) -> Document {
        switch entry.strategy {
        case .inverseContract:
            // Tier A sibling contract: the stored strategy wraps a
            // forward `EditContract` whose application on afterDoc
            // reproduces priorDoc. No known primitive populates this
            // in 5f; the generic builder always emits Tier B/C. Fall
            // through to returning afterDoc — the caller treats this
            // as a no-op undo.
            return afterDoc
        case let .blockSnapshot(range, blocks, ids):
            var result = afterDoc
            let lower = max(0, min(range.lowerBound, result.blocks.count))
            let upper = max(lower, min(range.upperBound, result.blocks.count))
            let clamped = lower..<upper
            result.blocks.replaceSubrange(clamped, with: blocks)
            result.blockIds.replaceSubrange(clamped, with: ids)
            return result
        case .fullDocument(let doc):
            return doc
        }
    }

    /// Redo reconstruction: re-derive the post-edit document from the
    /// pre-edit document using the opposing strategy recorded at edit
    /// time. For Tier B this is the mirror snapshot of the slots that
    /// undo restored; for Tier C it is the full post-edit document.
    private func reconstructPostEditDoc(
        entry: UndoJournal.UndoEntry,
        priorDoc: Document
    ) -> Document {
        guard let redoStrategy = entry.redoStrategy else {
            return priorDoc
        }
        return redoStrategy.applyInverse(to: priorDoc)
    }

    /// Route a reconstructed document change through the 5a-authorized
    /// `DocumentEditApplier.applyDocumentEdit` path, then update the
    /// projection and cursor. Does NOT register an undo — the caller
    /// is already inside `replayDepth > 0`.
    private func deliverDocumentChange(
        priorDoc: Document,
        newDoc: Document,
        targetCursor: DocumentRange?
    ) {
        guard let storage = textStorage else { return }
        guard let oldProjection = documentProjection else { return }
        let newProjection = DocumentProjection(
            document: newDoc,
            bodyFont: oldProjection.bodyFont,
            codeFont: oldProjection.codeFont
        )

        // Splice via the element-level applier on TK2.
        textStorageProcessor?.isRendering = true
        if let tlm = self.textLayoutManager,
           let contentStorage = tlm.textContentManager as? NSTextContentStorage {
            _ = DocumentEditApplier.applyDocumentEdit(
                priorDoc: priorDoc,
                newDoc: newDoc,
                contentStorage: contentStorage,
                bodyFont: newProjection.bodyFont,
                codeFont: newProjection.codeFont,
                note: self.note
            )
        } else {
            StorageWriteGuard.performingApplyDocumentEdit {
                storage.beginEditing()
                let full = NSRange(location: 0, length: storage.length)
                storage.replaceCharacters(
                    in: full,
                    with: newProjection.attributed
                )
                storage.endEditing()
            }
        }
        textStorageProcessor?.isRendering = false

        documentProjection = newProjection

        // Cursor
        if let cursor = targetCursor {
            let loc = newProjection.storageIndex(for: cursor.start)
            let len = newProjection.storageIndex(for: cursor.end) - loc
            let safeLoc = min(max(0, loc), storage.length)
            let safeLen = max(0, min(len, storage.length - safeLoc))
            setSelectedRange(
                NSRange(location: safeLoc, length: safeLen),
                affinity: .downstream,
                stillSelecting: false
            )
            scrollRangeToVisible(NSRange(location: safeLoc, length: safeLen))
        }

        note?.cacheHash = nil
        needsDisplay = true
        didChangeText()
    }

    // MARK: - Entry builder

    /// Build an `UndoEntry` from an `EditResult` + pre-edit cursor.
    /// Called from `applyEditResultWithUndo` at the journal-record
    /// site.
    func makeJournalEntry(
        result: EditResult,
        priorDoc: Document,
        cursorBefore: NSRange,
        cursorAfter: NSRange,
        actionName: String,
        coalesce: UndoJournal.CoalesceClass
    ) -> UndoJournal.UndoEntry {
        // Build or reuse inverse strategy from the contract. Generic
        // tier picker if absent.
        let strategy: EditContract.InverseStrategy
        if let c = result.contract, let inv = c.inverse {
            strategy = inv
        } else {
            strategy = EditContract.InverseStrategy.buildInverse(
                priorDoc: priorDoc,
                newDoc: result.newProjection.document
            )
        }

        let priorProj = DocumentProjection(
            document: priorDoc,
            bodyFont: result.newProjection.bodyFont,
            codeFont: result.newProjection.codeFont
        )
        let selBefore = DocumentRange(
            start: priorProj.cursor(atStorageIndex: cursorBefore.location),
            end: priorProj.cursor(
                atStorageIndex: cursorBefore.location + cursorBefore.length
            )
        )
        let selAfter = DocumentRange(
            start: result.newProjection.cursor(
                atStorageIndex: cursorAfter.location
            ),
            end: result.newProjection.cursor(
                atStorageIndex: cursorAfter.location + cursorAfter.length
            )
        )

        let redoStrategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: result.newProjection.document,
            newDoc: priorDoc
        )

        return UndoJournal.UndoEntry(
            strategy: strategy,
            redoStrategy: redoStrategy,
            selectionBefore: selBefore,
            selectionAfter: selAfter,
            groupID: UUID(),
            timestamp: Date(),
            actionName: actionName,
            coalesce: coalesce
        )
    }

    /// Classify an action name as a `CoalesceClass` — heuristic;
    /// `applyEditResultWithUndo` supplies the name, so the mapping
    /// mirrors the strings used there.
    func coalesceClass(forActionName name: String) -> UndoJournal.CoalesceClass {
        switch name {
        case "Typing":            return .typing
        case "Delete":            return .deletion
        case "Replace":           return .structural
        default:                  return .structural
        }
    }
}
