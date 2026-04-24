//
//  DocumentCursorLocation.swift
//  FSNotesCore
//
//  Phase 5b — cursor canonicalization.
//
//  `DocumentCursor` is the canonical cursor type: a block-model coordinate
//  (block path + inline offset) that is independent of how the document is
//  laid out in storage. This file is the translation layer between
//  `DocumentCursor` and the TextKit 2 location types (`NSTextLocation`,
//  `NSTextRange`, and their `NSRange` shadows on the underlying
//  `NSTextStorage`).
//
//  A `DocumentRange` is the selection-shaped peer of `DocumentCursor`: a
//  pair of block-model cursors that define a contiguous span of document
//  content. Like `DocumentCursor`, it is independent of storage layout —
//  converting a `DocumentRange` to an `NSRange` requires a
//  `DocumentProjection` to resolve each cursor into a storage offset.
//
//  THE CONTRACT
//
//  1. `DocumentCursor` is the *truth*. `NSTextLocation` (and the
//     `NSRange`/`Int` shadows) are derived views — computed from a
//     `DocumentProjection` + `NSTextContentStorage` pair at the moment a
//     caller needs them.
//
//  2. Translation in both directions goes through the projection.
//     - Forward  (cursor → storage): `DocumentProjection.storageIndex(for:)`
//                                    already exists (see EditContract.swift).
//     - Inverse  (storage → cursor): `DocumentProjection.cursor(atStorageIndex:)`
//                                    already exists.
//     This file adds `NSTextLocation` convenience overloads that wrap those
//     calls by bridging to/from `NSRange` via `contentStorage.documentRange`.
//
//  3. An `NSTextLocation` produced from a `DocumentCursor` is valid only
//     for the projection + storage pair that produced it. Projections are
//     immutable — every edit produces a fresh projection — so the live
//     editor must always call the translation functions with the *current*
//     projection. Stale projections yield stale locations.
//
//  4. All conversions clamp to the valid storage range. Out-of-range
//     storage indices produce the `nil` result documented on the
//     individual function. Out-of-range cursors are clamped by
//     `DocumentProjection.storageIndex(for:)` (see EditContract.swift:204).
//
//  Why a separate file from EditContract.swift:
//  The storage-int translation helpers on `DocumentProjection` live on the
//  pure types in `EditContract.swift` because the `EditContract` itself
//  needs them. The `NSTextLocation` overloads added here depend on
//  `NSTextContentStorage`, which is AppKit-only (macOS) and UIKit-only
//  (iOS) — keeping them out of `EditContract.swift` means the pure-type
//  file stays pure-Foundation, while this file carries the TK2 bridge.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - DocumentCursor ↔ NSTextLocation

public extension DocumentCursor {

    /// Resolve this cursor to an `NSTextLocation` in the given content
    /// storage, using `projection` as the storage-layout map.
    ///
    /// The returned location is an offset from
    /// `contentStorage.documentRange.location` by the storage-index value
    /// that `projection.storageIndex(for: self)` computes. That storage
    /// index is already clamped to the valid block-span range, so the
    /// returned `NSTextLocation` is always in-range for the given
    /// storage (never past `contentStorage.documentRange.endLocation`).
    ///
    /// - Returns: `nil` only if the content storage has no document
    ///   range (an uninitialized `NSTextContentStorage` with no
    ///   `textStorage`). In practice the live editor's storage always
    ///   has a document range so callers can treat `nil` as an
    ///   "impossible, the storage is torn down" signal.
    func toTextLocation(
        in contentStorage: NSTextContentStorage,
        using projection: DocumentProjection
    ) -> NSTextLocation? {
        let storageIdx = projection.storageIndex(for: self)
        let docStart = contentStorage.documentRange.location
        return contentStorage.location(docStart, offsetBy: storageIdx)
    }

    /// Inverse: build a `DocumentCursor` from an `NSTextLocation` in the
    /// given content storage, using `projection` as the storage-layout
    /// map.
    ///
    /// - Returns: `nil` if `location` is outside `contentStorage`'s
    ///   document range, or if the computed storage index does not map
    ///   to any block via `projection.blockContaining(storageIndex:)`
    ///   (a location on an inter-block separator that the projection
    ///   chooses not to map to any block). `DocumentProjection.cursor(atStorageIndex:)`
    ///   falls back to `(blockIndex: 0, inlineOffset: 0)` for
    ///   unmappable indices, so this overload returns the same fallback
    ///   value rather than `nil` in those cases — `nil` is reserved for
    ///   "location is outside the document range."
    static func from(
        textLocation location: NSTextLocation,
        in contentStorage: NSTextContentStorage,
        using projection: DocumentProjection
    ) -> DocumentCursor? {
        let docStart = contentStorage.documentRange.location
        let docEnd = contentStorage.documentRange.endLocation
        // Outside document range → nil. Equal to docEnd is allowed
        // (cursor at the very end of the document).
        if contentStorage.offset(from: docStart, to: location) < 0 {
            return nil
        }
        if contentStorage.offset(from: location, to: docEnd) < 0 {
            return nil
        }
        let storageIdx = contentStorage.offset(from: docStart, to: location)
        return projection.cursor(atStorageIndex: storageIdx)
    }
}

// MARK: - DocumentRange

/// A selection-shaped pair of `DocumentCursor`s defining a contiguous
/// span of document content. The canonical representation of a selection
/// in block-model coordinates; callers translate to `NSRange` only at the
/// boundary with AppKit / TextKit 2.
///
/// `start` and `end` are both block-model cursors. A `DocumentRange` is
/// empty when `start == end` (the cursor-only case — a zero-length
/// selection). The type does not enforce `start` ≤ `end` at the
/// block-model layer because block ordering comparison requires a
/// projection; callers that need the normalized ordering should convert
/// through `NSRange` (which normalizes naturally via
/// `NSRange.location`/`length`).
public struct DocumentRange: Equatable {

    public let start: DocumentCursor
    public let end: DocumentCursor

    public init(start: DocumentCursor, end: DocumentCursor) {
        self.start = start
        self.end = end
    }

    /// Convenience: a zero-length range at a single cursor.
    public init(cursor: DocumentCursor) {
        self.start = cursor
        self.end = cursor
    }

    /// True when `start == end` (cursor-only, no span).
    public var isEmpty: Bool { start == end }

    // MARK: - NSRange bridging

    /// Resolve this `DocumentRange` to an `NSRange` in storage
    /// coordinates. Uses the projection to map each endpoint's cursor.
    ///
    /// The returned range is always ordered so that `.location` is
    /// smaller than `.location + .length` — if the caller passed a
    /// `DocumentRange` whose `start` maps to a later storage index than
    /// `end`, the result swaps them. This matches AppKit selection
    /// conventions where `NSRange` is always forward-oriented.
    public func toNSRange(in projection: DocumentProjection) -> NSRange {
        let startIdx = projection.storageIndex(for: start)
        let endIdx = projection.storageIndex(for: end)
        if startIdx <= endIdx {
            return NSRange(location: startIdx, length: endIdx - startIdx)
        } else {
            return NSRange(location: endIdx, length: startIdx - endIdx)
        }
    }

    /// Inverse: build a `DocumentRange` from an `NSRange` in storage
    /// coordinates. Both endpoints are resolved via
    /// `projection.cursor(atStorageIndex:)`.
    ///
    /// - Returns: `nil` if `range.location` or `NSMaxRange(range)` is
    ///   negative (i.e. `NSNotFound`-sentinel input). An out-of-bounds
    ///   range above `projection.attributed.length` does not return
    ///   nil — the projection's `cursor(atStorageIndex:)` falls back to
    ///   the first-block / zero-offset cursor, matching the existing
    ///   `storageIndex(for:)` clamping semantics.
    public static func fromNSRange(
        _ range: NSRange,
        in projection: DocumentProjection
    ) -> DocumentRange? {
        guard range.location >= 0 else { return nil }
        let endLoc = range.location + range.length
        guard endLoc >= 0 else { return nil }
        let startCursor = projection.cursor(atStorageIndex: range.location)
        let endCursor = projection.cursor(atStorageIndex: endLoc)
        return DocumentRange(start: startCursor, end: endCursor)
    }

    // MARK: - NSTextLocation bridging

    /// Resolve this `DocumentRange` to an `NSTextRange` in the given
    /// content storage. Returns `nil` if either endpoint cannot be
    /// bridged into an `NSTextLocation` (only possible if the storage
    /// is torn down — see `DocumentCursor.toTextLocation`).
    ///
    /// Like `toNSRange(in:)`, the returned range is ordered: `start`
    /// is always the earlier location, even if this `DocumentRange`
    /// was constructed with a reverse-oriented start/end pair.
    public func toTextRange(
        in contentStorage: NSTextContentStorage,
        using projection: DocumentProjection
    ) -> NSTextRange? {
        guard let startLoc = start.toTextLocation(in: contentStorage, using: projection),
              let endLoc = end.toTextLocation(in: contentStorage, using: projection) else {
            return nil
        }
        let order = contentStorage.offset(from: startLoc, to: endLoc)
        if order >= 0 {
            return NSTextRange(location: startLoc, end: endLoc)
        } else {
            return NSTextRange(location: endLoc, end: startLoc)
        }
    }

    /// Inverse: build a `DocumentRange` from an `NSTextRange`.
    static func fromTextRange(
        _ textRange: NSTextRange,
        in contentStorage: NSTextContentStorage,
        using projection: DocumentProjection
    ) -> DocumentRange? {
        guard let startCursor = DocumentCursor.from(
            textLocation: textRange.location,
            in: contentStorage, using: projection
        ), let endCursor = DocumentCursor.from(
            textLocation: textRange.endLocation,
            in: contentStorage, using: projection
        ) else { return nil }
        return DocumentRange(start: startCursor, end: endCursor)
    }
}
