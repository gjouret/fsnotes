//
//  EditorScenario.swift
//  FSNotesTests
//
//  Phase 11 Slice A — composable user-flow builder.
//
//  A `Given.note(...)` call returns an `EditorScenario`: a chainable
//  builder owning a single `EditorHarness`. Every step (`with`,
//  `insertTable`, `clickInCell`, `type`, `pressReturn`, ...) forwards
//  to the harness and returns `self` so flows compose linearly:
//
//      Given.note().with(paragraph: "p")
//          .insertTable()
//          .type("X")
//          .Then.cursor.isInCell(row: 0, col: 0)
//          .Then.tableContent.cell(0, 0).equals("X")
//
//  Assertions live in `EditorAssertions.swift`; this file is the
//  user-flow side only.
//
//  Constraints (Slice A):
//    - Pure-additive: no production code is touched. Every step maps
//      to an existing `EditorHarness` operation or an existing
//      production IBAction (e.g. `EditTextView.insertTableMenu`).
//    - The harness chooses window-activation on init. Steps that need
//      `.keyWindow` (e.g. `clickInCell` driven through a real mouse
//      event) live in scenarios constructed with `Given.keyWindow(...)`;
//      pure-pipeline scenarios use the default `.offscreen` mode.
//

import XCTest
import AppKit
@testable import FSNotes

// MARK: - Given factory

/// Static factory namespace. Every flow starts at `Given.note()` (or
/// the `.keyWindow` variant for clickable scenarios). Returns a
/// chainable `EditorScenario`.
enum Given {

    /// Empty offscreen-window scenario. Use for the pure-pipeline
    /// flows (typing, IBActions, structural edits) that don't need
    /// real mouse events.
    static func note(
        markdown: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        return EditorScenario(
            markdown: markdown,
            activation: .offscreen,
            file: file,
            line: line
        )
    }

    /// Key-window scenario. Use when the test must drive a real
    /// `mouseDown` (e.g. `clickInCell`) or when widget-layer
    /// subviews (`BulletGlyphView`, `CheckboxGlyphView`,
    /// `TableHandleView`, `CodeBlockEditToggleView`) must mount
    /// before assertion.
    static func keyWindowNote(
        markdown: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        return EditorScenario(
            markdown: markdown,
            activation: .keyWindow,
            file: file,
            line: line
        )
    }
}

// MARK: - EditorScenario

/// Chainable builder. Every `When`-style step returns `self` so flows
/// compose linearly. The `.Then` property opens the assertion
/// namespace (`EditorAssertions`), which itself returns chainable
/// readbacks.
///
/// Lifetime: the underlying `EditorHarness` is torn down on `deinit`.
/// Tests don't need an explicit teardown call — the scenario is
/// scoped to the test method.
final class EditorScenario {

    /// Internal handle to the harness. Exposed for the assertion layer
    /// (which reads `editor`, `documentProjection`, `selectedRange`,
    /// snapshot, etc.) and for tests that escape the DSL for a one-off
    /// readback that doesn't yet exist as a `Then.*` call.
    let harness: EditorHarness

    /// Captured at scenario construction so contract failures and
    /// path errors point at the test method rather than this file.
    let originFile: StaticString
    let originLine: UInt

    init(
        markdown: String,
        activation: EditorHarness.WindowActivation,
        file: StaticString,
        line: UInt
    ) {
        self.harness = EditorHarness(
            markdown: markdown, windowActivation: activation
        )
        self.originFile = file
        self.originLine = line
    }

    deinit {
        harness.teardown()
    }

    /// Convenience accessor — the live editor.
    var editor: EditTextView { harness.editor }

    // MARK: - Given builders (seed-shape variants)

    /// Seed the editor with the given paragraph as the only block.
    /// Useful when the flow needs at least one block to operate on
    /// (e.g. `insertTableMenu` needs `blockContaining(0)` to resolve).
    @discardableResult
    func with(paragraph: String) -> EditorScenario {
        harness.type(paragraph)
        return self
    }

    // MARK: - When chain (input verbs)

    /// Type at the current selection. No newlines — use `pressReturn`.
    @discardableResult
    func type(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        harness.type(text, file: file, line: line)
        return self
    }

    /// Press Return.
    @discardableResult
    func pressReturn(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        harness.pressReturn(file: file, line: line)
        return self
    }

    /// Backspace.
    @discardableResult
    func pressDelete(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        harness.pressDelete(file: file, line: line)
        return self
    }

    /// Forward-delete.
    @discardableResult
    func pressForwardDelete(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        harness.pressForwardDelete(file: file, line: line)
        return self
    }

    /// Press Tab. Routes through `handleTableNavCommand` so the
    /// table-cell move semantics (advance-cell, no literal `\t`) are
    /// exercised when the cursor is in a TableElement; falls through to
    /// default handling otherwise.
    @discardableResult
    func pressTab(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        _ = editor.handleTableNavCommand(
            #selector(NSResponder.insertTab(_:))
        )
        return self
    }

    /// Press Shift-Tab. Mirrors `pressTab` for the previous-cell move.
    @discardableResult
    func pressShiftTab(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        _ = editor.handleTableNavCommand(
            #selector(NSResponder.insertBacktab(_:))
        )
        return self
    }

    /// Paste markdown at the current selection.
    @discardableResult
    func paste(
        markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        harness.paste(markdown: markdown, file: file, line: line)
        return self
    }

    /// Move the cursor to the given storage offset.
    @discardableResult
    func cursorAt(_ offset: Int) -> EditorScenario {
        harness.moveCursor(to: offset)
        return self
    }

    /// Select the given storage range.
    @discardableResult
    func select(_ range: NSRange) -> EditorScenario {
        harness.selectRange(range)
        return self
    }

    /// Select the entire document.
    @discardableResult
    func selectAll() -> EditorScenario {
        let len = editor.textStorage?.length ?? 0
        harness.selectRange(NSRange(location: 0, length: len))
        return self
    }

    // MARK: - When chain (IBActions / structural verbs)

    /// Insert a 2-column × 1-body-row table after the current block —
    /// the same shape `EditTextView.insertTableMenu` produces. Cursor
    /// lands inside the new table's top-left cell when the production
    /// path works correctly. The `rows`/`cols` parameters are accepted
    /// for forward compatibility with Slice B but Slice A only ships
    /// the IBAction's hard-coded 2x2 (header + 1 body row) shape; non-
    /// default values currently raise `XCTFail` rather than fabricate
    /// a divergent table.
    @discardableResult
    func insertTable(
        rows: Int = 1,
        cols: Int = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        if rows != 1 || cols != 2 {
            XCTFail(
                "EditorScenario.insertTable: only the IBAction's " +
                "default 2-col × 1-body-row shape is supported in " +
                "Slice A (got rows=\(rows) cols=\(cols)). Slice B " +
                "will accept arbitrary shapes via a pure primitive.",
                file: file, line: line
            )
        }
        editor.insertTableMenu(NSObject())
        return self
    }

    /// Click inside the cell `(row, col)` of the (single) table block
    /// in the document. Drives `mouseDown` through the live event
    /// chain — the same path `handleTableCellClick` maps via
    /// `TableLayoutFragment.cellHit(at:)`.
    ///
    /// Requires the scenario to be `.keyWindow`; offscreen scenarios
    /// don't pump the event loop.
    @discardableResult
    func clickInCell(
        row: Int, col: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        guard let projection = editor.documentProjection else {
            XCTFail(
                "EditorScenario.clickInCell: no document projection.",
                file: file, line: line
            )
            return self
        }
        // Find the first table block + its TK2 fragment.
        var tableBlockIdx: Int? = nil
        for (i, block) in projection.document.blocks.enumerated() {
            if case .table = block { tableBlockIdx = i; break }
        }
        guard let blockIdx = tableBlockIdx,
              blockIdx < projection.blockSpans.count
        else {
            XCTFail(
                "EditorScenario.clickInCell: no table block in document.",
                file: file, line: line
            )
            return self
        }
        let span = projection.blockSpans[blockIdx]

        guard let tlm = editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage
        else {
            XCTFail(
                "EditorScenario.clickInCell: no TK2 layout manager.",
                file: file, line: line
            )
            return self
        }
        tlm.ensureLayout(for: tlm.documentRange)
        let docStart = cs.documentRange.location

        var fragment: TableLayoutFragment? = nil
        var fragOrigin: CGPoint = .zero
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            guard let er = f.textElement?.elementRange else { return true }
            let charIndex = cs.offset(from: docStart, to: er.location)
            if charIndex == span.location, let tf = f as? TableLayoutFragment {
                fragment = tf
                fragOrigin = f.layoutFragmentFrame.origin
                return false
            }
            return true
        }
        guard let frag = fragment, let geom = frag.geometryForHandleOverlay()
        else {
            XCTFail(
                "EditorScenario.clickInCell: could not locate TableLayoutFragment.",
                file: file, line: line
            )
            return self
        }

        // Compute the click point in fragment-local coordinates.
        // rowHeights[0] is the header row; rowHeights[r+1] is body
        // row r. For the demo flow, row==0 means header — match
        // the existing `cellHit(at:)` semantics in TableCellHitTestTests.
        guard col >= 0, col < geom.columnWidths.count,
              row >= 0, row < geom.rowHeights.count
        else {
            XCTFail(
                "EditorScenario.clickInCell: (row=\(row), col=\(col)) " +
                "out of range cols=\(geom.columnWidths.count) " +
                "rows=\(geom.rowHeights.count).",
                file: file, line: line
            )
            return self
        }
        var localX = TableGeometry.handleBarWidth
        for c in 0..<col { localX += geom.columnWidths[c] }
        localX += geom.columnWidths[col] / 2
        var localY = TableGeometry.handleBarHeight
        for r in 0..<row { localY += geom.rowHeights[r] }
        localY += geom.rowHeights[row] / 2

        // Translate to view-local coordinates: fragment origin +
        // textContainerInset.
        let viewPoint = NSPoint(
            x: localX + fragOrigin.x + editor.textContainerInset.width,
            y: localY + fragOrigin.y + editor.textContainerInset.height
        )
        harness.clickAt(point: viewPoint)
        return self
    }

    // MARK: - Then namespace

    /// Open the assertion namespace. Each readback returns a fresh
    /// `EditorAssertions` so chains read left-to-right:
    ///
    ///     .Then.cursor.isInCell(row: 0, col: 0)
    ///         .Then.tableContent.cell(0, 0).equals("X")
    var Then: EditorAssertions {
        return EditorAssertions(scenario: self)
    }
}
