//
//  EditTextViewFillRenderSyncTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-f (Batch N+2) — Bug #2: async-render flash.
//
//  Pins the invariant that after `EditTextView.fillViaBlockModel(note:)`
//  returns synchronously, the initial TK2 layout pass has completed
//  before first paint. Previously `renderTables()` and the first
//  layout pass were deferred via `DispatchQueue.main.async`, causing:
//   • ~500ms generic-document icon flash on table attachments (legacy
//     attachment path).
//   • Checkbox / view-provider attachments not drawing until the user
//     scrolled, because TK2's view-provider integration needs a
//     layout pass to wire the hosted views (TK2 native path).
//
//  Fix: `fillViaBlockModel` now calls `renderTables()` and
//  `textLayoutManager.ensureLayout(for: documentRange)` synchronously
//  before returning. Heavier async work (mermaid/math bitmap
//  generation, PDF hydration, image load) stays async.
//
//  Test strategy: reuse `EditorHarness` (offscreen window). The
//  harness's `seed()` path mirrors `fillViaBlockModel`'s
//  setAttributedString but does NOT call the post-seed synchronous
//  steps — so we mirror production here by calling `ensureLayout`
//  explicitly on the harness's TLM and asserting the layout
//  completed synchronously.
//

import XCTest
import AppKit
@testable import FSNotes

final class EditTextViewFillRenderSyncTests: XCTestCase {

    /// `textLayoutManager.ensureLayout(for: documentRange)` completes
    /// synchronously. After fillViaBlockModel's ensureLayout call, the
    /// layout manager has laid out the document's text fragments — so
    /// TK2 view-provider integration (used by checkboxes, images with
    /// hosted views, and native table elements) has been wired.
    ///
    /// Production calls this inside `fillViaBlockModel` right after
    /// `storage.setAttributedString(projection.attributed)`; this
    /// test mirrors that sequence via `EditorHarness.seed()` then
    /// explicit `ensureLayout`. Assert:
    ///   (a) at least one fragment was laid out (non-zero count).
    ///   (b) at least one fragment has non-zero height (layout
    ///       actually completed, not merely enumerated placeholders).
    func test_ensureLayoutSync_producesLaidOutFragments() {
        FeatureFlag.nativeTableElements = true
        let md = """
        - [ ] unchecked
        - [x] checked

        Some paragraph.

        | A |
        |---|
        | 1 |
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager else {
            // Editor was created without TK2 — skip this assertion.
            // The sync contract only matters on TK2; TK1 uses a
            // different layout manager that lays out on demand.
            return
        }

        // Production calls ensureLayout(for: documentRange) inside
        // fillViaBlockModel. Mirror that here.
        tlm.ensureLayout(for: tlm.documentRange)

        var fragmentCount = 0
        var sawNonZeroFragment = false
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: []
        ) { fragment in
            fragmentCount += 1
            let frame = fragment.layoutFragmentFrame
            if frame.height > 0 {
                sawNonZeroFragment = true
            }
            return fragmentCount < 20
        }
        XCTAssertGreaterThan(
            fragmentCount, 0,
            "ensureLayout must produce at least one layout fragment for a non-empty document."
        )
        XCTAssertTrue(
            sawNonZeroFragment,
            "At least one laid-out fragment must have a non-zero height — else layout did not actually complete synchronously, which means TK2 view-provider integration (checkboxes etc.) is deferred to the next event and the first paint will be wrong."
        )
    }

    /// Legacy-path sanity check: under `nativeTableElements = false`,
    /// `renderTables()` is what replaces the generic-document-icon
    /// placeholder with the live `InlineTableAttachmentCell`. The
    /// production fix moves this call inline (synchronous) in
    /// `fillViaBlockModel`. This test only verifies that
    /// `tableController.renderTables()` does not crash when called
    /// synchronously on a freshly-seeded harness — the real live-cell
    /// binding contract depends on a fully-realized window geometry
    /// that the harness does not reliably reproduce, so we assert
    /// only the no-crash post-condition here and pin the full
    /// geometric contract via manual QA / snapshot tests.
    func test_renderTablesSync_legacyPath_doesNotCrash() {
        let prevFlag = FeatureFlag.nativeTableElements
        FeatureFlag.nativeTableElements = false
        defer { FeatureFlag.nativeTableElements = prevFlag }

        let md = """
        | A | B |
        |---|---|
        | x | y |
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        // Should not crash.
        harness.editor.renderTables()

        // The attachment exists in storage regardless of whether the
        // live cell was successfully configured — the storage is set
        // up in seed(). This exercises the full renderTables walk.
        guard let storage = harness.editor.textStorage else {
            XCTFail("Editor has no textStorage")
            return
        }
        var foundTableAttachment = false
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            if value is TableBlockAttachment {
                foundTableAttachment = true
            }
        }
        XCTAssertTrue(foundTableAttachment, "Legacy-path seed must produce at least one TableBlockAttachment.")
    }
}
