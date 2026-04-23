//
//  Invariants.swift
//  FSNotesTests
//
//  Phase 0 seed invariants. Every harness-driven test should call
//  `Invariants.assertAll(harness)` at meaningful checkpoints (after
//  seeding, after each scripted input, before teardown). The
//  invariants assert properties that MUST hold for every valid
//  editor state, regardless of the edit sequence that produced it.
//
//  A failure at a checkpoint localizes a bug to the operation just
//  performed. This is the whole reason the harness exists.
//
//  Categories, from REFACTOR_PLAN.md Phase 0:
//  - content-manager equivalence (today: storage.string ⇄ serialize(Document))
//  - selection validity (range inside content bounds)
//  - block-element parity (Document.blocks count matches serialized block count)
//  - CommonMark baseline (harness content round-trips through parse/serialize)
//
//  Invariants are allowed to be *looser* than the eventual TextKit 2
//  equivalence (character-position ↔ NSTextLocation). They represent
//  the strongest properties that hold today on TextKit 1 + block model
//  and continue to hold after the migration.
//

import XCTest
import AppKit
@testable import FSNotes

/// Checkpoint invariants. Static-only namespace; not meant to be
/// instantiated.
enum Invariants {

    // MARK: - Entry points

    /// Run every invariant and record failures via XCTFail.
    /// Call this at every meaningful checkpoint in harness tests.
    static func assertAll(
        _ harness: EditorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertSelectionValid(harness, file: file, line: line)
        assertContentManagerEquivalence(harness, file: file, line: line)
        assertBlockElementParity(harness, file: file, line: line)
        assertCommonMarkRoundTrip(harness, file: file, line: line)
    }

    // MARK: - Individual invariants

    /// Selection range lies within the current content's UTF-16
    /// character bounds. An out-of-bounds selection is one of the
    /// canonical symptoms of a seam bug.
    static func assertSelectionValid(
        _ harness: EditorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let length = (harness.contentString as NSString).length
        let range = harness.selectedRange

        XCTAssertTrue(
            range.location != NSNotFound,
            "Selection location is NSNotFound",
            file: file, line: line
        )
        XCTAssertTrue(
            range.location >= 0 && range.location <= length,
            "Selection location \(range.location) out of bounds (0…\(length))",
            file: file, line: line
        )
        XCTAssertTrue(
            range.length >= 0,
            "Selection length \(range.length) is negative",
            file: file, line: line
        )
        XCTAssertTrue(
            range.location + range.length <= length,
            "Selection end \(range.location + range.length) exceeds content length \(length)",
            file: file, line: line
        )
    }

    /// Content-manager equivalence: the visible text in `textStorage`
    /// matches the text that `Document` serializes to. This is the
    /// "no drift between Document and storage" invariant — the target
    /// TextKit 2 refactor makes this tautological, but today it's a
    /// property we have to check explicitly because storage and
    /// Document are peer sources of truth.
    ///
    /// Weakness note: today's pipeline renders markers visually (not
    /// in storage) for block-model notes. So `savedMarkdown` (what
    /// disk sees) and `contentString` (what storage holds) can
    /// diverge. The invariant here is the *structural* one: what
    /// we'd save MUST round-trip through parse/serialize cleanly.
    /// Character-for-character equivalence is a TextKit-2-era goal.
    static func assertContentManagerEquivalence(
        _ harness: EditorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let doc = harness.document else {
            // Source-mode or non-markdown — no Document, nothing to
            // diff against. Storage is authoritative on its own.
            return
        }
        let serialized = MarkdownSerializer.serialize(doc)
        let reparsed = MarkdownParser.parse(serialized)
        let roundTripped = MarkdownSerializer.serialize(reparsed)
        XCTAssertEqual(
            serialized, roundTripped,
            "Document does not round-trip through parse/serialize",
            file: file, line: line
        )
    }

    /// Block-element parity: the number of top-level blocks in
    /// `Document.blocks` matches the number of blocks that the
    /// serialized markdown would re-parse to. Catches cases where
    /// an edit leaves the Document in a structurally-inconsistent
    /// state (e.g. split/merge gone wrong).
    ///
    /// This is a weaker form of the TextKit 2 "element count == block
    /// count" invariant. Once each block has its own NSTextElement,
    /// we'll assert count(elements) == count(Document.blocks).
    static func assertBlockElementParity(
        _ harness: EditorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let doc = harness.document else { return }
        let serialized = MarkdownSerializer.serialize(doc)
        let reparsed = MarkdownParser.parse(serialized)
        XCTAssertEqual(
            doc.blocks.count, reparsed.blocks.count,
            "Block count drifted: Document has \(doc.blocks.count), re-parse has \(reparsed.blocks.count)",
            file: file, line: line
        )
    }

    /// CommonMark baseline: the current content, serialized and re-parsed
    /// through the block-model pipeline, produces the same Document.
    /// This catches edits that generate non-canonical markdown which
    /// the parser would re-interpret differently on reload.
    static func assertCommonMarkRoundTrip(
        _ harness: EditorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let doc = harness.document else { return }
        let serialized = MarkdownSerializer.serialize(doc)
        let reparsed = MarkdownParser.parse(serialized)
        // Structural equality: blocks equal, trailingNewline equal.
        XCTAssertEqual(
            doc, reparsed,
            "Document != parse(serialize(Document)) — edit produced non-idempotent markdown",
            file: file, line: line
        )
    }

    // MARK: - Phase 1 contract invariants

    /// Assert that the structural diff between `before` and `after`
    /// projections matches the primitive's `declaredActions`. The
    /// declaration is a *specification* — the harness holds the
    /// primitive to exactly what it promised.
    ///
    /// Extra (undeclared) changes fail the invariant: that's the
    /// "toggleList accidentally deleted a neighbor" bug class.
    /// Missing declared changes also fail: a primitive that claims
    /// to change kind but leaves the kind identical is lying.
    ///
    /// Pilot implementation handles the action kinds needed for
    /// `changeHeadingLevel`. Additional cases are added as primitives
    /// are retrofitted.
    static func assertContract(
        before: DocumentProjection,
        after: DocumentProjection,
        contract: EditContract,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let beforeBlocks = before.document.blocks
        let afterBlocks = after.document.blocks

        // Index-level diff: which block indices structurally changed
        // between before and after. We compute this as two sets —
        // "changed in place" (same-index, differing block) vs "count
        // mismatch" (insertions/deletions). This is coarse today;
        // nested-block support in Phase 2 will extend it.

        // Compute the net block-count delta expected from the declared
        // actions, and verify the observed delta matches.
        let expectedDelta = contract.declaredActions.reduce(0) { acc, act in
            switch act {
            case .insertBlock, .splitBlock:         return acc + 1
            case .deleteBlock, .mergeAdjacent:      return acc - 1
            default:                                return acc
            }
        }
        let observedDelta = afterBlocks.count - beforeBlocks.count
        XCTAssertEqual(
            expectedDelta, observedDelta,
            "Block count delta mismatch: expected \(expectedDelta), got \(observedDelta) (before=\(beforeBlocks.count), after=\(afterBlocks.count), actions=\(contract.declaredActions))",
            file: file, line: line
        )

        if contract.declaredActions.isEmpty {
            // No structural change declared. Blocks must match exactly.
            XCTAssertEqual(
                beforeBlocks, afterBlocks,
                "Contract declared no actions but blocks changed: before=\(beforeBlocks.count) after=\(afterBlocks.count)",
                file: file, line: line
            )
        }

        // Collect the set of pre-edit indices and post-edit indices that
        // the contract says are "allowed to change". For size-preserving
        // actions (changeBlockKind, modifyInline, replaceBlock), the pre-
        // and post-edit indices coincide. For size-changing actions
        // (insert/delete/split/merge), the primitive is claiming the
        // change happens at that index, so we skip neighbor-equality
        // checks for this pilot implementation and rely on the
        // count-delta invariant above.
        var hasSizeChange = false
        var touchedInPlace: Set<Int> = []

        for action in contract.declaredActions {
            switch action {
            case .changeBlockKind(let i),
                 .modifyInline(blockIndex: let i),
                 .replaceBlock(let i):
                touchedInPlace.insert(i)
            case .replaceTableCell(let i, _, _):
                touchedInPlace.insert(i)
            case .insertBlock, .deleteBlock, .mergeAdjacent, .splitBlock:
                hasSizeChange = true
            case .renumberList, .reindentList:
                // These can touch a range; we don't know bounds without
                // more metadata. Skip strict neighbor check for now.
                hasSizeChange = true
            }
        }

        // Validate bounds and neighbor preservation for in-place actions
        // (only when there are no size-changing actions in the same
        // contract).
        if !hasSizeChange && !touchedInPlace.isEmpty {
            for idx in 0..<min(beforeBlocks.count, afterBlocks.count) {
                if touchedInPlace.contains(idx) { continue }
                XCTAssertEqual(
                    beforeBlocks[idx], afterBlocks[idx],
                    "Contract leaked to undeclared block \(idx) (declaredActions=\(contract.declaredActions))",
                    file: file, line: line
                )
            }
            for i in touchedInPlace {
                XCTAssertTrue(
                    beforeBlocks.indices.contains(i) && afterBlocks.indices.contains(i),
                    "Declared action references out-of-range block \(i)",
                    file: file, line: line
                )
            }
        }

        // Structural per-cell diff for `.replaceTableCell` actions. The
        // contract declares exactly which cell changed; the harness verifies
        // that every OTHER cell in the table — header, body, alignments —
        // is structurally equal between before and after. Without this,
        // a primitive that accidentally clobbered a second cell while
        // editing the declared one would slip past the block-level check
        // (both tables would still be `.table` at index i, just with
        // different-but-both-declared-touched cells).
        //
        // `rowIndex = -1` is the header-cell sentinel used by EditingOps.
        // `rowIndex >= 0` refers to `rows[rowIndex]`.
        for action in contract.declaredActions {
            guard case .replaceTableCell(let bi, let r, let c) = action else { continue }
            guard beforeBlocks.indices.contains(bi),
                  afterBlocks.indices.contains(bi) else {
                XCTFail(
                    "replaceTableCell references out-of-range block \(bi)",
                    file: file, line: line
                )
                continue
            }
            guard case .table(let beforeHeader, let beforeAlignments,
                              let beforeRows, _, _) = beforeBlocks[bi] else {
                XCTFail(
                    "replaceTableCell(\(bi), \(r), \(c)): before block at \(bi) is not a .table",
                    file: file, line: line
                )
                continue
            }
            guard case .table(let afterHeader, let afterAlignments,
                              let afterRows, _, _) = afterBlocks[bi] else {
                XCTFail(
                    "replaceTableCell(\(bi), \(r), \(c)): after block at \(bi) is not a .table",
                    file: file, line: line
                )
                continue
            }

            // Shape preservation: header count, row count, per-row column
            // count, and alignments all unchanged. `.replaceTableCell` is
            // explicitly a cell-content edit; any shape change is a
            // different action class (not declared here).
            XCTAssertEqual(
                beforeHeader.count, afterHeader.count,
                "replaceTableCell(\(bi), \(r), \(c)): header column count changed (\(beforeHeader.count) → \(afterHeader.count))",
                file: file, line: line
            )
            XCTAssertEqual(
                beforeAlignments, afterAlignments,
                "replaceTableCell(\(bi), \(r), \(c)): alignments changed — not permitted by this action",
                file: file, line: line
            )
            XCTAssertEqual(
                beforeRows.count, afterRows.count,
                "replaceTableCell(\(bi), \(r), \(c)): row count changed (\(beforeRows.count) → \(afterRows.count))",
                file: file, line: line
            )

            // Per-cell diff. Every cell OTHER than the declared (r, c)
            // must be byte-identical in inline content. The declared
            // cell is expected to differ (but we don't require it — a
            // no-op `.replaceTableCell` is still a valid declaration,
            // e.g. toggleBold on an already-bold run).
            let shapeOK = beforeHeader.count == afterHeader.count &&
                          beforeRows.count == afterRows.count

            if shapeOK {
                // Header row.
                for col in 0..<beforeHeader.count {
                    let isDeclared = (r == -1 && col == c)
                    if !isDeclared {
                        XCTAssertEqual(
                            beforeHeader[col], afterHeader[col],
                            "replaceTableCell(\(bi), \(r), \(c)): undeclared header cell [header,\(col)] changed",
                            file: file, line: line
                        )
                    }
                }
                // Body rows.
                for row in 0..<beforeRows.count {
                    let beforeRow = beforeRows[row]
                    let afterRow = afterRows[row]
                    XCTAssertEqual(
                        beforeRow.count, afterRow.count,
                        "replaceTableCell(\(bi), \(r), \(c)): row \(row) column count changed",
                        file: file, line: line
                    )
                    let rowShapeOK = beforeRow.count == afterRow.count
                    if rowShapeOK {
                        for col in 0..<beforeRow.count {
                            let isDeclared = (r == row && col == c)
                            if !isDeclared {
                                XCTAssertEqual(
                                    beforeRow[col], afterRow[col],
                                    "replaceTableCell(\(bi), \(r), \(c)): undeclared body cell [\(row),\(col)] changed",
                                    file: file, line: line
                                )
                            }
                        }
                    }
                }
            }
        }

        // Verify postCursor resolves within the new projection bounds.
        let storageIdx = after.storageIndex(for: contract.postCursor)
        let totalLen = after.blockSpans.last.map { $0.location + $0.length } ?? 0
        XCTAssertTrue(
            storageIdx >= 0 && storageIdx <= totalLen,
            "postCursor resolves out of bounds: storageIdx=\(storageIdx) totalLen=\(totalLen)",
            file: file, line: line
        )

        // ID alignment: `blockIds` must stay 1:1 with `blocks` in both
        // projections. A drift here is almost always a primitive that
        // mutated `blocks` directly (e.g. `doc.blocks.append(x)`) instead
        // of through the identity-aware helpers on `Document`.
        XCTAssertTrue(
            before.document.isIdAligned,
            "before.document.blockIds (\(before.document.blockIds.count)) drifted from before.document.blocks (\(before.document.blocks.count))",
            file: file, line: line
        )
        XCTAssertTrue(
            after.document.isIdAligned,
            "after.document.blockIds (\(after.document.blockIds.count)) drifted from after.document.blocks (\(after.document.blocks.count))",
            file: file, line: line
        )

        // ID preservation / minting per declared action. The slot-identity
        // model (see `Document.blockIds` doc) says:
        //   - `.replaceBlock(at:)`       — id at that slot preserved.
        //   - `.changeBlockKind(at:)`    — id at that slot preserved.
        //   - `.modifyInline(at:)`       — id at that slot preserved.
        //   - `.replaceTableCell(at:...)`— id at that slot preserved.
        //   - `.insertBlock(at:)`        — id at that post-edit slot is fresh
        //                                  (not present in before's id set).
        //   - `.deleteBlock(at:)`        — id at that pre-edit slot is
        //                                  dropped (not present in after's set).
        //   - `.splitBlock(at:...)`      — pre-edit id preserved at post-edit
        //                                  slot `at`; post-edit slot `at+1`
        //                                  is fresh.
        //   - `.mergeAdjacent(firstIndex:)` — pre-edit id at `firstIndex`
        //                                  preserved at post-edit `firstIndex`;
        //                                  pre-edit id at `firstIndex+1` dropped.
        //   - `.renumberList`/`.reindentList` — ids in the affected range
        //                                  preserved (but we don't know the
        //                                  bounds precisely, so we skip the
        //                                  strict check and rely on no-extra
        //                                  structural change).
        //
        // When multiple actions appear in one contract (e.g. a merge-then-
        // inline-modify sequence that coalesceAdjacentLists produced), the
        // invariant model is weaker — we only check the counts match.
        let beforeIdSet = Set(before.document.blockIds)
        let afterIdSet = Set(after.document.blockIds)

        // Duplicate-id detection — a slot id appearing twice in the same
        // projection is a bug: `insertBlock` minted a colliding UUID, or
        // a `replaceBlocks` caller supplied an already-used id.
        XCTAssertEqual(
            beforeIdSet.count, before.document.blockIds.count,
            "before.document.blockIds has duplicates — slot ids must be unique",
            file: file, line: line
        )
        XCTAssertEqual(
            afterIdSet.count, after.document.blockIds.count,
            "after.document.blockIds has duplicates — slot ids must be unique",
            file: file, line: line
        )

        // Per-action id checks. Only applied when the action list is
        // unambiguous (single action, or all size-preserving actions).
        // Multi-action contracts skip per-action id checks and rely on
        // the structural invariants above.
        if contract.declaredActions.count == 1 {
            let action = contract.declaredActions[0]
            let beforeIds = before.document.blockIds
            let afterIds = after.document.blockIds
            switch action {
            case .replaceBlock(let i),
                 .changeBlockKind(let i),
                 .modifyInline(blockIndex: let i),
                 .replaceTableCell(blockIndex: let i, _, _):
                if beforeIds.indices.contains(i), afterIds.indices.contains(i) {
                    XCTAssertEqual(
                        beforeIds[i], afterIds[i],
                        "Slot identity at index \(i) not preserved by \(action): before=\(beforeIds[i]) after=\(afterIds[i])",
                        file: file, line: line
                    )
                }
            case .insertBlock(let i):
                if afterIds.indices.contains(i) {
                    XCTAssertFalse(
                        beforeIdSet.contains(afterIds[i]),
                        "Inserted slot at \(i) reused a pre-edit id \(afterIds[i]) — insertBlock must mint a fresh UUID",
                        file: file, line: line
                    )
                }
            case .deleteBlock(let i):
                if beforeIds.indices.contains(i) {
                    XCTAssertFalse(
                        afterIdSet.contains(beforeIds[i]),
                        "Deleted slot at \(i) kept its id \(beforeIds[i]) in the post-edit set — deleteBlock must drop it",
                        file: file, line: line
                    )
                }
            case .splitBlock(at: let i, _, _):
                if beforeIds.indices.contains(i), afterIds.indices.contains(i) {
                    XCTAssertEqual(
                        beforeIds[i], afterIds[i],
                        "splitBlock must preserve the pre-edit id at the first half: before[\(i)]=\(beforeIds[i]) after[\(i)]=\(afterIds[i])",
                        file: file, line: line
                    )
                }
                if afterIds.indices.contains(i + 1) {
                    XCTAssertFalse(
                        beforeIdSet.contains(afterIds[i + 1]),
                        "splitBlock second-half id \(afterIds[i + 1]) must be fresh (not present in before)",
                        file: file, line: line
                    )
                }
            case .mergeAdjacent(firstIndex: let i):
                if beforeIds.indices.contains(i), afterIds.indices.contains(i) {
                    XCTAssertEqual(
                        beforeIds[i], afterIds[i],
                        "mergeAdjacent must preserve the first slot's id: before[\(i)]=\(beforeIds[i]) after[\(i)]=\(afterIds[i])",
                        file: file, line: line
                    )
                }
                if beforeIds.indices.contains(i + 1) {
                    XCTAssertFalse(
                        afterIdSet.contains(beforeIds[i + 1]),
                        "mergeAdjacent must drop the second slot's id \(beforeIds[i + 1])",
                        file: file, line: line
                    )
                }
            case .renumberList, .reindentList:
                // Range-scoped operations — the bounds aren't recorded on
                // the action, so we settle for the "no extra structural
                // change" check above.
                break
            }
        }
    }
}
