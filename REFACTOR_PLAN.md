# Fourth Architecture Revamp — Status & Remaining Work

`ARCHITECTURE.md` is the canonical description of how the editor works *today*. This file tracks the multi-phase refactor that got us there: what's done, what's left, and the bug-class lessons worth preserving so we don't relearn them.

## Why this refactor existed

Three earlier refactors of FSNotes++ each reduced some bug classes and left others. Stubborn residual bugs (Find across tables, attribute-diff seam bugs, widget/data desyncs) all traced to two root causes:

1. **`Document` and `NSTextStorage` were peer sources of truth** for the same content, kept in sync via translation code. Every "seam bug" was a symptom of the split.
2. **The wrong layout primitive.** TextKit 1's `NSLayoutManager` + `NSTextAttachment` + `U+FFFC` placeholder required widget-internal text (e.g. table cells) that `NSTextFinder` couldn't see, selection couldn't cross, and accessibility couldn't reach. The placeholder was the seam.

The fix was to collapse the dual-source-of-truth into **`Document` as the sole source of truth**, backed by **TextKit 2** (`NSTextLayoutManager` + `NSTextContentStorage` + per-block `NSTextElement` + `NSTextLayoutFragment`) so each block type declares its own layout natively.

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
| 6 — Cleanup | ✅ partial | Tier C delete legacy `NotesTextProcessor.highlightMarkdown` + dead `processInlineTags` / `applySyntaxHiding`. **Tier B′ deferred** (TextStorageProcessor.blocks retirement — see Remaining Work) |
| 7 — Theme system | ✅ shipped | `BlockStyleTheme` schema + bundled Default/Dark/HighContrast + user overrides; preferences write-through; UD subsumption; rule-7 gate |
| 8 — Code-block edit toggle | ✅ shipped (slices 1-5) | `</>` hover button, cursor-leaves auto-collapse. Slice 5 broadened the overlay + gutter copy-icon filters to also accept `MermaidLayoutFragment` / `MathLayoutFragment` / `DisplayMathLayoutFragment` (the dedicated fragment classes for fenced ```mermaid``` / ```math``` / ```latex``` blocks) so the user can open them for editing. Display math via `$$…$$` is a paragraph-with-displayMath-inline, not a code block — correctly rejected by the per-block filter |
| 9 — Compiler-warning cleanup | ✅ partial | Tier 1 mechanical sweep, Tier 2 UTType migration, Tier 3 AppKit modernization (partial). Pod warnings deferred |
| 10 — CommonMark Slice A | ✅ shipped | 92.2% → 95.1% via small grammar edits across 11 commits |
| 11 — Composable user-flow harness | ✅ partial | Slice A (Given/When builder + 8 readbacks) shipped; bug inventory mostly migrated. Slices A.5/C/D/E/F outstanding |
| 12.A — Inline-trait toggle ladder collapse | ✅ shipped | 6-clone wrappers replaced with trait-parameterized method |
| 12.B — `EditableBlock` per-kind extraction | ✅ shipped | All 9 block kinds have dedicated `BlockEditor` files; switches collapsed; dead scaffold deleted |
| 12.C — Parser combinators + 100% CommonMark | ✅ shipped | `Parser.swift` lib + 18 ported combinator/reader files; compliance 95.1% → 99.8% (651/652) |

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
3. **✅ Sub-slice 3** (this slice) — migrated `Note.cachedFoldState` from index-Set to offset-Set in-memory. New V2 UserDefaults key (`fsnotes.foldStateOffsets.<path>`) carries the canonical offset-keyed form; the legacy V1 key (`fsnotes.foldState.<path>`) is read once on first load into a transient `legacyFoldStateIndices` field, then converted to offsets via the freshly-built `blockSpans` and written back as V2 by the editor's restore path. `TextStorageProcessor` exposes `collapsedBlockOffsets` and `restoreCollapsedState(byOffsets:textStorage:)`; `toggleFold` writes offsets directly with no index conversion at the persistence boundary. 6 new tests in `Phase46BlocksPeerDeletionTests` cover V2 load, V1 legacy-field load, V2-preferred-over-V1, V1-cleared-on-write, empty-set-clears-V2, and end-to-end migration via `EditorHarness.fillViaBlockModel`.
4. **Sub-slice 4** — move `renderMode` lifecycle to a side-table on `TextStorageProcessor` or attribute-tagged storage on `MermaidElement` / `MathElement`.
5. **Sub-slice 5** — rewrite `GutterController.drawIconsTK2` + `visibleCodeBlocksTK2` to read from `Document.blocks` + `blockSpans` instead of `processor.blocks`.
6. **Sub-slice 6** — rewrite `EditTextView+Interaction.swift`'s click-to-edit rendered-image path.
7. **Sub-slice 7** — drop `MarkdownBlock.collapsed` field entirely, retire `processor.blocks` once all readers are gone.

### Phase 8 Slice 5 — ✅ shipped

Filter broadened in both `CodeBlockEditToggleOverlay.swift:295` and `GutterController.swift:399` to accept `MermaidLayoutFragment` / `MathLayoutFragment` / `DisplayMathLayoutFragment` alongside `CodeBlockLayoutFragment`. The per-block `case .codeBlock` gate further down remains the authoritative filter (paragraphs containing `Inline.displayMath` from `$$…$$` syntax are correctly rejected — they're not editable code blocks). Two new tests in `CodeBlockEditToggleOverlayTests` cover the mermaid + fenced-math cases.

### Phase 9 remnants

- **9.a** — UTType-related Tier-1 sites (currently shipped: mechanical sweep + UTType migration partial, AppKit modernization partial)
- **Pod warnings** (~100 from `libcmark_gfm`, `MASShortcut`, `SSZipArchive`) — deferred. Right mitigation is silencing at Pod target level via `OTHER_CFLAGS = -Wno-strict-prototypes -Wno-deprecated-declarations`.

### Phase 11 remaining slices

- **Slice A.5** — FSM transition table in machine-readable form (prerequisite for Slice E combinatorial coverage)
- **Slice B** — bug inventory migration: most done, ~15 entries open. Highlights:
  - **#27** Image resize (shrink) draws image left-aligned instead of centered
  - **#29 (REOPENED)** Click in top-left cell paints caret ABOVE the cell. Fix shipped earlier but live regression reported. Investigation needs diagnostic dump from live app comparing `selectedRange(forProposedRange:)` output vs. `TableLayoutFragment`'s computed cell rect.
  - **#33** Stale column-handle subview lingers after `Insert Column Left/Right`
  - **#37** (Slice E discovery) Backspace at start of a table cell crosses the cell boundary instead of staying inside
  - **#38** (Slice E discovery) List exit-to-body transition mints a fresh `Block` UUID rather than mutating in place
  - **#47** Row/column drag-selection border offset rightwards from boundary (coord-space class)
  - **#48** Spreadsheet-paste WYSIWYG mismatch — source-mode paste handler converts TSV/HTML→GFM, WYSIWYG path doesn't route through it
  - **#52** Headings don't parse inline markdown (code spans, bold/italic in heading body) — `HeadingRenderer` flattens suffix to `[.text(suffix)]` instead of `MarkdownParser.parseInlines(suffix, refDefs:)`
  - **#53** AI toolbar button doesn't open chat panel — investigation: log entry into `toggleAIChat` to confirm responder-chain reach
  - **#54** After unfolding a folded header, list bullets/checkboxes don't render until scroll — view-providers not re-instantiated until next layout pass
  - **#55** Folded `[...]` chip indicator doesn't paint until scroll — same redraw-after-attribute-change class as #54

- **Slice C** — bitmap-based `Then` readbacks (4 visual readbacks: folded header, kbd box, HR line, dark-mode contrast)
- **Slice D** — async-hydration `eventually(within:)` polling helper for mermaid render, MathJax baseline, image bounds, QuickLook thumbnail
- **Slice E** — combinatorial coverage generator over (block kind × cursor position × edit primitive × selection state) with minimal-invariant assertions
- **Slice F** — consolidation: collapse 5+ per-suite `makeHarness` / `makeFullPipelineEditor` factory functions into one `Given.note(...)` factory; absorb `EditorHTMLParityTests` `EditStep` DSL; rewrite `UIBugRegressionTests.swift` (~1,400 LoC of probes) to ~300 LoC of named regressions

### Deferred bugs / investigations

| Item | Gate to re-investigate |
|---|---|
| Bug #41 — seamCursor in `(paragraph, blankLine, paragraph)` delete | Needs live-repro investigation, not arithmetic patches in `EditingOps.delete`. Pure-function semantic captured in `test_bug41_returnThenDelete_*` (passing at primitive layer) |
| Bug #29 — caret above cell (REOPENED) | Live diagnostic dump comparing `selectedRange(forProposedRange:)` to `TableLayoutFragment`'s computed cell rect for the failing click region |
| Bugs 3 invisible todo text in one specific note | Was gated on TK2 fragment dispatch (achieved). Re-investigate under TK2 fragments — likely `<mark>` / `<kbd>` / `<sup>` interaction with todo line attribute assignment |
| `test_headerFonts_areBold` full-suite hang | Test isolation issue (single-suite run passes; full sweep hangs after ~28 prior suites). Fix is in test isolation, not code under test. Gates full CI re-introduction |

### Accepted non-fixes

- **CommonMark spec #590** — wikilink-extension non-conformance. `![[foo]]` resolves to a wiki link by product design rather than literal text. 651/652 (99.8%) is the practical ceiling for FSNotes++.

## Bug-class lessons

These are the patterns that recurred during the refactor and will recur again. Each has a recipe.

### View-provider state must be value-typed

**Symptom**: thumbnail / preview disappears after scrolling away and back; outer attachment frame survives but inner content is gone.

**Cause**: storing a pre-built live view on the attachment. TK2 detaches the view from its window on scroll-out and re-attaches on scroll-back; the inner state was lost during the detach.

**Recipe**: store only value types (URL + size) on the `NSTextAttachment`; build the inline view fresh inside `loadView()`. The TK2 contract is "loadView builds, doesn't recall." `ImageAttachmentViewProvider` is the reference pattern; both PDF and QuickLook were retrofitted to match.

### Attribute change without layout invalidation

**Symptom**: visual element doesn't repaint after a state change (folded chip, list bullets after unfold, caret after table-cell edit). User has to scroll to force a redraw.

**Cause**: setting `.foldedContent` / similar attribute on a range without firing layout invalidation. TK2's element-and-fragment dispatch only re-runs on the next layout pass.

**Recipe**: after mutating an attribute that affects element/fragment dispatch, call `textLayoutManager.invalidateLayout(for: NSTextRange(location:length:))` on the affected range. For attachment-driven views, this also forces `NSTextAttachmentViewProvider.loadView` re-execution.

### Coordinate-space mismatches

**Symptom**: visual element drawn at a small consistent offset from where it should be (caret above the cell instead of inside; chip offset rightward; selection border one column off).

**Cause**: producer returns coords in space A; consumer drew in space B; missing transform = `originOf(B in A)`.

**Recipe**: identify which space each side is in. The FSNotes++ stack is fragment-local → container (+ `fragment.origin`) → view (+ `textContainerOrigin`) → window (+ frame origins) → screen. Apply this checklist FIRST when caret/chip/click is offset — it's almost always a single missing transform, not a more elaborate bug.

### Stale projection drift after async storage swap

**Symptom**: edit lands at the wrong storage offset after an inline-math callback or image resize completes; subsequent edits corrupt unrelated content.

**Cause**: `applyDocumentEdit` assumes `DocumentRenderer.render(priorDoc)` matches what's currently in `NSTextContentStorage`. Async hydration paths (MathJax, image resize, attachment swap) mutate storage and patch `proj.rendered.attributed` + `proj.rendered.blockSpans` but leave `proj.document` stale. On the next edit, span-offset math places the splice at the wrong byte.

**Recipe**: pass `priorRenderedOverride: oldProjection.rendered` to `applyDocumentEdit` from any caller whose projection might be stale. The override forces span-offset math to use the post-swap rendered layout; `priorDoc` still drives the LCS block-diff (block-value equality is unaffected by rendered-form drift).

The clean fix is routing the async swap through `applyDocumentEdit` proper (Phase 5a bypass retirement above), but the `priorRenderedOverride` parameter is the survivable workaround until each bypass slice lands.

### Lazy-continuation rule tension with editor round-trip

**Symptom**: a CommonMark spec example fails because the editor's `Document` round-trip would re-merge content that was structurally separate, OR a user-typed paragraph after a list bleeds into the list.

**Cause**: strict CommonMark §5.1 lazy continuation merges any non-block-starter, non-blank line into an open paragraph regardless of indent. That's wrong for editor-produced `[list, paragraph]` Documents which serialize without an explicit `.blankLine` separator and would re-merge at load time.

**Recipe**: use a *narrow* lazy-continuation rule that requires `lineIndent > last.indent.count`, and add multi-block-evidence look-ahead for the spec cases that need strict behavior — scan forward through consecutive lazy-continuation candidates and any blank gap; if the next non-blank line is indented to ≥ contentCol, the item has multi-block content and lazy merge is licensed. The well-formed spec cases (#254, #286-#291) fire the narrow rule; multi-block spec cases (#290) fire the look-ahead; editor round-trip (`- foo\nbar` with no deep follower) parses as `[list, paragraph]`. Pattern lives in `ListReader.read`.

### `cacheDisplay` doesn't capture fragment-level draws

**Symptom**: per-block chrome (HR line, blockquote border, heading hairline, kbd box, code-block border) doesn't appear in test snapshots. The corresponding live editor renders fine.

**Cause**: `bitmapImageRepForCachingDisplay` / `cacheDisplay` invokes `view.draw()` but does NOT invoke `NSTextLayoutFragment.draw`. Per-fragment chrome only paints at TK2 layout time.

**Recipe**: don't snapshot-test fragment chrome via `cacheDisplay`. Either assert fragment-class dispatch (see `TextKit2FragmentDispatchTests`) or use the renderFragmentToBitmap helper which walks the layout manager directly. Live deployment is the final check.

### TK2 silent fallback to TK1

**Symptom**: TK2 worked at startup but every keystroke or mouse-move tore it down; `textLayoutManager` became `nil` permanently.

**Cause**: reading `NSTextView.layoutManager` on a TK2-wired view causes AppKit to lazily instantiate a TK1 `NSLayoutManager` compatibility shim. There's no API to detect this; it's a silent fallback.

**Recipe**: never read `NSTextView.layoutManager` directly on a TK2 view. Use `EditTextView.layoutManagerIfTK1`:
```swift
var layoutManagerIfTK1: NSLayoutManager? {
    return textLayoutManager == nil ? layoutManager : nil
}
```
The `textLayoutManager` check happens first (safe); `layoutManager` is read only when already on TK1. Grep discipline: `self.layoutManager` / `editor.layoutManager` outside `layoutManagerIfTK1`'s body is a code smell.

### Adoption-time fixity

**Symptom**: `replaceTextContainer(_:)` with a TK2-bound container on a storyboard-decoded `NSTextView` leaves the view on TK1; `textStorage` becomes `nil`.

**Cause**: `NSTextView` fixes its TextKit version when the initial `NSTextContainer` is attached. Post-hoc swap doesn't flip an already-TK1 view.

**Recipe**: construct a fresh TK2 instance (`init(frame:)` builds a TK2-bound container) and re-point `scrollView.documentView` to the new instance. `EditTextView.migrateNibEditorToTextKit2` mirrors the storyboard's configuration (`autoresizingMask`, `isEditable`, `min/maxSize`, `textContainerInset`, container `widthTracksTextView`) onto the new view.

### `cfprefsd` caches UD writes

**Symptom**: `PlistBuddy` writes to `co.fluder.FSNotes.plist` are silently overwritten before they take effect; `defaults read` shows the old value.

**Cause**: cfprefsd caches `UserDefaults` values in memory and writes back its cached version periodically.

**Recipe**: `killall cfprefsd 2>/dev/null` BEFORE `PlistBuddy` writes. Always.

### Save-path widget walker

**Symptom (historical)**: Saving a note required walking live `InlineTableView` state to recover cell text, which routed widget-rendered (markers stripped) attributed strings back into the data model — silently overwriting formatting in unrelated cells.

**Cause**: any code path that reads `cell.stringValue` / `view.attributedStringValue` into a model field is a view→data leak. The widget's render is lossy by design (markers consumed); reading it back loses information.

**Recipe**: views render data; views never write data. The cure was deleting the widget entirely (Phase 2e T2-h) and routing cell edits through `EditingOps.replaceTableCellInline` with `[Inline]` values. The grep gate bans `headers[…] = …stringValue` and `rows[…][…] = …stringValue` patterns to prevent reintroduction.

### Marker-hiding tricks

**Symptom (historical)**: Markdown markers in WYSIWYG storage hidden via 0.1pt font / clear foreground / negative kern attributes so Cmd+F could find them.

**Failure modes**: cursor invisibility, layout flicker, find-result ranges pointing at invisible runs, font-vs-kern desync re-revealing characters.

**Recipe**: markers don't live in WYSIWYG storage at all. The `Document` model is searchable independently of presentation; Find-across-blocks works because all text-bearing block content lives in storage as real characters. Source mode is the path for users who want to see/find markers; it has them as real content with `.markerRange` overpainting. The grep gate bans `systemFont(ofSize: 0.…)`, `NSColor.clear` foreground, `addAttribute(.kern`, and widget-local `parseInlineMarkdown` to prevent reintroduction.

## Process rules

These are discipline rules — the codebase can't enforce them mechanically.

### Stop and rescope when an invariant is in your way

If a task seems to require routing around the architecture (a second write path, a view reading back into the model, a literal presentation value outside Theme, a marker-hiding trick), stop the tool call and write to the user: "the clean fix requires X, the shortcut would be Y, here's the tradeoff." Wait for a decision. The compounding shortcuts in `InlineTableView` accumulated into a widget that had to be deleted wholesale.

### Run the rule-7 gate before editing render-path files

```bash
./scripts/rule7-gate.sh        # exit 0 = clean, 1 = violation
```

Pure shell, no xcodebuild, fast. Run it BEFORE editing files under `FSNotes/Rendering/` or `FSNotesCore/Rendering/`. The "inherited violation" failure mode (pattern-matching from existing-but-violating code) is exactly why this is mechanical rather than discretionary — discipline fails under load, the gate doesn't.

### Never fabricate historical reasoning

When asked why a piece of code looks a certain way, the honest answer starts with either "I wrote it that way because <actual reason>" or "I don't remember — let me look at git blame." Don't invent a plausible-sounding history ("this predates the refactor," "this was a constraint from an earlier design") to paper over not remembering. If you invent one, it will be wrong.

### A passing test suite with shipping bugs means the tests cover the wrong layer

Pure-function tests passing while the user reports live bugs means the test suite is pure-layer only and the bug is in the widget/view glue. The fix is not to add more pipeline tests — it's to identify the pure function that represents the feature's core logic and test *that*. If no such pure function exists yet, extracting it is the first fix. Phase 11 (composable user-flow harness) is the structural answer to this: short Given/When/Then chains over named user-perceptible outcomes, written cheaply per bug.

### After 3 failed attempts, write a test

If a bug isn't fixed after 3 tries, stop coding and write a pure-function unit test that captures the bug. If you can't express the bug as a pure function on value types, that's the bug — the logic is tangled in the view layer and needs extraction first.

### Debug at the source stage, not downstream

Before writing any fix:

1. Which pipeline stage is responsible? (parser, `EditingOps` primitive, `DocumentRenderer`, element class, fragment class, `applyDocumentEdit`, theme lookup)
2. Am I modifying THAT stage, or patching somewhere else?
3. If #2 is "somewhere else" — stop. Go back to #1.

Never set attributes after an operation to override what a stage already applied. Never patch the save path to rewrite state at serialization time. If the projection is wrong at save, the edit that produced it was wrong — fix the edit.

### New widgets and renderers must be unit-testable as pure functions on value types

If a test for your feature's core logic needs an `NSWindow`, a real field editor, or synthetic mouse events, the logic is in the wrong layer. Move it into a pure primitive on `Document` / `Block` / `Inline` values and test that. Keep the widget thin — it captures intent and calls the primitive.

### Verify the build before claiming a fix

For UI / frontend changes, build and use the feature in the live app before reporting the task as complete. Test golden path AND edge cases. Type checking and test suites verify code correctness, not feature correctness — if you can't test the UI, say so explicitly rather than claiming success.

When patching a macOS app: NEVER copy individual binaries — always copy the entire `.app` bundle (`cp -R`). Debug builds split code into dylibs (`App.debug.dylib`); copying only the main executable deploys a stub with none of your changes. After patching, verify with `nm` or `strings` that your changes (function names, string literals) exist in the deployed binary.

## Known build / test environment notes

### CocoaPods in worktrees

Git worktrees do NOT copy `.gitignored` files. `Pods/`, `Podfile`, and `Podfile.lock` are gitignored. After creating any worktree, symlink them:

```bash
MAIN_REPO="/Users/guido/Documents/Programming/Claude/fsnotes"
WORKTREE="$MAIN_REPO/.claude/worktrees/<name>"
ln -s "$MAIN_REPO/Pods" "$WORKTREE/Pods"
ln -s "$MAIN_REPO/Podfile" "$WORKTREE/Podfile"
ln -s "$MAIN_REPO/Podfile.lock" "$WORKTREE/Podfile.lock"
```

Without these, `xcodebuild` fails with "unable to resolve module dependency."

### Adding new Swift files

When creating any new `.swift` file, add it to `FSNotes.xcodeproj/project.pbxproj` in FOUR places:

1. **PBXBuildFile** — `<ID_B1> /* File.swift in Sources */ = {isa = PBXBuildFile; fileRef = <ID_F1> /* File.swift */; };`
2. **PBXFileReference** — `<ID_F1> /* File.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = File.swift; sourceTree = "<group>"; };`
3. **PBXGroup children** — add `<ID_F1>` to the appropriate group's `children` array
4. **PBXSourcesBuildPhase** — add `<ID_B1>` to the target's Sources build phase `files` array

For test files, the target is `FSNotesTests` (build phase ID: `TEST00000000000000000005`). Files on disk but not in pbxproj are silently ignored by `xcodebuild`. Always verify after adding.

### Debug builds aren't sandboxed

`NSHomeDirectory()` resolves to `/Users/guido` (real home, NOT a container). `UserDefaults` reads/writes go to `~/Library/Preferences/co.fluder.FSNotes.plist`. Documents directory → `~/Documents/`. To change a UserDefaults value from the command line:

```bash
killall cfprefsd 2>/dev/null
/usr/libexec/PlistBuddy -c "Set :keyName value" ~/Library/Preferences/co.fluder.FSNotes.plist
```

### Use file-based logging, never NSLog

`NSLog()` output doesn't reliably appear in `log show` for GUI apps. Use file-based logging via `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)` (resolves to `~/Documents/` for FSNotes++). Always write a timestamp + sentinel on app launch — if the log file doesn't exist after launch, the logging code isn't executing.

Unit-test output goes to `~/unit-tests/` (not sandboxed).

### Output redirection discipline

`xcodebuild` (build AND test) produces thousands of lines per invocation — dumping into context burns budget. Always redirect to a temp log and grep for what matters:

```bash
xcodebuild -workspace FSNotes.xcworkspace -scheme FSNotes build > /tmp/xcbuild.log 2>&1
# then: tail -n 50 /tmp/xcbuild.log, or: grep -E "error:|warning:|BUILD" /tmp/xcbuild.log

xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes > /tmp/xctest.log 2>&1
# then: grep -E "Test Case|failed|passed|error:" /tmp/xctest.log | tail -n 100
```

Same for `git diff` (>50 lines) and `git log`. Use `--oneline -N` and offset/limit on Read.
