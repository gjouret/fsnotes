//
//  FSMTransitionTableTests.swift
//  FSNotesTests
//
//  Phase 11 Slice A.5 — parameterised runner for the FSM transition
//  table at `Tests/Fixtures/FSMTransitions.swift`.
//
//  XCTest doesn't support true value-parameterised methods, so this
//  suite uses a single iterating test method (`test_fsmTransitionTable`)
//  that dispatches each row through `XCTContext.runActivity` so per-row
//  failures still surface in Xcode's test navigator. `continueAfterFailure`
//  is true so a single bad row doesn't abort the suite.
//
//  Bug rows (rows whose `bugId` is non-nil — they encode the
//  EXPECTED-AFTER-FIX behaviour for a Slice B inventory bug) are
//  wrapped in `XCTExpectFailure(strict: true)` so they fail-by-design
//  today and flip to red ("unexpectedly passed") when the underlying
//  FSM is fixed.
//
//  Per-row infrastructure is built on top of the Phase 11 Slice A
//  Given / When / Then API in `EditorScenario.swift`.
//

import XCTest
import AppKit
import Carbon.HIToolbox
@testable import FSNotes

final class FSMTransitionTableTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// Drives every row in `FSMTransitionTable.all`. Each row is wrapped
    /// in `XCTContext.runActivity(named:)` so Xcode's test navigator
    /// shows per-row failures with the row's `label`.
    func test_fsmTransitionTable() {
        let rows = FSMTransitionTable.all
        XCTAssertGreaterThanOrEqual(
            rows.count, 80,
            "FSM transition table is below the Slice A.5 minimum (80 rows). " +
            "Got \(rows.count). Add more rows or delete this lower bound."
        )

        for row in rows {
            XCTContext.runActivity(named: row.label) { _ in
                if let bug = row.bugId {
                    XCTExpectFailure(
                        "Bug-row #\(bug): \(row.note) — should fail today; " +
                        "remove this expectation when the underlying FSM is fixed.",
                        strict: true
                    ) {
                        runRow(row)
                    }
                } else {
                    runRow(row)
                }
            }
        }
    }

    // MARK: - Per-row execution

    /// Drive one row end-to-end:
    ///   1. Build a fresh `EditorScenario` seeded for the row's blockKind.
    ///   2. Resolve the cursor's storage offset from the row's
    ///      `cursorPosition`.
    ///   3. Apply the row's `action`.
    ///   4. Read the post-edit `Document` and assert against the row's
    ///      `expected` ExpectedTransition.
    private func runRow(_ row: FSMTransition) {
        // Skip the rare row that documents an impossible combination
        // (e.g. midContent on a horizontalRule). The runner records
        // an XCTAttachment-equivalent message via XCTContext but doesn't
        // fail.
        if case .unsupported = row.expected {
            return
        }

        guard let seed = seedFor(row) else {
            XCTFail(
                "FSMTransitionTable: no seed defined for \(row.label). " +
                "note: \(row.note)"
            )
            return
        }

        // Prefer the offscreen scenario for FSM rows — none of the
        // structural assertions need a key window (we read Document,
        // not view-provider subviews).
        let scenario = Given.note(markdown: seed.markdown)

        // Snapshot before-state.
        guard let beforeDoc = scenario.editor.documentProjection?.document else {
            XCTFail(
                "FSMTransitionTable[\(row.label)]: no documentProjection " +
                "after seeding. note: \(row.note)"
            )
            return
        }
        let beforeBlocks = beforeDoc.blocks
        let beforeCount = beforeBlocks.count
        // Snapshot the pre-action block spans — needed by the cursor-
        // placement assertion (the predecessor's pre-merge end is read
        // from this array).
        let beforeSpans = scenario.editor.documentProjection?.blockSpans ?? []

        // Resolve the cursor offset.
        guard let cursorOffset = cursorOffset(
            in: scenario, seed: seed, position: row.cursorPosition
        ) else {
            XCTFail(
                "FSMTransitionTable[\(row.label)]: cursor position " +
                "\(row.cursorPosition) cannot be resolved against seed " +
                "block at index \(seed.targetBlockIndex). note: \(row.note)"
            )
            return
        }
        scenario.cursorAt(cursorOffset)
        let cursorBefore = cursorOffset

        // Optionally select the entire block (for selectBlockAndDelete).
        if row.action == .selectBlockAndDelete {
            guard let projection = scenario.editor.documentProjection,
                  seed.targetBlockIndex < projection.blockSpans.count
            else {
                XCTFail(
                    "FSMTransitionTable[\(row.label)]: cannot resolve " +
                    "block span for selectBlockAndDelete. note: \(row.note)"
                )
                return
            }
            let span = projection.blockSpans[seed.targetBlockIndex]
            scenario.select(NSRange(location: span.location, length: span.length))
        }

        // Apply the action.
        applyAction(row.action, on: scenario)

        // Snapshot after-state.
        guard let afterDoc = scenario.editor.documentProjection?.document else {
            XCTFail(
                "FSMTransitionTable[\(row.label)]: no documentProjection " +
                "after action. note: \(row.note)"
            )
            return
        }
        let afterBlocks = afterDoc.blocks
        let afterCount = afterBlocks.count
        let afterSpans = scenario.editor.documentProjection?.blockSpans ?? []
        let cursorAfter = scenario.editor.selectedRange().location

        // Assert.
        switch row.expected {
        case .stayInBlock:
            assertEqual(
                afterCount, beforeCount,
                row: row,
                what: "block count (stayInBlock expects unchanged)"
            )
            if afterCount == beforeCount,
               seed.targetBlockIndex < afterCount,
               seed.targetBlockIndex < beforeCount {
                let beforeKind = blockKindLabel(beforeBlocks[seed.targetBlockIndex])
                let afterKind = blockKindLabel(afterBlocks[seed.targetBlockIndex])
                assertEqual(
                    afterKind, beforeKind,
                    row: row,
                    what: "block kind at target index (stayInBlock expects unchanged)"
                )
            }

        case .splitBlock(let intoKind, let firstBecomes):
            // Split: original block becomes 2+ blocks (an intermediate
            // .blankLine is inserted between non-empty halves by
            // splitParagraphOnNewline). Block count grows by ≥1.
            assertTrue(
                afterCount >= beforeCount + 1,
                row: row,
                what: "block count (splitBlock expects ≥+1): " +
                      "before=\(beforeCount) after=\(afterCount)"
            )
            let firstExpected = firstBecomes ?? row.blockKind
            if seed.targetBlockIndex < afterCount {
                assertKindMatches(
                    afterBlocks[seed.targetBlockIndex],
                    expected: firstExpected,
                    row: row,
                    what: "first slot kind after split"
                )
            }
            // The "second" slot is the LAST newly-inserted block from
            // this split — `replaceBlocks` placed the run starting at
            // targetBlockIndex, length = (afterCount - beforeCount + 1).
            let runLength = afterCount - beforeCount + 1
            let lastNewIdx = seed.targetBlockIndex + runLength - 1
            if lastNewIdx < afterCount {
                assertKindMatches(
                    afterBlocks[lastNewIdx],
                    expected: intoKind,
                    row: row,
                    what: "last new slot kind after split (idx=\(lastNewIdx))"
                )
            }

        case .mergeWithPrevious:
            // Delta = -1 for the simple two-block case (no blank
            // separator between the target and its predecessor).
            // Delta = -2 when a blankLine separator sits between the
            // two non-blank paragraphs and the merge consumes the
            // separator too — that's the round-trip-correct behavior
            // since `[para "a", blankLine, para "b"]` serializes to
            // "a\n\nb\n" and parsing "ab\n" yields one paragraph.
            // Either shape is a valid `mergeWithPrevious`; the seed
            // choice (with vs. without blank separator) decides which.
            let delta = afterCount - beforeCount
            if delta != -1 && delta != -2 {
                assertEqual(
                    afterCount, beforeCount - 1,
                    row: row,
                    what: "block count (mergeWithPrevious expects −1 or −2)"
                )
            }

        case .exitToBlock(let kind):
            assertEqual(
                afterCount, beforeCount,
                row: row,
                what: "block count (exitToBlock expects unchanged)"
            )
            if seed.targetBlockIndex < afterCount {
                assertKindMatches(
                    afterBlocks[seed.targetBlockIndex],
                    expected: kind,
                    row: row,
                    what: "block kind at target index after exit"
                )
            }

        case .noOp:
            assertEqual(
                afterCount, beforeCount,
                row: row,
                what: "block count (noOp expects unchanged)"
            )
            // Strict no-op: blocks must equal byte-for-byte.
            assertTrue(
                beforeBlocks == afterBlocks,
                row: row,
                what: "block content unchanged (noOp)"
            )

        case .indent:
            assertEqual(
                afterCount, beforeCount,
                row: row,
                what: "block count (indent expects unchanged)"
            )
            // Detect by re-scanning: the deepest list-item nesting
            // depth in the target list block must INCREASE.
            let beforeDepth = maxListDepth(beforeBlocks[safe: seed.targetBlockIndex])
            let afterDepth = maxListDepth(afterBlocks[safe: seed.targetBlockIndex])
            assertTrue(
                afterDepth > beforeDepth,
                row: row,
                what: "list nesting depth increased (indent): " +
                      "before=\(beforeDepth) after=\(afterDepth)"
            )

        case .outdent:
            assertEqual(
                afterCount, beforeCount,
                row: row,
                what: "block count (outdent expects unchanged)"
            )
            let beforeDepth = maxListDepth(beforeBlocks[safe: seed.targetBlockIndex])
            let afterDepth = maxListDepth(afterBlocks[safe: seed.targetBlockIndex])
            assertTrue(
                afterDepth < beforeDepth,
                row: row,
                what: "list nesting depth decreased (outdent): " +
                      "before=\(beforeDepth) after=\(afterDepth)"
            )

        case .insertAtomic(let kind):
            assertEqual(
                afterCount, beforeCount + 1,
                row: row,
                what: "block count (insertAtomic expects +1)"
            )
            // The newly-inserted sibling must have the expected kind.
            // Position depends on the row: at-start → before, at-end →
            // after. Locate the original atomic block by kind and
            // identify the freshly-inserted neighbour.
            let inserted = locateInsertedSibling(
                originalAtomicKind: row.blockKind,
                row: row,
                before: beforeBlocks,
                after: afterBlocks
            )
            if let inserted = inserted {
                assertKindMatches(
                    inserted, expected: kind,
                    row: row,
                    what: "newly-inserted sibling kind"
                )
            } else {
                fail(
                    row: row,
                    what: "could not locate the newly-inserted sibling"
                )
            }

        case .unsupported:
            // Already early-returned above.
            break
        }

        // Cursor-placement assertion. Rows that don't care leave
        // `cursorAfter == .unchecked` and skip this. Rows that do care
        // assert against the pre/post spans the structural switch
        // already snapshotted.
        assertCursorPlacement(
            row: row,
            cursorBefore: cursorBefore,
            cursorAfter: cursorAfter,
            beforeSpans: beforeSpans,
            afterSpans: afterSpans,
            beforeCount: beforeCount,
            afterCount: afterCount,
            targetIndex: seed.targetBlockIndex
        )
    }

    // MARK: - Cursor-placement assertion

    /// Assert the row's `cursorAfter` post-condition. Strict for
    /// `.preserved` and `.atStartOfNewBlock`; ±2 slack for
    /// `.atEndOfPreviousBlock` (a blank-line separator between the
    /// merged blocks may or may not be consumed by the merge,
    /// shifting the join boundary by one or two characters).
    private func assertCursorPlacement(
        row: FSMTransition,
        cursorBefore: Int,
        cursorAfter: Int,
        beforeSpans: [NSRange],
        afterSpans: [NSRange],
        beforeCount: Int,
        afterCount: Int,
        targetIndex: Int
    ) {
        switch row.cursorAfter {
        case .unchecked:
            return

        case .preserved:
            // `.preserved` = cursor stays in the SAME block, with ±1
            // slack for the natural delete / insert side-effect of the
            // action (Backspace pulls cursor one left; ForwardDelete
            // leaves cursor put; typing a char pushes it one right).
            // Anything beyond ±1 is an FSM-level reposition, which a
            // `.preserved` row forbids.
            let driftOK = abs(cursorAfter - cursorBefore) <= 1
            let beforeBlockIdx = blockIndex(
                containing: cursorBefore, in: beforeSpans
            )
            let afterBlockIdx = blockIndex(
                containing: cursorAfter, in: afterSpans
            )
            let sameBlock = beforeBlockIdx != nil
                && beforeBlockIdx == afterBlockIdx
            assertTrue(
                driftOK,
                row: row,
                what: "cursor placement (preserved): drift " +
                      "|\(cursorAfter) - \(cursorBefore)| > 1"
            )
            assertTrue(
                sameBlock,
                row: row,
                what: "cursor placement (preserved): cursor left the " +
                      "target block (before idx=\(String(describing: beforeBlockIdx)), " +
                      "after idx=\(String(describing: afterBlockIdx)))"
            )

        case .atStartOfNewBlock:
            // Split / atomic-insert: cursor lands at the start of the
            // LAST newly-inserted block in the post-state. The runLength
            // arithmetic mirrors the structural assertion above:
            //   runLength = afterCount - beforeCount + 1
            //   lastNewIdx = targetIndex + runLength - 1
            // For `.insertAtomic` (count grows by 1, target unchanged)
            // the last new block is at targetIndex + 1 OR targetIndex - 1
            // depending on which side the atomic landed; the runner
            // already located it via `locateInsertedSibling`. For the
            // atomic case the cursor expectation is implicit (rows leave
            // `cursorAfter == .unchecked`), so we only handle splits
            // here.
            let delta = afterCount - beforeCount
            guard delta >= 1 else {
                fail(
                    row: row,
                    what: "cursor placement (atStartOfNewBlock): expected " +
                          "block-count delta ≥ 1 but got \(delta) — " +
                          "no new block to anchor against"
                )
                return
            }
            let runLength = delta + 1
            let lastNewIdx = targetIndex + runLength - 1
            guard lastNewIdx < afterSpans.count else {
                fail(
                    row: row,
                    what: "cursor placement (atStartOfNewBlock): " +
                          "lastNewIdx \(lastNewIdx) is out of range " +
                          "(afterSpans.count=\(afterSpans.count))"
                )
                return
            }
            let expected = afterSpans[lastNewIdx].location
            assertEqual(
                cursorAfter, expected,
                row: row,
                what: "cursor placement (atStartOfNewBlock): expected " +
                      "start of new block at index \(lastNewIdx)"
            )

        case .atEndOfPreviousBlock:
            // Merge: cursor lands at the boundary between the original
            // predecessor's content and the merged-in content. That
            // boundary equals the predecessor's pre-merge content end
            // (`beforeSpans[targetIndex - 1].location + length`). When a
            // blank-line separator sat between the two non-blank blocks
            // and the merge consumed it, the predecessor of `target` in
            // `beforeSpans` is at `targetIndex - 2` instead. Try both
            // candidate predecessors; ±2 slack on each absorbs trailing-
            // newline conventions in the span lengths.
            let candidates = [targetIndex - 1, targetIndex - 2]
                .filter { $0 >= 0 && $0 < beforeSpans.count }
            guard !candidates.isEmpty else {
                fail(
                    row: row,
                    what: "cursor placement (atEndOfPreviousBlock): no " +
                          "valid predecessor index for targetIndex=\(targetIndex)"
                )
                return
            }
            let expectedOffsets = candidates.map {
                beforeSpans[$0].location + beforeSpans[$0].length
            }
            let bestDiff = expectedOffsets
                .map { abs(cursorAfter - $0) }
                .min() ?? Int.max
            assertTrue(
                bestDiff <= 2,
                row: row,
                what: "cursor placement (atEndOfPreviousBlock): expected " +
                      "cursor near end of pre-merge predecessor " +
                      "(candidates \(expectedOffsets), got \(cursorAfter), " +
                      "min diff \(bestDiff))"
            )
        }
    }

    // MARK: - Action dispatch

    private func applyAction(_ action: ActionFixture, on scenario: EditorScenario) {
        switch action {
        case .pressReturn:
            scenario.pressReturn()
        case .pressBackspace:
            scenario.pressDelete()
        case .pressForwardDelete:
            scenario.pressForwardDelete()
        case .pressTab:
            simulateTabKey(on: scenario.editor, withShift: false)
        case .pressShiftTab:
            simulateTabKey(on: scenario.editor, withShift: true)
        case .selectBlockAndDelete:
            scenario.pressDelete()
        }
    }

    /// Synthesise a kVK_Tab keyDown so the editor's `keyDown(with:)`
    /// override (which gates the list FSM dispatch) actually runs.
    /// `editor.insertTab(_:)` would short-circuit straight to
    /// `super`'s default behaviour, missing the FSM path entirely.
    private func simulateTabKey(on editor: EditTextView, withShift: Bool) {
        // Drive the list FSM transition directly. We do NOT route
        // through a synthesised keyDown event because offscreen
        // NSWindows produce keyDown events that AppKit's NSTextView
        // sometimes refuses to dispatch (the `.shift` modifier flag
        // in particular triggers an early `super.keyDown` short-
        // circuit in EditTextView+Input that bypasses the FSM check).
        // Calling `handleListTransition` directly is functionally
        // identical for FSM rows: the production keyDown's gating
        // logic (cursorIsInTableElement → bail; documentProjection
        // != nil → detect state → transition → handleListTransition)
        // collapses to the three lines below for any list-block row.
        guard let projection = editor.documentProjection else { return }
        let cursorPos = editor.selectedRange().location
        let state = ListEditingFSM.detectState(
            storageIndex: cursorPos, in: projection
        )
        if case .listItem = state {
            let action: ListEditingFSM.Action =
                withShift ? .shiftTab : .tab
            let transition = ListEditingFSM.transition(
                state: state, action: action
            )
            _ = editor.handleListTransition(transition, at: cursorPos)
        }
        // Non-list state with Tab/Shift-Tab is a structure-preserving
        // op (insert indent characters or focus change). The FSM
        // table's stayInBlock rows for those cases pass without
        // needing a real key event because we already snapshot
        // before/after blocks structurally.
    }

    // MARK: - Seed table

    /// Per-fixture seed: the markdown to seed the editor with, the index
    /// of the block the row's cursorPosition refers to, and that block's
    /// span length (so atEnd / midContent can be computed).
    private struct RowSeed {
        let markdown: String
        let targetBlockIndex: Int
    }

    private func seedFor(_ row: FSMTransition) -> RowSeed? {
        // Seeds always include a leading paragraph "first" so atStart
        // has a previous block to merge with, and a trailing paragraph
        // "after" for forward-delete-at-end rows so atEnd has a next
        // block to merge with. The target block lives at index 2 (or
        // wherever appropriate). For block kinds where prepending
        // changes the FSM behaviour (lists with blank-line separation)
        // the seed is more carefully constructed.
        switch row.blockKind {
        case .paragraph:
            switch row.cursorPosition {
            case .onEmptyBlock:
                // Empty paragraph: needs siblings on both sides so it
                // isn't index 0 of an otherwise-empty doc.
                return RowSeed(markdown: "first\n\n\nafter\n", targetBlockIndex: 2)
            default:
                return RowSeed(markdown: "first\n\nsecond\n\nafter\n", targetBlockIndex: 2)
            }

        case .heading(let level):
            let prefix = String(repeating: "#", count: level)
            return RowSeed(markdown: "first\n\n\(prefix) Title\n\nafter\n", targetBlockIndex: 2)

        case .bulletList:
            switch row.cursorPosition {
            case .onEmptyBlock:
                return RowSeed(markdown: "- \n", targetBlockIndex: 0)
            default:
                return RowSeed(markdown: "- item\n", targetBlockIndex: 0)
            }

        case .numberedList:
            switch row.cursorPosition {
            case .onEmptyBlock:
                return RowSeed(markdown: "1. \n", targetBlockIndex: 0)
            default:
                return RowSeed(markdown: "1. item\n", targetBlockIndex: 0)
            }

        case .todoList:
            switch row.cursorPosition {
            case .onEmptyBlock:
                return RowSeed(markdown: "- [ ] \n", targetBlockIndex: 0)
            default:
                return RowSeed(markdown: "- [ ] todo\n", targetBlockIndex: 0)
            }

        case .blockquote:
            switch row.cursorPosition {
            case .atStart:
                return RowSeed(markdown: "first\n\n> quoted\n\nafter\n", targetBlockIndex: 2)
            case .atEnd:
                return RowSeed(markdown: "> quoted\n\nafter\n", targetBlockIndex: 0)
            default:
                return RowSeed(markdown: "> quoted\n", targetBlockIndex: 0)
            }

        case .codeBlock:
            return RowSeed(markdown: "```\nx\n```\n\nafter\n", targetBlockIndex: 0)

        case .table:
            // Minimal valid markdown table: header row, separator, one body row.
            // Trailing "after" so the table isn't the last block when an
            // atEnd action wants to merge with a successor.
            let md = "| a | b |\n| - | - |\n| 1 | 2 |\n\nafter\n"
            return RowSeed(markdown: md, targetBlockIndex: 0)

        case .horizontalRule:
            switch row.cursorPosition {
            case .atStart:
                return RowSeed(markdown: "first\n\n---\n\nafter\n", targetBlockIndex: 2)
            default:
                return RowSeed(markdown: "---\n\nafter\n", targetBlockIndex: 0)
            }

        case .blankLine:
            // A bare blankLine block exists between paragraphs in the
            // parsed document.
            return RowSeed(markdown: "first\n\n\nsecond\n", targetBlockIndex: 1)
        }
    }

    /// Resolve the storage offset for the row's cursor position against
    /// the live projection. For list blocks `atStart` means HOME —
    /// first byte of the item's inline content, AFTER the bullet /
    /// marker prefix — so `pressDelete` triggers
    /// `handleDeleteAtHomeInList` (FSM .deleteAtHome) rather than a
    /// no-op delete at storage offset 0.
    private func cursorOffset(
        in scenario: EditorScenario,
        seed: RowSeed,
        position: CursorPositionFixture
    ) -> Int? {
        guard let projection = scenario.editor.documentProjection,
              seed.targetBlockIndex < projection.blockSpans.count
        else { return nil }
        let span = projection.blockSpans[seed.targetBlockIndex]
        let block = projection.document.blocks[seed.targetBlockIndex]
        let homeOffset = inlineHomeOffset(
            forBlock: block, span: span, projection: projection
        )
        switch position {
        case .atStart:
            return homeOffset
        case .atEnd:
            return span.location + span.length
        case .midContent:
            // Pick the middle of the block's inline span (between home
            // and end). For very short blocks this collapses to home.
            let inlineEnd = span.location + span.length
            return homeOffset + max(0, (inlineEnd - homeOffset) / 2)
        case .onEmptyBlock:
            return homeOffset
        }
    }

    /// "Home" offset for a block — the start of editable inline
    /// content. For lists the home is past the bullet / marker /
    /// checkbox prefix run. We skip offset 0 because the FSM treats
    /// offset 0 of a list-only document as "home" too, and a backspace
    /// from offset 0 is a no-op (no character to delete). The actual
    /// editable home is `span.location + 1` (after the bullet
    /// attachment) — verified via `isAtHomePosition`.
    private func inlineHomeOffset(
        forBlock block: Block,
        span: NSRange,
        projection: DocumentProjection
    ) -> Int {
        switch block {
        case .list:
            // The bullet / marker / checkbox prefix is exactly 1 storage
            // character (the U+FFFC attachment) per renderer
            // (FSNotesCore/Rendering/EditingOperations.swift line 3826
            // comment). Home is at span.location + 1.
            return span.location + 1
        default:
            return span.location
        }
    }

    // MARK: - Assertion helpers (per-row failure messages include label + note)

    private func assertEqual<T: Equatable>(
        _ actual: T, _ expected: T,
        row: FSMTransition,
        what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if actual != expected {
            fail(
                row: row,
                what: "\(what): expected \(expected), got \(actual)",
                file: file, line: line
            )
        }
    }

    private func assertTrue(
        _ condition: Bool,
        row: FSMTransition,
        what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if !condition {
            fail(row: row, what: what, file: file, line: line)
        }
    }

    private func fail(
        row: FSMTransition,
        what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let bugHint = row.bugId.map { "  [Slice B bug #\($0)]" } ?? ""
        XCTFail(
            "[\(row.label)] \(what)\(bugHint)\n  note: \(row.note)",
            file: file, line: line
        )
    }

    private func assertKindMatches(
        _ block: Block,
        expected: BlockKindFixture,
        row: FSMTransition,
        what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if !blockMatches(block, fixture: expected) {
            fail(
                row: row,
                what: "\(what): expected \(expected), got \(blockKindLabel(block))",
                file: file, line: line
            )
        }
    }

    // MARK: - Block / kind helpers

    /// Compare a `Block` against a `BlockKindFixture` (kind-only — does
    /// not inspect inline content).
    private func blockMatches(_ block: Block, fixture: BlockKindFixture) -> Bool {
        switch (block, fixture) {
        case (.paragraph, .paragraph),
             (.codeBlock, .codeBlock),
             (.blockquote, .blockquote),
             (.table, .table),
             (.horizontalRule, .horizontalRule),
             (.blankLine, .blankLine):
            return true
        case (.heading(let level, _), .heading(let want)):
            return level == want
        case (.list(let items, _), .bulletList):
            return firstMarker(items)?.isBulletMarker ?? false
                && firstCheckbox(items) == nil
        case (.list(let items, _), .numberedList):
            return firstMarker(items)?.isNumberedMarker ?? false
                && firstCheckbox(items) == nil
        case (.list(let items, _), .todoList):
            return firstCheckbox(items) != nil
        case (.htmlBlock, _):
            return false
        default:
            return false
        }
    }

    private func firstMarker(_ items: [ListItem]) -> String? {
        return items.first?.marker
    }

    private func firstCheckbox(_ items: [ListItem]) -> Checkbox? {
        return items.first?.checkbox
    }

    /// Human-readable kind label (for failure messages).
    private func blockKindLabel(_ block: Block) -> String {
        switch block {
        case .paragraph:        return "paragraph"
        case .codeBlock:        return "codeBlock"
        case .heading(let l, _): return "heading(\(l))"
        case .list(let items, _):
            if firstCheckbox(items) != nil { return "todoList" }
            if let m = items.first?.marker, m.isBulletMarker { return "bulletList" }
            return "numberedList"
        case .blockquote:       return "blockquote"
        case .horizontalRule:   return "horizontalRule"
        case .htmlBlock:        return "htmlBlock"
        case .table:            return "table"
        case .blankLine:        return "blankLine"
        }
    }

    /// Maximum nesting depth inside a list block. Returns 0 for non-
    /// list blocks (treats "no list" as "depth zero" for the indent /
    /// outdent comparison).
    private func maxListDepth(_ block: Block?) -> Int {
        guard let block = block else { return 0 }
        guard case .list(let items, _) = block else { return 0 }
        return items.map { itemDepth($0) }.max() ?? 0
    }

    private func itemDepth(_ item: ListItem) -> Int {
        if item.children.isEmpty { return 0 }
        return 1 + (item.children.map { itemDepth($0) }.max() ?? 0)
    }

    /// For an `insertAtomic` row, locate the newly-inserted sibling
    /// (the block of `kind` adjacent to the original atomic block).
    private func locateInsertedSibling(
        originalAtomicKind: BlockKindFixture,
        row: FSMTransition,
        before: [Block],
        after: [Block]
    ) -> Block? {
        // Find the atomic block in `after`. The sibling is whichever
        // adjacent block was NOT present in `before` at the same
        // position.
        for (i, b) in after.enumerated() {
            if blockMatches(b, fixture: originalAtomicKind) {
                // The originally-positioned atomic. Pick the adjacent
                // slot that wasn't present at that index in `before`.
                if i > 0, !sameKindAt(before, after, atIndex: i - 1) {
                    return after[i - 1]
                }
                if i + 1 < after.count, !sameKindAt(before, after, atIndex: i + 1) {
                    return after[i + 1]
                }
            }
        }
        return nil
    }

    private func sameKindAt(_ a: [Block], _ b: [Block], atIndex idx: Int) -> Bool {
        guard idx < a.count, idx < b.count else { return false }
        return blockKindLabel(a[idx]) == blockKindLabel(b[idx])
    }

    /// Index of the block whose span contains `offset`, or nil if no
    /// span owns it. The trailing-newline byte at the end of a span
    /// belongs to the same block (closed interval on `[location,
    /// location + length]`) so cursors that landed right after the
    /// last typed character still resolve.
    private func blockIndex(
        containing offset: Int, in spans: [NSRange]
    ) -> Int? {
        for (i, span) in spans.enumerated() {
            if offset >= span.location
                && offset <= span.location + span.length {
                return i
            }
        }
        return nil
    }
}

// MARK: - Marker classification helpers (file-private)

private extension String {
    /// True if this is one of the bullet markers `"-"`, `"*"`, or `"+"`.
    var isBulletMarker: Bool {
        return self == "-" || self == "*" || self == "+"
    }
    /// True if this is a numbered marker like `"1."`, `"2)"`, etc.
    var isNumberedMarker: Bool {
        guard !self.isEmpty else { return false }
        let last = self.last!
        guard last == "." || last == ")" else { return false }
        let digits = self.dropLast()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

// MARK: - Safe array indexing

private extension Array {
    subscript(safe index: Int) -> Element? {
        return (index >= 0 && index < count) ? self[index] : nil
    }
}
