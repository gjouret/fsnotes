//
//  EditTextView+TableNav.swift
//  FSNotes
//
//  Phase 2e-T2-d — Cursor + keyboard navigation inside a `TableElement`
//  grid. Does NOT edit cell text (T2-e) and does NOT implement hover /
//  drag-reorder / focus ring (T2-g). Pure routing:
//
//    * Tab / Shift-Tab  → next / previous cell (wraps across rows)
//    * Right-arrow at cell end    → start of next cell
//    * Left-arrow  at cell start  → end   of previous cell
//    * Down-arrow  inside a cell  → same column, row below
//    * Up-arrow    inside a cell  → same column, row above
//    * Down-arrow  on bottom row, Up-arrow on top row → default handling
//      (exit the grid into the block above / below)
//    * Return inside a cell → no-op with a diagnostic log. T2-e will
//      wire the actual `<br>` insertion.
//
//  Click-to-cell needs no wiring: NSTextView's hit-test already maps a
//  clicked point to a character offset in storage, and the locator
//  decodes that offset into a (row, col) for everything downstream.
//  The companion test `test_T2d_click_resolvesToCell` verifies this.
//
//  Integration contract:
//    * The entry point is `doCommand(by:)` — NSResponder's standard
//      keyboard-command funnel. `keyDown(with:)` in
//      `EditTextView+Input.swift` bails out of its list-FSM / Return
//      interception when the cursor is in a TableElement so the
//      keystroke reaches `super.keyDown` → `doCommand(by:)` → us.
//    * `handleEditViaBlockModel` in `EditTextView+BlockModel.swift`
//      early-returns true (with a diag log) when the cursor is inside
//      a TableElement and the replacement is not a T2-d-handled
//      keystroke. This makes typing a letter a no-op instead of
//      mutating the separator-encoded storage — T2-e is what turns
//      typing into a real cell edit.
//
//  The heavy lifting is three TK2 API calls:
//    1. `textLayoutManager.textLayoutFragment(for: NSTextLocation)`
//       resolves a cursor offset to its layout fragment.
//    2. `fragment.textElement as? TableElement` identifies whether the
//       cursor is inside the grid.
//    3. `TableElement.cellLocation(forOffset:)` / `offset(forCellAt:)`
//       (pure; shipped in 2e-T2-d) compute the (row, col) → offset
//       round-trip the navigation commands need.
//

import AppKit

extension EditTextView {

    // MARK: - Context resolution

    /// All the pieces a nav command needs: the `TableElement`, the
    /// cursor's *element-local* offset (so locator math is per-element,
    /// not per-document), and the cursor's (row, col).
    ///
    /// Returns `nil` if the cursor isn't inside a TableElement, if the
    /// layout manager isn't TK2, or if the cursor happens to be sitting
    /// on a separator character (U+001F / U+001E) — the locator returns
    /// nil there, and nav commands that rely on a cell context no-op.
    struct TableCursorContext {
        let element: TableElement
        let elementStorageStart: Int
        let localOffset: Int
        let row: Int
        let col: Int
    }

    /// Resolve the current selection's primary caret to a
    /// `TableCursorContext` — or nil if the cursor isn't inside a
    /// TableElement (i.e. everywhere but the grid).
    func tableCursorContext() -> TableCursorContext? {
        guard let tlm = self.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage
        else { return nil }

        let cursorOffset = selectedRange().location
        guard cursorOffset >= 0,
              cursorOffset <= (textStorage?.length ?? 0)
        else { return nil }

        let docStart = contentStorage.documentRange.location
        guard let cursorLoc = contentStorage.location(
            docStart, offsetBy: cursorOffset
        ) else { return nil }

        // `textLayoutFragment(for: NSTextLocation)` returns the fragment
        // that *contains* the location. For a cursor sitting on the
        // boundary between fragments, it returns the one whose range
        // starts at that location. That's the behaviour we want — a
        // cursor at position 0 of a TableElement should resolve to the
        // table, not to whatever fragment precedes it.
        guard let fragment = tlm.textLayoutFragment(for: cursorLoc),
              let element = fragment.textElement as? TableElement,
              let elementRange = element.elementRange
        else { return nil }

        let elementStart = contentStorage.offset(
            from: docStart, to: elementRange.location
        )
        let localOffset = cursorOffset - elementStart
        guard let (row, col) = element.cellLocation(forOffset: localOffset)
        else { return nil }

        return TableCursorContext(
            element: element,
            elementStorageStart: elementStart,
            localOffset: localOffset,
            row: row,
            col: col
        )
    }

    /// `true` if the cursor is currently anywhere inside a TableElement
    /// (including on a separator — this is the broad gate used by the
    /// defensive early-return in `handleEditViaBlockModel`). The
    /// narrower check used by nav commands is `tableCursorContext()`,
    /// which additionally requires a resolvable (row, col).
    func cursorIsInTableElement() -> Bool {
        return storageOffsetIsInTableElement(selectedRange().location)
    }

    /// `true` if the given storage offset lives inside a TableElement.
    /// The defensive gate in `handleEditViaBlockModel` uses this to
    /// check the edit range's start (which may differ from the current
    /// selection — e.g. when paste routes an arbitrary range through
    /// `shouldChangeText`).
    func storageOffsetIsInTableElement(_ offset: Int) -> Bool {
        guard let tlm = self.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage
        else { return false }
        guard offset >= 0, offset <= (textStorage?.length ?? 0) else {
            return false
        }
        let docStart = contentStorage.documentRange.location
        guard let loc = contentStorage.location(
            docStart, offsetBy: offset
        ) else { return false }
        guard let fragment = tlm.textLayoutFragment(for: loc) else {
            return false
        }
        return fragment.textElement is TableElement
    }

    // MARK: - doCommand(by:) chain

    /// NSResponder entry point for keyboard commands. Asks the
    /// table-nav handler first and falls through to super for
    /// non-table commands.
    ///
    /// Design choice: intercepting here (rather than in `keyDown`) gives
    /// us a stable, per-selector hook that doesn't care about keyCode
    /// layout or modifier flags. Selection-extension variants (e.g.
    /// `moveRightAndModifySelection:`) aren't intercepted in this slice
    /// — shift+arrow falls through to the default TK2 extension
    /// behaviour, which is the conservative choice until T2-e wires
    /// selection contracts through.
    override func doCommand(by selector: Selector) {
        if handleTableNavCommand(selector) {
            return
        }
        super.doCommand(by: selector)
    }

    /// Table-nav command dispatcher. Returns `true` when the command
    /// was handled (caller must not chain to super); `false` when the
    /// cursor isn't in a TableElement or the command doesn't apply —
    /// in which case the caller falls through to default handling.
    ///
    /// Tested standalone: each handler below is called directly from
    /// `Tests/TableNavigationTests.swift` via a public entry point
    /// on `EditTextView`, so the core routing logic is testable
    /// without driving `doCommand(by:)` through a synthesized key
    /// event (CLAUDE.md rule 3).
    func handleTableNavCommand(_ selector: Selector) -> Bool {
        // Fast path: not in a TableElement → nothing to do.
        guard let ctx = tableCursorContext() else {
            // If the cursor is in a TableElement but on a separator,
            // we still want to swallow Return so the default newline
            // path doesn't corrupt the storage. Gate that on the
            // broader `cursorIsInTableElement` predicate.
            if cursorIsInTableElement(),
               selector == #selector(NSResponder.insertNewline(_:)) ||
               selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                bmLog("T2-e: Return in TableElement (on separator) — no-op")
                return true
            }
            return false
        }

        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            return moveToAdjacentCell(from: ctx, offset: +1)

        case #selector(NSResponder.insertBacktab(_:)):
            return moveToAdjacentCell(from: ctx, offset: -1)

        case #selector(NSResponder.moveRight(_:)):
            return moveHorizontal(from: ctx, direction: +1)

        case #selector(NSResponder.moveLeft(_:)):
            return moveHorizontal(from: ctx, direction: -1)

        case #selector(NSResponder.moveDown(_:)):
            return moveVertical(from: ctx, direction: +1)

        case #selector(NSResponder.moveUp(_:)):
            return moveVertical(from: ctx, direction: -1)

        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Phase 2e-T2-e: Return inside a cell inserts a hard line
            // break into the cell's inline tree. Route through the
            // shared cell-edit path in `handleEditViaBlockModel` so
            // every insert shares the same encoding contract (the
            // converter translates `\n` in a cell's attributed string
            // to `.rawHTML("<br>")`, which matches the widget path's
            // cell line-break representation).
            let caret = selectedRange().location
            let insertedRange = NSRange(location: caret, length: 0)
            let handled = handleEditViaBlockModel(
                in: insertedRange, replacementString: "\n"
            )
            if handled {
                bmLog("T2-e: Return in cell (\(ctx.row),\(ctx.col)) inserted <br>")
                return true
            }
            // If the edit couldn't be routed through the cell path,
            // swallow the Return anyway — we never want the default
            // newline path (which inserts a real `\n` into storage) to
            // corrupt the separator-encoded TableElement.
            bmLog("T2-e: Return in cell (\(ctx.row),\(ctx.col)) — cell path refused, swallowing")
            return true

        default:
            return false
        }
    }

    // MARK: - Cell-granularity movement (Tab / Shift-Tab)

    /// Tab / Shift-Tab: advance to the next / previous cell in
    /// row-major order, wrapping across rows. At the end of the last
    /// cell, Tab wraps to the header's first cell; at the start of
    /// the first cell, Shift-Tab wraps to the last body cell. This
    /// is the InlineTableView widget's behaviour; T2-e may refine it
    /// (e.g. "Tab at bottom-right appends a new body row") but the
    /// wrap-around is the read-only default.
    private func moveToAdjacentCell(
        from ctx: TableCursorContext,
        offset delta: Int
    ) -> Bool {
        guard case .table(let header, _, let rows, _, _) = ctx.element.block
        else { return false }

        let cols = header.count
        let totalRows = 1 + rows.count // header + body
        guard cols > 0, totalRows > 0 else { return false }

        let totalCells = cols * totalRows
        let currentIdx = ctx.row * cols + ctx.col
        // Modular arithmetic so negative delta wraps correctly.
        let targetIdx = ((currentIdx + delta) % totalCells + totalCells) % totalCells
        let targetRow = targetIdx / cols
        let targetCol = targetIdx % cols

        return placeCursor(
            in: ctx.element,
            elementStart: ctx.elementStorageStart,
            at: (row: targetRow, col: targetCol)
        )
    }

    // MARK: - Cell boundary movement (Left / Right arrows)

    /// Right-arrow: if the cursor is at the end of its cell's text,
    /// jump to the start of the next cell. Otherwise, fall through to
    /// default character movement (the TK2 text view moves inside the
    /// cell text normally).
    ///
    /// Left-arrow: if the cursor is at the start of its cell's text,
    /// jump to the end of the previous cell. Otherwise, fall through.
    private func moveHorizontal(
        from ctx: TableCursorContext,
        direction: Int
    ) -> Bool {
        guard case .table(let header, _, let rows, _, _) = ctx.element.block
        else { return false }

        let cellStart = ctx.element.offset(
            forCellAt: (row: ctx.row, col: ctx.col)
        ) ?? 0
        let cellText = cellTextLength(
            of: ctx.element, row: ctx.row, col: ctx.col
        )
        let cellEnd = cellStart + cellText

        let cols = header.count
        let totalRows = 1 + rows.count
        let currentIdx = ctx.row * cols + ctx.col
        let totalCells = cols * totalRows

        if direction > 0 {
            // At end of cell? Jump to next cell's start.
            if ctx.localOffset >= cellEnd {
                let nextIdx = (currentIdx + 1) % totalCells
                let targetRow = nextIdx / cols
                let targetCol = nextIdx % cols
                return placeCursor(
                    in: ctx.element,
                    elementStart: ctx.elementStorageStart,
                    at: (row: targetRow, col: targetCol)
                )
            }
            return false
        } else {
            // At start of cell? Jump to previous cell's end.
            if ctx.localOffset <= cellStart {
                let prevIdx = ((currentIdx - 1) % totalCells + totalCells) % totalCells
                let targetRow = prevIdx / cols
                let targetCol = prevIdx % cols
                let prevStart = ctx.element.offset(
                    forCellAt: (row: targetRow, col: targetCol)
                ) ?? 0
                let prevLen = cellTextLength(
                    of: ctx.element, row: targetRow, col: targetCol
                )
                let targetLocal = prevStart + prevLen
                setSelectedRange(NSRange(
                    location: ctx.elementStorageStart + targetLocal,
                    length: 0
                ))
                return true
            }
            return false
        }
    }

    // MARK: - Cell vertical movement (Up / Down arrows)

    /// Down-arrow: same column, row below. At the bottom-most row, fall
    /// through so the default handler exits the grid into the block
    /// below (which is the InlineTableView widget's behaviour).
    ///
    /// Up-arrow: same column, row above. At the top-most row, fall
    /// through so the default handler exits into the block above.
    private func moveVertical(
        from ctx: TableCursorContext,
        direction: Int
    ) -> Bool {
        guard case .table(let header, _, let rows, _, _) = ctx.element.block
        else { return false }

        let totalRows = 1 + rows.count
        let targetRow = ctx.row + direction
        guard targetRow >= 0, targetRow < totalRows else {
            // Past the edge of the grid — let default handling exit
            // the table (into the block above / below).
            return false
        }
        let cols = header.count
        let targetCol = min(ctx.col, cols - 1)
        return placeCursor(
            in: ctx.element,
            elementStart: ctx.elementStorageStart,
            at: (row: targetRow, col: targetCol)
        )
    }

    // MARK: - Cursor placement helpers

    /// Place the cursor at the FIRST content character of the given
    /// cell. Returns true on success, false if the `(row, col)` is
    /// out of range.
    private func placeCursor(
        in element: TableElement,
        elementStart: Int,
        at position: (row: Int, col: Int)
    ) -> Bool {
        guard let local = element.offset(forCellAt: position) else {
            return false
        }
        let target = elementStart + local
        setSelectedRange(NSRange(location: target, length: 0))
        return true
    }

    /// Length (UTF-16 units) of the cell's content — i.e. how many
    /// characters sit between the cell's start offset and the next
    /// separator / end-of-element.
    ///
    /// Derives the value from the decoded `Block.table`'s cell raw
    /// text so the calculation stays pure over the element's block
    /// payload, not over the attributed string. The body cells are
    /// the decoded separator-split text, which is precisely what the
    /// storage encodes between separators.
    private func cellTextLength(
        of element: TableElement,
        row: Int,
        col: Int
    ) -> Int {
        guard case .table(let header, _, let rows, _, _) = element.block
        else { return 0 }

        // The stored `rawText` on a TableCell under the native path is
        // the rendered cell text — which is what the separator-encoded
        // storage holds. (`TableTextRenderer.renderNative` concatenates
        // the inline-rendered string for each cell; the content-storage
        // delegate's placeholder decode reconstructs `TableCell` from
        // that same rendered text.) So `rawText.utf16.count` is the
        // cell's storage length.
        let cell: TableCell?
        if row == 0 {
            cell = col < header.count ? header[col] : nil
        } else {
            let bodyIdx = row - 1
            guard bodyIdx < rows.count else { return 0 }
            let rowCells = rows[bodyIdx]
            cell = col < rowCells.count ? rowCells[col] : nil
        }
        return cell?.rawText.utf16.count ?? 0
    }
}
