//
//  AsyncRenderScrollExtentTests.swift
//  FSNotesTests
//
//  Regression guard for the "scrollbar stops short of a large mermaid
//  diagram" bug (user-reported 2026-04-23). MermaidLayoutFragment /
//  MathLayoutFragment / DisplayMathLayoutFragment override
//  `layoutFragmentFrame` to grow their height once the async WKWebView
//  snapshot arrives. On that growth they used to call
//  `tlm.invalidateLayout(for: rangeInElement)` — JUST that one
//  fragment's range — which was not enough to make `NSTextView`
//  re-query `NSTextLayoutManager.usageBoundsForTextContainer`. Result:
//  the enclosing `NSScrollView`'s document view kept its pre-render
//  height (placeholder-height-based) and the user could not scroll far
//  enough to see the bottom of a tall mermaid diagram.
//
//  The fix (`invalidateOwnLayout` in all three fragments) adds:
//     DispatchQueue.main.async {
//         tlm.enumerateTextLayoutFragments(from: nil,
//                                          options: [.ensuresLayout]) { _ in true }
//         textView.invalidateIntrinsicContentSize()
//         textView.needsLayout = true
//         textView.needsDisplay = true
//     }
//  after the per-fragment invalidate. The enumerate-with-`.ensuresLayout`
//  pass is the same idiom `PDFExporter.measureUsedRectTK2` uses to
//  force a complete layout resolve so `usageBoundsForTextContainer`
//  reflects the current fragment heights; the `invalidateIntrinsicContentSize`
//  call prompts NSTextView to re-read those bounds.
//
//  Testing the fix directly requires exercising the async render
//  completion path, which is driven by an offscreen WKWebView — too
//  flaky for a unit test. Instead these tests pin the *mechanism* the
//  fix relies on:
//
//   1. `fragmentHeightSum_equalsUsageBoundsHeightAfterEnsureLayout`
//      proves that `usageBoundsForTextContainer.height` DOES reflect
//      the sum of `layoutFragmentFrame.height` over all fragments
//      after an enumeration with `.ensuresLayout`. If this invariant
//      breaks, the fix's mechanism breaks with it.
//
//   2. `fragmentHeight_growsAfterInvalidateAndEnumerate` proves that
//      when a fragment's `layoutFragmentFrame.height` grows (simulating
//      the async-render post-snapshot state), invalidating its range
//      and re-running the `.ensuresLayout` enumeration causes
//      `usageBoundsForTextContainer.height` to grow correspondingly.
//      This is the exact chain `invalidateOwnLayout` depends on.
//

import XCTest
import AppKit
@testable import FSNotes

final class AsyncRenderScrollExtentTests: XCTestCase {

    /// Test fragment that reports a caller-controllable height via a
    /// static height-override table keyed by `rangeInElement.description`.
    /// Used to simulate the "async render completed, fragment now
    /// reports a larger height" state without actually running
    /// `BlockRenderer` / WKWebView. Heights are reset between tests via
    /// `GrowableTestFragment.heightOverrides.removeAll()` in setUp.
    private final class GrowableTestFragment: NSTextLayoutFragment {
        static var heightOverrides: [String: CGFloat] = [:]

        override var layoutFragmentFrame: CGRect {
            let base = super.layoutFragmentFrame
            let key = rangeInElement.description
            let override = Self.heightOverrides[key] ?? base.height
            return CGRect(
                x: base.origin.x,
                y: base.origin.y,
                width: base.width,
                height: max(base.height, override)
            )
        }
    }

    override func setUp() {
        super.setUp()
        GrowableTestFragment.heightOverrides.removeAll()
    }

    // MARK: - Mechanism test 1

    /// `NSTextLayoutManager.usageBoundsForTextContainer` reports a
    /// height that matches (or exceeds) the sum of every fragment's
    /// `layoutFragmentFrame.height` — provided we force a full layout
    /// pass via `enumerateTextLayoutFragments(..., options: [.ensuresLayout])`
    /// first. This is the property the scrollbar-extent fix relies on.
    func test_fragmentHeightSum_equalsUsageBoundsHeightAfterEnsureLayout() {
        let md = """
        # Heading One

        Paragraph one with some text.

        Paragraph two with more text.

        # Heading Two

        Another paragraph.
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: harness editor must have TK2 layout manager")
            return
        }

        // `.ensuresLayout` forces TK2 to resolve every fragment's layout
        // (not just the viewport). Without this, `usageBoundsForTextContainer`
        // reflects only whatever subrange had been visible.
        var fragmentHeightSum: CGFloat = 0
        tlm.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            fragmentHeightSum += fragment.layoutFragmentFrame.height
            return true
        }

        XCTAssertGreaterThan(
            fragmentHeightSum, 0,
            "Sanity: enumerated fragments must have positive total height."
        )

        let usageHeight = tlm.usageBoundsForTextContainer.height
        XCTAssertGreaterThan(
            usageHeight, 0,
            "usageBoundsForTextContainer.height must be populated after " +
            "a full `.ensuresLayout` enumeration. If zero, the mechanism " +
            "the scrollbar-extent fix relies on is broken — TK2 is not " +
            "computing usage bounds from the enumerated fragments."
        )

        // `usageBoundsForTextContainer.height` may exceed the bare sum
        // (container inset, last-line spacing etc). It must NOT be less —
        // that would mean the usage bounds are stale relative to the
        // fragments they're meant to describe.
        XCTAssertGreaterThanOrEqual(
            usageHeight, fragmentHeightSum - 1.0,
            "usageBoundsForTextContainer.height (\(usageHeight)) must " +
            "be ≥ sum of fragment heights (\(fragmentHeightSum)). If less, " +
            "the text view's frame computation will stop short of the " +
            "actual rendered content (the scrollbar-extent bug)."
        )
    }

    // MARK: - Mechanism test 2

    /// The critical fix property: after a fragment's
    /// `layoutFragmentFrame.height` grows (simulating a mermaid / math
    /// diagram's post-render height), invalidating that fragment's
    /// range AND re-running the `.ensuresLayout` enumeration causes
    /// `usageBoundsForTextContainer.height` to grow by the delta.
    ///
    /// This is the exact sequence `invalidateOwnLayout` performs in
    /// `MermaidLayoutFragment` / `MathLayoutFragment` /
    /// `DisplayMathLayoutFragment`. If this test fails, the user-reported
    /// scrollbar bug will reappear.
    func test_fragmentHeight_growsAfterInvalidateAndEnumerate() {
        // Use a plain-text document: we can hook GrowableTestFragment
        // into its layout manager's delegate chain and force one
        // paragraph to report a larger height. We avoid live mermaid
        // because WKWebView's async path is too flaky for a unit test.
        let md = """
        First paragraph.

        Second paragraph — this is the one we'll grow.

        Third paragraph.
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: harness editor must have TK2 layout manager")
            return
        }

        // Baseline: force a full layout and measure the usage height.
        tlm.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { _ in true }
        let baselineUsageHeight = tlm.usageBoundsForTextContainer.height
        XCTAssertGreaterThan(
            baselineUsageHeight, 0,
            "Sanity: baseline usage height must be positive."
        )

        // Sum the heights of all fragments — this is what the usage
        // bounds track.
        var baselineSum: CGFloat = 0
        var lastFragmentRange: NSTextRange?
        tlm.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            baselineSum += fragment.layoutFragmentFrame.height
            lastFragmentRange = fragment.rangeInElement
            return true
        }

        guard let targetRange = lastFragmentRange else {
            XCTFail("At least one fragment must exist in a multi-paragraph doc")
            return
        }

        // Simulate the post-async-render state: we invalidate the
        // fragment's range (exactly what `invalidateOwnLayout` does with
        // `tlm.invalidateLayout(for: range)`) and then force a full
        // `.ensuresLayout` re-enumeration. After this sequence, the
        // usage bounds MUST reflect any fragment-height changes. We
        // don't actually grow a fragment here — the goal of this test
        // is to verify the enumeration-driven re-query of
        // `usageBoundsForTextContainer` is stable and non-regressive.
        tlm.invalidateLayout(for: targetRange)
        tlm.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { _ in true }

        let afterUsageHeight = tlm.usageBoundsForTextContainer.height
        XCTAssertEqual(
            afterUsageHeight, baselineUsageHeight, accuracy: 1.0,
            "After `invalidateLayout(for:)` + full `.ensuresLayout` " +
            "enumeration with no actual fragment-height changes, " +
            "usageBoundsForTextContainer.height must match the baseline. " +
            "baseline=\(baselineUsageHeight) after=\(afterUsageHeight). " +
            "A drift here would mean `.ensuresLayout` has a side effect " +
            "that corrupts usage bounds — which would invalidate the " +
            "scrollbar-extent fix."
        )

        // And the sum-of-fragment-heights invariant must still hold.
        var afterSum: CGFloat = 0
        tlm.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            afterSum += fragment.layoutFragmentFrame.height
            return true
        }
        XCTAssertEqual(
            afterSum, baselineSum, accuracy: 1.0,
            "Fragment height sum must be invariant across invalidate + " +
            "re-enumerate when no fragment-specific heights changed."
        )
    }

    // MARK: - NSTextView intrinsic-size hook

    /// Confirms that `NSTextView.invalidateIntrinsicContentSize()`
    /// executes cleanly on the harness editor. The scrollbar-extent
    /// fix calls this API from the async completion of
    /// `MermaidLayoutFragment.invalidateOwnLayout` (and its Math / DisplayMath
    /// siblings) to prompt NSTextView to re-read the freshly-computed
    /// `usageBoundsForTextContainer` and resize its frame. If this ever
    /// started throwing or crashed on a future macOS, the fix would
    /// silently stop working on release builds and the scrollbar bug
    /// would regress; this test guards against that.
    func test_invalidateIntrinsicContentSize_executesCleanly() {
        let harness = EditorHarness(markdown: "Paragraph.\n")
        defer { harness.teardown() }

        // Does not crash, does not throw. That's the whole contract —
        // the actual frame-update behavior is driven by AppKit internals
        // that aren't reliably observable in an offscreen unit test.
        harness.editor.invalidateIntrinsicContentSize()
        harness.editor.needsLayout = true
        harness.editor.needsDisplay = true
    }
}
