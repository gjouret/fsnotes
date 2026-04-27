# Subview-Based Tables — Migration Plan

## Why

Phase 2e-T2 implemented tables natively in TK2 using a separator-encoded single-paragraph-per-table approach. Apple does **not** support tables in TK2 as of macOS 26 / WWDC 2025 (verified: Apple's own TextEdit falls back to TK1 when a table is inserted; krzyzanowskim's "TextKit 2 — The Promised Land" Aug 2025 lists tables among unsupported features). Every bug in the table editing surface — caret painting (#29), Find across cells (#60), IME inside cells, multi-line cell content, selection across cells — has been a workaround for the absence of a documented TK2 affordance.

Subview-based tables put each cell into its own small `NSTextView`, hosted in a parent grid view, attached to the document via `NSTextAttachment` + `NSTextAttachmentViewProvider`. The cell IS a real text editor; everything TK2 gives a normal paragraph (caret, selection, IME, autocorrect, spell-check, copy/paste, services menu, undo) it gives a cell. The framework is finally being used as designed for non-flow content.

## Non-goals (in this refactor)

- Changing `Document.Block.table` shape — it already supports rich-text cells (`TableCell.inline: [Inline]`)
- Changing the markdown serializer — `MarkdownSerializer.serialize` for `.table` is already correct
- Changing `EditingOps.replaceTableCellInline` and other pure primitives — they stay
- Changing CommonMark compliance — same parser

The Document model already knows what cells contain. We are only changing **how cells are rendered and edited at the view layer**.

## What gets deleted at the end

- `FSNotesCore/Rendering/Fragments/TableLayoutFragment.swift` (~1,100 LoC)
- `FSNotesCore/Rendering/TableTextRenderer.swift` `renderNative` path (~150 LoC)
- `FSNotesCore/Rendering/Elements/TableElement.swift` separator encoding helpers (~200 LoC; the type may stay as a thin marker)
- `FSNotes/View/TableCellCaretView.swift` (just shipped; no longer needed — cells paint their own caret)
- Native-cell editing/locator plumbing in `EditTextView+TableNav.swift`, `EditTextView+BlockModel.swift` (~500 LoC: `tableCursorContext`, `tableCursorContextForOffset`, `handleTableCellEdit`, `storageOffsetIsInTableElement`, `offsetIsTableCellStart`, `cellAtCursor` callers — most can be deleted; some adapt for the new path)
- `EditTextView+Appearance.swift` `caretRectIfInTableCell` + `drawInsertionPoint` table-rect override (~80 LoC)
- The U+2028 sanitization in `TableTextRenderer` (~30 LoC; cells now contain real `\n` because they're real paragraphs)
- `EditTextView+Interaction.swift` `handleTableCellClick` (~80 LoC; clicks land naturally in the cell's NSTextView)
- Most of `Bug29ClickSelectionTests.swift` and `TableCellHitTestTests.swift` (a few tests adapt; most lose meaning)

## What gets added

- `FSNotes/View/Tables/TableContainerView.swift` — parent NSView that hosts cells in a grid, paints borders, hosts hover handles. Replaces the per-block `TableLayoutFragment.draw` work. (~600-800 LoC)
- `FSNotes/View/Tables/TableCellTextView.swift` — `NSTextView` subclass for one cell. Routes Tab/Shift-Tab/arrow-at-boundary up to the parent. Coordinates undo via parent's NSUndoManager. (~200 LoC)
- `FSNotes/View/Tables/TableAttachment.swift` — `NSTextAttachment` subclass with `viewProvider(...)` returning a provider that hosts a `TableContainerView`. (~100 LoC)
- `FSNotes/View/Tables/TableAttachmentViewProvider.swift` — bridges between the attachment and the container view; lifecycles the cell views. (~150 LoC)
- `FSNotes/View/EditTextView+TableFind.swift` — `NSTextFinderClient` aggregator that exposes a unified searchable string across all cells of all tables in the document, plus the range translator that maps a global-find range back to (table, cell, cell-local-range) and drives focus + scroll. (~250 LoC)
- Phase F: hover handles port from `TableHandleOverlay.swift` (existing) to siblings of `TableContainerView` instead of overlays on `EditTextView`. ~200 LoC delta (mostly relocation).

Net: roughly **−1,500 to −2,000 LoC**, plus a class of bugs gone.

## Phases

Each phase is **self-contained, ships green tests, and can ship in isolation**. The current native-cell path keeps working until Phase G, with a feature flag flipping between the two implementations. Worst case: we abort mid-pivot and revert the flag.

### Phase A — Foundation (no behavior change)

A1. Add `TableContainerView`, `TableCellTextView`, `TableAttachment`, `TableAttachmentViewProvider` files. Empty / skeleton implementations. Add to `project.pbxproj` (4 entries each). Build clean.

A2. Add a `UserDefaultsManagement.useSubviewTables: Bool` flag, default `false`. Off-state behavior is exactly the current native-cell path.

A3. Implement `TableContainerView` to render a static read-only table from a `Block.table` — borders, header fill, zebra rows, cell content via `InlineRenderer` rendered into per-cell NSTextField (read-only). No editing yet. Pixel-match the current `TableLayoutFragment` chrome.

A4. Wire `TableAttachmentViewProvider` to construct a `TableContainerView` from the attachment's `Block.table` payload. Build a tiny opt-in test (`Tests/SubviewTable/SubviewTableRenderTests`) that creates an attachment, asks the provider for a view, and snapshots it. Green.

**Phase A exit criterion:** build clean, all existing tests still pass (flag is off so old path still runs), the new provider returns a view that renders a table when called from a test fixture.

### Phase B — Switch storage encoding behind the flag

B1. New `TableTextRenderer.renderAsAttachment(block:)` returns an `NSAttributedString` of length 1 — a single `U+FFFC` character with `NSAttachmentAttributeName` set to a `TableAttachment(block:)`. The block's content is the data the provider reads.

B2. `DocumentRenderer.renderBlock` for `.table` checks the feature flag: if `useSubviewTables` is on, calls `renderAsAttachment`; else calls the existing `renderNative`.

B3. `BlockModelContentStorageDelegate` already returns standard `NSTextParagraph` for `U+FFFC`-bearing paragraphs, so no special-case dispatch needed for the new path.

B4. New `TableTextRenderer` test asserts: a `Block.table` rendered with `useSubviewTables=true` produces exactly one `U+FFFC`, with the attachment carrying the `Block.table` payload.

**Phase B exit criterion:** with the flag on, opening a note with a table renders the table via the new view provider; with the flag off, it renders via the old fragment. Both paths green for read-only tables.

### Phase C — Editing inside cells

C1. `TableCellTextView` typing path: every edit dispatched through the cell's `NSTextView` is captured by the cell's `textViewDidChangeText` delegate, converted into the cell's new `[Inline]` tree via `InlineRenderer.inlineTreeFromAttributedString`, and applied via `EditingOps.replaceTableCellInline` on the parent's `Document`.

C2. Tab / Shift-Tab in a cell: `TableCellTextView.doCommand(by:)` intercepts `insertTab:` / `insertBacktab:`, and asks the parent `TableContainerView` to focus the next/previous cell. Parent calls `nextCellTextView.window?.makeFirstResponder(nextCellTextView)`.

C3. Tab from the LAST cell (last row, last col): ask parent `TableContainerView` whether to (a) stay put, (b) extend the table with a new row, or (c) exit downward. Default: stay put (matches current behavior). User-configurable later.

C4. Up/Down arrow at cell-content top/bottom: exit the table into the document's main NSTextView. Routes via responder chain — the cell's NSTextView resigns first responder, the document's NSTextView becomes first responder, cursor lands at appropriate position above/below the table's attachment character.

C5. Enter inside a cell: insert a hard line break (cell's storage gets a real `\n` because it's a real paragraph; round-trips through Inline as `.rawHTML("<br>")` per the existing `InlineRenderer.inlineTreeFromAttributedString` semantics — already working).

C6. Backspace at cell-start: no-op (matches current bug #37 fix). Otherwise normal cell deletion.

C7. Click anywhere in the cell: cell's NSTextView's standard `mouseDown` lands the caret correctly. The custom `handleTableCellClick` and click-routing code in `EditTextView+Interaction.swift` becomes unreachable for the new path and is gated by the flag.

**Phase C exit criterion:** the existing Bug29 test suite is rewritten in terms of `TableCellTextView` interactions and 6/6 green. Type, Tab, Enter, click — all behaviors that the user reported broken work end-to-end.

### Phase D — Find / search

D1. `EditTextView` adopts `NSTextFinderClient`. Aggregate `string` returns the document's main storage with a virtual marker for each table, expanded into per-cell text. Build a `TableFindIndex` data structure that maps "global find offset" ↔ "(tableBlockIndex, row, col, cellLocalOffset)".

D2. `NSTextFinder` `firstSelectedRange`, `rects(forCharacterRange:)`, `scrollRangeToVisible:`, `setSelectedRanges:` implementations consult the index. When a match is in a cell, focus shifts to that cell's NSTextView and the cell auto-scrolls into view.

D3. `Bug 60` (find across cells) becomes a passing test by construction: the aggregator exposes cell text to `NSTextFinder`, no special case needed.

**Phase D exit criterion:** Cmd+F in a note with tables finds matches inside cells and inside body paragraphs both, in document order.

### Phase E — Selection coordination

E1. Cmd+A in a cell selects the cell's content. Cmd+A again (within a short delta) extends to all cells of the table. A third Cmd+A extends to the whole document. (Standard "incremental Select All" pattern.)

E2. Selection that starts in body text and tries to extend INTO a table: stops at the table's attachment-character boundary. Selection inside a cell stays inside the cell. Document-spanning selections that include the attachment character treat it atomically.

E3. Drag-select inside a cell: handled by the cell's standard NSTextView. Drag from outside into a cell: stops at the boundary.

**Phase E exit criterion:** selection behavior is predictable and matches Notion / Bear / Obsidian's table selection (atomic table = atomic glyph in body selection; cell selection is internal to the cell).

### Phase F — Hover handles, drag-resize, drag-reorder

F1. Hover handles: `TableContainerView` adds `TableHandleChip` siblings (existing class; minor adapter to make it work with the new container instead of the overlay). Mouse-tracking moves with the container.

F2. Column drag-resize: pointer enters cell-boundary hit-zone, drags update `Block.table.columnWidths` via `EditingOps.setTableColumnWidths`. Container relays out cells.

F3. Row drag-reorder: existing `EditingOps.moveTableRow` primitive is unchanged; the drag UI re-anchors against `TableContainerView`'s cell rows.

F4. Insert column / row from menu: existing `EditingOps.insertTableRow / insertTableColumn` unchanged.

**Phase F exit criterion:** all chrome the user has today (handle chips, drag-resize, drag-reorder, insert/delete row/column) works in the subview path. Existing TableHandleOverlay tests pass against the new container, or are replaced.

### Phase G — Delete the native-cell path

G1. Flip `useSubviewTables` default to `true`. Run the full test suite; fix or delete any test that depended on the native-cell path.

G2. Delete: `TableLayoutFragment.swift`, `TableTextRenderer.renderNative`, `TableElement.swift` separator-encoding helpers (the type itself can stay as a marker if anything still references it), `TableCellCaretView.swift`, `caretRectIfInTableCell` and the `drawInsertionPoint` table-rect override, `handleTableCellClick`, `tableCursorContext` family, `handleTableCellEdit`, `storageOffsetIsInTableElement`, `offsetIsTableCellStart`, U+2028 sanitization.

G3. Delete: the obsolete tests (`Bug29ClickSelectionTests` adapted not deleted; `TableCellHitTestTests`, `TableCaretRectTests`, `TableNavigationTests` lose most cases — deletes-or-adapts pass).

G4. Remove the feature flag.

G5. `REFACTOR_PLAN.md` updated: Phase 2e-T2 is marked superseded by Phase 8 (this work). The "two paths considered and rejected" historical note about subview-based tables is updated with the actual reasons we picked it now (Apple has not added native TK2 table support in 4 years).

**Phase G exit criterion:** the native-cell code path is gone. All tests green. Bug #29 closed by construction. Bug #60 closed by construction.

## Rollback

At any point through Phase F, the flag flips off and we're back to the (buggy but working) native-cell path. After Phase G the rollback is a `git revert` of the deletion commits, which restores the native-cell code intact.

## Risks I'm flagging upfront

1. **First-responder coordination** between the document's NSTextView and the cell NSTextViews is the richest source of TK2 / AppKit gotchas. Tab focus, Cmd+A, Find, Services menu — all need explicit handling. Not architectural risks; just real engineering work.

2. **Print / PDF export**: the document's typeset includes the table attachment. The view provider's view is asked to render itself when the document prints. We need to verify the provider's view renders correctly to a print context. (Existing `ImageAttachmentViewProvider` does this for images; same pattern.)

3. **Performance** for large tables: each cell is a real NSTextView. A 20×20 table = 400 NSTextViews. Probably fine for typical user tables; flag the issue if it shows up on a real document.

4. **Document.cachedFoldState** referencing storage offsets that change shape (since tables now occupy 1 storage character instead of N): need to invalidate fold state on flag flip and on per-document table conversion.

5. **Existing `tableAuthoritativeBlock` attribute** consumed by `GutterController.handleTableCopyTK2` (copy table → TSV/HTML): adapt to read from the attachment instead of from the storage attribute.

## Sequencing

I'll work through phases sequentially. Each phase is a separate commit (or small commit series). Tests stay green throughout. I'll pause after Phase A and Phase D for an explicit checkpoint with you — those are the two phases that lock in architectural choices.

Estimated effort: 2-3 weeks of focused work.

Estimated commits: 30-50.

## Question before starting

One open question I want your direction on: **what should happen to existing notes' on-disk markdown when the flag flips on?**

Tables in markdown are unchanged shape — same `| ... | ... |` syntax. So there's no migration needed. But: any test fixtures or notes that depend on the native-cell encoding (storage with U+001F / U+001E / U+2028) will need to be re-rendered. That happens automatically on the next render pass; no action needed.

I'm ready to start Phase A on your sign-off.
