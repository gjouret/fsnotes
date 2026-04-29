# Fourth Architecture Revamp — Status & Remaining Work

This file is the **changelog and roadmap** for the multi-phase refactor: what shipped, what is open, and the convergence criteria that tell us when the plan is closed.

**Companion documents** (deliberately scoped):

- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — the canonical description of how the editor works *today* (the destination). Includes the recurring **Operational Patterns** worth knowing when working on the codebase. This is largely invariant; updates to it only land when the refactor uncovers a real architectural change.
- **[`CLAUDE.md`](CLAUDE.md)** — discipline rules for human and AI authors, build / runtime environment, per-codebase conventions.

This file does NOT carry process rules, build environment notes, or bug-class lessons; those live in the two companions above.

## Why this refactor existed

Three earlier refactors of FSNotes++ each reduced some bug classes and left others. Stubborn residual bugs (Find across tables, attribute-diff seam bugs, widget/data desyncs) all traced to two root causes:

1. **`Document` and `NSTextStorage` were peer sources of truth** for the same content, kept in sync via translation code. Every "seam bug" was a symptom of the split.
2. **The wrong layout primitive.** TextKit 1's `NSLayoutManager` + `NSTextAttachment` + `U+FFFC` placeholder required widget-internal text (e.g. table cells) that `NSTextFinder` couldn't see, selection couldn't cross, and accessibility couldn't reach. The placeholder was the seam.

The fix was to collapse the dual-source-of-truth into **`Document` as the sole source of truth**, backed by **TextKit 2** (`NSTextLayoutManager` + `NSTextContentStorage` + per-block `NSTextElement` + `NSTextLayoutFragment`) so each block type declares its own layout natively.

## Convergence criteria — when this plan is closed

The refactor is **architecturally complete**: every invariant in [`ARCHITECTURE.md` § Architecture Invariants](ARCHITECTURE.md#architecture-invariants) (A–G) holds and is mechanically enforced where possible (DEBUG assertions + `scripts/rule7-gate.sh`). All structural phases shipped: **0, 1, 2, 3, 4, 5a–f, 7, 10, 12.A, 12.B, 12.C** (single source of truth, TK2 migration, single write path, undo journal, parser decomposition, theme, **CommonMark 100% — 652/652 as of `489b983`**).

**The remaining tail is non-architectural and bounded to two items**:

| Item | Class | Why it is not blocking |
|---|---|---|
| **Phase 6 Sub-slice 7.B.2** — `processor.blocks` array retirement | Cleanup (Tier C) | Source-mode pipeline lift; the architectural invariants don't require it. |
| **Phase 9 Pod warnings** — silence at Pod target level | Cosmetic | ~100 warnings from third-party Pods. No correctness impact. |

Phase 11 Slice F is now ✅ closed: F.1–F.4 + F.6 + F.7 shipped (six factory consolidations + the `UIBugRegressionTests` rewrite). F.5 stays deferred as a known-different-code-path (source-mode renderer fixture). See the per-slice status further down for commit hashes.

Once those three land, the plan is closed. Bugs are tracked in `BugInventoryRegressionTests.swift` and the per-bug entries below; they are normal product engineering against a stable architecture, not refactor work.

**No new phases without an invariant violation.** If a future task seems to require a new phase, that is a signal to either (a) demonstrate which invariant in `ARCHITECTURE.md` is being broken, in which case the work belongs here, or (b) recognise it as feature work or cleanup, which lives elsewhere (a feature plan, a cleanup ticket, or this file's existing Sub-slice 7.B.2 / Pod / Slice F slots if it fits one of those buckets).

## Phase status

| Phase | Status | What it delivered |
|---|---|---|
| 0 — Harness + invariants + HTML proxy | ✅ shipped | `EditorHarness` DSL, invariant library, HTML-rendition diff, round-trip corpus |
| 1 — FSM contracts | ✅ shipped | `EditContract` declares each primitive's structural changes; `Invariants.assertContract` enforces in pure tests AND live harness |
| 2 — TextKit 2 migration | ✅ shipped | TK2 baseline + per-block elements/fragments; native table cells (Bug #60 fixed by construction); fold display; gutter; link hover; scroll position; image drag-resize |
| 3 — Element-level edit application | ✅ shipped | `DocumentEditApplier` with LCS block-diff + post-LCS coalescence pass; stale-projection guard via `priorRenderedOverride` |
| 4 — Source-mode pipeline retirement | ✅ shipped | `SourceRenderer` + `SourceLayoutFragment`; legacy `NotesTextProcessor.highlightMarkdown` and save-path widget walker deleted; canonical save through `Note.save(markdown:)` |
| 5a — Single write path | ✅ shipped + bypass retirement complete | `StorageWriteGuard` + DEBUG assertion in `TextStorageProcessor.didProcessEditing`. Zero `performingLegacyStorageWrite` call sites; the only non-canonical writes happen under sanctioned-exemption scopes (`attachmentHydrationInFlight`, IME composition predicate) |
| 5b — Cursor canonicalization | ✅ shipped | `DocumentCursor` ↔ `NSTextLocation` translation; selection round-trips through `DocumentRange` |
| 5c — Find | ⛔ skipped | Unnecessary — all text-bearing block types already live in storage; `NSTextFinder` walks natively |
| 5d — Copy / paste | ✅ shipped | `Document.slice(in:)`, `EditingOps.replaceFragment` (fused delete+insert, one undo step); `documentFromAttributedString` for cross-app paste |
| 5e — IME composition | ✅ shipped | `CompositionSession` value type; sanctioned exemption to Invariant A inside marked range while session active |
| 5f — Undo journal | ✅ shipped | `UndoJournal` per-editor with 5-class coalesce FSM; one `registerUndo` site survives in the editor path |
| 6 — Cleanup | ✅ partial | Tier C delete legacy `NotesTextProcessor.highlightMarkdown` + dead `processInlineTags` / `applySyntaxHiding`. Tier B′ Sub-slices 1–7.B.1 shipped — both legacy `MarkdownBlock.collapsed` and `MarkdownBlock.renderMode` per-block fields retired in favour of offset-keyed side-tables on `TextStorageProcessor`. **Sub-slice 7.B.2 deferred** — full `processor.blocks` array retirement requires lifting the source-mode pipeline off the per-block array (Tier C scope; see Remaining Work) |
| 7 — Theme system | ✅ shipped | `BlockStyleTheme` schema + bundled Default/Dark/HighContrast + user overrides; preferences write-through; UD subsumption; rule-7 gate |
| 8 — Code-block edit toggle | ✅ shipped (slices 1-5) | `</>` hover button, cursor-leaves auto-collapse. Slice 5 broadened the overlay + gutter copy-icon filters to also accept `MermaidLayoutFragment` / `MathLayoutFragment` / `DisplayMathLayoutFragment` (the dedicated fragment classes for fenced ```mermaid``` / ```math``` / ```latex``` blocks) so the user can open them for editing. Display math via `$$…$$` is a paragraph-with-displayMath-inline, not a code block — correctly rejected by the per-block filter |
| 9 — Compiler-warning cleanup | ✅ partial | Tier 1 mechanical sweep, Tier 2 UTType migration, Tier 3 AppKit modernization (partial). Pod warnings deferred |
| 10 — CommonMark Slice A | ✅ shipped | 92.2% → 95.1% via small grammar edits across 11 commits |
| 11 — Composable user-flow harness | ✅ partial | Slices A (Given/When builder + 8 readbacks), A.5 (FSM transition table, ~95 rows in `Tests/Fixtures/FSMTransitions.swift`), B (38-bug inventory migration), C (bitmap-based Then readbacks), D (async-hydration Then readbacks), E (combinatorial coverage generator + sequence widening) all shipped. Slice F (factory consolidation) outstanding |
| 12.A — Inline-trait toggle ladder collapse | ✅ shipped | 6-clone wrappers replaced with trait-parameterized method |
| 12.B — `EditableBlock` per-kind extraction | ✅ shipped | All 9 block kinds have dedicated `BlockEditor` files; switches collapsed; dead scaffold deleted |
| 12.C — Parser combinators + 100% CommonMark | ✅ shipped | `Parser.swift` lib + 18 ported combinator/reader files; compliance 95.1% → 100% (652/652) once #590 landed in `489b983` |

**Architectural goals achieved**: single source of truth, TK2 migration, source-mode pipeline retirement, single write path, undo journal, parser decomposition, CommonMark 99.8% (the practical ceiling — #590 is accepted wikilink-extension non-conformance).

## Remaining work

### Phase 5a bypass retirement — ✅ COMPLETE

`performingLegacyStorageWrite` has zero production call sites (down from 14). All bypasses either retired by routing through proper primitives, dropped as defensive dead code, or reclassified as sanctioned permanent exemptions with their own dedicated `StorageWriteGuard` scope. Audit: `rg -c 'performingLegacyStorageWrite' FSNotes/ FSNotesCore/ -g '*.swift'` returns 0.

| Bucket | Sites | Outcome |
|---|---:|---|
| Fold re-splice in `TextStorageProcessor` | 0 (was 1) | Retired via attribute-only `setAttributes` walk |
| Async attachment hydration (display math, mermaid) | 0 in `legacy`; 2 in new `attachmentHydration` scope | Reclassified as sanctioned permanent exemption |
| Formatting-IBAction `insertText` | 0 (was 8) | Retired via `wrapInLink` / `unwrapLink` primitives + source-mode wrapper drops |

**Sanctioned permanent exemptions** (architecturally necessary, not "legacy"):

1. **IME composition** (Phase 5e) — gated by `compositionAllowsEdit(editedRange:session:)` predicate, not a `StorageWriteGuard` scope. AppKit's input client writes during marked-text composition; commit folds the result into `Document` via one `applyEditResultWithUndo`.
2. **Async attachment hydration** (Phase 5a, this slice) — gated by `StorageWriteGuard.attachmentHydrationInFlight`. Display math + mermaid renderer callbacks swap source text for a rendered NSTextAttachment after `BlockRenderer`'s WebView render completes. Document doesn't change (presentation state only) so it can't route through `applyDocumentEdit`. Can't be made attribute-only because source character count differs from the post-hydration U+FFFC count. For mermaid specifically, an attribute-only refactor would actively hurt UX (user wants to see the source diagram syntax during the potentially-slow render, not a blank box of guessed size).

**Sliced retirement history**:
- `0444769` Phase 5a: link IBAction retirement via `EditingOps.wrapInLink`
- `35be87f` Phase 5a: code-span / code-block / table source-mode wrapper drop
- `e9ae1ea` Phase 5a: remove-link IBAction retirement via `EditingOps.unwrapLink`
- `56c8f7a` Phase 5a: fold re-splice as attribute-only update
- `2a8cd48` Phase 5a: PDF + QuickLook attachment hydration as attribute-only
- (this slice) Phase 5a: math hydration reclassified as sanctioned exemption

The `performingLegacyStorageWrite` function and `legacyStorageWriteInFlight` flag are retained as a future escape hatch — but the architecturally correct response to "I need to write to storage outside `applyDocumentEdit`" is now "introduce a dedicated sanctioned scope," not "use the legacy escape hatch."

**Latent risk class**: any new menu/toolbar IBAction calling `insertText(_:replacementRange:)` will hit the same `_insertText:replacementRange:` private bypass that Phase 5a's assertion catches. Rule-7 gate doesn't catch this (the grep pattern only flags `performEditingTransaction`); protection is discipline + the DEBUG assertion during dogfood.

### Phase 6 Tier B′ — `TextStorageProcessor.blocks` retirement

Initially scoped as a "mechanical 73-call-site sweep" — turned out to be a real architectural sub-phase. `MarkdownBlock` carries state that `Document.Block` doesn't expose:

- `collapsed: Bool` — fold state (would move to `FoldState` keyed by `Block.id` or storage offset)
- `renderMode: .source | .rendered` — mermaid/math lifecycle flag (would move to attribute-tagged storage on `MermaidElement` / `MathElement`)
- `id: UUID` — stable identifier for re-locating a block after `self.blocks` shifted
- `range`, `contentRange`, `syntaxRanges` — storage offsets (Document.Block is offset-free by design)

Live readers: 11 sites in `TextStorageProcessor`, plus `GutterController` (fold carets + code-block dedupe), `FormattingToolbar` (source-mode heading-level fallback), `EditTextView` (paragraph-rendering guard), `EditTextView+Interaction` (click-to-edit rendered-image), `NSTextStorage++` (tab-stop layout skip), `EditTextView+NoteState` + `EditTextView+BlockModel` (writers). Plus tests asserting on `.collapsed` / `.type` / `.range`.

Persistence coupling: `Note.cachedFoldState: Set<Int>` stores **indices into `processor.blocks`**, persisted per-URL in `UserDefaults` — so retirement requires a UserDefaults migration for fold-state entries.

Retirement path (sliced):

1. **✅ Sub-slice 1** (`a372a46`) — introduced `TextStorageProcessor.collapsedStorageOffsets: Set<Int>` (storage-offset-keyed) as the canonical fold-state side-table. Added public `isCollapsed(blockIndex:)` / `isCollapsed(storageOffset:)` query API + private `setCollapsed` mutator. Internal writers (`toggleFold`, `restoreCollapsedState`, `rebuildBlocksFromProjection`) route through the mutator. `MarkdownBlock.collapsed` field became a dual-written cache so external readers kept working untouched. The rebuild path drops dead offsets when blocks shift below them. 3 new tests in `Phase46BlocksPeerDeletionTests`.
2. **✅ Sub-slice 2** (`7b08aed`) — migrated all external readers (`GutterController.swift:250`, `Tests/FoldRangeTests.swift` ×8, `Tests/GutterOverlayTests.swift` ×3, `Tests/FoldSnapshotTests.swift` ×1) from `block.collapsed` to `proc.isCollapsed(blockIndex:)`. Tightened the Phase 4.6 grep-gate `permitted` allow-list to just `TextStorageProcessor.swift` (`GutterController.swift` no longer needs the exception). Discipline test now runs ~17× faster (0.188s vs 3.286s) since it has nothing to flag.
3. **✅ Sub-slice 3** (`a47acea`) — migrated `Note.cachedFoldState` from index-Set to offset-Set in-memory. New V2 UserDefaults key (`fsnotes.foldStateOffsets.<path>`) carries the canonical offset-keyed form; the legacy V1 key (`fsnotes.foldState.<path>`) is read once on first load into a transient `legacyFoldStateIndices` field, then converted to offsets via the freshly-built `blockSpans` and written back as V2 by the editor's restore path. `TextStorageProcessor` exposes `collapsedBlockOffsets` and `restoreCollapsedState(byOffsets:textStorage:)`; `toggleFold` writes offsets directly with no index conversion at the persistence boundary. 6 new tests in `Phase46BlocksPeerDeletionTests` cover V2 load, V1 legacy-field load, V2-preferred-over-V1, V1-cleared-on-write, empty-set-clears-V2, and end-to-end migration via `EditorHarness.fillViaBlockModel`.
4. **✅ Sub-slice 4** (`4fbd084`) — introduced `TextStorageProcessor.renderedStorageOffsets: Set<Int>` as the canonical render-mode side-table (mirrors Sub-slice 1's fold-state pattern). Public query API: `isRendered(blockIndex:) / isRendered(storageOffset:) / renderedBlockOffsets`. Public mutator: `setRenderMode(_:forBlockAt:)` for external callers. Internal writers (`rebuildBlocksFromProjection` WYSIWYG language-based classification, the async mermaid/math render callback in `renderSpecialCodeBlocks`, source-mode parser path post-`updateBlockModel` via `syncRenderedSideTableFromBlocks`) all route through the side-table; `MarkdownBlock.renderMode` field stays dual-written for external readers (NotesTextProcessor highlighter, MarkdownBlockParser internal classification, completion-context gating). The `EditTextView+Interaction` click-to-edit handler migrated from direct field write to `processor.setRenderMode(.source, forBlockAt:)`. 4 new tests in `Phase46BlocksPeerDeletionTests` cover language classification, setRenderMode flip, the renderedBlockOffsets accessor, and empty-by-default.
5. **✅ Sub-slice 5** (`de041a0`) — `GutterController.drawIconsTK2` heading-level fallback and `visibleCodeBlocksTK2` block lookup now route through `documentProjection.blockContaining(storageIndex:)` + `Document.blocks + blockSpans` when the projection is non-nil (WYSIWYG). Source mode keeps the legacy `processor.blocks` reads as a fallback until Sub-slice 7 retires the array entirely. Both reads (the only two real `processor.blocks` reads in this file outside doc-comments) gated; the heading-level fallback's primary path is still the storage `.headingLevel` attribute. New isolation test in `Phase46BlocksPeerDeletionTests` clears `proc.blocks = []` after harness fill and asserts `visibleCodeBlocksTK2()` still finds the same code-block ranges via `Document.blocks` — proving the WYSIWYG path no longer depends on `processor.blocks`.
6. **✅ Sub-slice 6** (`7ef9dc1`) — added `TextStorageProcessor.setRenderMode(_:forBlockAtOffset:)` so the click-to-edit rendered-image handler in `EditTextView+Interaction` operates purely on storage offsets. The previous `processor.blocks.firstIndex(where:)` lookup now lives behind the public API; external callers no longer touch `processor.blocks`. The lookup that survives is a single line inside `setRenderMode` (the dual-write to `MarkdownBlock.renderMode` field) — Sub-slice 7 collapses that to a side-table-only update once the field is removed. The pre-flight `isRendered(storageOffset:)` check that the old call site used is dropped: the click handler's authoritative gate is the `.attachment` + `.renderedBlockOriginalMarkdown` storage attribute pair (an offset that hosts a rendered block), and the side-table mutator is idempotent for unknown offsets. 2 new tests in `Phase46BlocksPeerDeletionTests` cover the offset-keyed flip and the no-op behaviour for unknown offsets.
7. **✅ Sub-slice 7.A** (`0947cee`) — `MarkdownBlock.collapsed` field retired entirely. The dual-write in `setCollapsed` (sub-slice 1's compatibility shim), the `mb.collapsed = true` assignment in `rebuildBlocksFromProjection`, and the `blockIndex` parameter on `setCollapsed` all dropped. The discipline test (`test_phase46_noMarkdownBlockCollapsed_reads`) hardened to enforce zero `.collapsed` reads anywhere in production code (no longer permits `TextStorageProcessor.swift` as an exception, since the field doesn't exist), with line-comment stripping so doc-comments referencing the historical name don't trigger false positives. `test_phase6Bprime_toggleFold_updatesSideTableAndLegacyField` renamed to `test_phase6Bprime_toggleFold_updatesSideTable` and asserts solely on `isCollapsed(...)` + `collapsedBlockOffsets`. 21/21 Phase 6 Tier B′ tests pass; broader fold/gutter/fragment-dispatch suites green at 106/0.

8. **✅ Sub-slice 7.B.1** (`6ac422d`) — `MarkdownBlock.renderMode` field retired entirely. The three parser methods (`MarkdownBlockParser.parsePreservingRendered` / `adjustBlocks` / `reparseBlocks`) now accept a `renderedOffsets: Set<Int>` parameter that the caller (`TextStorageProcessor.updateBlockModel`) sources from the `renderedStorageOffsets` side-table. The internal field reads in `codeBlockRanges`, `codeRanges` helper, and the async render skip-check switched to side-table lookups (`!renderedStorageOffsets.contains(...)` or `isRendered(blockIndex:)`). The `mb.renderMode = .rendered` writes in `rebuildBlocksFromProjection` and the dual-write in `setRendered` are gone; the redundant `syncRenderedSideTableFromBlocks` helper deleted. Side-table consistency across `adjustBlocks`'s offset-shift now comes from a UUID snapshot taken before the parse and re-derived after. New `test_phase6Bprime_subslice7B1_noMarkdownBlockRenderMode_reads` grep-discipline test enforces zero `.renderMode` reads in production code (line-comment-stripped). 22/22 Phase 6 Tier B′ tests pass; 117/0 across the broader fold/gutter/fragment-dispatch sweep.

9. **Sub-slice 7.B.2 (deferred)** — `processor.blocks` array retirement. Remaining surface: source-mode editing reads `block.range`, `block.contentRange`, `block.syntaxRanges`, `block.id`, `block.type` for marker overlays, code-block range tracking, async-callback identity, layout dispatch, and the source-mode parser is the canonical writer. Retirement requires lifting the source-mode pipeline off the per-block array entirely — likely a Phase 6 Tier C scope, not a Tier B′ tail-end.

### Phase 8 Slice 5 — ✅ shipped

Filter broadened in both `CodeBlockEditToggleOverlay.swift:295` and `GutterController.swift:399` to accept `MermaidLayoutFragment` / `MathLayoutFragment` / `DisplayMathLayoutFragment` alongside `CodeBlockLayoutFragment`. The per-block `case .codeBlock` gate further down remains the authoritative filter (paragraphs containing `Inline.displayMath` from `$$…$$` syntax are correctly rejected — they're not editable code blocks). Two new tests in `CodeBlockEditToggleOverlayTests` cover the mermaid + fenced-math cases.

### Phase 9 remnants

- **9.a** — UTType-related Tier-1 sites (currently shipped: mechanical sweep + UTType migration partial, AppKit modernization partial)
- **Pod warnings** (~100 from `libcmark_gfm`, `MASShortcut`, `SSZipArchive`) — deferred. Right mitigation is silencing at Pod target level via `OTHER_CFLAGS = -Wno-strict-prototypes -Wno-deprecated-declarations`.

### Phase 11 remaining slices

- ✅ **Slice A.5** (`3625f2b` plan; runner + `Tests/Fixtures/FSMTransitions.swift` shipped, ~95 rows ≥ 80-row floor) — FSM transition table in machine-readable form. Bug-rows wrapped in `XCTExpectFailure(strict:)` flip red when their underlying FSM is fixed.
- ✅ **Slice B** (`9a6a199`) — 38-bug inventory migrated to `BugInventoryRegressionTests.swift`. Per-bug status (commits named `Fix bug #N`):
  - **Fixed**: #1–#28 (✅ in earlier slice work + bug-fix commits), #30, #31 (`466840b`), #32 (`d2e8294`), #34 (`04c0c7d`), #35 (`406357f`), #36 (`4121390`), #37 (`dde37cf`, Slice E discovery), #38 (`cb314fc`, Slice E discovery), #47 (`4944023`), #50 (`9b1be2b`), #51 (`6579cda` slice 3), #54 + #55 (`b7ac4dd`).
  - **Open**:
    - **#29 (REOPENED)** — Click in top-left cell paints caret ABOVE the cell. 7 successive fix commits landed (`9fb9e6f` → `dacecec`); awaiting user validation in the live app before re-marking fixed.
    - **#33** — Stale column-handle subview lingers after `Insert Column Left/Right`.
    - **#48** — Spreadsheet-paste WYSIWYG mismatch — source-mode paste handler converts TSV/HTML→GFM, WYSIWYG path doesn't route through it.
    - **#52** — Headings don't parse inline markdown (code spans, bold/italic in heading body). NOT a one-liner: `Block.heading(level:suffix:)` carries raw `suffix: String` and `HeadingBlockEditor` operates on suffix-character offsets, so adding `parseInlines(suffix, refDefs:)` breaks the displayed-character ↔ suffix-character invariant. The architecturally clean fix changes the schema to `Block.heading(level:, inline: [Inline])` mirroring paragraphs, with corresponding renderer + editor + serializer + round-trip-test updates.
    - **#53** — AI toolbar button doesn't open chat panel. `45fbe17` added diagnostic, `6e3e726` fixed panel layout + caret/nav diagnostics; status uncertain.
- ✅ **Slice C** (`5c50998`) — bitmap-based `Then` readbacks shipped in `Tests/EditorAssertions+Bitmap.swift` + `Tests/UserFlows/BitmapReadbackTests.swift`.
- ✅ **Slice D** (`7d82fe4`) — async-hydration `Then` readbacks shipped in `Tests/EditorAssertions+Async.swift` + `Tests/UserFlows/AsyncHydrationThenTests.swift`.
- ✅ **Slice E** (`d70cb9d`, widened by `8138174`) — combinatorial coverage generator over (block kind × cursor position × edit primitive × selection state) with sequence widening + round-trip parity invariant. Surfaced bugs #37 + #38.
- ✅ **Slice F (closed except F.5)** — consolidation. Sub-slices:
  - ✅ **F.1** (`0992301`) — `SubviewTableBoundaryCaretTests` migrated. Introduced `Tests/EditorScenario+Fixtures.swift` with `firstAttachment(of:)` + `firstFragmentElement(of:)` helpers used by the rest of the slice.
  - ✅ **F.2** (`bbefb92`) — `TableCellEditingTests` migrated. Helpers extended with `tableCellOffset(row:col:)` + `tableBlock(at:)`.
  - ✅ **F.3** (`ef8a35d`) — `TableNavigationTests` migrated (-65 LoC; 12 keyboard-command tests over the same fixture).
  - ✅ **F.4** (`e6a096f`) — `SubviewTableInPlaceFastPathTests` migrated. Helpers extended with `firstTableBlockIndex()`.
  - **F.5 (deferred — different code path)** — `HeaderTests` + `NewLineTransitionTests` use a `makeFullPipelineEditor` + `runFullPipeline` pattern that bypasses `EditorHarness` entirely to test the *source-mode* renderer path (no block-model activation, explicit `setAttributedString` + `RunLoop` pump). Migrating to `Given.note(...)` would change the code path under test (block-model active by default), losing fidelity. The clean fix is a `Given.sourceModeNote(...)` builder + matching pipeline pump verb — separate slice from the table-fixture consolidation.
  - ✅ **F.6** (`2bd86db`) — `AppBridgeImplTestHelper.makeHarness(at:url:markdown:)` retired. Six call sites (4 MCP tool tests + 2 integration tests in `AIToolCallE2ETests`) migrated to `Given.mcpNote(at:markdown:)` in `Tests/EditorScenario+MCPFixture.swift`. The MCP-specific repointing of `note.url` is now a DSL factory sibling to `Given.note(...)`.
  - ✅ **F.7** (`7c2eeb0`) — `UIBugRegressionTests.swift` rewritten from ~1,740 LoC of probe-based `EditorHarness` + `snapshot.assertContains(...)` calls to ~550 LoC of named-invariant DSL regressions (47 tests). New readbacks added to `EditorAssertions.swift` (`Then.fragments.contains(class:)`, `Then.fragments.countOfClass(_)`, `Then.snapshot.contains(_)`, `Then.document.storageText`, `Then.document.blockCount(ofKind:)`, `Then.document.totalBlocks`, `Then.cursor.selectionIsCollapsed`). Net: -1,581 LoC of tests + 360 LoC of reusable DSL surface every regression suite benefits from. The `EditorHTMLParityTests` `EditStep` DSL absorption (originally bundled into the F.7 brief) is left as a separate cleanup — `EditorHTMLParityTests` already has its own focused live-edit harness and is not redundant with `EditorScenario`.

### Deferred bugs / investigations

| Item | Gate to re-investigate |
|---|---|
| Bug #41 — seamCursor in `(paragraph, blankLine, paragraph)` delete | Needs live-repro investigation, not arithmetic patches in `EditingOps.delete`. Pure-function semantic captured in `test_bug41_returnThenDelete_*` (passing at primitive layer) |
| Bug #29 — caret above cell (REOPENED) | Live diagnostic dump comparing `selectedRange(forProposedRange:)` to `TableLayoutFragment`'s computed cell rect for the failing click region |
| Bugs 3 invisible todo text in one specific note | Was gated on TK2 fragment dispatch (achieved). Re-investigate under TK2 fragments — likely `<mark>` / `<kbd>` / `<sup>` interaction with todo line attribute assignment |
| `test_headerFonts_areBold` full-suite hang | Test isolation issue (single-suite run passes; full sweep hangs after ~28 prior suites). Fix is in test isolation, not code under test. Gates full CI re-introduction |

### Accepted non-fixes

- *(none open — all prior accepted non-fixes have shipped)*

### Recently shipped clarifications

- **CommonMark spec #590** — ✅ shipped (`489b983`). Wikilink extension now declines in two contexts: when preceded by `!` (image-opener position; covers line 1 of #590) and when followed by `:` (malformed-ref-def shape; covers line 2). Conformance: 651/652 → 652/652 (100%). Pinned by `test_image_spec590_wikilinkInsideAltDoesNotBleed`. The Images bucket reaches 22/22; the legacy "wikilink-extension non-conformance" caveat is retired.

