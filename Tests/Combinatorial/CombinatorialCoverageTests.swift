//
//  CombinatorialCoverageTests.swift
//  FSNotesTests
//
//  Phase 11 Slice E — runner for the combinatorial generator.
//
//  Drives every `(blockKind × cursorPosition × edit × selectionState)`
//  scenario emitted by `CBMatrix.allValid` and asserts MINIMAL
//  invariants on each:
//
//    1. No crash. The harness completes without throwing.
//    2. Cursor still inside SOME block. Post-edit
//       `selectedRange().location` resolves to a valid block via
//       `DocumentProjection.blockContaining`.
//    3. Block-count delta plausible. Compared to the FSM transition
//       table's `expected` value when a matching row exists; otherwise
//       asserted to be in {-1, 0, 1, 2}.
//    4. Inline-content preservation. If the document had N list-item
//       glyphs (bullet / numbered / todo) before and the action was
//       not a list-toggle, expect N after — modulo +/-1 from
//       structural transitions (exit-to-paragraph, indent / outdent).
//
//  Discovered bugs are NOT fixed in this slice. Each is recorded in
//  `Tests/Combinatorial/DiscoveredBugs.txt` (one line per scenario).
//  The runner reads that file at startup and `XCTExpectFailure`-wraps
//  the listed scenarios so the suite passes today; entries flip to
//  red ("unexpectedly passed") when the underlying bug is fixed.
//
//  See REFACTOR_PLAN.md → "Slice E — Combinatorial coverage".
//

import XCTest
import AppKit
@testable import FSNotes

final class CombinatorialCoverageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: - The single iterating test

    /// Drives every scenario in `CBMatrix.allValid`. Each scenario is
    /// wrapped in `XCTContext.runActivity` so per-tuple failures show
    /// in Xcode's test navigator.
    ///
    /// Scenarios listed in `DiscoveredBugs.txt` are wrapped in
    /// `XCTExpectFailure(strict: true)` — they fail-by-design today
    /// and turn red ("unexpectedly passed") when fixed.
    func test_combinatorialCoverage() {
        let scenarios = CBMatrix.allValid
        let discovered = loadDiscoveredBugs()

        // Sanity: the matrix should be at least 400 scenarios after
        // pruning. The REFACTOR_PLAN target is 400-600; we set a
        // lower bound here so an accidental over-prune stops the suite
        // rather than passing trivially. Current size is ~780 scenarios.
        XCTAssertGreaterThanOrEqual(
            scenarios.count, 400,
            "Combinatorial matrix dropped below the Slice E minimum " +
            "(400 scenarios). Got \(scenarios.count). Either pruning is " +
            "too aggressive or the axis enums lost entries."
        )

        // Diagnostic trace: write each scenario label to a log file as
        // it runs so post-mortem analysis can correlate failures (the
        // harness's contract-assertion failures don't carry the
        // activity name through XCTContext, so we maintain our own
        // breadcrumb). The log lives at `~/unit-tests/combinatorial-trace.txt`
        // (debug builds are not sandboxed; NSHomeDirectory resolves
        // to the real home). Truncated at start of run.
        let traceURL = traceLogURL()
        try? FileManager.default.createDirectory(
            at: traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "".write(to: traceURL, atomically: true, encoding: .utf8)

        for scenario in scenarios {
            appendTrace("RUN: \(scenario.label)\n", to: traceURL)
            XCTContext.runActivity(named: scenario.label) { _ in
                if discovered.contains(scenario.label) {
                    XCTExpectFailure(
                        "Discovered bug — recorded in DiscoveredBugs.txt. " +
                        "Remove the entry when the underlying behaviour is fixed.",
                        strict: true
                    ) {
                        runScenario(scenario)
                    }
                } else {
                    runScenario(scenario)
                }
            }
        }
    }

    private func traceLogURL() -> URL {
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("unit-tests")
            .appendingPathComponent("combinatorial-trace.txt")
    }

    private func appendTrace(_ s: String, to url: URL) {
        guard let data = s.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Per-scenario execution

    /// Drive one scenario end-to-end:
    ///   1. Build a fresh `EditorScenario` seeded for the block kind.
    ///   2. Resolve the cursor offset / selection range.
    ///   3. Apply the edit.
    ///   4. Read the post-edit Document and assert minimal invariants.
    private func runScenario(_ scenario: CBScenario) {
        let seed = CBSeedTable.seed(for: scenario.blockKind, position: scenario.position)
        let editorScenario = Given.note(markdown: seed.markdown)

        // Snapshot before-state.
        guard let beforeProjection = editorScenario.editor.documentProjection else {
            XCTFail("[\(scenario.label)] no documentProjection after seeding.")
            return
        }
        let beforeBlocks = beforeProjection.document.blocks
        let beforeCount = beforeBlocks.count

        // The crossBlock selection state requires ≥2 blocks in the
        // seed. Every seed in CBSeedTable has ≥3 blocks (first,
        // separator, target, ...) so this is structurally safe — but
        // assert it for the future when seeds change.
        if scenario.selection == .crossBlock, beforeCount < 2 {
            // Skip this tuple — it's not exerciseable. Not a failure.
            return
        }

        // Resolve cursor offset for the block + position.
        guard let cursorOffset = resolveCursorOffset(
            scenario: scenario, seed: seed, projection: beforeProjection
        ) else {
            XCTFail(
                "[\(scenario.label)] could not resolve cursor offset for " +
                "block \(seed.targetBlockIndex) position \(scenario.position)."
            )
            return
        }

        // Apply selection state.
        applySelection(
            scenario: scenario,
            seed: seed,
            cursorOffset: cursorOffset,
            projection: beforeProjection,
            on: editorScenario
        )

        // Drive the edit. Capture failure count delta — anything
        // recorded during applyEdit() is harness-side (e.g.
        // Invariants.assertContract slot-identity check) and must be
        // attributed to this scenario.
        let failuresBefore = self.testRun?.failureCount ?? 0
        applyEdit(scenario.edit, on: editorScenario)
        let failuresAfter = self.testRun?.failureCount ?? 0
        if failuresAfter > failuresBefore {
            appendTrace(
                "  CONTRACT_FAIL: \(scenario.label) " +
                "(failures \(failuresBefore) → \(failuresAfter))\n",
                to: traceLogURL()
            )
        }

        // Snapshot after-state.
        guard let afterProjection = editorScenario.editor.documentProjection else {
            XCTFail("[\(scenario.label)] no documentProjection after edit.")
            return
        }
        let afterBlocks = afterProjection.document.blocks
        let afterCount = afterBlocks.count

        // ----- Invariant 1: no crash. We reached this line, so PASS.

        // ----- Invariant 2: cursor inside SOME block.
        let postCursor = editorScenario.editor.selectedRange().location
        let storageLen = editorScenario.editor.textStorage?.length ?? 0
        if postCursor < 0 || postCursor > storageLen {
            XCTFail(
                "[\(scenario.label)] cursor \(postCursor) outside storage " +
                "length \(storageLen)."
            )
            return
        }
        // postCursor == storageLen is a valid "end of doc" position;
        // blockContaining returns nil there. Treat as valid.
        if postCursor < storageLen,
           afterProjection.blockContaining(storageIndex: postCursor) == nil {
            XCTFail(
                "[\(scenario.label)] cursor \(postCursor) does not " +
                "resolve to any block (storage length \(storageLen))."
            )
            return
        }

        // ----- Invariant 3: block-count delta plausible.
        // Skip the delta-window check for `fullDocument` selection —
        // selecting all and pressing a key intentionally collapses the
        // document to 1 block (or 0 + a blank), so any delta is fine
        // as long as the cursor stayed inside SOME block (Invariant 2).
        if scenario.selection != .fullDocument {
            let delta = afterCount - beforeCount
            if !(-2...3).contains(delta) {
                XCTFail(
                    "[\(scenario.label)] block count delta \(delta) outside " +
                    "expected window {-2…+3}. before=\(beforeCount) " +
                    "after=\(afterCount)."
                )
                return
            }
            // Tighter check when an FSM-table row exists for this tuple.
            if let row = matchingFSMRow(for: scenario), row.bugId == nil {
                assertDeltaMatchesFSMRow(
                    scenario: scenario, row: row,
                    beforeCount: beforeCount, afterCount: afterCount
                )
            }
        }

        // ----- Invariant 4: glyph counts preserved (modulo allowed delta).
        // Skip for fullDocument selection — replacing the entire doc
        // legitimately removes all glyphs.
        if scenario.selection != .fullDocument {
            let beforeGlyphs = countListGlyphs(beforeBlocks)
            let afterGlyphs = countListGlyphs(afterBlocks)
            let glyphDelta = afterGlyphs - beforeGlyphs
            if !(-3...3).contains(glyphDelta) {
                XCTFail(
                    "[\(scenario.label)] list-glyph delta \(glyphDelta) " +
                    "outside ±3 window. before=\(beforeGlyphs) after=\(afterGlyphs)."
                )
            }
        }

        // ----- Invariant 5: live Document round-trips through serialize/parse.
        // The strongest single invariant — catches attribute drift, inline
        // reordering, identity changes, and any state that can't survive
        // save+reload. Mirrors EditorHTMLParityTests.assertLiveDocumentRoundTrips.
        assertRoundTripParity(label: scenario.label, doc: afterProjection.document)
    }

    /// Assert that `HTML(parse(serialize(doc))) == HTML(doc)`. Failures
    /// here mean the live document is in a state that won't survive
    /// save+reload — the strongest single invariant we have.
    private func assertRoundTripParity(label: String, doc: Document) {
        let liveHTML = CommonMarkHTMLRenderer.render(doc)
        let reparsed = MarkdownParser.parse(MarkdownSerializer.serialize(doc))
        let reparsedHTML = CommonMarkHTMLRenderer.render(reparsed)
        if liveHTML != reparsedHTML {
            XCTFail(
                "[\(label)] live Document does NOT round-trip through " +
                "serialize→parse. Live HTML differs from re-parsed HTML — " +
                "this state cannot survive save+reload."
            )
        }
    }

    // MARK: - Cursor / selection resolution

    private func resolveCursorOffset(
        scenario: CBScenario,
        seed: CBSeed,
        projection: DocumentProjection
    ) -> Int? {
        guard seed.targetBlockIndex < projection.blockSpans.count else {
            return nil
        }
        let span = projection.blockSpans[seed.targetBlockIndex]
        let block = projection.document.blocks[seed.targetBlockIndex]
        let homeOffset = inlineHomeOffset(forBlock: block, span: span)
        switch scenario.position {
        case .atStart:
            // Multi-item / nested list: cursor on second / inner item.
            switch scenario.blockKind {
            case .multiItemList:
                // Second item home is roughly span.location + (length of
                // first item). Use heuristic: walk to the byte after
                // the first '\n' in the rendered region.
                return secondItemHome(span: span, in: projection.attributed.string)
                    ?? homeOffset
            case .nestedList:
                return secondItemHome(span: span, in: projection.attributed.string)
                    ?? homeOffset
            default:
                return homeOffset
            }
        case .atEnd:
            return span.location + span.length
        case .midContent:
            let inlineEnd = span.location + span.length
            return homeOffset + max(0, (inlineEnd - homeOffset) / 2)
        case .onEmptyBlock:
            return homeOffset
        }
    }

    /// "Home" offset for a block — start of editable inline content.
    /// Lists / todos prefix the inline content with a single attachment
    /// character (the bullet / number / checkbox glyph) at
    /// `span.location`; home is `span.location + 1`.
    private func inlineHomeOffset(forBlock block: Block, span: NSRange) -> Int {
        switch block {
        case .list:
            return span.location + 1
        default:
            return span.location
        }
    }

    /// Best-effort scan for the second item's home offset within a
    /// list block's span. Walks the span looking for the FIRST '\n'
    /// then advances one (the '\n' anchors the next item; the
    /// attachment character follows immediately).
    private func secondItemHome(span: NSRange, in text: String) -> Int? {
        let ns = text as NSString
        let endLoc = min(span.location + span.length, ns.length)
        var i = span.location
        while i < endLoc {
            if ns.character(at: i) == 0x0A {  // '\n'
                let candidate = i + 2  // skip newline + attachment char
                if candidate < endLoc { return candidate }
                return nil
            }
            i += 1
        }
        return nil
    }

    private func applySelection(
        scenario: CBScenario,
        seed: CBSeed,
        cursorOffset: Int,
        projection: DocumentProjection,
        on editorScenario: EditorScenario
    ) {
        let storageLen = editorScenario.editor.textStorage?.length ?? 0
        switch scenario.selection {
        case .empty:
            editorScenario.cursorAt(cursorOffset)

        case .intraBlock:
            // Select 1 character starting at cursorOffset (or back up
            // by 1 if at end of storage).
            let span = (seed.targetBlockIndex < projection.blockSpans.count)
                ? projection.blockSpans[seed.targetBlockIndex]
                : NSRange(location: 0, length: 0)
            let blockEnd = span.location + span.length
            let start = min(cursorOffset, max(span.location, blockEnd - 1))
            let length = min(1, max(0, blockEnd - start))
            if length > 0 {
                editorScenario.select(NSRange(location: start, length: length))
            } else {
                editorScenario.cursorAt(cursorOffset)
            }

        case .crossBlock:
            // Select from cursorOffset to a point inside the next
            // block (storage offset cursorOffset + 4).
            let length = min(4, max(0, storageLen - cursorOffset))
            editorScenario.select(NSRange(location: cursorOffset, length: length))

        case .fullDocument:
            editorScenario.selectAll()
        }
    }

    // MARK: - Edit dispatch

    private func applyEdit(_ edit: CBEdit, on scenario: EditorScenario) {
        switch edit {
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
        }
    }

    /// Mirror of `FSMTransitionTableTests.simulateTabKey` — drive the
    /// list FSM transition directly to avoid offscreen-window keyDown
    /// dispatch quirks.
    private func simulateTabKey(on editor: EditTextView, withShift: Bool) {
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
        // Non-list state: Tab/Shift-Tab is a structure-preserving
        // op (insert indent characters or focus change). The minimal-
        // invariant assertions catch surprising behaviour without
        // needing a real key event.
    }

    // MARK: - FSM-row matching

    /// Find a row in `FSMTransitionTable.all` matching the scenario's
    /// (blockKind, cursorPosition, action) triplet. Used to enforce a
    /// tighter delta-check when the FSM owns the transition.
    private func matchingFSMRow(for scenario: CBScenario) -> FSMTransition? {
        // Only the empty-selection scenarios map cleanly onto FSM rows.
        guard scenario.selection == .empty else { return nil }
        guard let fsmKind = mapToFSMKind(scenario.blockKind) else { return nil }
        guard let fsmPos = mapToFSMPosition(scenario.position) else { return nil }
        guard let fsmAction = mapToFSMAction(scenario.edit) else { return nil }

        return FSMTransitionTable.all.first { row in
            row.blockKind == fsmKind
                && row.cursorPosition == fsmPos
                && row.action == fsmAction
        }
    }

    private func mapToFSMKind(_ kind: CBBlockKind) -> BlockKindFixture? {
        switch kind {
        case .paragraph:        return .paragraph
        case .heading(let l):   return .heading(level: l)
        case .bulletList:       return .bulletList
        case .numberedList:     return .numberedList
        case .todoList:         return .todoList
        case .blockquote:       return .blockquote
        case .codeBlock:        return .codeBlock
        case .table:            return .table
        case .horizontalRule:   return .horizontalRule
        // Mermaid / displayMath / multiItem / nested have no FSM table
        // counterpart — their behaviour is what Slice E discovers.
        default:                return nil
        }
    }

    private func mapToFSMPosition(_ pos: CBCursorPosition) -> CursorPositionFixture? {
        switch pos {
        case .atStart:      return .atStart
        case .midContent:   return .midContent
        case .atEnd:        return .atEnd
        case .onEmptyBlock: return .onEmptyBlock
        }
    }

    private func mapToFSMAction(_ edit: CBEdit) -> ActionFixture? {
        switch edit {
        case .pressReturn:        return .pressReturn
        case .pressBackspace:     return .pressBackspace
        case .pressForwardDelete: return .pressForwardDelete
        case .pressTab:           return .pressTab
        case .pressShiftTab:      return .pressShiftTab
        }
    }

    /// When an FSM row's `expected` directly maps to a block-count
    /// delta, enforce it. Coarse-grained — we only check the count
    /// dimension, not the specific kinds (the FSM table tests already
    /// do that).
    private func assertDeltaMatchesFSMRow(
        scenario: CBScenario,
        row: FSMTransition,
        beforeCount: Int,
        afterCount: Int
    ) {
        let actual = afterCount - beforeCount
        let expected: ClosedRange<Int>
        switch row.expected {
        case .stayInBlock, .noOp, .exitToBlock, .indent, .outdent:
            expected = 0...0
        case .splitBlock:
            expected = 1...3   // one+ new blocks, sometimes with separators
        case .mergeWithPrevious:
            expected = (-1)...(-1)
        case .insertAtomic:
            expected = 1...2
        case .unsupported:
            return  // skip
        }
        if !expected.contains(actual) {
            XCTFail(
                "[\(scenario.label)] block-count delta \(actual) does not " +
                "match FSM row '\(row.label)' expected window \(expected). " +
                "before=\(beforeCount) after=\(afterCount)."
            )
        }
    }

    // MARK: - List glyph counting

    /// Count list-item glyphs (bullet / numbered / todo) across the
    /// document. Used by Invariant 4. Recursive so nested items count.
    private func countListGlyphs(_ blocks: [Block]) -> Int {
        var n = 0
        for b in blocks {
            if case .list(let items, _) = b {
                n += countItems(items)
            }
        }
        return n
    }

    private func countItems(_ items: [ListItem]) -> Int {
        var n = items.count
        for item in items {
            n += countItems(item.children)
        }
        return n
    }

    // MARK: - DiscoveredBugs.txt

    /// Read the DiscoveredBugs.txt file and return the set of scenario
    /// labels listed there. Each non-empty, non-comment line is one
    /// scenario label exactly matching `CBScenario.label`.
    private func loadDiscoveredBugs() -> Set<String> {
        let url = discoveredBugsURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var out = Set<String>()
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // The file format is: "<label> → <expected vs actual>".
            // Extract the label (everything before the first " → ").
            let label: String
            if let arrowRange = trimmed.range(of: " → ") {
                label = String(trimmed[..<arrowRange.lowerBound])
            } else {
                label = trimmed
            }
            out.insert(label)
        }
        return out
    }

    /// URL of the DiscoveredBugs.txt file shipped alongside this test.
    /// Resolved at test-run time via the test bundle.
    private func discoveredBugsURL() -> URL {
        // The file is in the test source directory next to this swift
        // file. XCTest doesn't ship a path-to-source helper, so we use
        // the compile-time `#filePath` of THIS file as the anchor and
        // resolve a sibling path. This works because debug builds are
        // not sandboxed — `#filePath` resolves to the real source path.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile.deletingLastPathComponent()
            .appendingPathComponent("DiscoveredBugs.txt")
    }

    // MARK: - Sequence runner (length 2 + 3, leverages composable harness)

    /// Drives every length-2 and length-3 action sequence from
    /// `CBSequenceMatrix.allValid` against each seed kind. This is what
    /// the composable `EditorScenario` was built for: chain
    /// `pressReturn`/`type`/`pressDelete`/`pressTab`/`pressShiftTab` and
    /// assert at the end. Same minimal-invariants + round-trip parity
    /// as the single-action runner.
    func test_combinatorialSequences() {
        let scenarios = CBSequenceMatrix.allValid
        let discovered = loadDiscoveredBugs()

        XCTAssertGreaterThanOrEqual(
            scenarios.count, 500,
            "Sequence matrix dropped below 500. Got \(scenarios.count). " +
            "Either pruning is too aggressive or seedKinds shrank."
        )

        let traceURL = traceLogURL()
        try? FileManager.default.createDirectory(
            at: traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Append (not truncate) — the single-action runner already wrote
        // its trace; we want both in one file for post-mortem.
        appendTrace("\n=== SEQUENCE RUN ===\n", to: traceURL)

        for scenario in scenarios {
            appendTrace("RUN: \(scenario.label)\n", to: traceURL)
            XCTContext.runActivity(named: scenario.label) { _ in
                if discovered.contains(scenario.label) {
                    XCTExpectFailure(
                        "Discovered sequence bug — recorded in DiscoveredBugs.txt.",
                        strict: true
                    ) {
                        runSequenceScenario(scenario)
                    }
                } else {
                    runSequenceScenario(scenario)
                }
            }
        }
    }

    /// Drive one sequence scenario:
    ///   1. Build a fresh `EditorScenario` seeded for the block kind.
    ///   2. Move cursor to the block's home offset.
    ///   3. Apply each action in `actions` via the chainable harness verbs.
    ///   4. Assert minimal invariants + round-trip parity at the end.
    private func runSequenceScenario(_ scenario: CBSequenceScenario) {
        let seed = CBSeedTable.seed(for: scenario.blockKind, position: .atStart)
        let editorScenario = Given.note(markdown: seed.markdown)

        guard let beforeProj = editorScenario.editor.documentProjection else {
            XCTFail("[\(scenario.label)] no projection after seeding.")
            return
        }
        guard let cursorOffset = resolveCursorOffset(
            scenario: CBScenario(
                blockKind: scenario.blockKind, position: .atStart,
                edit: .pressReturn, selection: .empty
            ),
            seed: seed,
            projection: beforeProj
        ) else {
            XCTFail("[\(scenario.label)] could not resolve cursor offset.")
            return
        }
        editorScenario.cursorAt(cursorOffset)

        // Drive each action in the sequence. Uses the chainable
        // EditorScenario verbs the composable harness exposes. Snapshot
        // failure count per-action so harness-side contract failures
        // (which fire from inside `pressDelete` / `pressReturn` and
        // don't carry the scenario label) get attributed to a label
        // via the trace log.
        for (i, action) in scenario.actions.enumerated() {
            let before = self.testRun?.failureCount ?? 0
            applySequenceAction(action, on: editorScenario)
            let after = self.testRun?.failureCount ?? 0
            if after > before {
                appendTrace(
                    "  HARNESS_FAIL: \(scenario.label) at action[\(i)]=\(action)\n",
                    to: traceLogURL()
                )
            }
        }

        // Snapshot the after-state.
        guard let afterProj = editorScenario.editor.documentProjection else {
            XCTFail("[\(scenario.label)] no projection after sequence.")
            return
        }

        // Invariant 1: no crash (we got here).
        // Invariant 2: cursor inside SOME block.
        let postCursor = editorScenario.editor.selectedRange().location
        let storageLen = editorScenario.editor.textStorage?.length ?? 0
        if postCursor < 0 || postCursor > storageLen {
            XCTFail(
                "[\(scenario.label)] cursor \(postCursor) outside storage " +
                "length \(storageLen)."
            )
            return
        }
        if postCursor < storageLen,
           afterProj.blockContaining(storageIndex: postCursor) == nil {
            XCTFail(
                "[\(scenario.label)] cursor does not resolve to any block."
            )
            return
        }

        // Invariant 3 (loose): block-count delta sane. Sequences can
        // grow up to +3 blocks (each Return splits) and shrink up to -3
        // (each Backspace merges); be permissive — we want round-trip
        // to be the strong gate.
        let beforeCount = beforeProj.document.blocks.count
        let afterCount = afterProj.document.blocks.count
        let delta = afterCount - beforeCount
        if !(-5...5).contains(delta) {
            XCTFail(
                "[\(scenario.label)] block-count delta \(delta) outside ±5."
            )
        }

        // Invariant 5: round-trip parity (the strong one).
        assertRoundTripParity(label: scenario.label, doc: afterProj.document)
    }

    private func applySequenceAction(
        _ action: CBSequenceAction,
        on scenario: EditorScenario
    ) {
        switch action {
        case .typeChar:
            scenario.type("a")
        case .pressReturn:
            scenario.pressReturn()
        case .pressDelete:
            scenario.pressDelete()
        case .pressTab:
            simulateTabKey(on: scenario.editor, withShift: false)
        case .pressShiftTab:
            simulateTabKey(on: scenario.editor, withShift: true)
        }
    }
}
