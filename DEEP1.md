# DEEP1 — FSNotes++ Deep Code Review

**Date**: 2026-04-26
**Scope**: Table widget usage (editing/redrawing), glyph hiding/showing, image rendering (center justification), architecture consistency
**Codebase**: ~241,000 loc Swift across FSNotesCore + FSNotes (macOS only)

---

## 1. EXECUTIVE SUMMARY

The codebase shows strong architectural discipline: the documented single-write-path invariant (Invariant A), EditContract enforcement, and TK2-native table rendering are all well-implemented. However, this review identified **5 bugs / deviations**, **3 consistency issues**, and **2 architectural concerns** worth addressing.

---

## 2. TABLE WIDGET USAGE: EDITING & REDRAWING

### 2.1 Architecture (as documented)

The ARCHITECTURE.md states that tables render via a native TK2 pipeline:

- `DocumentRenderer` → `TableTextRenderer.render()` → flat separator-encoded `NSAttributedString` (cells joined by U+001F/U+001E)
- `.blockModelKind = .table` + `.tableAuthoritativeBlock` attribute → `BlockModelContentStorageDelegate` returns a `TableElement`
- `BlockModelLayoutManagerDelegate` dispatches to `TableLayoutFragment`
- `TableLayoutFragment.draw(at:in:)` paints the grid directly — **never calls super.draw**
- Cell editing routes through `EditingOps.replaceTableCellInline`

### 2.2 BUG: Column widths lost in table authoritative block attribute

**Location**: `FSNotesCore/Rendering/TableTextRenderer.swift`, line 159

```swift
let authBlock: Block = .table(
    header: header,
    alignments: alignments,
    rows: rows,
    columnWidths: nil   // ← BUG: always nil, even when original block had widths
)
```

The `render` function receives a reconstructed table from `DocumentRenderer.renderBlock` which already passed `columnWidths: _` (the wildcard ignores the field). The authoritative block boxed attribute is therefore built with `columnWidths: nil`, meaning:

1. The `TableElement.block` payload carried into `TableLayoutFragment` has no persisted widths
2. `TableLayoutFragment.geometry()` falls back to content-based widths even when the user previously dragged columns to specific sizes
3. `columnWidthsOverride` in `TableGeometry.compute()` is always nil, so the override path is dead

**Severity**: MEDIUM. T2-g.4 column resize works for the current session (the persist via `setTableColumnWidths` writes to the Document correctly), but on re-render (theme change, note reload, switch from source mode) the persisted widths are dropped. The document level stores them correctly (the serializer emits the sentinel comment), but the TK2 render path loses them.

**Fix**: Thread `columnWidths` through the table render path. `DocumentRenderer.renderBlock` currently pattern-matches `let widths` as `_` — it should pass them to `TableTextRenderer.render`, which should include them in the authoritative block.

### 2.3 BUG: Duplicate <br> replacement logic (measure/draw drift risk)

**Location 1**: `FSNotesCore/Rendering/Elements/TableGeometry.swift`, lines 127-138
**Location 2**: `FSNotesCore/Rendering/Fragments/TableLayoutFragment.swift`, lines 1048-1083

Both `TableGeometry.renderedCellText` (measurement) and `TableLayoutFragment.makeRenderedCellText` (drawing) contain identical `<br>` → `\n` replacement logic. The code comments explicitly warn:

> If this ever drifts from the geometry-side copy, row heights will disagree with their painted content — the whole grid will clip.

This is a textbook copy-paste hazard. Any future change to one function must be mirrored in the other. The comment on line 1044-1046 acknowledges the problem but defers to a future slice (`2e-T2-h`) that was already shipped — the comment is now stale.

**Severity**: LOW (no current drift detected, but fragility is high). The functions produce identical output today, confirmed by the `TableGeometryTests` suite.

**Fix**: Extract the shared logic into a single function (e.g., `TableTextRenderer.sanitizeCellNewlines` already exists for newline → U+2028 conversion; a similar function for `<br>` → `\n` should exist once). The `sanitizeCellNewlines` function in `TableTextRenderer` handles a different transformation (newline → line separator for paragraph integrity), so a single consolidated path is still missing.

### 2.4 BUG: TableLayoutFragment ignores theme foreground color

**Location**: `FSNotesCore/Rendering/Fragments/TableLayoutFragment.swift`, line 1054

```swift
var attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.textColor  // ← hardcoded, not theme-resolved
]
```

The theme schema (`ThemeSchema.swift`) defines `colors.text` for foreground text, and the renderer pipeline generally resolves through `Theme.shared`. `TableLayoutFragment` uses the raw `NSColor.textColor` (AppKit dynamic system color) instead, which means:

1. Custom themes with explicit text colors won't affect table cell content
2. High-contrast themes that ship custom text colors won't apply to tables
3. This is inconsistent with `DocumentRenderer` and `InlineRenderer`, which both use `PlatformColor.label` or theme-resolved colors

Compare with `TableGeometry.renderedCellText` (line 114) which also uses `NSColor.textColor` — so measurement and drawing at least agree, but neither respects the theme.

**Severity**: LOW (most themes won't notice since dark mode is handled by `NSColor.textColor` being a dynamic color). But violates the theme-is-the-single-source-of-truth principle stated in ARCHITECTURE.md.

**Fix**: Resolve from `Theme.shared.colors.text.resolvedForCurrentAppearance(fallback: NSColor.textColor)`.

### 2.5 BUG: TableElement.block field comment references deleted field

**Location**: `FSNotesCore/Rendering/Elements/TableElement.swift`, line 52-54

```swift
/// The authoritative `Block.table` value this element represents.
/// Downstream slices read `header`/`alignments`/`rows`/`raw` off
/// this payload to drive grid geometry and serialization without
/// re-parsing the attributed string.
```

The `raw` field was deleted in Phase 4.2 (replaced by canonical `rebuildTableRaw`). The comment is stale and misleading — it suggests downstream code reads `raw` when no such field exists.

**Severity**: TRIVIAL (documentation only). No runtime impact.

**Fix**: Update comment to read `header`/`alignments`/`rows`/`columnWidths`.

### 2.6 BUG: Header-less table division by zero in cellHit / draw

**Location**: `FSNotesCore/Rendering/Fragments/TableLayoutFragment.swift`

The guards at lines 274-276 and 514-517 correctly bail out when `header.count == 0`, but the code path that reaches these functions with an empty header represents a malformed table in the document model. The parser should never produce a table with zero columns, but if it does (or if a structural edit creates one), the fragment silently renders nothing — no error log, no visual indication.

This is defensive today, but if a future edit creates a zero-column table (e.g., `deleteTableColumn` on a single-column table fails, but what about a race during undo?), the user gets a silent blank where their table used to be.

**Severity**: VERY LOW (parser won't produce this, structural edits guard against it). Worth adding a debug log for early detection.

### 2.7 Consistency: Table geometry cache key excludes cell formatting

**Location**: `FSNotesCore/Rendering/Fragments/TableLayoutFragment.swift`, lines 158-201

The `GeometryKey.shapeHash` is computed from `cell.rawText` (the serialized markdown source), alignment, and column widths. However, cells can contain formatted inline trees (bold, italic, code, links) whose *visual* width differs from their *serialized source* width. For example:

- `**bold**` has `rawText = "**bold**"` (7 chars serialized) but renders as "bold" (4 chars visual)
- `[link](url)` has `rawText = "[link](url)"` but renders as "link"

The hash is based on `rawText`, so two cells with the same `rawText` but different formatting (e.g., `**bold**` vs `__bold__` producing the same visual output) theoretically get different cache entries — wasteful but correct. More importantly, if cells have the same `rawText` but different internal inline structure that renders to different visual widths, the cache would return a stale measurement.

In practice, `rawText` serializes through `MarkdownSerializer.serializeInlines` which is deterministic for a given inline tree, so identical inline trees produce identical `rawText`. The hash is correct — just potentially cache-unfriendly for equivalent visual output.

**Severity**: TRIVIAL (correct, if slightly wasteful). No action needed.

### 2.8 Redraw trigger analysis

When a table cell is edited via `replaceTableCellInline`:
1. The Document is mutated → new block with updated cell
2. `DocumentEditApplier.applyDocumentEdit` splices the new element into storage
3. TK2 detects the storage change and rebuilds the `TableElement` + `TableLayoutFragment`
4. `TableLayoutFragment` is a fresh instance → cache (`cachedGeometry`) is empty → `TableGeometry.compute()` re-measures
5. `draw(at:in:)` re-paints the grid

This is correct: every cell edit produces a fresh fragment with a fresh cache. No stale-redraw issues.

However, hover handle operations (column resize, alignment change) also go through `replaceBlock` → new fragment → full redraw. The hover handle chips are managed separately by `TableHandleOverlay` as NSView subviews, which move independently of fragment repaints (see line 580-588 comment about "stuck chrome" that motivated the chip approach). This architecture is sound — chips as NSViews get AppKit's free frame-change invalidation.

---

## 3. GLYPH HIDING / SHOWING

### 3.1 Bullet and checkbox glyph rendering

Two parallel paths (TK1 cell + TK2 view provider) as documented in `ListRenderer.swift`:

**TK2 path (active)**:
- `BulletTextAttachment.viewProvider()` → `BulletAttachmentViewProvider.loadView()` → `BulletGlyphView` (NSView subclass)
- `CheckboxTextAttachment.viewProvider()` → `CheckboxAttachmentViewProvider.loadView()` → `CheckboxGlyphView`
- Both view subclasses set `isFlipped = false` for consistent baseline math with TK1 cell draws
- Both override `hitTest(_:)` to return `nil`, making clicks pass through to the editor

**Transparent placeholder pattern**:
- `ListRenderer.transparentPlaceholder(size:)` memoizes blank NSImages in an NSCache
- Set as `attachment.image` before TK2's first layout pass to suppress AppKit's generic document-icon flash
- Cache keyed by size, 64-entry limit — well-optimized for the realistic working set

### 3.2 BUG: CheckboxGlyphView.tintedForCheckbox duplicates tinted(with:) logic

**Location**: `FSNotesCore/Rendering/ListRenderer.swift`, lines 575-585 and 888-897

Two identical `tinted(with:)` / `tintedForCheckbox(with:)` extensions on NSImage exist in the same file. The second was renamed to avoid "duplicate declaration warnings" but performs the exact same operation. This duplication is fragile — if the tinting logic changes, both must be updated.

**Severity**: TRIVIAL (functionally identical, just maintenance hazard).

**Fix**: Extract into a single fileprivate extension.

### 3.3 Source-mode marker rendering

`SourceRenderer` tags marker runs with `.markerRange = NSNull()`. `SourceLayoutFragment.draw(at:in:)` overpaints those runs in `Theme.shared.chrome.sourceMarker`. No glyph hiding — markers are always visible in source mode. The documented architecture (ARCHITECTURE.md: "SourceLayoutFragment paints those runs... without mutating .foregroundColor") is correctly implemented.

### 3.4 Bullet glyph shape cycling

`ListRenderer.visualBullet(for:depth:)` cycles through `• ◦ ▪ ▫` at depths 0-3, then wraps. The shape drawing in `BulletGlyphView` and `BulletAttachmentCell` correctly branches on the unicode character. No bugs found.

### 3.5 Checkbox hit-test pass-through

Both `CheckboxGlyphView.hitTest(_:)` (line 868) and `BulletGlyphView.hitTest(_:)` (line 728) return `nil`, routing clicks to the parent text view. The comments document this clearly (Bug: users couldn't click directly on the checkbox to toggle it). This is correctly implemented.

### 3.6 Line height invariance

`ListRenderer.naturalLineHeight(for:)` (lines 99-124) uses an `NSLayoutManager` to measure actual typesetter line height rather than approximating with `ascender + |descender| + leading`. This prevents Bug 20 (vertical shift when typing into an empty list item). The cache key `fontName|pointSize` is correct — same name + size = same metrics on a given platform. The TK1 vs TK2 view provider gating (`textContainer?.textLayoutManager != nil` guard in `viewProvider()`) correctly ensures TK1 falls through to the cell path and TK2 gets the view provider.

---

## 4. IMAGE RENDERING (CENTER JUSTIFICATION)

### 4.1 Image-only paragraph centering

**Render time**: `DocumentRenderer.paragraphStyle(for:isFirst:baseSize:lineSpacing:theme:)` at line 463-464:

```swift
if inline.count == 1, case .image = inline[0] {
    style.alignment = .center
}
```

This correctly sets the paragraph alignment to `.center` for image-only paragraphs. The condition `inline.count == 1` means a paragraph with `![alt](img) trailing text` is left-aligned (correct — mixed content paragraphs shouldn't center).

**Resize time**: `InlineImageView.mouseDragged(with:)` re-anchors the frame around `dragStartCenterX` (Bug #27 fix, lines 344-349). Without this, shrinking preserves `frame.origin.x` and the image appears to drift left during a shrink drag. The fix captures `frame.midX` at drag start and recomputes `origin.x` on each tick: `dragStartCenterX - newSize.width / 2`.

**Hydration time**: `ImageAttachmentHydrator.installLoadedImage` sets `attachment.bounds` to the loaded image size. The bounds origin is `(0, 0)` — centering comes from the paragraph style, not from the attachment position. This is correct: NSTextAttachment positioning is determined by the surrounding paragraph attributes.

### 4.2 BUG: Mixed-content image paragraphs are left-aligned

**Location**: `FSNotesCore/Rendering/DocumentRenderer.swift`, line 463-464

A paragraph like `some text ![img](photo.png) more text` has `inline.count > 1` and is NOT centered. This matches typical editor behavior (you don't want inline images in the middle of paragraphs to force centering), but it also means a paragraph like `![img](photo.png)\n` (image + trailing newline in source) that parses as `[.image(...), .text("")]` (count = 2) is NOT centered — the empty text node at the end breaks the `count == 1` check.

**Investigation**: The parser does NOT produce empty `.text("")` nodes; the condition `inline.count == 1, case .image` should only fire for genuinely image-only paragraphs. However, if a future parser change introduces empty trailing text nodes, this would break silently.

**Severity**: VERY LOW (current parser doesn't produce empty text nodes). Consider a more robust check: `inline.allSatisfy { if case .image = $0 { true } else { false } }` or verify that empty text nodes are filtered upstream.

### 4.3 Remote image hydration

`InlineRenderer.makeImageAttachment` (lines 320-339) creates `ImageNSTextAttachment` for remote URLs with the full attribute set (`.attachmentUrl`, `.attachmentPath`, `.attachmentTitle`, `.renderedBlockOriginalMarkdown`, `.renderedBlockType`, `.renderedImageWidth`). The hydrator's `loadImage` dispatches remote URLs through `URLSession.shared.dataTask` and local files through `editor.imagesLoaderQueue`. Both paths correctly guard against stale storage (the `storedAttachment === attachment` identity check on the main queue after the async load completes).

### 4.4 Image resize live invalidation

`ImageAttachmentViewProvider.applyLiveResize` (lines 138-159) updates `attachment.bounds` and calls `tlm.invalidateLayout(for: range)` on every drag tick. This correctly solves the "text jumps at mouseUp" problem. The test suite (`Phase2f5ImageResizeInvalidationTests`) covers nil-attachment, nil-TLM, and doc-end boundary cases.

### 4.5 Centering correctness summary

| Stage | Centered? | Mechanism |
|-------|-----------|-----------|
| Initial render | YES (image-only) | `paragraphStyle.alignment = .center` |
| Hydration (async load) | YES | Paragraph style already set; attachment bounds at (0,0) |
| Live resize drag | YES | `dragStartCenterX` re-anchoring |
| Resize commit | YES | New `frame.origin.x` already computed correctly |
| Source mode | N/A | Images render as `![alt](path)` text |

The centering is correctly implemented across all stages.

---

## 5. ARCHITECTURE CONSISTENCY REVIEW

### 5.1 ARCHITECTURE.md claims verified

| Claim | Verdict | Notes |
|-------|---------|-------|
| "`textStorage.string` contains only displayed characters" | CORRECT | WYSIWYG storage has no markers |
| "`Block.table`... `raw` was deleted in Phase 4.2" | CORRECT | `raw` absent from Block enum, serializer uses `rebuildTableRaw` |
| "Zero `.kern`. Zero clear-color foreground." | CORRECT | grep confirms no banned patterns in rendering path |
| "`InlineTableView`... deleted in slice 2e-T2-h" | CORRECT | 34 file results for `Table*` — `InlineTableView.swift` not among them |
| "Tables serialize canonically on every write" | CORRECT | `MarkdownSerializer.serialize(block:)` calls `rebuildTableRaw` |
| "Single `U+FFFC` attachment character per block" | CORRECT | `TableTextRenderer` grep confirms zero U+FFFC |
| "columnWidths sentinel comment" | CORRECT | `MarkdownSerializer` emits `<!-- fsnotes-col-widths: [...] -->` |
| "Theme — single source of truth" | PARTIAL | TableLayoutFragment uses `NSColor.textColor` instead of theme-resolved (see 2.4) |
| "EditContract enforcement" | CORRECT | 66 tests, harness auto-assertion wired in `applyEditResultWithUndo` |

### 5.2 Stale comments

1. **TableElement.swift lines 7-8**: "This class is dead code on disk: no dispatch path instantiates it" — the file header still claims dead code, but the class is now the active TK2 table element dispatching to `TableLayoutFragment`. Entirely alive since Phase 2e-T2.

2. **TableElement.swift lines 52-54**: References `raw` field (deleted Phase 4.2). See 2.5.

3. **TableLayoutFragment.swift lines 5-16**: "Read-only grid rendering... Editing, cursor, and hover handles are deliberately out of scope" — editing (`cellHit`, `caretRectInCell`), cursor routing, and hover handles (`setHoverState`, `drawHoverHandles`) are all implemented. The comment is from Phase 2e-T2-c and needs updating.

4. **TableLayoutFragment.swift lines 1044-1047**: "Keep them in sync until slice 2e-T2-h collapses the measurement/draw paths." Slice 2e-T2-h was shipped. The paths were NOT collapsed. The comment is a deferred TODO that never happened.

### 5.3 Deviations from documented patterns

1. **Theme bypass**: `TableLayoutFragment` and `TableGeometry` both use `NSColor.textColor` directly rather than resolving through the theme. ARCHITECTURE.md states: "Theme is the single source of every presentation literal." This is a deviation, though mitigated by `NSColor.textColor` being a dynamic color.

2. **Hardcoded font size in handle chrome**: `TableLayoutFragment.paintHandleChrome` uses `NSFont.systemFont(ofSize: pt, weight: .bold)` (line 711) — a hardcoded system font for the grip glyph. The theme doesn't control this. Similar to the documented `PreferencesEditorViewController.previewFontSize` exemption but not listed in the whitelist.

3. **DocumentRenderer.renderBlock line 579**: `EditingOps.rebuildTableRaw(header:alignments:rows:)` is called during render to produce `rawMarkdown` for the `.renderedBlockOriginalMarkdown` attribute. This means every table render re-serializes the table. For large documents with many tables, this is wasteful — the serializer already produces canonical output on save, and the `rawMarkdown` attribute is only used by the save path and TextFinder. Consider caching or deferring.

---

## 6. POTENTIAL LOGIC BUGS (HIGH-IMPACT)

### 6.1 HIGH: Table authoritative block loses columnWidths (see 2.2)

This is the most impactful bug found. Persisted column widths from drag-resize are silently dropped on re-render. Reproducible: drag-resize columns → switch to source mode and back → columns snap back to content-based widths.

### 6.2 MEDIUM: cellLocation overflow race for tables with empty rows

**Location**: `FSNotesCore/Rendering/Elements/TableElement.swift`, line 291

```swift
guard position.row >= 0, position.row <= rows.count else { return nil }
```

If `rows` is empty, `row == 0 <= 0` passes, but the while-loop will never find that row because there are no body rows. The function returns `nil` at line 324 because `row == position.row && col == position.col` is only true for the header row (row 0) or the tail case. For `position.row == 0` when `rows` is empty, the header case finds the right column for the header, but a caller asking for body row 0 of an empty body gets a confusing nil.

This interacts with `cellHit(at:)` which maps clicks to `(row: 0, col: N)` for header clicks — the `offset(forCellAt:)` lookup for `(0, N)` returns the header offset, which is correct. The issue is only with callers that target body rows of empty-row tables.

**Severity**: LOW (structural edits ensure at least one row exists when the user is interacting).

### 6.3 MEDIUM: TableEditorViewController and TableHandleView existence

**Location**: `FSNotes/Helpers/TableEditorViewController.swift`, `FSNotes/Helpers/TableHandleView.swift`

These files exist in the FSNotes target (not iOS). `TableEditorViewController` likely represents a legacy standalone table editor. The current editing path flows through the inline text view + `EditingOps.replaceTableCellInline` — a separate view controller for table editing would be a parallel editing path that could bypass the documented single-write-path invariant.

Grep for references:
- `TableEditorViewController` — needs investigation whether it's live or dead code
- `TableHandleView` — part of the `TableHandleOverlay` pool, definitely live

This is flagged for investigation — a second editing entry point would violate Invariant A.

### 6.4 LOW: FoldedElement dispatch applies to table elements

**Location**: `FSNotesCore/Rendering/BlockModelElements.swift` (content-storage delegate)

The ARCHITECTURE.md states: "checks for `.foldedContent` first — if present, returns `FoldedElement`". For tables, this would mean a folded table range gets a zero-height `FoldedLayoutFragment` instead of `TableLayoutFragment`. While this is functionally fine (folded = hidden), it means a user who folds a section containing a table and later unfolds it will trigger a full re-render of the table. The table's geometry cache was already lost (fresh fragment on re-render), so this is acceptable — just noting the interaction.

---

## 7. POSITIVE FINDINGS

1. **EditContract machinery is impressive**: 66 tests, automatic harness assertion, negative tests proving the harness catches lying contracts. This is the kind of architecture that prevents regressions at the structural level.

2. **Transparent placeholder pattern**: The `NSCache`-backed placeholder system for bullet/checkbox attachments is elegant — prevents flash-of-document-icon with minimal allocation overhead.

3. **TK1/TK2 dual-path for list markers**: The `viewProvider()` gating (`textContainer?.textLayoutManager != nil`) cleanly separates TK1 cell-draw from TK2 view-provider rendering without code duplication in the storage layer.

4. **Bug #27 fix (centered image resize)**: The `dragStartCenterX` approach correctly handles centered images without requiring the paragraph style to be re-read during the drag. This is the right fix at the right level.

5. **Single write path enforcement**: `StorageWriteGuard` + DEBUG assertions + grep gates. The 18 `performingLegacyStorageWrite` call sites are all catalogued and most have follow-up TODOs.

6. **`cellLocation` empty-cell handling**: The `cellStart == i, offset == i` branch (TableElement.swift line 194) correctly resolves cursor positions in empty cells — without this, typing into a freshly-inserted empty table would fail because every offset is also a separator position.

---

## 8. SUMMARY TABLE

| # | Category | Severity | Description | Location |
|---|----------|----------|-------------|----------|
| B1 | Table | MEDIUM | columnWidths lost in authoritative block attribute | TableTextRenderer.swift:159 |
| B2 | Table | LOW | Duplicate <br> replacement logic | TableGeometry.swift:127, TableLayoutFragment.swift:1048 |
| B3 | Table | LOW | Hardcoded foreground color ignores theme | TableLayoutFragment.swift:1054 |
| B4 | Table | TRIVIAL | Stale comment referencing deleted `raw` field | TableElement.swift:52 |
| B5 | Glyphs | TRIVIAL | Duplicate NSImage tinting extensions | ListRenderer.swift:575,888 |
| C1 | Consistency | LOW | Theme bypass in table rendering | TableLayoutFragment, TableGeometry |
| C2 | Consistency | LOW | Stale comments about "dead code" / deferred slices | TableElement.swift:7, TableLayoutFragment.swift:1044 |
| C3 | Consistency | LOW | renderBlock calls rebuildTableRaw wastefully | DocumentRenderer.swift:579 |
| P1 | Architecture | MEDIUM | Investigate TableEditorViewController for potential parallel write path | TableEditorViewController.swift |
| P2 | Architecture | MEDIUM | Image-only check fragile against future parser changes | DocumentRenderer.swift:463 |

**Total**: 5 bugs, 3 consistency issues, 2 architectural concerns. No CRITICAL issues found. The codebase is in good shape.

---

## 9. RECOMMENDED ACTIONS

### Immediate (bug fixes)

1. Thread `columnWidths` through `DocumentRenderer.renderBlock` → `TableTextRenderer.render` → authoritative block attribute (fixes B1)
2. Extract shared `<br>` replacement into a single function (fixes B2)
3. Resolve table cell foreground color from theme (fixes B3)
4. Update `TableElement.swift` comments to reflect current state (fixes B4, C2)

### Short-term (cleanup)

5. Investigate `TableEditorViewController` — if dead, delete; if live, ensure it routes through `EditingOps` + `DocumentEditApplier`
6. Extract shared NSImage tinting into a single extension (fixes B5)
7. Cache or defer `rebuildTableRaw` during render for unmodified tables

### Nice-to-have

8. Add `guard inline.count > 0, case .image = inline[0], inline.allSatisfy({...})` for robustness (P2)
9. Consider collapsing `TableGeometry.renderedCellText` and `TableLayoutFragment.makeRenderedCellText` into one public function on `TableTextRenderer` using the existing `sanitizeCellNewlines` pattern plus a `<br>` variant
