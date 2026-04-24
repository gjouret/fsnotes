//
//  EditContract.swift
//  FSNotesCore
//
//  Phase 1 of the TextKit 1 → 2 refactor introduces declarative
//  contracts for every EditingOps primitive and FSM transition.
//
//  Today, each primitive returns an `EditResult` that describes the
//  *textual* outcome (splice range + replacement + raw cursor int).
//  The structural outcome — which blocks were created, deleted,
//  merged, split, or renumbered — is implicit in the diff between
//  the old and new projections. That means bugs like "toggleList
//  accidentally deleted a neighboring block" are only caught by
//  human code review: nothing in the primitive's type signature
//  declares what it is allowed to change.
//
//  A contract makes the structural outcome explicit:
//
//      EditContract {
//          declaredActions: [EditAction]    // .deleteBlock(at: 3), …
//          postCursor:      DocumentCursor  // (blockPath, inlineOffset)
//          postSelectionLength: Int
//      }
//
//  The harness runs the declared actions against the before/after
//  projections as invariants — if the primitive changed something it
//  didn't declare (e.g. renumbered an adjacent list that the
//  contract said was untouched), the invariant fails and the bug
//  surfaces at the pure-function layer.
//
//  Why Phase 1 and not Phase 2: these types don't depend on TextKit
//  2. They're pure-function ergonomics. Getting them right before
//  the NSTextLayoutManager switchover means the migration has
//  something stable to convert into — DocumentCursor
//  (blockPath-based) is the natural representation for an
//  NSTextLocation-backed cursor, so Phase 2 replaces the storage-int
//  translation rather than re-designing the type.
//

import Foundation

// MARK: - DocumentCursor

/// A cursor position expressed in document terms, not storage terms.
///
/// `blockPath` identifies a block: for today's flat block model it's
/// always `[blockIndex]`. The type is path-shaped to survive the
/// eventual nesting of blocks inside list items without a migration.
///
/// `inlineOffset` is a character offset into the block's inline text
/// content (the flattened string produced by concatenating its
/// inline tree). For block kinds whose storage representation is a
/// single attachment (`.horizontalRule`, today's `.table`), the
/// offset is ignored and canonically 0.
///
/// Conversion between `DocumentCursor` and the raw storage `Int`
/// goes through the projection: the projection owns `blockSpans`
/// and therefore knows the storage location of each block. In
/// Phase 2, storage `Int` disappears and `DocumentCursor` resolves
/// directly to `NSTextLocation` via `NSTextContentStorage`.
public struct DocumentCursor: Equatable, CustomStringConvertible {

    public let blockPath: [Int]
    public let inlineOffset: Int

    public init(blockPath: [Int], inlineOffset: Int) {
        self.blockPath = blockPath
        self.inlineOffset = inlineOffset
    }

    /// Convenience: flat cursor for a single top-level block.
    public init(blockIndex: Int, inlineOffset: Int) {
        self.blockPath = [blockIndex]
        self.inlineOffset = inlineOffset
    }

    public var description: String {
        "DocumentCursor(\(blockPath), offset: \(inlineOffset))"
    }
}

// MARK: - EditAction

/// A single structural change a primitive may perform on the
/// document. Every non-trivial primitive declares its `EditAction`
/// list in its `EditContract`. The harness asserts that the diff
/// between before/after projections matches the declared actions —
/// undeclared structural changes (or missing ones) surface as
/// invariant failures.
///
/// Actions are intentionally coarse-grained: we're describing
/// *what* changed, not *how*. The "how" is the primitive's
/// implementation. A primitive that inserts two blocks declares
/// two `.insertBlock` actions; a primitive that merges two blocks
/// declares one `.mergeAdjacent`.
public enum EditAction: Equatable, CustomStringConvertible {

    /// A new block appeared at top-level index `index` (0-indexed
    /// in the post-edit document).
    case insertBlock(at: Int)

    /// The block at top-level index `index` (in the *pre*-edit
    /// document) was removed.
    case deleteBlock(at: Int)

    /// The block at top-level index `index` was replaced — same
    /// position, same-or-different kind, different content.
    case replaceBlock(at: Int)

    /// Two adjacent blocks were merged. `firstIndex` is the index
    /// of the first of the pair in the *pre*-edit document; the
    /// post-edit document is one block shorter.
    case mergeAdjacent(firstIndex: Int)

    /// A block was split in two. `blockIndex` is the pre-edit
    /// index. `inlineIndex` + `offset` identify the split point
    /// within that block's inline tree. The post-edit document is
    /// one block longer.
    case splitBlock(at: Int, inlineIndex: Int, offset: Int)

    /// An ordered list was renumbered. `startIndex` is the index
    /// of the first block affected; contiguous ordered-list blocks
    /// beginning there have fresh sequential markers.
    case renumberList(startIndex: Int)

    /// The indent/outdent of a range of list items changed.
    case reindentList(range: Range<Int>)

    /// An inline-level change within a single block — covers
    /// character typing, formatting toggle, deletion within a
    /// block. `blockIndex` is the top-level block; the rest is
    /// informational.
    case modifyInline(blockIndex: Int)

    /// A block kind changed (paragraph ↔ heading, paragraph ↔
    /// blockquote, paragraph ↔ list, list marker change, heading
    /// level change, todo-list toggle). The block stays at the
    /// same top-level index.
    case changeBlockKind(at: Int)

    /// A table cell's inline content changed. Does not alter
    /// table shape. The `location` encoding matches
    /// `TableCellLocation` in `EditingOps`.
    case replaceTableCell(blockIndex: Int, rowIndex: Int, colIndex: Int)

    public var description: String {
        switch self {
        case .insertBlock(let i):                        return "+block@\(i)"
        case .deleteBlock(let i):                        return "-block@\(i)"
        case .replaceBlock(let i):                       return "~block@\(i)"
        case .mergeAdjacent(let i):                      return "merge@\(i)+\(i+1)"
        case .splitBlock(let i, let inI, let o):         return "split@\(i)/\(inI)+\(o)"
        case .renumberList(let i):                       return "renumber@\(i)…"
        case .reindentList(let r):                       return "reindent@\(r.lowerBound)..<\(r.upperBound)"
        case .modifyInline(let i):                       return "~inline@\(i)"
        case .changeBlockKind(let i):                    return "kind@\(i)"
        case .replaceTableCell(let i, let r, let c):     return "~cell@\(i)[\(r),\(c)]"
        }
    }
}

// MARK: - EditContract

/// The declarative contract a primitive exposes to describe its
/// structural and cursor outcome. Populated by the primitive and
/// attached to `EditResult`.
///
/// The contract is a *declaration* — it is the primitive saying
/// "after my return, the document will differ from the input in
/// exactly these ways, and the cursor will be here." The harness
/// then verifies.
///
/// Empty `declaredActions` means "no structural change" — a
/// pure-inline edit that doesn't change block count or kind.
public struct EditContract: Equatable {

    public var declaredActions: [EditAction]
    public var postCursor: DocumentCursor
    public var postSelectionLength: Int

    /// Phase 5f: how to undo this edit. Populated at primitive
    /// result-construction time; consumed by `UndoJournal` when the
    /// user fires Cmd-Z. `nil` on primitives not yet retrofitted —
    /// the journal falls back to Tier C (full-document snapshot) in
    /// that case so undo never silently drops an edit.
    public var inverse: InverseStrategy?

    public init(
        declaredActions: [EditAction] = [],
        postCursor: DocumentCursor,
        postSelectionLength: Int = 0,
        inverse: InverseStrategy? = nil
    ) {
        self.declaredActions = declaredActions
        self.postCursor = postCursor
        self.postSelectionLength = postSelectionLength
        self.inverse = inverse
    }
}

// MARK: - InverseStrategy (Phase 5f)

public extension EditContract {

    /// Three tiers of "how to undo a primitive's effect":
    ///
    /// - **Tier A (`inverseContract`)**: the primitive exposes a
    ///   symmetric sibling contract that, when applied to the
    ///   post-edit document, reproduces the pre-edit document. Cheapest
    ///   — no block payload to carry. Used by single-run, single-block
    ///   edits: insert-without-newline, delete-without-merge, inline-trait
    ///   toggles, atomic table mutations that round-trip to themselves.
    ///
    /// - **Tier B (`blockSnapshot`)**: snapshot a contiguous slice of
    ///   `Document.blocks` before the edit. Undo replaces the same
    ///   slot-range in the post-edit document with the saved blocks +
    ///   ids. Used by structural edits bounded to a few blocks: Return
    ///   splits, cross-block merges, list FSM transitions, toggleList /
    ///   toggleBlockquote / HR insert, move-up/down, table-row insert,
    ///   multi-char insertWithTraits, paragraph ↔ heading kind changes.
    ///
    /// - **Tier C (`fullDocument`)**: snapshot the entire pre-edit
    ///   `Document`. Safety fallback when the primitive cannot
    ///   localize its effect (pathological toggleList that touches
    ///   non-adjacent blocks, huge multi-block paste, coalesce
    ///   helpers). Expensive — the journal caps Tier C entries at 5.
    ///
    /// Equatable so test harnesses can assert `inverse` round-trips
    /// exactly across corpus edits.
    ///
    /// `indirect` because `inverseContract` carries an `EditContract`
    /// which itself holds an optional `InverseStrategy` — symmetrical
    /// contracts form a recursive value graph.
    indirect enum InverseStrategy: Equatable {
        case inverseContract(contract: EditContract)
        case blockSnapshot(range: Range<Int>, blocks: [Block], ids: [UUID])
        case fullDocument(Document)
    }
}

// MARK: - Building the inverse

public extension EditContract.InverseStrategy {

    /// Generic tier-picker: construct the minimal `InverseStrategy`
    /// that, when applied to `newDoc`, recovers `priorDoc`. Picks
    /// Tier A/B/C based on the block-slot diff between the two.
    ///
    /// A primitive that has already computed its effect as a block
    /// slot diff can call this at result-construction to annotate its
    /// contract — no per-primitive inverse code to maintain. The
    /// per-primitive-picks-tier obligation becomes "call
    /// `buildInverse(priorDoc:newDoc:hintedTier:)`" with an optional
    /// hint for primitives that know they produced an inverse-contract
    /// sibling (Tier A round-trip toggles).
    ///
    /// Tier selection:
    ///
    /// - Zero block slots changed (a pure-inline edit that didn't
    ///   alter the block count) → Tier B snapshot of the affected
    ///   block (the primitive's `declaredActions` contains a
    ///   `.modifyInline` or `.changeBlockKind`). Falls back to Tier C
    ///   if the affected block can't be localized.
    /// - 1-3 block slots changed → Tier B snapshot of that slice.
    /// - >3 block slots changed OR non-contiguous slots → Tier C
    ///   full-document snapshot.
    static func buildInverse(
        priorDoc: Document,
        newDoc: Document
    ) -> EditContract.InverseStrategy {
        // Find the minimal contiguous block range that differs
        // between priorDoc and newDoc. LCS would be more accurate but
        // is overkill here — the primitive's `declaredActions` have
        // already told us roughly what changed.
        let priorBlocks = priorDoc.blocks
        let newBlocks = newDoc.blocks

        // Common prefix length.
        var prefix = 0
        let maxPrefix = min(priorBlocks.count, newBlocks.count)
        while prefix < maxPrefix && priorBlocks[prefix] == newBlocks[prefix] {
            prefix += 1
        }

        // Common suffix length (not overlapping the prefix).
        var suffix = 0
        while
            suffix < min(priorBlocks.count - prefix, newBlocks.count - prefix) &&
            priorBlocks[priorBlocks.count - 1 - suffix] ==
            newBlocks[newBlocks.count - 1 - suffix]
        {
            suffix += 1
        }

        let priorChangedCount = priorBlocks.count - prefix - suffix
        let newChangedCount = newBlocks.count - prefix - suffix

        // If both sides have the same (possibly zero) change width,
        // AND it's small, use Tier B.
        let changeWidth = max(priorChangedCount, newChangedCount)

        // Heuristic threshold for Tier C fallback.
        let tierCThreshold = 4

        if changeWidth > tierCThreshold {
            return .fullDocument(priorDoc)
        }

        // Tier B: snapshot the prior-side changed slice. The range
        // encodes the POST-edit slot range to overwrite — i.e.
        // `prefix..<(prefix + newChangedCount)`, which is where the
        // primitive's output lives in `newDoc`.
        let priorSliceRange = prefix..<(prefix + priorChangedCount)
        let postEditRange = prefix..<(prefix + newChangedCount)

        let snapshotBlocks = Array(priorBlocks[priorSliceRange])
        let snapshotIds = Array(priorDoc.blockIds[priorSliceRange])

        // Edge: documents identical — return a zero-width Tier B
        // snapshot rather than fullDocument, so the journal's record
        // path doesn't pay the cost. An undo that replaces 0 slots
        // with 0 snapshots is a no-op, correctly.
        return .blockSnapshot(
            range: postEditRange,
            blocks: snapshotBlocks,
            ids: snapshotIds
        )
    }
}

// MARK: - Applying the inverse

public extension EditContract.InverseStrategy {

    /// Apply this inverse strategy to `afterDoc` and return a
    /// reconstructed pre-edit `Document`. Pure function — no side
    /// effects; the caller owns delivery through `applyDocumentEdit`.
    ///
    /// - `inverseContract` — returns `afterDoc` unchanged and
    ///   requires the caller to run the sibling primitive on
    ///   `afterDoc` to reproduce `beforeDoc`. Tier A's round-trip
    ///   obligation lives at the primitive that emits the sibling
    ///   contract (e.g. `EditingOps.insert` annotates itself with a
    ///   `delete` sibling). This function returns `afterDoc` so the
    ///   journal's codepath is uniform; callers that need the
    ///   before-doc must replay the sibling contract themselves.
    ///
    /// - `blockSnapshot` — splices the saved blocks + ids back into
    ///   `afterDoc.blocks` at the recorded range. This is the common
    ///   Tier B path.
    ///
    /// - `fullDocument` — returns the saved document verbatim.
    func applyInverse(to afterDoc: Document) -> Document {
        switch self {
        case .inverseContract:
            // Tier A: the journal uses this for the sibling-contract
            // dispatch; this helper exists for Tier B/C symmetry.
            return afterDoc
        case let .blockSnapshot(range, blocks, ids):
            precondition(blocks.count == ids.count,
                         "InverseStrategy.blockSnapshot: blocks.count (\(blocks.count)) must match ids.count (\(ids.count))")
            var result = afterDoc
            // Splice: replace afterDoc.blocks[range] with the saved
            // blocks + ids. `range` is in the pre-edit index space; it
            // maps to the post-edit space as "the run that the
            // primitive emitted as replacement."
            //
            // For a well-formed Tier B snapshot, the caller recorded
            // `range` against the post-edit document's block slots —
            // i.e. the slots whose content was produced by this edit
            // and must be overwritten by the snapshot to restore the
            // pre-edit state.
            let clampedLower = max(0, min(range.lowerBound, result.blocks.count))
            let clampedUpper = max(clampedLower, min(range.upperBound, result.blocks.count))
            let clamped = clampedLower..<clampedUpper
            result.blocks.replaceSubrange(clamped, with: blocks)
            result.blockIds.replaceSubrange(clamped, with: ids)
            return result
        case let .fullDocument(doc):
            return doc
        }
    }
}

// MARK: - Cursor translation

public extension DocumentProjection {

    /// Resolve a `DocumentCursor` to its storage `Int` in *this*
    /// projection. For today's flat block model the path is
    /// `[blockIndex]`; we take element 0 and ignore the rest until
    /// Phase 2 nesting.
    ///
    /// Clamps `inlineOffset` to the block's span so callers
    /// cannot produce an out-of-bounds index even if they compute
    /// an offset against a stale projection.
    func storageIndex(for cursor: DocumentCursor) -> Int {
        guard let blockIndex = cursor.blockPath.first,
              blockSpans.indices.contains(blockIndex) else {
            return 0
        }
        let span = blockSpans[blockIndex]
        let clampedOffset = max(0, min(cursor.inlineOffset, span.length))
        return span.location + clampedOffset
    }

    /// Inverse: resolve a storage `Int` into a `DocumentCursor`
    /// for *this* projection. Primitives call this at the end to
    /// populate their `EditContract.postCursor`.
    func cursor(atStorageIndex storageIndex: Int) -> DocumentCursor {
        guard let (blockIndex, offsetInBlock) = blockContaining(storageIndex: storageIndex) else {
            // Fallback: first block, offset 0. An invalid storage
            // index can only happen if the caller violates the
            // primitive's pre-conditions; returning a safe cursor
            // is preferable to trapping.
            return DocumentCursor(blockIndex: 0, inlineOffset: 0)
        }
        return DocumentCursor(blockIndex: blockIndex, inlineOffset: offsetInBlock)
    }
}
