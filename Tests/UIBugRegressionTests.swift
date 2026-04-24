//
//  UIBugRegressionTests.swift
//  FSNotesTests
//
//  One test per currently-known UI bug, written against
//  `EditorSnapshot`. Each test captures the observed widget-layer
//  failure — the ~1,640 pure-function tests in this suite pass while
//  these ship, because the defect lives in the overlay / fragment /
//  subview mounting glue, not in the pipeline.
//
//  Currently-broken tests wrap in `XCTExpectFailure` so the overall
//  suite stays green. When a fix lands, the expected-failure flips
//  to a pass and the test reports an "unexpectedly passed" failure
//  (XCTest's mechanism for retiring the wrapper), which surfaces the
//  fix in CI and tells the maintainer to drop the `XCTExpectFailure`.
//
//  Bugs captured here (date 2026-04-24):
//
//    1. test_tableHandleOverlay_mountsOnFill
//       Hover handles don't appear even after commit 08506d3 wired
//       `vc.tableHandleOverlay.reposition()` into the fill path.
//
//    2. test_codeBlockEditToggle_buttonVisibleOnFill
//       `</>` edit toggle button doesn't appear even after commits
//       25dd7dd + e03a75a wired `vc.codeBlockEditToggleOverlay.
//       reposition()` into the fill path.
//
//    3a. test_singleTable_producesSingleTableLayoutFragment
//        Plain single-table fill should produce exactly one
//        TableLayoutFragment — regression gate for the "table
//        rendered twice" bug.
//    3b. test_tableWithTrailingBrInLastCell_stillSingleFragment
//        Table whose last cell contains `<br><br>` is observed to
//        render twice on master (two TableLayoutFragments).
//
//    4. test_clickInsideCell_placesCursorInsideCellSpan
//       Deferred to `TableCellClickHarnessTests` (another agent is
//       building the click DSL + this specific test).
//
//    5. test_inlineMath_attachmentBaselineAligned
//       Inline-math attachment hydration is async via WKWebView —
//       synchronous snapshot cannot observe the hydrated
//       attachment bounds. Covered by `InlineMathBaselineTests`
//       at the pure-function layer (commit 1095395).
//
//    6. test_bulletList_mountsGlyphsOnFill /
//       test_checkboxList_mountsGlyphsOnFill
//       Bullet and checkbox glyphs don't mount as subviews until
//       the editor scrolls; first-fill snapshots find no
//       BulletGlyphView / CheckboxGlyphView subviews.
//

import XCTest
@testable import FSNotes

final class UIBugRegressionTests: XCTestCase {

    // MARK: - Helpers

    /// Strict options: reports a test failure when the expected
    /// failure does NOT occur. Without `isStrict = true`, a test
    /// where the bug got silently fixed would keep passing with no
    /// signal to drop the `XCTExpectFailure` wrapper. Strict mode
    /// makes the "bug is fixed" case loud.
    private func strictExpectedFailureOptions() -> XCTExpectedFailure.Options {
        let opts = XCTExpectedFailure.Options()
        opts.isStrict = true
        return opts
    }

    // MARK: - Bug 1: TableHandleView overlay mounts on fill

    /// EXPECTED TO FAIL on master — per user report, hover handles
    /// still don't appear after `08506d3`'s responder-chain wire-up.
    /// Offscreen tests have an additional reason to fail: the harness
    /// creates a borderless window without a `ViewController`, so the
    /// production path `owningViewControllerForTableHandleOverlay()`
    /// returns nil and `tableHandleOverlay.reposition()` never runs.
    /// Either way, a correct fix mounts `TableHandleView` subviews on
    /// the editor. This test captures that outcome.
    func test_tableHandleOverlay_mountsOnFill() {
        XCTExpectFailure(
            "Known bug 2026-04-24: TableHandleView subviews are not " +
            "mounted after fill. Responder-chain wire-up in 08506d3 " +
            "does not fire in offscreen harness, and user reports it " +
            "still doesn't fire in the live app.",
            options: strictExpectedFailureOptions()
        )
        let h = EditorHarness(
            markdown: "| a | b |\n|---|---|\n| 1 | 2 |",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(overlay class=TableHandleView visible=true"
        )
    }

    // MARK: - Bug 2: CodeBlockEditToggleView button visible on fill

    /// EXPECTED TO FAIL — parallel to bug 1. `</>` button overlay is
    /// wired the same way (`owningViewControllerForTableHandleOverlay()`
    /// → `vc.codeBlockEditToggleOverlay.reposition()`), so offscreen
    /// harness + live-app report the same missing-subview outcome.
    func test_codeBlockEditToggle_buttonVisibleOnFill() {
        XCTExpectFailure(
            "Known bug 2026-04-24: CodeBlockEditToggleView subviews " +
            "are not mounted after fill. Same wiring failure as " +
            "TableHandleOverlay — see bug 1.",
            options: strictExpectedFailureOptions()
        )
        let h = EditorHarness(
            markdown: "```swift\nlet x = 1\n```",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(overlay class=CodeBlockEditToggleView visible=true"
        )
    }

    // MARK: - Bug 3a: single-table fragment count regression gate

    /// SHOULD PASS on master. Guards against reintroducing the "table
    /// rendered twice" class of bugs: a well-formed single-table fill
    /// must produce exactly one `TableLayoutFragment` per block.
    func test_singleTable_producesSingleTableLayoutFragment() {
        let h = EditorHarness(
            markdown: "| a | b |\n|---|---|\n| 1 | 2 |"
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "class=TableLayoutFragment count=1"
        )
    }

    // MARK: - Bug 3b: table with trailing <br><br> in last cell

    /// EXPECTED TO FAIL — the `<br><br>` in the last cell is observed
    /// on master to cause the table to render twice
    /// (two `TableLayoutFragment`s against a single `kind=table`
    /// block). Wrapped in XCTExpectFailure until the fix lands.
    func test_tableWithTrailingBrInLastCell_stillSingleFragment() {
        XCTExpectFailure(
            "Known bug 2026-04-24: table with <br><br> in the last " +
            "cell renders twice — two TableLayoutFragment instances " +
            "per block.",
            options: strictExpectedFailureOptions()
        )
        let h = EditorHarness(
            markdown: "| a | b |\n|---|---|\n| 1 | 2<br><br> |"
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "class=TableLayoutFragment count=1"
        )
    }

    // MARK: - Bug 4: click inside cell places cursor inside cell span
    //
    // Coverage for this bug lives in `TableCellClickHarnessTests` —
    // a sibling agent is building the `.clickAt(point:)` harness DSL
    // and wiring the test there. Do not duplicate here.

    // MARK: - Bug 5: inline-math attachment baseline alignment

    /// Inline-math hydration is async via WKWebView. The harness is
    /// synchronous — the math placeholder renders with
    /// `.inlineMathSource` on plain text, and the actual
    /// `NSTextAttachment` is substituted later by the hydration
    /// callback. Without a deterministic "wait for hydration" hook,
    /// a snapshot taken right after fill sees no attachment and
    /// cannot observe `bounds.y`.
    ///
    /// The pure-function contract (bounds.y = -|descender|) is
    /// already covered by `InlineMathBaselineTests` (commit
    /// 1095395). This test is skipped pending a hydration-wait
    /// primitive in the harness.
    func test_inlineMath_attachmentBaselineAligned() throws {
        throw XCTSkip(
            "Inline-math hydration is async via WKWebView. The " +
            "pure function `InlineMathBaseline.bounds(imageSize:font:)` " +
            "is covered by InlineMathBaselineTests. A live-harness " +
            "assertion needs a deterministic hydration-wait primitive " +
            "which EditorHarness does not yet expose."
        )
    }

    // MARK: - Bug 6: bullet list glyphs mount on fill

    /// Regression gate: bullet glyphs must mount as subviews on the
    /// first fill (no scroll required). TK2 parents attachment-host
    /// subviews via `NSTextAttachmentViewProvider.loadView`, which
    /// fires only after the viewport has been laid out AND the run
    /// loop has ticked once. Production calls `layoutViewport()`
    /// twice around a `DispatchQueue.main.async` boundary to satisfy
    /// this two-phase contract.
    ///
    /// Historical bug (2026-04-24): glyphs didn't mount until the
    /// user scrolled. Fixed by the two-phase pump in
    /// `EditTextView.fillViaBlockModel`.
    func test_bulletList_mountsGlyphsOnFill() {
        let h = EditorHarness(
            markdown: "- one\n- two\n- three\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(attachment-host class=BulletGlyphView"
        )
    }

    /// Same mount contract as bullets; checkbox glyphs must appear
    /// on first fill without a scroll.
    func test_checkboxList_mountsGlyphsOnFill() {
        let h = EditorHarness(
            markdown: "- [ ] a\n- [x] b\n",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }
        let snap = h.snapshot()
        snap.assertContains(
            "(attachment-host class=CheckboxGlyphView"
        )
    }
}
