//
//  SubviewTableClickResponderTests.swift
//  FSNotesTests
//
//  Phase 8 / Subview Tables — C1 hypothesis test.
//
//  Tests the falsifiable hypothesis: when the user clicks inside a
//  table cell rendered via the subview path (`useSubviewTables = true`,
//  `TableAttachmentViewProvider` -> `TableContainerView` -> per-cell
//  `TableCellTextView`), the click must land on the cell's NSTextView
//  and that view must become first responder. If either fails, the
//  caret will paint in the parent EditTextView's coordinate space and
//  the result is the C1 caret-above-cell bug.
//
//  This is the diagnostic test the bug-hypothesis skill names in slot
//  {e}: "I will test this by ..." — it isolates the responder-chain
//  question from the typing pipeline so we know precisely which stage
//  is broken before changing more code.
//

import XCTest
import AppKit
@testable import FSNotes

final class SubviewTableClickResponderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaultsManagement.useSubviewTables = true
    }

    override func tearDown() {
        UserDefaultsManagement.useSubviewTables = true
        super.tearDown()
    }

    /// Recursive subview walk for a view of type `T`. Returns the first
    /// match in depth-first order.
    private func firstDescendant<T: NSView>(of root: NSView, type: T.Type) -> T? {
        for sub in root.subviews {
            if let hit = sub as? T { return hit }
            if let nested = firstDescendant(of: sub, type: type) { return nested }
        }
        return nil
    }

    /// Recursive subview walk that returns ALL matches of type `T` in
    /// depth-first order.
    private func allDescendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
        var out: [T] = []
        for sub in root.subviews {
            if let hit = sub as? T { out.append(hit) }
            out.append(contentsOf: allDescendants(of: sub, type: type))
        }
        return out
    }

    func test_clickInCell_landsOnTableCellTextView_andCellBecomesFirstResponder() throws {
        let markdown = """
        | A | B |
        |---|---|
        | x | y |

        """
        let harness = EditorHarness(markdown: markdown, windowActivation: .keyWindow)
        defer { harness.teardown() }

        // The view-provider's hosted view (TableContainerView) should
        // exist in the editor's subview tree after the keyWindow pump.
        // If it doesn't, Phase A4's view-provider wiring isn't firing —
        // that's a separate bug from the click-routing one.
        guard let container = firstDescendant(
            of: harness.editor, type: TableContainerView.self
        ) else {
            XCTFail("TableContainerView did not mount; view-provider not firing")
            return
        }

        let cells = allDescendants(of: container, type: TableCellTextView.self)
        guard !cells.isEmpty else {
            XCTFail("TableContainerView contains zero TableCellTextView subviews")
            return
        }

        // Pick the body cell at (row 1, col 0) — the "x" cell — to match
        // the failing-test pattern in `TableCellClickHarnessTests`.
        guard let xCell = cells.first(where: { $0.cellRow == 1 && $0.cellCol == 0 })
        else {
            XCTFail("no cell with (cellRow=1, cellCol=0); cells=\(cells.map { ($0.cellRow, $0.cellCol) })")
            return
        }

        // Click point: center of the cell, in the cell's view-local
        // coordinates. Convert to window coordinates for the synthesized
        // event and to the contentView's space for the hitTest call.
        let cellLocalCenter = NSPoint(x: xCell.bounds.midX, y: xCell.bounds.midY)
        let windowPoint = xCell.convert(cellLocalCenter, to: nil)

        guard let window = xCell.window,
              let contentView = window.contentView else {
            XCTFail("xCell has no window or contentView")
            return
        }

        // The contentView's hitTest expects a point in its OWN coordinate
        // space (its superview's space, which is the window for top-level
        // contentViews; window=contentView for borderless harness windows).
        let contentLocal = contentView.convert(windowPoint, from: nil)
        let hitView = contentView.hitTest(contentLocal)

        // Hypothesis test #1: the click must hit the cell's NSTextView,
        // not the parent EditTextView or some intermediary.
        XCTAssertTrue(
            hitView === xCell,
            "click at cell center hit \(String(describing: hitView)) — expected the TableCellTextView at (1,0). " +
            "If hitView is the parent EditTextView, the click is being intercepted before it reaches the cell."
        )

        // Hypothesis test #2: drive a real mouseDown on the hit view and
        // assert the cell becomes first responder.
        guard let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ),
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        ) else {
            XCTFail("could not synthesize NSEvent")
            return
        }

        // NSTextView.mouseDown enters a drag-tracking loop that blocks
        // until a mouseUp arrives — same trick the EditorHarness uses.
        window.postEvent(upEvent, atStart: false)
        if let hit = hitView {
            hit.mouseDown(with: downEvent)
        } else {
            xCell.mouseDown(with: downEvent)
        }

        XCTAssertTrue(
            window.firstResponder === xCell,
            "after mouseDown, expected xCell to be first responder, got \(String(describing: window.firstResponder))"
        )
    }
}
