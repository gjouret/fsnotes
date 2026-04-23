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

    public init(
        declaredActions: [EditAction] = [],
        postCursor: DocumentCursor,
        postSelectionLength: Int = 0
    ) {
        self.declaredActions = declaredActions
        self.postCursor = postCursor
        self.postSelectionLength = postSelectionLength
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
