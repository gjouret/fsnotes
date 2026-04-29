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
                              let beforeRows, _) = beforeBlocks[bi] else {
                XCTFail(
                    "replaceTableCell(\(bi), \(r), \(c)): before block at \(bi) is not a .table",
                    file: file, line: line
                )
                continue
            }
            guard case .table(let afterHeader, let afterAlignments,
                              let afterRows, _) = afterBlocks[bi] else {
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

    // MARK: - Attachment-identity invariant (fsnotes-ibj)

    /// Assert that an edit preserved `NSTextAttachment` *object identity*
    /// for attachments that the contract didn't claim to touch.
    ///
    /// **Why this matters.** TK2's `NSTextAttachmentViewProvider` cache
    /// is keyed on attachment instance identity (`===`), not value-
    /// equality (`isEqual`). Replacing a bullet / checkbox / image
    /// attachment with a fresh-but-identical instance forces TK2 to
    /// drop the cached view provider and call `loadView()` again on the
    /// next layout pass. The user perceives that as a per-keystroke
    /// flash on every visible glyph touched by the splice — fsnotes-ibj.
    ///
    /// The contract `narrowSplice` is meant to uphold (see
    /// `EditingOperations.narrowSplice` doc comment) is exactly this
    /// invariant, expressed in storage-byte terms. By asserting it
    /// directly on attachment instances we sidestep the storage-layer
    /// detail and catch the bug class regardless of which renderer or
    /// applier path produced the splice.
    ///
    /// **Two clauses:**
    /// 1. *Outside-touched-block.* For every `(offset, attachment)` in
    ///    `beforeSnapshot` whose host block isn't named in the
    ///    contract's declared actions, the same instance must still be
    ///    in `afterStorage` at the corresponding (possibly-shifted)
    ///    offset. Catches "edits to block A leaked into block B's
    ///    attachment view providers".
    /// 2. *Inside-touched-block, value-preserved.* For each touched
    ///    block (`.modifyInline` / `.changeBlockKind` / `.replaceBlock`
    ///    / `.replaceTableCell`), every attachment in the BEFORE block
    ///    whose value-equal counterpart sits at the same within-block
    ///    offset in the AFTER block must keep its `===` identity.
    ///    Catches the in-list-item flicker — the original ibj symptom.
    ///
    /// **Limitations** (acknowledged):
    /// - Skipped when any structural action is present
    ///   (`.insertBlock`, `.deleteBlock`, `.mergeAdjacent`,
    ///   `.splitBlock`, `.renumberList`, `.reindentList`). Those shift
    ///   block indices in ways the simple before/after pairing here
    ///   doesn't model. A v2 of this invariant could handle them.
    /// - The within-block correspondence in clause 2 uses same-relative-
    ///   offset matching — adequate for typing, backspace, and trait
    ///   toggles where attachment positions don't shift, but won't
    ///   catch every correspondence. Wrap with the bounded pairing
    ///   when stricter coverage is needed.
    static func assertAttachmentIdentityPreservation(
        beforeSnapshot: [Int: NSTextAttachment],
        afterStorage: NSTextStorage,
        before: DocumentProjection,
        after: DocumentProjection,
        contract: EditContract,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Bail out early if the contract carries any structural action;
        // index shifting is out of scope for this v1 invariant.
        for action in contract.declaredActions {
            switch action {
            case .insertBlock, .deleteBlock,
                 .mergeAdjacent, .splitBlock,
                 .renumberList, .reindentList:
                return
            default:
                break
            }
        }

        // Collect the set of touched block indices (these all index into
        // the BEFORE document, since the size-preserving actions don't
        // shift). Multi-touch is allowed; an empty set means "no
        // structural change declared" and triggers strict whole-storage
        // identity preservation (clause 1 covers everything).
        var touchedBefore: Set<Int> = []
        for action in contract.declaredActions {
            switch action {
            case .modifyInline(blockIndex: let i),
                 .changeBlockKind(let i),
                 .replaceBlock(let i),
                 .replaceTableCell(blockIndex: let i, _, _):
                touchedBefore.insert(i)
            default:
                break  // structural actions returned above
            }
        }

        // Helper: which BEFORE block contains this offset? Returns nil
        // if no block covers the offset (rare; happens in inter-block
        // separator slots).
        func beforeBlockIndex(forOffset offset: Int) -> Int? {
            for (i, span) in before.blockSpans.enumerated() {
                if offset >= span.location && offset < span.location + span.length {
                    return i
                }
            }
            return nil
        }

        let afterStorageLen = afterStorage.length

        // Compute the cumulative offset shift for blocks AFTER the
        // touched range. For non-structural actions, indices don't
        // shift, but the touched block's length can. So an attachment
        // in a non-touched block whose index is greater than the max
        // touched index needs to be looked up at a shifted offset.
        let maxTouched = touchedBefore.max()
        let beforeBlocksTotalLen: Int = before.blockSpans.last
            .map { $0.location + $0.length } ?? 0
        let afterBlocksTotalLen: Int = after.blockSpans.last
            .map { $0.location + $0.length } ?? 0
        let totalDelta = afterBlocksTotalLen - beforeBlocksTotalLen

        // === Clause 1: outside-touched-block identity preservation ===
        for (offset, beforeAttachment) in beforeSnapshot {
            guard let i = beforeBlockIndex(forOffset: offset) else {
                continue  // attachment outside any block — shouldn't happen, ignore
            }
            if touchedBefore.contains(i) {
                continue  // handled in clause 2
            }

            // Compute the corresponding AFTER offset. Indices don't
            // shift for non-structural actions; only the touched
            // block's length differs, so blocks before the touched
            // band are at unchanged offsets, blocks after are shifted
            // by `totalDelta`.
            let afterOffset: Int
            if let mt = maxTouched, i > mt {
                afterOffset = offset + totalDelta
            } else {
                afterOffset = offset
            }
            guard afterOffset >= 0, afterOffset < afterStorageLen else {
                XCTFail(
                    "[attachment-identity / clause 1] before offset \(offset) " +
                    "(non-touched block \(i)) maps to after offset " +
                    "\(afterOffset) which is out of bounds for storage " +
                    "length \(afterStorageLen)",
                    file: file, line: line
                )
                continue
            }
            let afterAttachment = afterStorage.attribute(
                .attachment, at: afterOffset, effectiveRange: nil
            ) as? NSTextAttachment
            XCTAssertTrue(
                beforeAttachment === afterAttachment,
                "[attachment-identity / clause 1] non-touched block \(i)'s " +
                "attachment at offset \(offset)→\(afterOffset) was " +
                "replaced (instance changed). " +
                "before=\(Unmanaged.passUnretained(beforeAttachment).toOpaque()), " +
                "after=\(afterAttachment.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil")",
                file: file, line: line
            )
        }

        // === Clause 2: inside-touched-block, value-equal must keep === ===
        for i in touchedBefore {
            guard before.blockSpans.indices.contains(i),
                  after.blockSpans.indices.contains(i)
            else { continue }
            let beforeBlockRange = before.blockSpans[i]
            let afterBlockRange = after.blockSpans[i]
            let beforeStart = beforeBlockRange.location
            let beforeEnd = beforeStart + beforeBlockRange.length
            let afterStart = afterBlockRange.location
            let afterEnd = afterStart + afterBlockRange.length

            // For each BEFORE attachment in the touched block, look up
            // the AFTER attachment at the same within-block offset. If
            // value-equal, the instance must match.
            for (offset, beforeAttachment) in beforeSnapshot {
                guard offset >= beforeStart, offset < beforeEnd else {
                    continue
                }
                let withinOffset = offset - beforeStart
                let afterOffset = afterStart + withinOffset
                guard afterOffset >= afterStart, afterOffset < afterEnd,
                      afterOffset < afterStorageLen
                else { continue }
                let afterAttachment = afterStorage.attribute(
                    .attachment, at: afterOffset, effectiveRange: nil
                ) as? NSTextAttachment
                guard let after = afterAttachment else { continue }
                if !beforeAttachment.isEqual(after) { continue }
                XCTAssertTrue(
                    beforeAttachment === after,
                    "[attachment-identity / clause 2] touched block \(i): " +
                    "value-equal attachment at within-block offset " +
                    "\(withinOffset) (storage \(offset)→\(afterOffset)) " +
                    "was replaced with a fresh instance — TK2's " +
                    "view-provider cache will miss. " +
                    "Symptom: visible flash on every keystroke (fsnotes-ibj). " +
                    "Root cause: the splice covered this offset even " +
                    "though the attachment value didn't change. The fix " +
                    "lives in narrowSplice / DocumentEditApplier.",
                    file: file, line: line
                )
            }
        }
    }
}
