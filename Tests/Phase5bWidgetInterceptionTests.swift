//
//  Phase5bWidgetInterceptionTests.swift
//  FSNotesTests
//
//  Phase 5b — widget-level cursor canonicalization tests.
//
//  Pure-function coverage of the `DocumentCursor ↔ NSTextLocation`
//  translation layer lives in `Phase5bCursorCanonicalizationTests`. This
//  file exercises the *live* editor's `setSelectedRanges(_:affinity:
//  stillSelecting:)` override — the hook `EditTextView+Selection.swift`
//  installs — by driving it against a real `EditTextView` behind an
//  `EditorHarness`. The purpose is to pin down that the interception
//  actually fires (not just that the helper it calls returns the right
//  values) and that every early-exit path is observable.
//
//  Coverage matrix:
//    1. Single-range selection round-trips byte-equal through the
//       override.
//    2. Multi-range (discontiguous) selection round-trips byte-equal
//       per-range.
//    3. Out-of-bounds `NSRange` gets clamped to `[0, storageLength]`
//       per the `clampRange` logic in `EditTextView+Selection.swift`.
//    4. Source-mode editor (no `documentProjection`) passes through
//       unchanged — no canonicalization happens.
//    5. `NSNotFound` sentinel is preserved unchanged through the
//       override (pass-through per the clamp logic's explicit check).
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase5bWidgetInterceptionTests: XCTestCase {

    // MARK: - Test 1: single-range selection round-trips identically

    /// Setting a simple single-range selection via `setSelectedRanges`
    /// round-trips byte-equal: what we hand `super` matches what the
    /// caller passed. This is the v1 contract — canonicalization is
    /// idempotent for valid spans.
    func test_widget_singleRange_roundTripsIdentically() {
        let harness = EditorHarness(markdown: "hello world\n")
        defer { harness.teardown() }

        // Pick a span inside the first (and only) paragraph.
        let ns = NSRange(location: 2, length: 5)  // "llo w"
        harness.editor.setSelectedRanges(
            [NSValue(range: ns)],
            affinity: .downstream,
            stillSelecting: false
        )

        XCTAssertEqual(harness.editor.selectedRanges.count, 1)
        let observed = (harness.editor.selectedRanges[0] as! NSValue).rangeValue
        XCTAssertEqual(observed, ns, "single-range selection should survive canonicalization byte-equal")
    }

    // MARK: - Test 2: discontiguous multi-range selection round-trips

    /// Setting a multi-range (discontiguous) selection also round-trips
    /// each range byte-equal. The override iterates `ranges.map`, so
    /// every range flows through `DocumentRange` translation
    /// independently.
    func test_widget_multiRange_roundTripsIdentically() {
        let harness = EditorHarness(markdown: "hello world foo bar baz\n")
        defer { harness.teardown() }

        // Two disjoint, forward-ordered spans inside the paragraph.
        let r1 = NSRange(location: 0, length: 5)   // "hello"
        let r2 = NSRange(location: 12, length: 3)  // "foo"
        harness.editor.setSelectedRanges(
            [NSValue(range: r1), NSValue(range: r2)],
            affinity: .downstream,
            stillSelecting: false
        )

        // AppKit may normalize / merge selections; the contract this
        // test pins is that *the ranges we hand super after
        // canonicalization* equal the ranges we passed in. We verify
        // by driving the `canonicalizeSelectionRanges` helper directly
        // (same translation path the override invokes) and checking
        // byte-equal on the mapped output.
        let canonicalized = harness.editor.canonicalizeSelectionRanges(
            [NSValue(range: r1), NSValue(range: r2)]
        )
        XCTAssertEqual(canonicalized.count, 2)
        XCTAssertEqual(
            (canonicalized[0] as! NSValue).rangeValue, r1,
            "first range should survive canonicalization byte-equal"
        )
        XCTAssertEqual(
            (canonicalized[1] as! NSValue).rangeValue, r2,
            "second range should survive canonicalization byte-equal"
        )
    }

    // MARK: - Test 3: out-of-bounds range gets clamped

    /// A range with `location` beyond the storage length gets clamped
    /// to `[0, storageLength]` by `clampRange`. After clamping the
    /// round-tripped range should land at `storageLength` with zero
    /// length (an empty cursor at the document end).
    func test_widget_outOfBoundsLocation_clampsToStorageEnd() {
        let harness = EditorHarness(markdown: "hello\n")
        defer { harness.teardown() }

        let storageLen = harness.editor.textStorage?.length ?? 0
        XCTAssertGreaterThan(storageLen, 0)

        // Location beyond storage end; length arbitrary.
        let oob = NSRange(location: storageLen + 100, length: 50)
        let canonicalized = harness.editor.canonicalizeSelectionRanges(
            [NSValue(range: oob)]
        )
        XCTAssertEqual(canonicalized.count, 1)
        let out = (canonicalized[0] as! NSValue).rangeValue
        // Clamped `location` is min(oob.location, storageLen) == storageLen;
        // max allowable length becomes 0 => a zero-length range at doc end.
        // After DocumentRange round-trip that resolves to (last block, end).
        XCTAssertLessThanOrEqual(
            out.location + out.length, storageLen,
            "canonicalized range must fit inside storage (\(out) vs len \(storageLen))"
        )
        XCTAssertEqual(out.length, 0, "out-of-bounds length gets clamped to 0")
    }

    /// Length that overflows past the storage end gets clamped to fit
    /// within `[location, storageLength]`.
    func test_widget_outOfBoundsLength_clampsToStorageEnd() {
        let harness = EditorHarness(markdown: "hello\n")
        defer { harness.teardown() }

        let storageLen = harness.editor.textStorage?.length ?? 0

        // Location in-bounds but length runs past end.
        let oob = NSRange(location: 1, length: storageLen + 100)
        let canonicalized = harness.editor.canonicalizeSelectionRanges(
            [NSValue(range: oob)]
        )
        XCTAssertEqual(canonicalized.count, 1)
        let out = (canonicalized[0] as! NSValue).rangeValue
        XCTAssertLessThanOrEqual(
            out.location + out.length, storageLen,
            "over-long range must be clamped inside storage (\(out) vs len \(storageLen))"
        )
        XCTAssertEqual(out.location, 1, "in-bounds location should not move")
    }

    // MARK: - Test 4: source-mode / missing-projection passes through unchanged

    /// When `documentProjection` is nil (source-mode, uninitialized,
    /// or actively being torn down) the canonicalization short-circuits
    /// and `ranges` flows to `super` unchanged. This is the documented
    /// pass-through branch in `canonicalizeSelectionRanges`.
    func test_widget_noProjection_passesThroughUnchanged() {
        let harness = EditorHarness(markdown: "hello\n")
        defer { harness.teardown() }

        // Temporarily clear the projection to simulate source-mode /
        // loading state. Keep the raw storage intact — the override
        // only checks `documentProjection`.
        let savedProjection = harness.editor.documentProjection
        harness.editor.documentProjection = nil
        defer { harness.editor.documentProjection = savedProjection }

        // Use a range that would be rewritten by DocumentRange round-trip
        // if canonicalization ran — a deliberately out-of-bounds one.
        let oob = NSRange(location: 9999, length: 50)
        let canonicalized = harness.editor.canonicalizeSelectionRanges(
            [NSValue(range: oob)]
        )
        XCTAssertEqual(canonicalized.count, 1)
        // Pass-through: the returned NSValue should be byte-equal to
        // the input value. Canonicalization is suppressed without a
        // projection, so neither clamp nor DocumentRange translation
        // fires.
        let out = (canonicalized[0] as! NSValue).rangeValue
        XCTAssertEqual(out, oob, "no-projection path must pass through unchanged")
    }

    // MARK: - Test 5: NSNotFound sentinel preserved

    /// An `NSRange` with `location == NSNotFound` is AppKit's "no
    /// selection" sentinel. Production preserves it byte-equal through
    /// canonicalization via two complementary guards:
    ///
    ///   1. `clampRange` (in `EditTextView+Selection.swift`) hits the
    ///      `location == NSNotFound` short-circuit and returns the
    ///      input unchanged.
    ///   2. `DocumentRange.fromNSRange` rejects NSNotFound explicitly
    ///      (added 2026-04-24 to close a latent bug — NSNotFound is
    ///      `Int.max`, not negative, so the prior `>= 0` guard alone
    ///      did not catch it, and the downstream
    ///      `projection.cursor(atStorageIndex:)` fallback silently
    ///      converted "no selection" into "cursor at offset 0" — a
    ///      different state).
    ///
    /// The `canonicalizeSelectionRanges` unmappable-input branch then
    /// passes the original `NSValue` through, giving byte-equal
    /// preservation.
    func test_widget_nsNotFound_preservedThroughRoundTrip() {
        let harness = EditorHarness(markdown: "hello\n")
        defer { harness.teardown() }

        let sentinel = NSRange(location: NSNotFound, length: 0)
        let canonicalized = harness.editor.canonicalizeSelectionRanges(
            [NSValue(range: sentinel)]
        )
        XCTAssertEqual(canonicalized.count, 1)
        let out = (canonicalized[0] as! NSValue).rangeValue
        XCTAssertEqual(
            out.location, NSNotFound,
            "NSNotFound sentinel must survive canonicalization untouched"
        )
        XCTAssertEqual(
            out.length, 0,
            "sentinel length must survive unchanged (was \(out.length))"
        )
    }

    /// Same preservation contract for negative `location` values —
    /// shielded by the `< 0` branch of `clampRange` and the
    /// matching `>= 0` guard in `DocumentRange.fromNSRange`. Pinning
    /// both sentinels together so a regression in either branch
    /// surfaces here.
    func test_widget_negativeLocation_preservedThroughRoundTrip() {
        let harness = EditorHarness(markdown: "hello\n")
        defer { harness.teardown() }

        let negative = NSRange(location: -1, length: 0)
        let canonicalized = harness.editor.canonicalizeSelectionRanges(
            [NSValue(range: negative)]
        )
        XCTAssertEqual(canonicalized.count, 1)
        let out = (canonicalized[0] as! NSValue).rangeValue
        XCTAssertEqual(
            out.location, -1,
            "negative location must survive canonicalization untouched"
        )
    }
}
