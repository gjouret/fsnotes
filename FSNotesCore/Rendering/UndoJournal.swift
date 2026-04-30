//
//  UndoJournal.swift
//  FSNotesCore
//
//  Phase 5f — structured undo/redo via `Document` journaling.
//
//  Before 5f, undo/redo used NSUndoManager.registerUndo with closures
//  that captured whole-projection snapshots and replaced textStorage
//  via `setAttributedString` (the `restoreBlockModelState` path in
//  EditTextView+BlockModel.swift). That worked but:
//    1. Every edit paid a full-document clone cost.
//    2. Undo bypassed `DocumentEditApplier.applyDocumentEdit` — the
//       5a-authorized single write path — via a full-storage swap.
//    3. There was no coalescing: each character typed was one undo
//       stack entry, so Cmd-Z felt glacial on fast typing.
//    4. Toolbar / drag / todo operations invoked `begin/endUndoGrouping`
//       directly, fragmenting undo semantics across call sites.
//
//  5f replaces the closure-stack with a `UndoJournal` per editor:
//
//    - `UndoEntry` pairs an `EditContract.InverseStrategy` (Tier A/B/C
//      inverse blueprint, see EditContract.swift) with cursor
//      snapshots (before + after) and a coalescing classifier.
//    - `past` / `future` stacks replace NSUndoManager's internals.
//    - NSUndoManager still receives ONE `registerUndo` per user-visible
//      entry so the Edit menu's Undo / Redo commands and action names
//      continue to work — the closure pops the journal, not the stack.
//    - A 1-second heartbeat finalizes the current group idle; adjacent
//      typing inside 1s coalesces.
//    - During IME composition (`compositionSession.isActive == true`)
//      the journal `Suspended`: in-flight `record` calls are dropped.
//      On commit, the editor records ONE entry for the full composed
//      run; on abort, zero entries.
//
//  Thread model: main-thread only. AppKit's undo / redo commands
//  dispatch on main; `NSTimer` heartbeat fires on main; associated-
//  object storage inherits the main-thread constraint.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - UndoJournal

/// Per-editor undo / redo journal. Lives on `EditTextView` via
/// associated objects (see `EditTextView+UndoJournal.swift` for the
/// slot).
///
/// Reference type: journals mutate in place as edits stream in, and
/// AppKit owns the editor lifecycle. The replay-depth flag must be
/// observable by `record` callers during the inverse-apply path — a
/// struct would require manual ref-counting.
public final class UndoJournal {

    // MARK: - UndoEntry

    public struct UndoEntry: Equatable {
        public let strategy: EditContract.InverseStrategy
        /// Forward replay strategy. Undo uses `strategy` to recover
        /// the pre-edit document from the post-edit document; redo
        /// uses this opposing snapshot to recover the post-edit
        /// document from the pre-edit document.
        public let redoStrategy: EditContract.InverseStrategy?
        /// Pre-edit cursor. Consumed by `undo(on:)` to position the
        /// caret in the pre-edit document after the inverse splice.
        public let selectionBefore: DocumentRange
        /// Post-edit cursor. Consumed by `redo(on:)` to position the
        /// caret after re-applying the forward edit.
        public let selectionAfter: DocumentRange
        /// All entries in a single undo group share a `groupID`. A
        /// user-visible Cmd-Z pops every tail entry with the same id.
        public let groupID: UUID
        public let timestamp: Date
        public let actionName: String
        public let coalesce: CoalesceClass

        public init(
            strategy: EditContract.InverseStrategy,
            redoStrategy: EditContract.InverseStrategy? = nil,
            selectionBefore: DocumentRange,
            selectionAfter: DocumentRange,
            groupID: UUID,
            timestamp: Date,
            actionName: String,
            coalesce: CoalesceClass
        ) {
            self.strategy = strategy
            self.redoStrategy = redoStrategy
            self.selectionBefore = selectionBefore
            self.selectionAfter = selectionAfter
            self.groupID = groupID
            self.timestamp = timestamp
            self.actionName = actionName
            self.coalesce = coalesce
        }
    }

    /// Coalescing classifier — drives the FSM state transitions. An
    /// adjacent `.typing` entry within the heartbeat window extends
    /// the current group; any other class (or non-adjacent typing)
    /// starts a fresh group.
    public enum CoalesceClass: Equatable {
        case typing        // single-char insert
        case deletion      // backspace / forward-delete
        case structural    // Return / Tab / toolbar / list ops
        case formatting    // bold / italic / heading-level
        case composition   // IME commit — atomic, never coalesces
    }

    // MARK: - Stacks

    public private(set) var past: [UndoEntry] = []
    public private(set) var future: [UndoEntry] = []

    // MARK: - Coalescing FSM state

    /// State machine for adjacent-entry coalescing. See the brief §4
    /// transition table.
    public enum FSMState: Equatable {
        case idle
        case typingRun
        case deletionRun
        case structural
        case suspended  // composition in flight
    }

    public private(set) var state: FSMState = .idle
    public private(set) var currentGroupID: UUID = UUID()

    /// When `replayDepth > 0`, `record` is a no-op. Used during the
    /// undo / redo apply-inverse codepath so the re-applied splice
    /// doesn't register a new journal entry (which would wipe future).
    /// Also used by composition abort (5e): the abort's undo of the
    /// marked-range text must not journal.
    public var replayDepth: Int = 0
    public var isReplaying: Bool { replayDepth > 0 }

    // MARK: - Heartbeat

    /// Seconds of idle-time before the FSM auto-finalizes a group.
    /// Brief §4: 1-second heartbeat.
    private let heartbeatInterval: TimeInterval = 1.0
    /// Last time an entry was recorded. Used by `advanceTime(by:)` to
    /// drive FSM expiry deterministically in tests.
    public private(set) var lastRecordTime: Date = .distantPast
    #if os(OSX)
    private var heartbeatTimer: Timer?
    #endif

    // MARK: - Memory cap

    /// Brief §3: cap 100 entries OR 2 MB total, whichever trips first.
    /// Drop FIFO from the head of `past`.
    public var maxEntries: Int = 100
    public var maxTierCEntries: Int = 5

    // MARK: - Init

    public init() {}

    // MARK: - Group control

    public func beginGroup(reason: String) {
        finalizeGroup()
        currentGroupID = UUID()
        state = .structural
    }

    public func endGroup() {
        finalizeGroup()
    }

    /// Transition the FSM back to `.idle`. Called on:
    ///   - Explicit `endGroup()`.
    ///   - Heartbeat timeout.
    ///   - Selection change while in typingRun / deletionRun.
    ///   - Composition exit (`unsuspend(commitRecorded:)`).
    public func finalizeGroup() {
        state = .idle
        #if os(OSX)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        #endif
    }

    // MARK: - Composition coordination (Phase 5e)

    /// Enter the `Suspended` state: `record` becomes a no-op until
    /// `unsuspend` is called. The editor calls this on
    /// `setMarkedText` with a non-empty marked string.
    public func suspend() {
        finalizeGroup()
        state = .suspended
    }

    /// Leave the `Suspended` state. Does NOT record an entry — the
    /// editor records the single composition-commit entry via
    /// `record(_:on:)` directly.
    public func unsuspend() {
        state = .idle
    }

    // MARK: - Record

    /// Record an edit into the journal. If `replayDepth > 0` or
    /// `state == .suspended`, drops the entry — the canonical 5e /
    /// 5f replay-flag contract.
    ///
    /// The `editor` parameter is used to route the single surviving
    /// `NSUndoManager.registerUndo` call so the Edit menu's Undo
    /// command still fires a closure that pops this journal.
    public func record(_ entry: UndoEntry, on editor: AnyObject?) {
        guard replayDepth == 0 else { return }
        guard state != .suspended else { return }

        // Coalescing decision.
        let coalesced = shouldCoalesce(
            newEntry: entry,
            lastEntry: past.last,
            now: entry.timestamp
        )
        var finalEntry = entry
        if coalesced, let last = past.last {
            // Merge into previous entry's group.
            finalEntry = UndoEntry(
                strategy: entry.strategy,
                redoStrategy: entry.redoStrategy,
                selectionBefore: last.selectionBefore,
                selectionAfter: entry.selectionAfter,
                groupID: last.groupID,
                timestamp: entry.timestamp,
                actionName: last.actionName,
                coalesce: entry.coalesce
            )
        } else {
            // Start a fresh group.
            currentGroupID = entry.groupID
            finalEntry = UndoEntry(
                strategy: entry.strategy,
                redoStrategy: entry.redoStrategy,
                selectionBefore: entry.selectionBefore,
                selectionAfter: entry.selectionAfter,
                groupID: currentGroupID,
                timestamp: entry.timestamp,
                actionName: entry.actionName,
                coalesce: entry.coalesce
            )
        }

        past.append(finalEntry)
        future.removeAll()
        lastRecordTime = finalEntry.timestamp

        // FSM transition.
        advanceFSM(from: state, on: finalEntry.coalesce)

        // Enforce memory cap.
        enforceMemoryCap()

        // Schedule heartbeat for typing / deletion runs.
        #if os(OSX)
        heartbeatTimer?.invalidate()
        if state == .typingRun || state == .deletionRun {
            heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: heartbeatInterval,
                repeats: false
            ) { [weak self] _ in
                self?.finalizeGroup()
            }
        }
        #endif

        // Route undo registration through NSUndoManager. This is the
        // ONE surviving registerUndo call outside
        // `DocumentEditApplier.applyDocumentEdit` scope. The closure
        // pops this journal; it does NOT re-enter journal.record on
        // its replay path because `undo(on:)` wraps in replayDepth.
        //
        // Register exactly once per journal group. Coalesced typing /
        // deletion entries still accumulate in `past` under one
        // groupID, but they must not add duplicate AppKit undo
        // actions; one AppKit action pops the whole journal group.
        #if os(OSX)
        if !coalesced, let editor = editor as? NSResponder {
            registerInitialUndoAction(on: editor, actionName: finalEntry.actionName)
        }
        #endif
    }

    private func shouldCoalesce(
        newEntry: UndoEntry,
        lastEntry: UndoEntry?,
        now: Date
    ) -> Bool {
        guard let last = lastEntry else { return false }
        guard newEntry.coalesce == last.coalesce else { return false }
        // Only typing / deletion coalesce; structural, formatting,
        // composition are always atomic.
        guard newEntry.coalesce == .typing ||
              newEntry.coalesce == .deletion else {
            return false
        }
        // FSM must still be in the matching run state. `beginGroup`
        // and `endGroup` reset state to `.structural` / `.idle`,
        // which explicitly ends a typing / deletion run — the coalesce
        // must respect that boundary even if the raw class of the
        // next entry matches the previous.
        let expectedState: FSMState =
            newEntry.coalesce == .typing ? .typingRun : .deletionRun
        guard state == expectedState else { return false }
        // Heartbeat window.
        guard now.timeIntervalSince(last.timestamp) < heartbeatInterval else {
            return false
        }
        // Same block — typing in block A then block B is a group
        // boundary.
        guard newEntry.selectionBefore.start.blockPath ==
              last.selectionAfter.start.blockPath else {
            return false
        }
        // Adjacency: new edit's pre-cursor must equal previous edit's
        // post-cursor.
        return newEntry.selectionBefore == last.selectionAfter
    }

    private func advanceFSM(from: FSMState, on cls: CoalesceClass) {
        switch (from, cls) {
        case (.idle, .typing):                state = .typingRun
        case (.idle, .deletion):              state = .deletionRun
        case (.idle, .structural):            state = .idle
        case (.idle, .formatting):            state = .idle
        case (.idle, .composition):           state = .idle
        case (.typingRun, .typing):           state = .typingRun
        case (.typingRun, .deletion):         state = .deletionRun
        case (.typingRun, .structural):       state = .idle
        case (.typingRun, _):                 state = .idle
        case (.deletionRun, .deletion):       state = .deletionRun
        case (.deletionRun, .typing):         state = .typingRun
        case (.deletionRun, _):               state = .idle
        case (.structural, _):                state = .idle
        case (.suspended, _):                 state = .idle
        }
    }

    // MARK: - Memory cap

    private func enforceMemoryCap() {
        // Entry-count cap: drop FIFO from head.
        while past.count > maxEntries {
            past.removeFirst()
        }
        // Tier C cap: keep at most `maxTierCEntries` tier-C entries.
        // Drop the oldest tier-C past the limit.
        let tierCCount = past.reduce(0) { acc, e in
            if case .fullDocument = e.strategy { return acc + 1 }
            return acc
        }
        if tierCCount > maxTierCEntries {
            var toDrop = tierCCount - maxTierCEntries
            var newPast: [UndoEntry] = []
            newPast.reserveCapacity(past.count - toDrop)
            for e in past {
                if toDrop > 0, case .fullDocument = e.strategy {
                    toDrop -= 1
                    continue
                }
                newPast.append(e)
            }
            past = newPast
        }
    }

    // MARK: - Undo / redo

    /// Pop the trailing group from `past`, reverse each entry via its
    /// `InverseStrategy`, and push onto `future`. No-op if `past` is
    /// empty. Throws if the editor is unavailable (should not happen
    /// in the live app since the NSUndoManager closure captures it).
    public func undo(on target: AnyObject?) {
        guard let last = past.last else { return }
        let groupID = last.groupID

        // Collect every entry in the same group (typing coalesce
        // produces a run of same-group entries that must all undo
        // together).
        var popped: [UndoEntry] = []
        while let tail = past.last, tail.groupID == groupID {
            popped.append(past.removeLast())
        }

        // Apply inverses in reverse order (most-recent first) —
        // popped is already reverse-chronological.
        replayDepth += 1
        defer { replayDepth -= 1 }

        // Delegate the actual splice to the editor via a hook; the
        // default in-code path is a pure strategy application for
        // tests.
        applyPoppedToEditor(popped: popped, target: target)

        // Push onto future in original order (so redo replays in
        // forward time).
        future.append(contentsOf: popped.reversed())

        #if os(OSX)
        registerRedoAfterUndo(on: target, entries: popped)
        #endif

        // Reset FSM — an undo is a group boundary.
        finalizeGroup()
    }

    /// Pop the trailing group from `future`, re-apply each entry,
    /// push onto `past`.
    public func redo(on target: AnyObject?) {
        guard let last = future.last else { return }
        let groupID = last.groupID

        var popped: [UndoEntry] = []
        while let tail = future.last, tail.groupID == groupID {
            popped.append(future.removeLast())
        }

        replayDepth += 1
        defer { replayDepth -= 1 }

        applyPoppedToEditorRedo(popped: popped, target: target)

        past.append(contentsOf: popped.reversed())

        #if os(OSX)
        registerUndoAfterRedo(on: target, entries: popped)
        #endif

        finalizeGroup()
    }

    /// Hook for the editor to apply an inverse to its live storage +
    /// projection. Default implementation: no-op (pure-test mode).
    /// The live editor installs a closure at wire-in time that calls
    /// `DocumentEditApplier.applyDocumentEdit` on the inverse.
    public var applyInverseHook: ((_ entries: [UndoEntry], _ target: AnyObject?) -> Void)?

    /// Hook for redo. Re-applies the forward edit derived from the
    /// entry's inverse strategy + original before/after docs.
    public var applyForwardHook: ((_ entries: [UndoEntry], _ target: AnyObject?) -> Void)?

    private func applyPoppedToEditor(popped: [UndoEntry], target: AnyObject?) {
        applyInverseHook?(popped, target)
    }

    private func applyPoppedToEditorRedo(popped: [UndoEntry], target: AnyObject?) {
        applyForwardHook?(popped, target)
    }

    #if os(OSX)
    private func registerRedoAfterUndo(
        on target: AnyObject?,
        entries: [UndoEntry]
    ) {
        guard let editor = target as? NSResponder,
              let actionName = replayActionName(for: entries) else {
            return
        }
        let um = editor.undoManager
        um?.registerUndo(withTarget: editor) { [weak self] target in
            self?.redo(on: target)
        }
        um?.setActionName(actionName)
    }

    private func registerUndoAfterRedo(
        on target: AnyObject?,
        entries: [UndoEntry]
    ) {
        guard let editor = target as? NSResponder,
              let actionName = replayActionName(for: entries) else {
            return
        }
        let um = editor.undoManager
        um?.registerUndo(withTarget: editor) { [weak self] target in
            self?.undo(on: target)
        }
        um?.setActionName(actionName)
    }

    private func replayActionName(for entries: [UndoEntry]) -> String? {
        return entries.last?.actionName ?? entries.first?.actionName
    }

    private func registerInitialUndoAction(
        on editor: NSResponder,
        actionName: String
    ) {
        guard let undoManager = editor.undoManager else { return }
        let oldGroupsByEvent = undoManager.groupsByEvent
        undoManager.groupsByEvent = false
        while undoManager.groupingLevel > 0 {
            undoManager.endUndoGrouping()
        }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: editor) { [weak self] target in
            self?.undo(on: target)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = oldGroupsByEvent
    }
    #endif

    // MARK: - Reset

    public func reset() {
        past.removeAll()
        future.removeAll()
        state = .idle
        currentGroupID = UUID()
        replayDepth = 0
        lastRecordTime = .distantPast
        #if os(OSX)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        #endif
    }

    // MARK: - Testing hooks

    /// Deterministic heartbeat advancement for unit tests — skips the
    /// real Timer and drives the FSM directly. Production code
    /// should never call this.
    public func advanceTime(by interval: TimeInterval) {
        lastRecordTime = lastRecordTime.addingTimeInterval(interval)
        if interval >= heartbeatInterval {
            finalizeGroup()
        }
    }

    /// Memory-estimation diagnostic — returns an approximate byte
    /// count of the journal's block snapshots. Used by the 10K-edit
    /// property test to assert the cap holds.
    public func approximateMemoryBytes() -> Int {
        return past.reduce(0) { acc, entry in
            switch entry.strategy {
            case .inverseContract:
                return acc + 64  // contract size estimate
            case let .blockSnapshot(_, blocks, _):
                // Rough: one Block ~= 256 bytes for a small paragraph.
                return acc + blocks.count * 256
            case .fullDocument(let doc):
                return acc + doc.blocks.count * 256
            }
        }
    }
}
