# Code-Block Edit Toggle Plan

**Status:** design complete 2026-04-23. Not yet started. Implementation gated on user approval.

Obsidian-style UX: hover a code block → semi-transparent `</>` button appears top-right → click to toggle between rendered and editable source form → cursor-leaves re-renders.

---

## Current state snapshot

- **Regular code** (python/swift/etc): `CodeBlockRenderer.render(language:content:codeFont:)` emits content WITHOUT fences. `CodeBlockLayoutFragment` paints background chip + border on top.
- **Mermaid/math/latex**: `CodeBlockRenderer` emits a single `U+FFFC` `BlockSourceTextAttachment`; source on `.renderedBlockSource` attribute; `MermaidLayoutFragment` / `MathLayoutFragment` draw bitmap, skip glyph paint.
- **Today's edit-from-rendered path** (`handleRenderedBlockClick` in `EditTextView+Interaction.swift:449-536`): TK1-only, tied to `renderMode` + `.renderedBlockOriginalMarkdown`. Not available under TK2 for mermaid/math.

## Design

### Toggle button location: top-right overlay of the code block

`NSView` subclass `CodeBlockEditToggleView`, child of `EditTextView`. Positioned by a `CodeBlockEditToggleOverlay` controller that enumerates `CodeBlockLayoutFragment`s and places one button per logical block at the first fragment's top-right. Scrolls naturally with the text view. Pooled instances to avoid per-scroll allocations.

**NOT in the gutter** — gutter sits on the left; user's ask is right-edge. Gutter keeps its copy icon (coexist).

### State: `editingCodeBlocks: Set<BlockRef>`

Per-editor-session, not persisted. Keyed by content-hash (not block index — stable across structural edits that insert blocks above). Empty set = default rendered behaviour for every block; adding an entry flips that block to editing form.

### "Fences visible" mechanism: option (a) — renderer re-emits with fences

`CodeBlockRenderer.render` grows an `editingForm: Bool` parameter. When `true`:
- For every language, emit `"```<lang>\n<content>\n```"` as plain themed code font (no syntax highlighting — raw source).
- For `mermaid`/`math`/`latex`, skip the `BlockSourceTextAttachment` branch entirely. Fall through to the plain-text-with-fences path.
- `DocumentRenderer.blockModelKind(for:)` downgrades `.mermaid`/`.math` → `.codeBlock` so `CodeBlockLayoutFragment` (not the bitmap fragment) handles display.

Rejected alternatives:
- Hidden fences via `foregroundColor = .clear` + negative kern — **banned by CLAUDE.md rule 7**.
- Distinct element kinds (`CodeBlockEditingElement`) — duplicates fragment plumbing.

### Cursor-leaves detection: selection observer

`textViewDidChangeSelection` observer on `EditTextView+BlockModel.swift`. Per iteration: for every block ref in `editingCodeBlocks`, check whether the new selection's char index falls inside that block's storage span (via `DocumentEditApplier`'s block-span map). If not, remove the ref and trigger re-render.

### Re-render trigger: thread flag through `DocumentEditApplier` — approach (R1)

Extend `DocumentRenderer.render(...)` and `DocumentEditApplier.applyDocumentEdit(...)` with an `editingCodeBlocks` parameter. On toggle, call `applyDocumentEdit(priorDoc:newDoc:editingCodeBlocksBefore:editingCodeBlocksAfter:...)`. The applier re-renders both with their respective sets. The toggled block's rendered bytes differ between renders, so the existing LCS diff picks it up as `.modified` and replaces just that block's span. No new splice path.

Rejected: targeted `rerenderBlock(...)` helper — violates "one place" architectural principle (two write paths into storage).

### UX details

- SF Symbol `chevron.left.forwardslash.chevron.right` (built-in).
- Hover: alpha 0 → 0.5. Active edit-mode: alpha 0.9 regardless of hover (so user can click to exit).
- Click toggles + moves cursor inside the block.
- Scroll tracks naturally (text-view subview).
- Track-area per fragment rect; boundsDidChange reposition pass.

## Integration with shipped infrastructure

- **Phase 3 `DocumentEditApplier`**: consumes the new `editingCodeBlocks` param. Initial `fillViaBlockModel` must also accept the set for a consistent starting point.
- **Phase 7 theme**: `Theme.chrome.codeBlockEditToggle = { cornerRadius, horizontalPadding, verticalPadding, foreground, backgroundHover, backgroundActive }`. Defaults match `CodeBlockLayoutFragment.cornerRadius = 5`, `horizontalBleed = 5`.
- **Phase 2f.2 gutter**: unchanged — different edge.
- **Fold state**: overlay controller skips blocks carrying `.foldedContent`. No toggle on folded blocks.

## Proposed slice plan

### Slice 1 — Renderer flag threaded, no UI
- Add `editingCodeBlocks: Set<BlockRef> = []` param through `DocumentRenderer.render(...)`.
- Add `CodeBlockRenderer.render(...editingForm: Bool = false)` overload; `editingForm == true` emits fenced plain source.
- Wire `DocumentEditApplier.applyDocumentEdit(priorEditingBlocks:newEditingBlocks:...)`.
- Tests: set flag directly, assert renderer output contains/lacks fences.
- **Risk L.** Rollback: revert; default path untouched.

### Slice 2 — Mermaid/math editing-form branch
- In `CodeBlockRenderer.render`, the `mermaid/math/latex` switch falls through to the fenced-plain path when `editingForm == true`.
- In `DocumentRenderer.blockModelKind(for:)`, downgrade `.mermaid`/`.math` → `.codeBlock` for blocks in `editingCodeBlocks`.
- Tests: toggle a mermaid block; assert storage contains `"\`\`\`mermaid\ngraph LR\n...\n\`\`\`"` and block kind is `.codeBlock`.
- **Risk L.** Orthogonal to other language paths. Rollback: revert branch.

### Slice 3 — Hover-triggered `</>` button UI
- New `FSNotes/Helpers/CodeBlockEditToggleView.swift` (NSView subclass).
- New `FSNotes/Helpers/CodeBlockEditToggleOverlay.swift` (controller on `EditTextView`).
- Enumerates `CodeBlockLayoutFragment`s, positions pooled buttons.
- Click flips `editingCodeBlocks` + calls `applyDocumentEdit` with current Document.
- Theme hook placeholder: `Theme.chrome.codeBlockEditToggle` (add stub if Phase 7.3 hasn't wired yet).
- **Risk M.** New NSView lifecycle. Rollback: remove overlay; no storage touched.

### Slice 4 — Cursor-leaves trigger
- `textViewDidChangeSelection` observer drops blocks from `editingCodeBlocks` when cursor exits their span.
- Re-apply via `DocumentEditApplier` to re-render.
- **Risk L.** Rollback: remove observer; edit mode becomes sticky-until-click.

### Slice 5 — Dogfood + theme polish
- User feedback pass.
- Theme values tuned.
- Keyboard `Tab`-out / arrow-out verified against slice 4 observer.
- **Risk L.** Rollback: revert cosmetic tweaks.

## Risks + unknowns

- **MermaidLayoutFragment bitmap cache**: `BlockRenderer.render` cache is keyed by `(source, type, maxWidth)`. Changes during edit mode produce a new cache key → fresh render on flip back. No collision risk expected. Verify on dogfood.
- **Block ref stability**: content-hash key beats block-index key across structural edits. Switch hash function if collisions become a problem (unlikely for typical code-block sizes).
- **Undo**: toggling is visual-only (no Document mutation). Edits during edit mode are regular undoable block mutations. Undo past toggle-point doesn't "un-toggle" — selection observer handles collapse on next move.
- **Keyboard nav**: Tab-out + arrow-out both fire `textViewDidChangeSelection` → slice 4 handles.
- **Multi-window**: `editingCodeBlocks` is per-editor. Each window independently edits different blocks. Saves are whole-file; unaffected.
- **Viewport layout timing**: overlay positioning needs TK2's `textViewportLayoutController` to have run. Schedule after `configureRenderingSurfaceFor` or first `enumerateTextLayoutFragments`.

## Out of scope

- Full-note source-mode toggle (existing editor mode).
- Syntax highlighting theming (orthogonal).
- Code-block fold UI (exists).
- Table / PDF / image hover toggles (different architectures).
- CommonMark fence-variant handling (reads `Block.codeBlock(...fence:)` — no new parser).
