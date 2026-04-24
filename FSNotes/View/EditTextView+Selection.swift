//
//  EditTextView+Selection.swift
//  FSNotes
//
//  Phase 5b — cursor canonicalization.
//
//  Intercepts TK2's selection setter (`setSelectedRanges(_:affinity:stillSelecting:)`)
//  so that every selection change entering the editor is canonicalized
//  through a `DocumentRange` (pairs of `DocumentCursor`) before being
//  handed to `super`.
//
//  For v1 this is a byte-identical round-trip — the resulting `NSRange`
//  values passed to `super` equal the ones the caller passed in. The
//  value of the interception is not the behavior change (there is none)
//  but the fact that every selection now flows through the
//  block-model coordinate space at least once. That's the contract
//  Phase 5b declares: `DocumentCursor` is the truth, `NSTextLocation`
//  (and its `NSRange` shadow) is a derived view. Later phases (5e
//  composition, 5f undo/redo journaling) can count on this invariant
//  when they need to persist a cursor across an edit or re-project it
//  onto a different storage revision.
//
//  Scope:
//  - WYSIWYG block-model mode (`blockModelActive && !sourceRendererActive`
//    with a live `documentProjection`): canonicalize through `DocumentRange`.
//  - Source mode, loading/empty state, or any state without a projection:
//    pass through to `super` unchanged — the projection is the resolver
//    and we can't canonicalize without one.
//
//  Why `setSelectedRanges(_:affinity:stillSelecting:)` and not
//  `setSelectedRange(_:)`:
//  The single-range setter's documented behavior is to call the
//  multi-range setter under the hood. Overriding the multi-range
//  setter catches every selection change — single-range, multi-range
//  (discontiguous), programmatic, mouse-driven, arrow-key-driven. The
//  two-argument `(range, affinity)` overload is also routed through
//  this one by AppKit. See
//  `https://developer.apple.com/documentation/appkit/nstextview/setselectedranges(_:affinity:stillselecting:)`
//  for the documented delegation chain.
//

import Foundation
import AppKit

extension EditTextView {

    /// Canonicalize incoming selection ranges through `DocumentRange`
    /// (pairs of `DocumentCursor`) before handing off to `super`.
    ///
    /// In WYSIWYG block-model mode each incoming `NSRange` is
    /// converted to a `DocumentRange` via `DocumentRange.fromNSRange(_:in:)`
    /// and then back to an `NSRange` via `DocumentRange.toNSRange(in:)`.
    /// For valid in-range selections the round-trip is identity, so the
    /// observable selection does not change. If the projection is
    /// missing, nil, or the editor is in source mode, this override
    /// passes through unchanged.
    ///
    /// This hook also catches every selection change routed through
    /// the simpler `setSelectedRange(_:)` and the
    /// `setSelectedRange(_:affinity:stillSelecting:)` overloads — AppKit
    /// documents both as ultimately calling this designated setter.
    public override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        let canonicalized = canonicalizeSelectionRanges(ranges)
        super.setSelectedRanges(
            canonicalized, affinity: affinity, stillSelecting: stillSelecting
        )
    }

    /// Pure helper: given an array of `NSValue`-wrapped selection
    /// ranges, return the round-tripped array.
    ///
    /// Exposed `internal` for in-process tests that don't need a full
    /// `NSWindow`. Production code goes through `setSelectedRanges`.
    func canonicalizeSelectionRanges(_ ranges: [NSValue]) -> [NSValue] {
        // Source-mode or loading: pass through. `documentProjection` is
        // the resolver; without it we can't canonicalize.
        guard shouldCanonicalizeSelectionThroughDocumentRange,
              let projection = documentProjection else {
            return ranges
        }

        // Clamp to the current storage length. TK2 occasionally calls
        // `setSelectedRanges` with ranges that exceed the current
        // storage length (e.g. during a mid-edit layout pass); clamping
        // before round-tripping avoids handing the projection an
        // out-of-bounds index.
        let storageLen = textStorage?.length ?? 0

        return ranges.map { value -> NSValue in
            let incoming = value.rangeValue
            let clamped = clampRange(incoming, to: storageLen)
            guard let docRange = DocumentRange.fromNSRange(clamped, in: projection) else {
                // Unmappable input (negative location). Pass through
                // the original value; AppKit handles its own sanity
                // checks.
                return value
            }
            let roundTripped = docRange.toNSRange(in: projection)
            return NSValue(range: roundTripped)
        }
    }

    /// True when selection changes should be canonicalized through
    /// `DocumentRange`. Currently: block-model WYSIWYG mode only.
    /// Source mode keeps its own markdown-character-aware selection
    /// semantics — marker runs are *real text* under `SourceRenderer`,
    /// not derived presentation, so `DocumentCursor` (which is defined
    /// in terms of the inline tree of a block and does not carry
    /// marker offsets) is not the right coordinate space there.
    private var shouldCanonicalizeSelectionThroughDocumentRange: Bool {
        guard let processor = textStorageProcessor else { return false }
        return processor.blockModelActive && !processor.sourceRendererActive
    }

    /// Clamp `range` to `[0, storageLength]`, preserving `NSNotFound`
    /// and negative locations as-is so downstream conversion can
    /// detect them.
    private func clampRange(_ range: NSRange, to storageLength: Int) -> NSRange {
        if range.location < 0 || range.location == NSNotFound {
            return range
        }
        let loc = min(range.location, storageLength)
        let maxLen = storageLength - loc
        let len = max(0, min(range.length, maxLen))
        return NSRange(location: loc, length: len)
    }
}
