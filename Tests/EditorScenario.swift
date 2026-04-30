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
    /// `TableContainerView`, `CodeBlockEditToggleView`) must mount
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
        if let cell = editor.window?.firstResponder as? TableCellTextView {
            cell.insertText(text, replacementRange: cell.selectedRange())
        } else {
            harness.type(text, file: file, line: line)
        }
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

    /// Press Tab. If a table cell view owns first responder, route the
    /// command through that cell's NSTextView delegate; otherwise fall
    /// back to the parent editor.
    @discardableResult
    func pressTab(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        if let cell = editor.window?.firstResponder as? NSTextView {
            cell.doCommand(by: #selector(NSResponder.insertTab(_:)))
        } else {
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        }
        return self
    }

    /// Press Shift-Tab. Mirrors `pressTab` for the previous-cell move.
    @discardableResult
    func pressShiftTab(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        if let cell = editor.window?.firstResponder as? NSTextView {
            cell.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        } else {
            editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        }
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

    private func allDescendants<T: NSView>(
        of root: NSView,
        type: T.Type
    ) -> [T] {
        var out: [T] = []
        for subview in root.subviews {
            if let typed = subview as? T { out.append(typed) }
            out.append(contentsOf: allDescendants(of: subview, type: type))
        }
        return out
    }

    /// Click inside the cell `(row, col)` of the first mounted
    /// subview-backed table. Drives `mouseDown` on the actual
    /// `TableCellTextView`, matching AppKit's normal hit-test route.
    ///
    /// Requires the scenario to be `.keyWindow`; offscreen scenarios
    /// don't pump the event loop.
    @discardableResult
    func clickInCell(
        row: Int, col: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EditorScenario {
        guard let window = editor.window else {
            XCTFail(
                "EditorScenario.clickInCell: editor has no window.",
                file: file, line: line
            )
            return self
        }
        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            tlm.textViewportLayoutController.layoutViewport()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            tlm.textViewportLayoutController.layoutViewport()
        }
        let cells = allDescendants(of: editor, type: TableCellTextView.self)
        guard let cell = cells.first(where: {
            $0.cellRow == row && $0.cellCol == col
        }) else {
            XCTFail(
                "EditorScenario.clickInCell: (row=\(row), col=\(col)) " +
                "not found. Mounted cells=\(cells.map { ($0.cellRow, $0.cellCol) })",
                file: file, line: line
            )
            return self
        }
        let cellPoint = NSPoint(x: cell.bounds.midX, y: cell.bounds.midY)
        let windowPoint = cell.convert(cellPoint, to: nil)
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
            XCTFail("EditorScenario.clickInCell: could not synthesize mouse event", file: file, line: line)
            return self
        }
        window.postEvent(upEvent, atStart: false)
        cell.mouseDown(with: downEvent)
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
