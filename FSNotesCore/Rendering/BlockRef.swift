//
//  BlockRef.swift
//  FSNotesCore
//
//  Content-hash keyed reference to a `Block` in a `Document`. Used by
//  the Code-Block Edit Toggle feature (slice 1+) so the renderer and
//  applier can identify "which blocks are in editing form" across
//  document versions WITHOUT tracking block-index positions.
//
//  ARCHITECTURAL CONTRACT
//  ----------------------
//  - `BlockRef` is keyed on a stable content-hash of the block's
//    canonical serialized markdown form. Two `Block` values that
//    serialize byte-identical produce byte-identical `BlockRef`s.
//  - Stable across structural edits that insert blocks ABOVE the
//    ref'd block: index-keyed references shift on every insert above,
//    content-hash refs do not.
//  - `Hashable` / `Equatable`: refs are first-class members of `Set`
//    and dictionary keys.
//  - Collision policy: content-hash collisions on full markdown text
//    are vanishingly unlikely for typical code-block sizes. If they
//    ever appear in practice, upgrade the hash function here — every
//    consumer goes through `BlockRef(_:)` so the fix is local.
//
//  Stability notes
//  ---------------
//  - The hash is computed from `MarkdownSerializer.serializeBlock(_:)`
//    output. That function is pure and deterministic (round-trip
//    invariant is an existing test property of the serializer), so
//    same block value → same hash across process boundaries, app
//    launches, and Swift versions.
//  - Not persisted. `editingCodeBlocks` is a per-editor-session
//    in-memory set.
//

import Foundation

/// A stable content-hash reference to a `Block` in a `Document`.
///
/// Two `Block` values that serialize to the same markdown text
/// produce equal `BlockRef`s. Insert-above structural edits do not
/// invalidate a ref because the block's content is unchanged.
public struct BlockRef: Hashable {

    /// Hash of the block's canonical markdown form. Stable across
    /// process boundaries since `MarkdownSerializer.serializeBlock`
    /// is a pure function of the block's value.
    public let contentHash: Int

    /// Construct a ref from a block value. Walks
    /// `MarkdownSerializer.serializeBlock(_:)` and hashes the
    /// resulting string.
    public init(_ block: Block) {
        var hasher = Hasher()
        hasher.combine(MarkdownSerializer.serializeBlock(block))
        self.contentHash = hasher.finalize()
    }

    /// Direct initializer for tests that want to construct a ref
    /// without a `Block` value on hand. Not used in production paths.
    public init(contentHash: Int) {
        self.contentHash = contentHash
    }
}
