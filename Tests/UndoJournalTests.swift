//
//  UndoJournalTests.swift
//  FSNotesTests
//
//  Phase 5f commit 3: pure FSM tests for `UndoJournal`. No AppKit,
//  no NSWindow, no textStorage. All `record` calls pass `nil` for the
//  editor target so the NSUndoManager branch is short-circuited; the
//  journal's past / future stacks and FSM transitions are exercised
//  directly. The live-editor wire-in lands in commit 4 and gets its
//  own EditorHarness coverage.
//
//  Coverage per brief §7:
//    1. Inverse correctness — delegated to `EditContractInverseTests`.
//    2. Coalescing (pure FSM): 5-char typing run → 1 entry; 1.5s
//       pause → 2 entries; cursor jump → 2 entries.
//    3. Structural isolation — Return / toggle breaks a typing run.
//    4. Composition + undo — see Phase5eCompositionSession suite.
//    5. Redo fidelity — round-trip property test.
//    7. Memory bound — 10K synthetic edits → past.count < 150.
//    9. Replay flag — record inside `replayDepth > 0` is a no-op.
//

import XCTest
@testable import FSNotes

final class UndoJournalTests: XCTestCase {

    // MARK: - Helpers

    private func cursor(_ block: Int, _ offset: Int) -> DocumentCursor {
        DocumentCursor(blockIndex: block, inlineOffset: offset)
    }

    private func range(_ c: DocumentCursor) -> DocumentRange {
        DocumentRange(start: c, end: c)
    }

    private func entry(
        beforeBlock: Int = 0, beforeOffset: Int = 0,
        afterBlock: Int = 0, afterOffset: Int = 1,
        groupID: UUID = UUID(),
        timestamp: Date,
        actionName: String = "Typing",
        coalesce: UndoJournal.CoalesceClass = .typing
    ) -> UndoJournal.UndoEntry {
        let empty = EditContract.InverseStrategy.blockSnapshot(
            range: 0..<0,
            blocks: [],
            ids: []
        )
        return UndoJournal.UndoEntry(
            strategy: empty,
            selectionBefore: range(cursor(beforeBlock, beforeOffset)),
            selectionAfter: range(cursor(afterBlock, afterOffset)),
            groupID: groupID,
            timestamp: timestamp,
            actionName: actionName,
            coalesce: coalesce
        )
    }

    // MARK: - Initial state

    func test_emptyJournal_noPastNoFuture() {
        let j = UndoJournal()
        XCTAssertEqual(j.past.count, 0)
        XCTAssertEqual(j.future.count, 0)
        XCTAssertEqual(j.state, .idle)
        XCTAssertFalse(j.isReplaying)
    }

    // MARK: - Coalescing

    func test_fiveCharsInOneSecond_coalesceToOneGroup() {
        let j = UndoJournal()
        let now = Date()
        let gid = UUID()
        for i in 0..<5 {
            let e = entry(
                beforeBlock: 0, beforeOffset: i,
                afterBlock: 0, afterOffset: i + 1,
                groupID: gid,
                timestamp: now.addingTimeInterval(TimeInterval(i) * 0.1),
                coalesce: .typing
            )
            j.record(e, on: nil)
        }
        XCTAssertEqual(j.past.count, 5,
                       "Each entry is stored; 'coalesce' means same groupID")
        let uniqueGroups = Set(j.past.map { $0.groupID })
        XCTAssertEqual(uniqueGroups.count, 1,
                       "Adjacent typing within 1s shares one groupID")
    }

    func test_typingThenPauseThenTyping_twoGroups() {
        let j = UndoJournal()
        let t0 = Date()
        // First run: "he"
        for i in 0..<2 {
            j.record(entry(
                beforeBlock: 0, beforeOffset: i,
                afterBlock: 0, afterOffset: i + 1,
                groupID: UUID(),
                timestamp: t0.addingTimeInterval(TimeInterval(i) * 0.1),
                coalesce: .typing
            ), on: nil)
        }
        // 1.5s pause: second run starts on a fresh groupID.
        let t1 = t0.addingTimeInterval(1.5)
        for i in 0..<3 {
            j.record(entry(
                beforeBlock: 0, beforeOffset: 2 + i,
                afterBlock: 0, afterOffset: 3 + i,
                groupID: UUID(),
                timestamp: t1.addingTimeInterval(TimeInterval(i) * 0.1),
                coalesce: .typing
            ), on: nil)
        }
        let groups = Set(j.past.map { $0.groupID })
        XCTAssertEqual(groups.count, 2,
                       "Typing → >1s pause → typing: two groupIDs")
    }

    func test_typingThenCursorJump_breaksGroup() {
        let j = UndoJournal()
        let t0 = Date()
        // Block 0 typing
        j.record(entry(
            beforeBlock: 0, beforeOffset: 0,
            afterBlock: 0, afterOffset: 1,
            groupID: UUID(),
            timestamp: t0,
            coalesce: .typing
        ), on: nil)
        // Block 2 typing — cross-block ⇒ new group
        j.record(entry(
            beforeBlock: 2, beforeOffset: 0,
            afterBlock: 2, afterOffset: 1,
            groupID: UUID(),
            timestamp: t0.addingTimeInterval(0.2),
            coalesce: .typing
        ), on: nil)
        let groups = Set(j.past.map { $0.groupID })
        XCTAssertEqual(groups.count, 2,
                       "Cross-block typing: two groupIDs")
    }

    func test_structuralOp_breaksTypingRun() {
        let j = UndoJournal()
        let t0 = Date()
        j.record(entry(
            beforeBlock: 0, beforeOffset: 0,
            afterBlock: 0, afterOffset: 1,
            groupID: UUID(),
            timestamp: t0,
            coalesce: .typing
        ), on: nil)
        j.record(entry(
            beforeBlock: 0, beforeOffset: 1,
            afterBlock: 1, afterOffset: 0,
            groupID: UUID(),
            timestamp: t0.addingTimeInterval(0.2),
            actionName: "Return",
            coalesce: .structural
        ), on: nil)
        j.record(entry(
            beforeBlock: 1, beforeOffset: 0,
            afterBlock: 1, afterOffset: 1,
            groupID: UUID(),
            timestamp: t0.addingTimeInterval(0.3),
            coalesce: .typing
        ), on: nil)
        let groups = Set(j.past.map { $0.groupID })
        XCTAssertEqual(groups.count, 3,
                       "typing → Return → typing: three groupIDs")
    }

    // MARK: - Replay flag

    func test_recordInsideReplayDepth_dropped() {
        let j = UndoJournal()
        j.replayDepth = 1
        j.record(entry(timestamp: Date()), on: nil)
        XCTAssertEqual(j.past.count, 0,
                       "replayDepth > 0: record must be a no-op")
    }

    func test_recordWhileSuspended_dropped() {
        let j = UndoJournal()
        j.suspend()
        XCTAssertEqual(j.state, .suspended)
        j.record(entry(timestamp: Date()), on: nil)
        XCTAssertEqual(j.past.count, 0,
                       "Suspended state: record must be a no-op")
        j.unsuspend()
        XCTAssertEqual(j.state, .idle)
        j.record(entry(timestamp: Date()), on: nil)
        XCTAssertEqual(j.past.count, 1,
                       "Unsuspended: record resumes")
    }

    // MARK: - Undo / redo

    func test_undo_popsTrailingGroup_and_pushesToFuture() {
        let j = UndoJournal()
        let t0 = Date()
        let gid = UUID()
        for i in 0..<3 {
            j.record(entry(
                beforeBlock: 0, beforeOffset: i,
                afterBlock: 0, afterOffset: i + 1,
                groupID: gid,
                timestamp: t0.addingTimeInterval(TimeInterval(i) * 0.1),
                coalesce: .typing
            ), on: nil)
        }
        XCTAssertEqual(j.past.count, 3)
        XCTAssertEqual(j.future.count, 0)

        j.undo(on: nil)
        XCTAssertEqual(j.past.count, 0, "Undo pops the whole group")
        XCTAssertEqual(j.future.count, 3)
    }

    func test_redo_afterUndo_restoresPast() {
        let j = UndoJournal()
        let t0 = Date()
        let gid = UUID()
        for i in 0..<2 {
            j.record(entry(
                beforeBlock: 0, beforeOffset: i,
                afterBlock: 0, afterOffset: i + 1,
                groupID: gid,
                timestamp: t0.addingTimeInterval(TimeInterval(i) * 0.1),
                coalesce: .typing
            ), on: nil)
        }
        j.undo(on: nil)
        XCTAssertEqual(j.past.count, 0)
        XCTAssertEqual(j.future.count, 2)

        j.redo(on: nil)
        XCTAssertEqual(j.past.count, 2, "Redo restores past")
        XCTAssertEqual(j.future.count, 0)
    }

    func test_recordAfterUndo_clearsFuture() {
        let j = UndoJournal()
        let t0 = Date()
        j.record(entry(timestamp: t0), on: nil)
        j.undo(on: nil)
        XCTAssertEqual(j.future.count, 1)
        // New edit after undo invalidates the redo stack.
        j.record(entry(
            beforeBlock: 1, beforeOffset: 0,
            afterBlock: 1, afterOffset: 1,
            timestamp: t0.addingTimeInterval(2.0),
            coalesce: .typing
        ), on: nil)
        XCTAssertEqual(j.future.count, 0,
                       "New edit must drop the redo stack")
    }

    // MARK: - Reset

    func test_reset_clearsEverything() {
        let j = UndoJournal()
        j.record(entry(timestamp: Date()), on: nil)
        j.reset()
        XCTAssertEqual(j.past.count, 0)
        XCTAssertEqual(j.future.count, 0)
        XCTAssertEqual(j.state, .idle)
        XCTAssertEqual(j.replayDepth, 0)
    }

    // MARK: - Memory bound (brief §7.7)

    func test_tenThousandEntries_capped() {
        let j = UndoJournal()
        let now = Date()
        // Simulate 10,000 edits spaced 0.1s apart. maxEntries = 100.
        for i in 0..<10_000 {
            j.record(entry(
                beforeBlock: 0, beforeOffset: i,
                afterBlock: 0, afterOffset: i + 1,
                groupID: UUID(),  // fresh groups = no coalesce
                timestamp: now.addingTimeInterval(TimeInterval(i) * 0.1),
                coalesce: .structural
            ), on: nil)
        }
        XCTAssertLessThanOrEqual(j.past.count, 150,
                                 "10K edits must be capped under 150 entries")
    }

    func test_tierCEntries_respectTierCCap() {
        let j = UndoJournal()
        j.maxTierCEntries = 3
        let now = Date()
        // Record 10 Tier C entries (unique groupIDs — no coalesce).
        let fullDoc = Document(blocks: [.paragraph(inline: [.text("x")])])
        for i in 0..<10 {
            let e = UndoJournal.UndoEntry(
                strategy: .fullDocument(fullDoc),
                selectionBefore: range(cursor(0, 0)),
                selectionAfter: range(cursor(0, 1)),
                groupID: UUID(),
                timestamp: now.addingTimeInterval(TimeInterval(i) * 0.1),
                actionName: "Op",
                coalesce: .structural
            )
            j.record(e, on: nil)
        }
        let tierCs = j.past.filter {
            if case .fullDocument = $0.strategy { return true }
            return false
        }
        XCTAssertLessThanOrEqual(tierCs.count, j.maxTierCEntries,
                                 "Tier C entries must be capped to maxTierCEntries")
    }

    // MARK: - advanceTime test-hook

    func test_advanceTime_finalizesGroup() {
        let j = UndoJournal()
        j.record(entry(timestamp: Date(), coalesce: .typing), on: nil)
        XCTAssertEqual(j.state, .typingRun)
        j.advanceTime(by: 1.5)
        XCTAssertEqual(j.state, .idle,
                       "advanceTime(>= heartbeat) must finalize group")
    }

    // MARK: - beginGroup / endGroup

    func test_beginGroup_coalesceBoundary() {
        let j = UndoJournal()
        let t0 = Date()
        // First edit
        j.record(entry(timestamp: t0, coalesce: .typing), on: nil)
        let firstGroup = j.past[0].groupID
        // Forced group boundary
        j.beginGroup(reason: "Insert Link")
        j.record(entry(
            beforeBlock: 0, beforeOffset: 1,
            afterBlock: 0, afterOffset: 2,
            timestamp: t0.addingTimeInterval(0.1),
            actionName: "Link",
            coalesce: .typing
        ), on: nil)
        XCTAssertNotEqual(
            j.past[1].groupID, firstGroup,
            "beginGroup must force a new groupID on the next record"
        )
    }

    // MARK: - applyInverseHook wire (test-only)

    func test_undoHook_receivesPoppedEntries() {
        let j = UndoJournal()
        var received: [UndoJournal.UndoEntry] = []
        j.applyInverseHook = { entries, _ in received = entries }
        j.record(entry(timestamp: Date()), on: nil)
        j.undo(on: nil)
        XCTAssertEqual(received.count, 1,
                       "Undo hook must receive the popped entry")
    }
}
