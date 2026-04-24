//
//  TableCellClickHarnessTests.swift
//  FSNotesTests
//
//  Rule-3 driven: a user-reported bug ("clicking inside a table cell
//  places the cursor somewhere close by but NOT inside the cell's
//  storage range") stayed invisible to the suite because `EditorHarness`
//  had no primitive for synthesised mouse clicks. The harness drove the
//  `handleEditViaBlockModel` path but never `NSTextView.mouseDown(with:)`,
//  so click-routing issues could only be debugged in the live app.
//
//  This file adds the FAILING test that pins the bug's shape, so that a
//  follow-up fix (extending the Phase 5b `DocumentCursor` translation
//  layer for table cells — see `ARCHITECTURE.md` line 327: "for block
//  kinds whose storage representation is a single attachment
//  (`.horizontalRule`, `.table`), `inlineOffset` is ignored and
//  canonically 0") can flip it green.
//
//  The hypothesis: before Phase 2e T2-f (2026-04-23, commit `957dc7e`)
//  tables rendered as a single `NSTextAttachment`, so `.inlineOffset =
//  0` was sound. T2-f moved cell text into native content storage
//  characters but the cursor-translation layer was not extended to track
//  intra-cell offsets. A live click now lands at a storage offset that
//  the canonicalisation layer snaps to the table-block boundary.
//
//  The test is marked `XCTExpectFailure` so the full suite stays green.
//  When the `DocumentCursor` gap is closed, drop the `XCTExpectFailure`
//  wrapper and the test flips to an unexpected pass — that will be the
//  signal to remove the expectation.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableCellClickHarnessTests: XCTestCase {

    // MARK: - Helpers

    /// Derive a view-local point that is geometrically inside the cell
    /// whose storage offset is `cellOffset`. Walks TK2's layout manager
    /// to find the line fragment containing the offset, picks the
    /// midpoint of its typographic bounds, and shifts by the editor's
    /// `textContainerInset` so the returned point is in the editor's
    /// view-local space (what `NSTextView.mouseDown` expects after
    /// window→view conversion).
    ///
    /// Returns `nil` if layout hasn't produced a fragment at that offset
    /// — the caller should `XCTFail` on that because a missing fragment
    /// is a test-setup bug, not the bug under test.
    private func viewLocalPoint(
        forStorageOffset cellOffset: Int,
        in editor: EditTextView
    ) -> NSPoint? {
        guard let tlm = editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage else {
            return nil
        }
        tlm.ensureLayout(for: tlm.documentRange)
        let docStart = cs.documentRange.location
        guard let target = cs.location(docStart, offsetBy: cellOffset) else {
            return nil
        }
        guard let fragment = tlm.textLayoutFragment(for: target) else {
            return nil
        }
        let fragOrigin = fragment.layoutFragmentFrame.origin
        // Prefer a line fragment whose character range covers `target`;
        // fall back to the first line fragment if none match (e.g. the
        // TableLayoutFragment synthesises its own geometry and returns
        // a single line fragment for the whole grid).
        let lineFragment = fragment.textLineFragments.first {
            let charRange = $0.characterRange
            let loc = cs.offset(from: docStart, to: target)
            let fragStart = cs.offset(from: docStart, to: fragment.rangeInElement.location)
            let localOffset = loc - fragStart
            return NSLocationInRange(localOffset, charRange)
        } ?? fragment.textLineFragments.first

        let bounds: CGRect
        if let lf = lineFragment {
            bounds = lf.typographicBounds
        } else {
            bounds = CGRect(
                origin: .zero,
                size: fragment.layoutFragmentFrame.size
            )
        }
        // Midpoint of the line fragment, in text-container coords.
        let midContainer = NSPoint(
            x: fragOrigin.x + bounds.midX,
            y: fragOrigin.y + bounds.midY
        )
        // text-container → view-local: add textContainerInset.
        return NSPoint(
            x: midContainer.x + editor.textContainerInset.width,
            y: midContainer.y + editor.textContainerInset.height
        )
    }

    // MARK: - Failing test

    /// Clicking at a point geometrically inside the `(row 1, col 0)`
    /// body cell ("x") should place the insertion point inside that
    /// cell's storage range.
    ///
    /// Observed shape on 2026-04-24: the click lands at a storage offset
    /// that is either the block-boundary of the table attachment or the
    /// first character of the table's flat separator-encoded storage,
    /// NOT inside the "x" character's range.
    ///
    /// See the file-level doc comment for the hypothesis. This test is
    /// wrapped in `XCTExpectFailure` — the full test suite remains
    /// green; the expectation flips to an unexpected pass when the
    /// `DocumentCursor` table-cell gap is closed.
    func test_clickInsideCell_placesCursorInsideCellStorageRange() throws {
        let markdown = """
        | A | B |
        |---|---|
        | x | y |
        | z | w |

        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        // Give TK2 layout a chance to finalise — the harness seeds via
        // `setAttributedString` but fragment frames are lazy until
        // `ensureLayout` runs.
        if let tlm = harness.editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        guard let storage = harness.editor.textStorage else {
            return XCTFail("editor has no text storage")
        }
        let full = storage.string as NSString
        let xLoc = full.range(of: "x").location
        guard xLoc != NSNotFound else {
            return XCTFail("couldn't find cell content 'x' in storage; string was \(storage.string.debugDescription)")
        }
        let xNSRange = NSRange(location: xLoc, length: 1)

        // Compute a click point geometrically inside the "x" cell by
        // asking TK2 for the line fragment covering `xLoc` and taking
        // its midpoint. This avoids `firstRect(forCharacterRange:)`
        // which needs a live screen the offscreen harness window
        // doesn't have.
        guard let clickPoint = viewLocalPoint(
            forStorageOffset: xNSRange.location,
            in: harness.editor
        ) else {
            return XCTFail("could not derive a view-local point for offset \(xNSRange.location)")
        }

        // Sanity check the test setup: `characterIndexTK2` at the
        // click point should resolve back to (or very near) `xLoc`.
        // If that fails, the click point isn't in the cell and the
        // test is measuring the wrong thing — fix the setup rather
        // than letting the assertion fire on a setup bug.
        let properPoint = NSPoint(
            x: clickPoint.x - harness.editor.textContainerInset.width,
            y: clickPoint.y - harness.editor.textContainerInset.height
        )
        let hitIndex = harness.editor.characterIndexTK2(at: properPoint)
        XCTAssertNotNil(
            hitIndex,
            "test-setup precondition: the derived click point must hit a text fragment"
        )

        // Drive the real mouseDown path.
        XCTExpectFailure(
            "Known-red: clicking inside a table cell should place the cursor inside the cell's storage range, but `DocumentCursor` canonicalisation for table blocks still treats `.inlineOffset = 0` as invariant (ARCHITECTURE.md line 327). Remove this expectation once the canonicalisation layer is extended for native table cells."
        )

        _ = harness.clickAt(point: clickPoint)
        let postClickRange = harness.editor.selectedRange

        // Expected: cursor lands inside xNSRange (or adjacent to it —
        // cell-start or cell-end are both "inside the cell" per the
        // `handleTableCellEdit` normalisation).
        let cellLower = xNSRange.location
        let cellUpper = xNSRange.location + xNSRange.length
        XCTAssertGreaterThanOrEqual(
            postClickRange.location, cellLower,
            "click inside 'x' cell should place cursor >= \(cellLower) (cell start), got \(postClickRange.location). hitIndex=\(hitIndex ?? -1), clickPoint=\(clickPoint)"
        )
        XCTAssertLessThanOrEqual(
            postClickRange.location, cellUpper,
            "click inside 'x' cell should place cursor <= \(cellUpper) (cell end), got \(postClickRange.location). hitIndex=\(hitIndex ?? -1), clickPoint=\(clickPoint)"
        )
    }
}
