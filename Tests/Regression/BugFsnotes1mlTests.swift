//
//  BugFsnotes1mlTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-1ml (P1):
//  "Table cell: typed text appears LEFT of cursor (1-2 char offset)"
//
//  Verifiable property: after typing N characters at the start of an
//  empty cell, the caret rect for cellLocalOffset == N must sit at
//  (or within < 1pt of) the right edge of the rendered run. The bug
//  reports a 1–2 char-width gap, so a 1pt tolerance is conservative.
//
//  Layer: coord-space (per DEBUG.md §1 layer table). Queries
//  TableLayoutFragment.caretRectInCell directly and compares against
//  NSAttributedString.size of the rendered character — no pixel
//  sampling, no screenshot.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes1mlTests: XCTestCase {

    /// 2x2 table with cell (1, 0) seeded with "Xab" so that
    /// `caretRectInCell(cellLocalOffset:)` is exercised at three
    /// distinct rendered positions (after each char). An empty cell
    /// would cause every offset to fall back to the same caret rect.
    private static let markdown = """
    | A | B |
    | --- | --- |
    | Xab | y |
    | z |  |
    """

    private struct LiveTableContext {
        let harness: EditorHarness
        let fragment: TableLayoutFragment
        let element: TableElement
    }

    private func makeLiveTable() -> LiveTableContext? {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        guard let tlm = harness.editor.textLayoutManager else {
            harness.teardown()
            return nil
        }
        tlm.ensureLayout(for: tlm.documentRange)

        var fragment: TableLayoutFragment?
        var element: TableElement?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            if let tf = f as? TableLayoutFragment,
               let el = f.textElement as? TableElement {
                fragment = tf
                element = el
                return false
            }
            return true
        }
        guard let f = fragment, let el = element else {
            harness.teardown()
            return nil
        }
        return LiveTableContext(harness: harness, fragment: f, element: el)
    }

    func test_caretRect_followsTypedCharacters_inDataCell() {
        guard let ctx = makeLiveTable() else {
            XCTFail("table fragment not laid out")
            return
        }
        defer { ctx.harness.teardown() }

        // Verifiable property: cell (1, 0) is seeded with "Xab" — three
        // distinct cellLocalOffsets (0, 1, 2, 3) must produce caret
        // rects whose pairwise differences match the rendered widths
        // of "X", "a", "b" respectively. If the bug is live, advances
        // will be too large (caret over-shoots glyphs by 1-2 char
        // widths) or zero (caret never advances).
        let offsets = (0...3).map { off -> CGRect in
            ctx.fragment.caretRectInCell(
                row: 1, col: 0, cellLocalOffset: off
            ) ?? .zero
        }
        let advances = zip(offsets.dropFirst(), offsets.dropLast())
            .map { $0.minX - $1.minX }

        // Build the same-attributes string the fragment would render
        // (data row, default (left) alignment, body font).
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let chars = ["X", "a", "b"]
        let expectedAdvances = chars.map { ch -> CGFloat in
            NSAttributedString(string: ch, attributes: [.font: baseFont])
                .size().width
        }

        let tolerance: CGFloat = 1.0
        for (i, ch) in chars.enumerated() {
            XCTAssertEqual(
                advances[i], expectedAdvances[i], accuracy: tolerance,
                "caret advance after '\(ch)' should equal its rendered " +
                "width (expected \(expectedAdvances[i]) ± \(tolerance), " +
                "got \(advances[i]))"
            )
        }
    }
}
