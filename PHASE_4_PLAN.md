# Phase 4 Slice Plan

**Status:** proposed 2026-04-23. **Not yet started — requires Phase 3 landing + Phase 2e T2 decision.**

---

## Preconditions

- **Phase 2e T2 (native TK2 table cells)** — NOT shipped. `InlineTableView` is still alive; `BlockRenderer.swift`'s table path is explicitly retained per plan. Either complete 2e T2 first (+15–25d) or accept Phase 4 shipping with tables on attachments (small amount of attachment-specific code survives 4.8's guard sweep).
- **Phase 3 `applyDocumentEdit` primitive** — not yet in tree; subagent in flight 2026-04-23.
- **Phase 2f.1–2f.6** — ✅ all shipped.
- **Corpus round-trip** — green on current build.
- **CommonMark compliance** — 80.7% (baseline met).

## Source-mode pipeline surface inventory

| Target | File / count | Notes |
|---|---|---|
| `NotesTextProcessor.scanBasicSyntax` | 0 in-tree call sites | Exit criterion "zero scanBasicSyntax calls" already met |
| `NotesTextProcessor.highlight*` (markdown path) | 6 production sites | Real Phase 4 scope |
| `NotesTextProcessor.swift` total | 1,618 LoC | Bulk deletion |
| `FSNotes/LayoutManager.swift` | 724 LoC | TK1 layout manager subclass; replaced by BlockModelLayoutManagerDelegate |
| `TextStorageProcessor.blocks` + `syncBlocksFromProjection` | `TextStorageProcessor.swift:113, 200` + 5 production call sites + 9 test sites | Fold/unfold reads `self.blocks` |
| `NoteSerializer.prepareForSave()` + `Note.save(content:)` | 34 LoC + 9 call sites | Single save path via `save(markdown:)` |
| `Block.table.raw` | `Document.swift:232` + readers in `MarkdownSerializer.swift:74`, `EditingOperations.swift`, `Editing/TableEditing.swift`, `InlineTableView.swift` | Canonical rebuild via `EditingOps.rebuildTableRaw` |
| `blockModelActive` guards | 38 hits, 20 files | Phase 2 bridge guards |
| `documentProjection == nil` guards | 26 hits, 16 files | Same |
| `.txt`/`.rtf` path | `Note.swift:746, 1393` | Needs trivial "body-font element" renderer |

**Total estimated surface:** ~30 files touched, ~3,800 LoC deleted or replaced.

## `SourceRenderer` design questions (answer before writing)

1. **Mode semantics** — new `BlockModelKind` variants (`.sourceMarkdown` / `.sourceHeading` etc.) vs. a parallel "syntax-highlight mode" flag on existing kinds? Recommendation: new `.sourceMarkdown` kind + dedicated `SourceLayoutFragment`.
2. **Fragment reuse** — `FoldedLayoutFragment` reused; `CodeBlockLayoutFragment` reused; `HeadingLayoutFragment` / `MermaidLayoutFragment` / `MathLayoutFragment` / `KbdBoxParagraphLayoutFragment` NOT reused (source mode shows markers). Net: ~1 new fragment (`SourceLayoutFragment`).
3. **Marker coloring** — needs `.markerRange` sibling attribute on elements so `SourceLayoutFragment` paints `#` / `**` / ` `` ` / `>` markers in a different foreground color without mutating storage.
4. **Editing parity** — every `EditingOps` primitive must produce identical `Document` output across source vs. WYSIWYG. Any view-mode branch in editing ops is a bug.
5. **Mode-toggle preservation** — `Note.scrollPosition` + `cachedFoldState` already round-trip through mode switches on the current pipeline; confirm no additional plumbing needed post-unification.

## Proposed slices (foundation-first)

### 4.0 — Audit `Block.table.raw` drop (prep, non-shipping)

- Corpus round-trip with `raw` forcibly recomputed; diff.
- User sign-off per plan.
- Risk: L (read-only). Rollback: N/A.

### 4.1 — `SourceRenderer` + `SourceLayoutFragment` (additive, feature-flagged)

- New `FSNotesCore/Rendering/SourceRenderer.swift`, new fragment, new `BlockModelKind` variant + element.
- Gated by `useSourceRendererV2` debug flag; source mode still uses old pipeline by default.
- Grep gate: zero `NotesTextProcessor.highlight` calls in the new path.
- Risk: M. Rollback: flip flag off; files remain unused.

### 4.2 — Delete `Block.table.raw`

- Remove field from `Document.swift:232`.
- `MarkdownSerializer.swift:74` always emits canonical.
- Drop readers in `EditingOperations.swift`, `Editing/TableEditing.swift`, `InlineTableView.swift`.
- Grep gate: zero `table.raw` matches outside docs.
- Accepted trade: first save of legacy notes with non-canonical tables produces a diff.
- Risk: M. Rollback: single revert.

### 4.3 — Non-markdown (`.txt`, `.rtf`) TK2 path

- Trivial "body-font element" renderer for non-markdown notes.
- Remove non-markdown dependency on `NotesTextProcessor`.
- Grep gate: non-markdown notes render without any `highlight*` call.
- Risk: L. Rollback: revert one commit.

### 4.4 — Flip source mode to `SourceRenderer`; delete markdown highlight path **[HIGH RISK]**

- Default-on `SourceRenderer`; remove debug flag.
- Delete all 6 `NotesTextProcessor.highlight*` markdown call sites.
- Grep gate: `grep NotesTextProcessor.highlight` == 0 outside fenced code-block highlighter.
- Risk: H — user-visible source-mode behavior change; regression potential across dark mode + preferences.
- Rollback: revert 4.4 only; 4.1's SourceRenderer stays.

### 4.5 — Delete `FSNotes/LayoutManager.swift`

- File delete (724 LoC).
- Wire-up cleanup in views that instantiated it.
- Grep gate: zero `NSLayoutManager` subclasses in `FSNotes/`.
- Already gated by `blockModelActive` since 2a — any latent TK1 fallback crashes.
- Risk: M. Rollback: revert one commit.

### 4.6 — Delete `Note.blocks` peer + `syncBlocksFromProjection`

- Retire `blocks: [MarkdownBlock]` on `TextStorageProcessor`.
- Fold/unfold consumes `Document.blocks` directly (`cachedFoldState: Set<Int>` already indexes block indices).
- 5 production call-site removals in `EditTextView+BlockModel.swift` + `EditTextView+Todo.swift`.
- 9 test sites to rewrite (tests exercising `syncBlocksFromProjection` directly — rewrite against `Document.blocks`, adds ~1 day).
- Grep gate: zero `syncBlocksFromProjection` matches.
- Risk: M — fold/unfold is load-bearing; covered by `GutterOverlayTests`.

### 4.7 — Delete `NoteSerializer.prepareForSave()` + `Note.save(content:)` **[HIGH RISK]**

- Delete `NoteSerializer.swift`.
- Route all 9 call sites through `save(markdown: MarkdownSerializer.serialize(doc))`.
- Grep gate: zero `prepareForSave` / `save(content:` matches.
- Risk: H — save path is load-bearing; regression corrupts user data. Mandatory dogfood on real notes.
- Rollback: revert one commit.

### 4.8 — Delete all `blockModelActive` / `documentProjection == nil` guards

- Sweep 64 conditionals across 20 files.
- After 4.4–4.7 every guarded branch is dead.
- Grep gate: `grep blockModelActive` == 0 and `documentProjection == nil` == 0 in non-test code.
- Risk: L-M. Each file change independent; revert per-file possible.

## Side notes

- `scanBasicSyntax`: zero in-tree call sites; plan's exit criterion already met. Drop from Phase 4 scope.
- `MarkdownBlockParser.swift`: dead code once `SourceRenderer` is live. Add to 4.4 or 4.8 deletion scope.
- iOS `EditorViewController.swift:653` calls `note.save(content:)` — confirm in/out of macOS-only Phase 4 scope.
- `hermes_conversation_20260417_154911.json` at repo root is a large conversation dump — candidate for `.gitignore`.
- `Tests/BlockModelFormattingTests.swift` has 7 tests directly calling `syncBlocksFromProjection` (lines 794–872) — Slice 4.6 requires rewriting these against `Document.blocks`.
- 4.4's deletion of `NotesTextProcessor.highlight*` does NOT affect `CodeBlockRenderer.swift`'s fenced-code highlighting (uses `highlightr` via `SwiftHighlighter`, separate library).

---

## Ship order decision log

- Plan's natural order (SourceRenderer first → deletions → guard removal) confirmed correct.
- Added 4.0 (audit) and 4.3 (non-markdown) as low-risk preparatory slices to de-risk 4.4.
- 4.4 is "the flip the switch moment" — highest live risk. Stabilize 4.1/4.2/4.3 before.
- 4.5–4.7 are deletion-only after 4.4 is stable.
- 4.8 is final cleanup.
