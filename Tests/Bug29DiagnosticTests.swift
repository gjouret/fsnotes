//
//  Bug29DiagnosticTests.swift
//  FSNotesTests
//
//  Bug #29 — "Click in top-left cell paints caret ABOVE the cell".
//  Re-opened on 2026-04-25 after the user reports it still happens
//  despite the prior fix in commits `de68ca6` and `44fd868`.
//
//  This file is diagnostic-only: it does NOT assert a fix. It captures
//  the discrepancy between (a) the expected caret rect — derived
//  using the same fragment-local → view-coord conversion that
//  `TableHandleOverlay` uses to position handle chips correctly — and
//  (b) the actual caret rect returned by
//  `EditTextView.caretRectIfInTableCell`. If the two diverge, the
//  delta and component values are dumped to
//  `~/unit-tests/bug29-rects.log` so the maintainer can reproduce
//  the live-app bug on the harness.
//
//  Approach:
//    * Use `EditorHarness(markdown:, windowActivation: .keyWindow)`
//      so the editor is keyed + first-responder. `TableLayoutFragment`
//      geometry is fully populated after `activateWindowForWidgetLayer`.
//    * Park the cursor at the first-content offset of cell (row, col),
//      mirroring what `EditTextView.handleTableCellClick` does on a
//      click at the cell's content area.
//    * Compute the EXPECTED rect using `TableHandleOverlay`-style math:
//        x = textContainerOrigin.x + handleBarWidth + sum(colWidths[..col]) + padH + measured
//        y = textContainerOrigin.y + fragFrame.origin.y + handleBarHeight + sum(rowHeights[..row]) + padTop
//      (NB: `TableHandleOverlay` uses `origin.x` (no `fragFrame.origin.x`) for
//      column rects — i.e. the grid x-origin is independent of the
//      fragment's natural-flow x. The current `caretRectIfInTableCell`
//      adds `fragFrame.origin.x` instead, which differs whenever the
//      fragment is not at container-x = 0.)
//    * Compare against `editor.caretRectIfInTableCell()`.
//

import XCTest
import AppKit
@testable import FSNotes

final class Bug29DiagnosticTests: XCTestCase {

    // MARK: - Log helpers

    /// Append a line to `~/unit-tests/bug29-rects.log`. Best-effort —
    /// silently no-ops if the file can't be opened. Mirrors the
    /// `bmLog` pattern in production but writes to a test-specific
    /// path so harness runs don't pollute the live diagnostic log.
    private func logLine(_ s: String) {
        let dir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let path = dir + "/bug29-rects.log"
        guard let data = (s + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Coord-space helpers

    /// Find the first `TableLayoutFragment` in the editor.
    private func firstTableFragment(_ editor: EditTextView) -> TableLayoutFragment? {
        guard let tlm = editor.textLayoutManager else { return nil }
        var found: TableLayoutFragment?
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let tf = fragment as? TableLayoutFragment {
                found = tf
                return false
            }
            return true
        }
        return found
    }

    /// Compute the EXPECTED caret rect for cell (row, col) using the
    /// `TableHandleOverlay`-style math: grid coords are container-
    /// relative on X (NO `fragFrame.origin.x` addition) and
    /// frame-relative on Y. Result is in view coords.
    private func expectedCaretRect(
        in editor: EditTextView,
        fragment: TableLayoutFragment,
        row: Int, col: Int,
        cellLocalOffset: Int = 0
    ) -> CGRect? {
        guard let element = fragment.textElement as? TableElement,
              case .table(let header, let alignments, let rows, _) = element.block,
              let geom = fragment.geometryForHandleOverlay()
        else { return nil }

        let frame = fragment.layoutFragmentFrame
        let origin = editor.textContainerOrigin

        // Grid origin in view coords — mirrors `TableHandleOverlay`'s
        // `columnRect` math at lines 320-333: x uses `origin.x`
        // ONLY (NO frame.origin.x); y uses `frame.origin.y + origin.y`.
        var colX = TableGeometry.handleBarWidth
        for i in 0..<col { colX += geom.columnWidths[i] }
        let cellWidth = geom.columnWidths[col]

        var rowY = TableGeometry.handleBarHeight
        for i in 0..<row { rowY += geom.rowHeights[i] }
        let rowHeight = geom.rowHeights[row]

        let padH = TableGeometry.cellPaddingH()
        let padTop = TableGeometry.cellPaddingTop()
        let padBot = TableGeometry.cellPaddingBot()
        let contentX = colX + padH
        let contentY = rowY + padTop
        let contentWidth = max(0, cellWidth - padH * 2)
        let contentHeight = max(0, rowHeight - padTop - padBot)

        // Measure rendered text width up to cellLocalOffset, mirroring
        // `caretRectInCell` so the comparison is apples-to-apples.
        let isHeader = (row == 0)
        let cellsForRow: [TableCell] = isHeader
            ? header
            : (row - 1 < rows.count ? rows[row - 1] : [])
        guard col < cellsForRow.count else { return nil }
        let cell = cellsForRow[col]

        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let drawFont: NSFont = isHeader
            ? NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            : baseFont
        let alignment = col < alignments.count
            ? TableGeometry.nsAlignment(for: alignments[col])
            : .left

        let attributed = NSMutableAttributedString(string: cell.rawText)
        attributed.addAttribute(
            .font, value: drawFont,
            range: NSRange(location: 0, length: attributed.length)
        )
        let clampedOffset = max(0, min(cellLocalOffset, attributed.length))
        let measured: CGFloat
        if clampedOffset == 0 || attributed.length == 0 {
            measured = 0
        } else {
            let prefix = attributed.attributedSubstring(
                from: NSRange(location: 0, length: clampedOffset)
            )
            measured = prefix.size().width
        }
        let caretX: CGFloat
        switch alignment {
        case .right:
            caretX = contentX + max(0, contentWidth - attributed.size().width) + measured
        case .center:
            caretX = contentX + max(0, (contentWidth - attributed.size().width) / 2) + measured
        default:
            caretX = contentX + measured
        }

        // FRAGMENT-LOCAL rect for the caret:
        //   (caretX, contentY, caretWidth, contentHeight)
        //
        // To convert fragment-local → view coords using the SAME
        // formula `TableHandleOverlay` uses for column rects:
        //   viewX = origin.x + caretX     (NO frame.origin.x)
        //   viewY = origin.y + frame.origin.y + contentY
        let caretWidth: CGFloat = editor.caretWidth
        return CGRect(
            x: origin.x + caretX,
            y: origin.y + frame.origin.y + contentY,
            width: caretWidth,
            height: contentHeight
        )
    }

    /// Park the cursor at the first-content offset of cell (row, col).
    /// Returns the storage offset.
    @discardableResult
    private func parkCursorInCell(
        editor: EditTextView,
        fragment: TableLayoutFragment,
        row: Int, col: Int
    ) -> Int? {
        guard let tlm = editor.textLayoutManager,
              let contentStorage = tlm.textContentManager
                as? NSTextContentStorage,
              let element = fragment.textElement as? TableElement,
              let elementRange = element.elementRange,
              let cellRange = element.cellRange(
                forCellAt: (row: row, col: col)
              )
        else { return nil }
        let docStart = contentStorage.documentRange.location
        let elementStart = contentStorage.offset(
            from: docStart, to: elementRange.location
        )
        // Park at the START of the cell content (offset 0 within cell).
        // Note: handleTableCellClick parks at END; for caret diagnostic
        // we want offset=0 so measured width is 0 — easier comparison.
        let target = elementStart + cellRange.location
        editor.setSelectedRange(NSRange(location: target, length: 0))
        return target
    }

    // MARK: - Diagnostic tests

    /// 3x3 table, cell (0, 0). Compare overlay-style math vs.
    /// `caretRectIfInTableCell`. Dump components on mismatch.
    func test_diag_caretRect_cell_0_0_topLeft() {
        let md = """
        | A | B | C |
        | --- | --- | --- |
        | r1c1 | r1c2 | r1c3 |
        | r2c1 | r2c2 | r2c3 |
        """
        let h = EditorHarness(markdown: md, windowActivation: .keyWindow)
        defer { h.teardown() }
        guard let fragment = firstTableFragment(h.editor) else {
            XCTFail("no TableLayoutFragment found")
            return
        }
        guard let _ = parkCursorInCell(
            editor: h.editor, fragment: fragment, row: 0, col: 0
        ) else {
            XCTFail("parkCursorInCell failed for (0,0)")
            return
        }
        guard let expected = expectedCaretRect(
            in: h.editor, fragment: fragment, row: 0, col: 0
        ) else {
            XCTFail("expectedCaretRect nil for (0,0)")
            return
        }
        let actual = h.editor.caretRectIfInTableCell()
        let frame = fragment.layoutFragmentFrame
        let origin = h.editor.textContainerOrigin
        let inset = h.editor.textContainerInset
        // Use NSTextView's super.textContainerOrigin via KVC-reflective
        // path — `super.textContainerOrigin` is not directly callable
        // outside the override, but we can reproduce by reading
        // `textContainerInset.height` (system-default origin in
        // non-vertically-resizable layout = inset).
        let superOriginY = inset.height
        let superOriginX = inset.width
        logLine("=== test_diag_caretRect_cell_0_0_topLeft ===")
        logLine("  fragment.layoutFragmentFrame = \(frame)")
        logLine("  editor.textContainerOrigin   = \(origin)  (overridden)")
        logLine("  editor.textContainerInset    = \(inset)")
        logLine("  super.textContainerOrigin    ≈ (\(superOriginX), \(superOriginY))  (= inset; the override subtracts 7 from y)")
        if let geom = fragment.geometryForHandleOverlay() {
            logLine("  geom.columnWidths = \(geom.columnWidths)")
            logLine("  geom.rowHeights   = \(geom.rowHeights)")
        }
        logLine("  expected (overlay-style) = \(expected)")
        logLine("  actual   (caretRectIfIn) = \(actual.map { "\($0)" } ?? "nil")")
        if let a = actual {
            let dx = a.origin.x - expected.origin.x
            let dy = a.origin.y - expected.origin.y
            logLine("  Δ(x=\(dx), y=\(dy))")
        }
    }

    /// 3x3 table, cell (2, 2) — bottom-right corner.
    func test_diag_caretRect_cell_2_2_bottomRight() {
        let md = """
        | A | B | C |
        | --- | --- | --- |
        | r1c1 | r1c2 | r1c3 |
        | r2c1 | r2c2 | r2c3 |
        """
        let h = EditorHarness(markdown: md, windowActivation: .keyWindow)
        defer { h.teardown() }
        guard let fragment = firstTableFragment(h.editor) else {
            XCTFail("no TableLayoutFragment found")
            return
        }
        guard let _ = parkCursorInCell(
            editor: h.editor, fragment: fragment, row: 2, col: 2
        ) else {
            XCTFail("parkCursorInCell failed for (2,2)")
            return
        }
        guard let expected = expectedCaretRect(
            in: h.editor, fragment: fragment, row: 2, col: 2
        ) else {
            XCTFail("expectedCaretRect nil for (2,2)")
            return
        }
        let actual = h.editor.caretRectIfInTableCell()
        let frame = fragment.layoutFragmentFrame
        let origin = h.editor.textContainerOrigin
        let inset = h.editor.textContainerInset
        logLine("=== test_diag_caretRect_cell_2_2_bottomRight ===")
        logLine("  fragment.layoutFragmentFrame = \(frame)")
        logLine("  editor.textContainerOrigin   = \(origin)")
        logLine("  editor.textContainerInset    = \(inset)")
        logLine("  expected (overlay-style) = \(expected)")
        logLine("  actual   (caretRectIfIn) = \(actual.map { "\($0)" } ?? "nil")")
        if let a = actual {
            let dx = a.origin.x - expected.origin.x
            let dy = a.origin.y - expected.origin.y
            logLine("  Δ(x=\(dx), y=\(dy))")
        }
    }

    /// Verify that the click hit-test (`handleTableCellClick`) and the
    /// caret painter (`caretRectIfInTableCell`) use SYMMETRIC coord
    /// transforms. Click handler subtracts `textContainerInset`, caret
    /// painter adds `textContainerOrigin`. With the -7pt y override
    /// these differ by 7pt — possibly the bug.
    func test_diag_clickToCaret_symmetry_topLeft() {
        let md = """
        | A | B | C |
        | --- | --- | --- |
        | r1c1 | r1c2 | r1c3 |
        | r2c1 | r2c2 | r2c3 |
        """
        let h = EditorHarness(markdown: md, windowActivation: .keyWindow)
        defer { h.teardown() }
        guard let fragment = firstTableFragment(h.editor) else {
            XCTFail("no TableLayoutFragment found")
            return
        }
        let frame = fragment.layoutFragmentFrame
        let inset = h.editor.textContainerInset
        let origin = h.editor.textContainerOrigin
        logLine("=== test_diag_clickToCaret_symmetry_topLeft ===")
        logLine("  fragment.layoutFragmentFrame = \(frame)")
        logLine("  inset                        = \(inset)  (click handler subtracts THIS)")
        logLine("  origin                       = \(origin)  (caret painter adds THIS)")
        logLine("  Δ(origin.y - inset.height)   = \(origin.y - inset.height)  (-7 = the override)")
        logLine("  Δ(origin.x - inset.width)    = \(origin.x - inset.width)")
        // Simulate a click at the visual top-left of the (0, 0) cell.
        // Visual cell-top-left in view coords:
        //   x = origin.x + handleBarWidth
        //   y = origin.y + frame.origin.y + handleBarHeight
        let cellTopLeftViewX = origin.x + TableGeometry.handleBarWidth
        let cellTopLeftViewY = origin.y + frame.origin.y + TableGeometry.handleBarHeight
        // Click handler maps viewPoint → containerPoint via:
        //   properPoint = viewPoint - inset
        let properX = cellTopLeftViewX - inset.width
        let properY = cellTopLeftViewY - inset.height
        // Then localPoint = properPoint - frame.origin
        let localX = properX - frame.origin.x
        let localY = properY - frame.origin.y
        logLine("  click at view=(\(cellTopLeftViewX), \(cellTopLeftViewY))")
        logLine("    -> properPoint=(\(properX), \(properY))")
        logLine("    -> localPoint=(\(localX), \(localY))")
        logLine("    handleBarHeight = \(TableGeometry.handleBarHeight)")
        // cellHit returns nil for localY < handleBarHeight. With the
        // -7pt override, localY of the visual cell-top is `handleBarHeight - 7`.
        // If handleBarHeight > 7, localY > 0 but < handleBarHeight,
        // landing in the column-handle strip and returning nil.
        let topStripHit = localY < TableGeometry.handleBarHeight
        logLine("    localY < handleBarHeight (i.e. cellHit returns nil)? \(topStripHit)")
        if topStripHit {
            logLine("    >>> THIS IS THE BUG: a click at the visual cell-top resolves to the handle strip <<<")
        }
    }
}
