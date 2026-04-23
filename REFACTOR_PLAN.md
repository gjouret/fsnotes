# Fourth Architecture Revamp — Refactor Plan

> **File relocation:** user requested final location at `REFACTOR_PLAN.md` in the project root. Plan mode restricts writes to this file only; first action after ExitPlanMode approval is copying this to `/Users/guido/Documents/Programming/Claude/fsnotes/REFACTOR_PLAN.md`.

---

## Context

Why this change is being made:

FSNotes++ has shipped three architectural refactors. Each one reduced some bug classes and left others. The current live bug rate is roughly 3 incoming per week and 1 fixed per week — the queue grows even while I work. The stubborn residual bugs (#35, #36, #41, #60 and their class) all trace to two root causes:

1. `Document` (the block model) and `NSTextStorage` are **peer sources of truth** for the same content, kept in sync via translation code with its own rules. Every "seam bug" is a symptom of that split.
2. **The wrong layout primitive.** TextKit 1 (`NSLayoutManager` + `NSTextAttachment` + `U+FFFC`) requires a placeholder character in `textStorage` to reserve space for custom-drawn block content (tables, mermaid, math, HR, code blocks with language). Because table cell text lives inside the attachment's widget rather than in `textStorage.string`, `NSTextFinder` can't see it (bug #60), selection can't cross it, accessibility can't reach it, and `narrowSplice`'s attribute-diff has to special-case attachment identity. The placeholder is the seam.

This is the fourth architecture revamp. Its goal is to collapse the dual-source-of-truth into **`Document` as the sole source of truth**, backed by a **TextKit 2 text system (`NSTextLayoutManager` + `NSTextContentStorage` + per-block `NSTextElement` + `NSTextLayoutFragment`)** so each block type declares its own layout without needing a placeholder character in the character stream. Supported by test infrastructure that actually catches seam bugs before shipping.

User has explicitly said: stop promising, start demonstrating. Each phase ends in a shippable tree. User approves each phase exit individually. **Plan is immutable within a phase.** Discovery that invalidates the current phase's scope, or that invalidates downstream phases, triggers a checkpoint stop: phase halts, the discovery is written up, and work resumes only after user approval of the amended plan.

**Intended outcomes:**
1. Seam-bug class reduction (bugs #35, #36, #41, #60 and recurrence of their class)
2. `U+FFFC` + `NSTextAttachment` eliminated as the mechanism for block-level content; Find/selection/accessibility work natively across all block types
3. CommonMark compliance ≥ 90% (up from current 80%+ baseline — hard non-regression gate at every phase)
4. Test infrastructure that fails on seam bugs before ship (harness + invariants + HTML-proxy)
5. Source-mode pipeline retired; single rendering pipeline owning all markdown notes

---

## Out of scope

1. **Wholesale `setAttributedString` on every edit.** Per user: the narrowSplice concept stays. Redraw scope is bounded: nothing above the edit point changes, nothing below the affected blocks changes (only reflow), off-screen content is deferred by the layout engine. In TextKit 2, this becomes element-level diffing on `NSTextContentStorage` — block-bounded by construction.
2. **Visual regression via screenshot.** Deferred. Replaced by HTML-rendition proxy (render `Document` to HTML, diff strings).
3. **CommonMark regression.** Must hold ≥ current 80%+ at every phase. Target 90%+ as refactor completes.
4. **Parser improvements beyond the CommonMark target.**
5. **Accessibility overhaul as a dedicated phase** (user: skip Phase 5e). Native accessibility falls out of Phase 2 as a side effect since text-bearing content is now real content in `NSTextContentStorage`.
6. **iOS / mobile parity.**
7. **Abandoning `NSTextView` entirely for a stack-of-per-block-views architecture** (Notion/Obsidian Live-Preview model). That was considered and rejected — it would require re-implementing cursor navigation, selection, Find, scroll, copy/paste from scratch. TextKit 2 is the middle path: keep `NSTextView` semantics, make custom layout a first-class citizen.
8. **Performance optimization pass.** Measure, don't optimize, until numbers demand it.

If execution discovers we need to touch any of the above, we **stop and re-scope explicitly**, not quietly expand.

---

## Pre-flight spike (before Phase 0)

**Reframed.** The earlier question ("is `U+FFFC`/`NSTextAttachment` the right primitive?") has been answered during planning: no — TextKit 2's `NSTextElement` + `NSTextLayoutFragment` is the sanctioned AppKit mechanism for first-class per-block-type layout, and the `U+FFFC` placeholder is a TextKit 1 workaround we should replace.

This spike now **verifies the migration mechanics**, not the architectural choice.

**Scope:** 2–3 days. Read-only investigation + a prototype.

**Deliverables:** `PREFLIGHT.md` (temporary) answering each of:

1. **Deployment target.** What is FSNotes++'s current minimum macOS? `NSTextLayoutManager` requires macOS 12+; custom `NSTextLayoutFragment` subclasses are macOS 12+. If current target is lower, what is the cost of raising it? (Check user base implications with user if needed.)
2. **Prototype.** One real `NSTextElement` + `NSTextLayoutFragment` subclass implemented end-to-end for a single block type (simplest candidate: `HorizontalRuleElement` — no text content, fixed-height draw). Validates the toolchain works in this codebase and reveals surprises early.
3. **Table primitive choice (within TextKit 2).** Two sub-options, both use TextKit 2 but differ in how table cells are stored:
   - **T1. Cells as sub-elements.** `TableElement` contains child `TableCellElement`s, each holding cell text as real content in the content manager. Custom `TableLayoutFragment` positions each cell's glyph runs in its grid cell. Find/selection across cells work natively by walking the element tree.
   - **T2. Cells as text ranges in one element.** `TableElement` holds all cell text linearly; metadata (cell boundaries, row/col geometry) lives on attributes. Custom layout fragment reads metadata and lays out the text range as a grid.
   - Prototype picks one based on feasibility; other is noted for fallback.
4. **`NSTextFinder` behavior on TextKit 2 custom elements.** Verify it walks the content manager correctly (expected) and that our chosen element structure exposes searchable text as expected. This is the bug #60 verification.
5. **Migration ordering.** Validate that TextKit 2 can be adopted on an `NSTextView` instance in this codebase (check `NSTextView.textLayoutManager` property wiring) without a rewrite of the view hierarchy.

Downstream phase shapes depend on the spike's findings (particularly T1 vs T2 and the deployment-target question). **User approval of the spike conclusion is required before Phase 0 starts.**

---

## Phase 0 — Harness + invariants + HTML proxy

### Goal
Build enough test infrastructure to detect seam bugs before any production code changes.

### Work

**Layer 1: `EditorHarness`**
- Real `EditTextView` in offscreen `NSWindow`
- Scripted input API: `moveCursor(to:)`, `pressReturn`, `pressDelete`, `type(_:)`, `pressCmd(_:)` (B/I/F/S/X/V), `paste(markdown:)`, `clickAt(point:)`, `selectRange(_:)`
- Dispatches through **real** code paths (`insertNewline(_:)`, `insertText(_:)`, `performKeyEquivalent`) — no mocks
- Pumps `RunLoop.main` for async work; optional timeout per step
- Reads: `contentString` (full text per `NSTextContentManager`), `selectedRange`, `document`, `savedMarkdown`, `htmlRendition`

**Layer 2: Invariant library (also Layer 5)**
- `Invariants.check(harness)` → `[InvariantViolation]`
- Seed invariants:
  - `contentManager content == DocumentRenderer.render(document)` (content-manager-side equivalent of the storage invariant)
  - `selectedRange valid inside content manager`
  - Per-block: element at `blockIndex` matches block type and payload in `Document`
  - `.link` attribute at offset matches `Document` at that offset
  - CommonMark compliance of `MarkdownSerializer.serialize(document)` ≥ baseline
- New invariants added per bug-fix (monotonic ratchet)

**Layer 3: Round-trip corpus (`Tests/Corpus/`)**
- 10–15 markdown files covering paragraphs, headings, nested lists, tables (with formatting), code blocks (fenced + language), mermaid, math, wikilinks, tags, checkboxes, blockquotes, HR, large note (~50k chars)
- Standard battery per file:
  - `load → invariants.check → save → byte-identical` (for canonical files)
  - `load → random-walk 100 edits (seeded) → invariants.check → save → reload → document-equal`

**Layer 4 replacement: HTML-rendition proxy (per user)**
- New `DocumentHTMLRenderer.render(document) → String` — deterministic HTML serialization
- Reference HTML committed per corpus file
- Test: `load → render to HTML → diff vs reference` (strict string equality)
- Intentional rendering changes require explicit reference update (audit point)
- **This replaces screenshot-based visual regression** — cheap, deterministic, LLM-friendly

**Bug-driven tests**
- Every known live bug (#22, #35, #36, #39, #40, #41, #47, #60) becomes a harness test
- Must **FAIL** on current code — proves the harness detects real bugs before any fix lands
- Each bug-fix in later phases flips its test from FAIL to PASS

**Reuse of existing infrastructure**
- `makeFullPipelineEditor()` — absorbed into `EditorHarness.init`
- `runFullPipeline()` — absorbed into `EditorHarness.applyEdit`
- Existing Tests/CommonMark/ corpus — continues to run unchanged; compliance gate in invariant library

### Test migration strategy (per user ask)

Existing tests are categorized into four buckets. Full inventory is Phase 0 work (subagent exploration was rate-limited; scheduled as first Phase 0 task).

| Bucket | What | Action | Examples |
|---|---|---|---|
| **A. Keep pure** | Parser, serializer, CommonMark, InlineRenderer roundtrip | No change. Harness adds no value at this layer. | `CommonMarkComplianceTests`, `MarkdownParserTests`, `InlineRendererRoundtripTests` |
| **B. Augment** | `EditingOps` primitive tests asserting on `EditResult` | Add a companion harness test running the same edit live; same post-conditions asserted. Seam verification. | `BugFixes3Tests.test_bug41_returnThenDelete_mergeShape` → augment with `testHarness_bug41_returnThenDelete_live` |
| **C. Parameterize + migrate** | Groups of similar tests (e.g., "toggle bold on X selection in Y block") | Collapse into one parameterized harness test fed by a corpus matrix | `ToolbarFormattingTests` family |
| **D. Replace** | Tests that manually emulate live-editor state via pure-function orchestration (pump RunLoop, fake delegate, etc.) | Replace with real harness tests | Tests using raw `EditTextView` setup with ad-hoc field editor fakes |

Sequencing of test migration:
- **Phase 0:** categorize full test suite (inventory table) + build Bucket B companion tests for every bug-driven case
- **Phase 1:** Bucket B/C benefit automatically when contracts land (invariants fire in both pure + harness tests)
- **Phase 2 (TextKit 2):** `InlineTableView`-dependent tests (Bucket D) are replaced or deleted as the widget is removed
- **Phase 5:** Bucket D replacements complete once Document is sole source of truth
- **Phase 6:** prune dead pure helpers where harness version is canonical

**Corpus governance:**
- `Tests/Corpus/*.md` files. New block type or FSM transition requires adding a corpus file exercising it.
- Bug-driven: every user-reported bug becomes a corpus case if relevant.

### Exit criteria
- Harness runs headless in CI (or documented as local-only with reason)
- Layer 2 invariants + Layer 3 round-trip pass on corpus (minus files hitting known bugs)
- HTML-proxy references committed; diff on intentional changes
- Bug-driven tests FAIL on current code (proves harness works)
- Existing pure-function tests pass unchanged. Snapshot at 2026-04-22: 1,081 tests, 7 skipped, 3 pre-existing failures (bug #60 NSTextFinder, two CommonMark link/image edge cases). Downstream phases reference this snapshot and re-snapshot at each phase exit
- Existing test helpers (`makeFullPipelineEditor`, `runFullPipeline`) absorbed into harness or explicitly kept
- Test inventory table completed and committed

### Estimate
10–14 days.

### Rollback
Fully additive. No production code changed.

### Checkpoint
User reviews harness API, corpus selection, and inventory table.

---

## Phase 1 — FSM contracts (user item 4)

### Goal
Per user: *"We shouldn't only have cursor position as a pre & post transition assertion — include other relevant state/action (e.g. merge preceding & current block in the case where two adjacent numbered lists should now be consolidated). The state transitions should also specify specific actions taken."*

Every FSM/EditingOps transition declares its contract: preconditions, declared actions, postconditions (including cursor AND structural state), and explicit action list.

### Work

1. **Update `ARCHITECTURE.md`** (per user): formalize FSM specification, list every transition with its contract, cross-reference `EditingOps` primitives.

2. **Introduce `EditContract` struct:**
   ```
   EditContract {
     preConditions:  [Invariant]
     declaredActions: [Action]      // e.g., .deleteBlock(index), .mergeAdjacent(i, i+1), .renumberList(from: i), .splitInline(blockIndex, inlineIndex, offset)
     postConditions: [Invariant]
     cursor: DocumentCursor          // (blockPath: [Int], inlineOffset: Int)
   }
   ```

3. **Introduce `DocumentCursor`:** `(blockPath: [Int], inlineOffset: Int)`. Replaces raw `newCursorPosition: Int` in `EditResult`. Resolved to `NSTextLocation` (TextKit 2) at apply time via `cursor.toTextLocation(in:)`.

   **`inlineOffset` is defined as the UTF-16 offset into the block's rendered storage text, measured as `DocumentRenderer` emits it.** Not markdown source offset, not a depth-first walk of the inline tree. This is the same coordinate that `DocumentProjection.blockSpans[i].location` + `inlineOffset` yields today when a cursor lands inside a block. `cursor.storageIndex(for: projection)` is therefore the inverse of the renderer's offset emission. Nested inline (e.g. bold-inside-italic-inside-link) is already flattened by the renderer into a single run of storage characters, so the offset is unambiguous regardless of inline-tree depth.

   `blockPath` is `[Int]` to leave room for nested-block addressing (list items inside list items inside blockquotes). For flat top-level blocks, `blockPath == [blockIndex]`. Nested resolution is a Phase 2 concern once block hierarchy enters `Document.blocks`.

4. **Introduce `Action` enum:** enumerates structural changes a transition may perform:
   - `.insertBlock(at:)`, `.deleteBlock(at:)`, `.replaceBlock(at:)`
   - `.mergeAdjacent(firstIndex:)`
   - `.splitBlock(at: inlineIndex, offset:)`
   - `.renumberList(startIndex:)`, `.reindentList(range:)`
   - `.insertInline(blockIndex: inlineIndex:)`, etc.

5. **Retrofit every primitive and FSM:**
   - `newLineTransition` / `applyTransition` (Return FSM)
   - `ListEditingFSM` (indent, unindent, exit, newItem)
   - `EditingOps.insert` / `.delete` / `.replace` / `.splitBlock` / `.mergeAdjacentBlocks`
   - `EditingOps.toggleInlineTrait` / `.changeHeadingLevel` / `.toggleList` / `.toggleBlockquote` / `.insertHorizontalRule` / `.toggleTodoList` / `.toggleTodoCheckbox` / `.replaceTableCellInline`

6. **Harness integrates contracts:** Layer 5 invariants auto-check pre/post conditions after every harness edit. Bucket B/C tests benefit automatically.

### Exit criteria
- Every transition has explicit declared `Action` list + post-conditions (not only cursor)
- `ARCHITECTURE.md` updated with FSM contract reference and every transition documented
- Harness runs contracts as invariants
- Corpus tests pass with contracts enforced
- Bugs whose root cause is a mis-declared contract are fixed OR flagged as "blocked on Phase 2/5" (e.g., #41 if it's a layout-primitive bug not a pure-function bug)
- CommonMark compliance ≥ baseline

### Estimate
10–14 days.

### Rollback
Contracts are `#if DEBUG` assertions. Disable flag available. No release-behavior change.

### Checkpoint
User reviews `DocumentCursor` type, `Action` enum, ARCHITECTURE.md updates, and list of declared contracts before Phase 2.

### Open questions for Phase 2 kickoff

(These emerged from a 2026-04-22 review. Where a concern translated into
a plan change, the change is applied in the relevant section below and
a pointer is given here. The items left open are the ones that genuinely
need decisions before Phase 2 begins.)

- **Block identity for diffing**. The plan mentions "UUID or block index
  with generation counter" without picking. `Block` is currently a value
  enum — attaching stable IDs changes its memory model and serializer,
  but index-only identity shifts on every insert. **Decision needed
  before Phase 2**: (a) introduce `Block.id: UUID` at parse time and
  preserve it through `EditingOps` primitives, or (b) keep `Block` value-
  typed and use structural diff (Myers/patience) at element-sync time.
  Undo/redo journaling (Phase 5) and element diffing (Phase 3) both
  depend on this choice. Recording it here so the spike-for-Phase-2 has
  a concrete deliverable.

- **Harness coverage of tables / math / mermaid**. The HTML proxy built
  in Phase 0 can't represent these deterministically. Before Phase 2
  introduces `TableLayoutFragment`, the harness needs a structural diff
  path for tables (TableCell inline-tree equality) and raw-source
  equality for mermaid/math so table-seam and diagram bugs are catchable.
  ~~Small additive change, scoped into Phase 1 exit.~~ **Landed
  2026-04-22.** The coverage was already structurally in place through
  `Invariants.assertContract` and became explicit with the harness
  auto-assert wiring:

  - **Tables.** `.replaceTableCell` carries a per-cell structural diff
    at `Tests/Invariants.swift:266–368`: header/row counts, alignments,
    and every cell NOT equal to the declared `(row, col)` sentinel
    (row = −1 for header) are asserted byte-identical. Direct primitive
    tests cover this (`test_replaceTableCellInline_*` in
    `Tests/EditContractTests.swift`), including two negative-control
    tests that verify a lying `.replaceTableCell` contract (e.g. a
    primitive that silently wipes a second cell while editing the
    declared one) is caught. The harness-level path is covered by
    `HarnessContractCoverageTests.test_harness_replaceTableCellInline_contractPropagates`
    — it drives the primitive against the harness-owned live projection
    to prove the contract propagates end-to-end through the same
    `EditTextView.applyEditResultWithUndo` path the app uses.
  - **Mermaid / math.** Both render to `Block.codeBlock(language: "mermaid"
    | "math", content: …)`, and the `Block` enum equality is structural.
    The size-preserving neighbor-preservation check
    (`Invariants.swift:248–264`) therefore asserts bit-equality on every
    block NOT declared touched by the contract — any primitive that
    accidentally re-renders a mermaid/math codeBlock (e.g. stripping the
    language field) while editing a neighbour would be caught. Typing /
    backspace / Return inside mermaid and math code blocks route through
    the default `insertIntoBlock` / `delete` paths, which emit
    `.modifyInline(blockIndex: …)` — the harness auto-assert in
    `EditorHarness.assertLastContract` fires automatically on every
    such edit. `HarnessContractCoverageTests` adds three end-to-end
    driver tests (`test_harness_type_inMermaidCodeBlock_*`,
    `test_harness_backspace_inMermaidCodeBlock_*`,
    `test_harness_type_inMathCodeBlock_*`) that type / backspace inside
    mermaid and math blocks, then independently assert the language
    field survives and every neighbour block is `==` to its pre-edit
    counterpart. 4 new tests total.

  No structural HTML-proxy diff was required because the contract-layer
  invariants already catch the class of bug the concern pointed at — a
  primitive that silently modifies a mermaid/math/table block outside
  its declared scope. The HTML proxy's non-determinism for these block
  types would have weakened its utility as a seam-bug detector in this
  area, but the contract invariants are byte-exact, so the coverage is
  actually stronger.

- **`NSTextFinder` behaviour across custom layout fragments** (bug #60,
  Phase 5c). The plan assumes Find "works natively" on custom elements.
  ~~Not verified.~~ **Verified at Phase 1 exit** (2026-04-22) via
  `Tests/TextKit2FinderSpikeTests.swift` — 4 passing spike tests
  confirming:
  1. `NSTextView` can adopt TextKit 2 (`NSTextLayoutManager` +
     `NSTextContentStorage`) on the current deployment target. `textLayoutManager`
     is non-nil; `usesFindBar = true` sticks. Phase 2a migration is
     viable.
  2. Arbitrary text in `NSTextContentStorage` is reachable through
     `textView.textStorage.string` — the same surface `NSTextFinder`
     walks on `NSTextView` and the surface bug #60's harness asserts
     on. Moving cell text into content storage (Phase 2e) resolves
     bug #60 by construction.
  3. A custom `NSTextLayoutFragment` installed over a range via
     `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)`
     does NOT alter `textStorage.string` — Find is driven by content,
     not layout. T2 (cells-as-ranges) cell layout can be customised
     freely without breaking Find.
  4. **Empirical surprise:** `NSTextView` does NOT formally adopt
     `NSTextFinderClient` in Swift (`as? NSTextFinderClient` returns
     nil). Cmd+F works via an internal AppKit helper that proxies
     `textStorage.string`. This is fine — it just means any test or
     assertion about Find must go through `textStorage.string`, not
     through a typed `NSTextFinderClient` reference. Record this so
     Phase 5c implementors don't waste time trying to override the
     protocol.

  **Conclusion:** Phase 5c stays thin. The Mermaid case is not
  separately spiked — same mechanism as tables: if the fragment
  renders over real content-storage text, Find walks it. Phase 2e
  must keep cell text as live characters in `NSTextContentStorage`
  (not as attachments whose `cellSize()` draws the text). That
  invariant is asserted in the negative-control spike test (attachment
  approach hides text from Find).

- **IME / composition state** — landed in Phase 5 as sub-phase 5e, see
  below.
- **Undo/redo** — landed in Phase 5 as sub-phase 5f, see below.
- **Phase 2 sub-phase split for tables** — landed as Phase 2e, see below.
- **`DocumentCursor.inlineOffset` definition** — landed in Phase 1 Work
  section, see below.
- **Phase 2 / Phase 4 estimate realism** — revised in each phase's
  Estimate section below.
- **Phase 4 "zero `NSLayoutManager` references" wording** — revised in
  Phase 4's Exit criteria below.

The reviewer also raised concerns about Phase 0 scope and the Pre-flight
spike estimate. Those phases are complete, so those critiques are
recorded here for history only and do not drive new work.

---

## Phase 2 — TextKit 2 migration (primitive change)

### Goal
Adopt `NSTextLayoutManager` + `NSTextContentStorage` + per-block `NSTextElement` + `NSTextLayoutFragment` across the editor. Each block type becomes a first-class text element with its own layout fragment. `U+FFFC` + `NSTextAttachment` exits the codebase as the mechanism for block-level content.

### Why this phase here (after contracts, before narrowSplice and source-mode removal)
Every residual seam bug class (#60 Find, selection across attachments, attribute-diff in narrowSplice, widget-state tangles) traces to `NSTextAttachment` being the layout primitive for structurally-non-linear content. `NSTextElement` + `NSTextLayoutFragment` is AppKit's sanctioned answer to "I have a custom-layout region in a text editor." Addressing the primitive before Phases 3–5 makes those phases strictly simpler: narrowSplice becomes element-level diffing (Phase 3 shrinks), Find is native (Phase 5c shrinks to near-zero), and "demote `NSTextStorage`" becomes "Document drives `NSTextContentStorage`" — a cleaner bridge.

### Sub-phases

Sub-phases 2a–2d cover every block type **except tables**. Tables are a separate sub-phase (2e) because `TableLayoutFragment` is the single biggest engineering item in the phase and deleting the table attachment path depends on it landing. 2a–2d must NOT touch the table attachment path; `InlineTableView` + the `U+FFFC` table attachment stay live until 2e ships.

**2a. Adopt TextKit 2 on `EditTextView` — ✅ LANDED (2026-04-22)**
- Construct `EditTextView`'s text system with `NSTextLayoutManager` + `NSTextContentStorage`
- `NSTextView` exposes `textLayoutManager` property; set on init
- Implement `NSTextContentStorageDelegate` methods we depend on: `textContentStorage(_:textParagraphWith:)` for element substitution, location-validation hooks, and `performEditingTransaction` wrapping for batched edits — this is the surface through which `DocumentRenderer` will feed custom elements in 2b
- Keep existing text content (paragraphs only, no custom blocks yet) rendering correctly with default `NSTextParagraph` elements
- All current editing (typing, selection, Find, scroll, copy/paste) continues to work on pure-text notes
- **Ship alone.** Validates the TextKit 2 adoption doesn't regress the baseline before we touch block renderers.

**2a. Landing notes** — what actually shipped:

1. **Adoption happens at construction, not via `replaceTextContainer`.** `NSTextView` fixes its TextKit version when the initial `NSTextContainer` is attached. A post-hoc `replaceTextContainer(_:)` with a TK2-bound container does NOT flip an already-TK1 view — verified empirically. We therefore override:
   - `init(frame:)` — builds a TK2-bound container via `makeTextKit2Container(size:)` and forwards to `super.init(frame:textContainer:)`.
   - `init(frame:textContainer:)` — explicit-container pass-through (respects caller intent; used by test helpers that hand us a custom container).
   - `init?(coder:)` — plain pass-through to `super.init(coder:)`. **No in-place flip attempted.** An earlier attempt (`adoptTextKit2PostDecode()`) detached the TK1 layout manager from the nib-decoded view and called `replaceTextContainer(_:)` with a TK2-bound container, but the view stayed on TK1 while `textStorage` went nil — crashing every force-unwrap call site (first seen: `TextFormatter.init` at line 53 force-unwrapping `textView.textStorage!`).
2. **Storyboard path uses programmatic instance swap.** Because in-place flip isn't possible, `EditTextView.migrateNibEditorToTextKit2(oldEditor:scrollView:)` constructs a fresh `EditTextView(frame:)` (TK2 via the `init(frame:)` override above), mirrors the nib-configured knobs (`autoresizingMask`, `isEditable`, `isSelectable`, `isRichText`, resize flags, `min/maxSize`, `textContainerInset`, `isVertically/HorizontallyResizable`, automatic-substitution flags, undo flag, container `widthTracksTextView` / `heightTracksTextView` / `lineFragmentPadding` / `size` with a 1e7 height floor so vertical growth isn't capped), and re-points `scrollView.documentView` to the new instance. Callers reassign their `editor` outlet to the return value. Wired in `ViewController+Setup.configureLayout()` (before `editor.configure()`) and `NoteViewController.initWindow()` (before `editor.initTextStorage()`). The weak outlet in `NoteViewController` stays live because the scroll view's strong `documentView` retains the new editor.
3. **AppKit silent-fallback pitfall.** Reading `NSTextView.layoutManager` on a TK2-wired view causes AppKit to lazily instantiate a TK1 `NSLayoutManager` compatibility shim, and `self.textLayoutManager` PERMANENTLY becomes `nil` — a silent fallback with no API to detect. Every `layoutManager` access in the hot path (edit, layout invalidation, configure, image attachment hit-test, inline-tag drawing, gutter cursor tracking, scroll-position save/restore, cursor hover, click hit-test) tore down TK2 on the very first keystroke or mouse-move, which is why naive adoption appeared to work in init but collapsed under typing.
4. **Single-point fix: `layoutManagerIfTK1` accessor.** New computed property on `EditTextView`:
   ```swift
   var layoutManagerIfTK1: NSLayoutManager? {
       return textLayoutManager == nil ? layoutManager : nil
   }
   ```
   Evaluation order matters: the `textLayoutManager` check happens first (safe), and `layoutManager` is only read when we're already on TK1. Routed through this accessor: `GutterController.swift` (4 sites), `EditTextView+Interaction.swift` (5 sites — mouseMoved, cursor hover, handleRenderedBlockClick, handleTodo, handleClick), `EditorViewController+ScrollPosition.swift` (2 sites — restoreScrollPosition, scrollViewDidScroll), `ImageAttachmentHydrator.swift` (2 sites — inline-image layout invalidation), `TableRenderController.swift` (2 sites — focusFirstInlineTableCell, reflowTablesForWidthChange), `InlineTableView.invalidateAttachmentLayout` (1), `PDFExporter.export` (1 — usedRect measurement; TK2 falls back to dataWithPDF default rect), `EditTextView+Appearance.drawInsertionPoint` (1 — caret height tweak), `EditTextView+EditorDelegate.editorLayoutManager` (1 — protocol accessor returning `layoutManagerIfTK1`), `NoteViewController.textViewDidChangeSelection` (1), `ViewController+Events.textViewDidChangeSelection` (1). The three remaining direct `self.layoutManager` reads in `EditTextView+BlockModel.swift` are all gated by `if textLayoutManager == nil, let lm = self.layoutManager` (block-model edit path — TK1 paragraph-style sync code inside a larger guard). **Grep discipline:** `self.layoutManager` / `textView.layoutManager` / `editor.layoutManager` outside `layoutManagerIfTK1`'s own body is a code-smell; audit comment on the helper points future editors at the grep.
5. **Baseline tests:** `Tests/TextKit2BaselineTests.swift` (8 tests) covers TK2 adoption via `init(frame:)`, paragraph round-trip through the content storage's bridged `textStorage`, direct storage mutation preserving TK2, `handleEditViaBlockModel` preserving TK2, typing through the full `EditorHarness` pipeline preserving TK2, TK1-stand-in baseline (editor built with `init(frame:textContainer:)` + a TK1 container stays TK1 — baseline for the storyboard repro), and two storyboard-path tests: migration adopts TK2 while keeping `textStorage` live, and the migrated editor survives the `TextFormatter.init` force-unwrap call pattern that crashed the app on 2026-04-22. All 8 pass.
6. **Test suite status:** 1126 / 1126 executed, 7 skipped, 3 failures. Of the 3: (a) `test_bug60_findAcrossTableCells` is a pre-documented 2a-accepted regression (expected to FAIL until 2e — table cell text is still inside `NSTextAttachment`); (b) `test_images` (CommonMark 21/22) and `test_links` (CommonMark 75/90) are pre-existing branch regressions in the pure `MarkdownParser → CommonMarkHTMLRenderer` path — neither test references `EditTextView` / `NSLayoutManager` / `NSTextLayoutManager`.
7. **Phase 2f targets — features currently broken under TK2 (visual only, not correctness).** These are carried by Phase 2f ("TK2 visual-feature restoration") below, not silently absorbed. The custom `LayoutManager.drawBackground` visuals (bullet dots, blockquote left-border, horizontal-rule line, kbd key boxes, inline-tag chip backgrounds) are 2c/2d's territory — folded into the per-block `NSTextLayoutFragment` draws there and not repeated in 2f. The remaining items that do NOT have a home in 2b–2e are scoped into Phase 2f: header-fold display, gutter (fold carets / H-level badges / copy icons), link-hover cursor, scroll-position save/restore, inline-image drag-resize bound updates, and PDF export used-rect measurement. Inline-tag text still renders correctly today (as attributed characters); only the rounded chip background is suppressed, and that restoration is in scope for 2c alongside the other `AttributeDrawer`-derived draws. Block-model rendered attachments (code/mermaid/math/tables) still display but may have layout quirks until `NSTextLayoutFragment` overrides land in 2c/2d. User-verified working on 2026-04-22: typing, selection, Find, copy/paste, save, switch notes, scroll on long notes.

**2b. Custom `NSTextElement` subclasses per block type (non-table)**
- Block types map to element subclasses via a dispatch in `DocumentRenderer`:
  - `ParagraphElement` (`NSTextParagraph`-based, standard flow)
  - `HeadingElement` (paragraph with heading font attributes)
  - `ListItemElement` (paragraph with list-marker metadata — drawn by layout fragment margin)
  - `BlockquoteElement` (paragraph with blockquote-border metadata — drawn by layout fragment margin)
  - `CodeBlockElement` (paragraph with mono-font + syntax-highlight attributes; no attachment)
  - `HorizontalRuleElement` (custom, minimal content + fixed-height fragment)
  - `MermaidElement` / `MathElement` (custom, source text as element content so Find works; rendered bitmap in layout fragment)
- `TableElement` is deferred to 2e.

**2c. Custom `NSTextLayoutFragment` subclasses per block type (non-table)**
- Text-flow elements (paragraph, heading, list item, blockquote) can reuse the default fragment with attribute-driven rendering plus margin drawing for bullets / borders (pattern we already have in `AttributeDrawer`, ported to fragment-level draw)
- Structurally-different elements get custom fragments:
  - `MermaidLayoutFragment` / `MathLayoutFragment`: reserves bitmap size, draws rendered image over source text (source text hidden visually via the layout fragment but remains searchable in content manager)
  - `HRLayoutFragment`: fixed minimal height, draws horizontal line
  - `CodeBlockLayoutFragment`: standard text flow; may add gutter/background draw
- `TableLayoutFragment` is deferred to 2e.

**2d. Remove `U+FFFC` + `NSTextAttachment` for non-table block-level content** — **Shipped 2026-04-22**
- Delete `BlockRenderer.swift` attachment paths for mermaid/math/code; replace with fragment-based renderers. Keep the `MPreview.bundle` + WebView rendering pipeline internal to `MermaidLayoutFragment` / `MathLayoutFragment` (they still need WebView to produce the bitmap; they just don't stuff the result into an `NSTextAttachment`).
- Delete HR attachment; replace with `HorizontalRuleElement` + `HRLayoutFragment`
- **Tables are out of scope here.** `InlineTableView` and the table `U+FFFC` attachment stay in the tree — they are 2e's responsibility. Grep verification for 2d is "zero `NSTextAttachment` references in block renderers **except tables**."
- `NSTextAttachment` retained only for genuinely inline-image content (pasted/embedded images in paragraphs), if the codebase supports that today

**2d. Revised grep gate (view-provider reinterpretation).** As 2d landed, the gate language "zero `NSTextAttachment` references in block renderers except tables" was too strict: Apple's TK2 pattern for view-hosted attachments (PDFs, QuickLook previews, inline images) is `NSTextAttachment` + `NSTextAttachmentViewProvider`, NOT a custom `NSTextLayoutFragment`. Deleting those `NSTextAttachment` subclasses would have broken the TK2 view-hosting contract. Revised wording:

> **Phase 2d grep gate (revised):** zero `NSTextAttachmentCell`-only block renderers. Every block-level attachment must either (a) render via a custom `NSTextLayoutFragment`, or (b) vend an `NSTextAttachmentViewProvider` under TK2 (the cell may remain as TK1 fallback). Tables are the sole exception — their cell-only render path is deferred to Phase 2e.

**2d. Shipped — what landed and via which mechanism:**

| Block type | Mechanism | Notes |
|---|---|---|
| Mermaid fenced code | `MermaidLayoutFragment` + `BlockSourceTextAttachment` (landed 2026-04-23) | WebView renders bitmap; fragment draws it. Storage contains a single `U+FFFC` attachment character per block — `CodeBlockRenderer.render` emits `NSAttributedString(attachment: BlockSourceTextAttachment())` for `mermaid/math/latex` rather than the source text verbatim. `DocumentRenderer` tags the attachment's one-character range with `.renderedBlockSource` carrying the full multi-line source. Fragment reads the attribute to recover source before handing to `BlockRenderer`. The attachment's `viewProvider(...)` returns `nil` so TK2 paints no default placeholder; the fragment owns all drawing. Keeps the whole block as one `NSTextContentStorage` paragraph regardless of how many source lines it contains — without this, `\n`-on-paragraph-boundary semantics split the block into one element per line, each submitting a single line to MermaidJS (which rejects every call because one line isn't a valid diagram). Trade-off: Find-in-note cannot match text inside mermaid source — source lives on an attribute, not the paragraph string. Fragment overrides `layoutFragmentFrame` to `max(base.height, bitmapHeight)` so TK2 reserves enough vertical space for the bitmap — without this override the one-character-tall default frame would cause the bitmap to overlap the fragments below (confirmed regression 2026-04-23 when `BlockSourceTextAttachment` replaced source-in-storage). (The earlier U+2028 substitution approach was reverted 2026-04-23 in favour of this cleaner path — one character in storage, no cross-reader converter contract to maintain.) |
| Math fenced code | `MathLayoutFragment` + `BlockSourceTextAttachment` (landed 2026-04-23) | Same pattern as mermaid, same `layoutFragmentFrame` override. MathJax receives real `\n` between `\begin{…}` / `\end{…}` lines via `.renderedBlockSource`. |
| Horizontal rule | `HorizontalRuleLayoutFragment` | Fixed-height fragment, no attachment |
| Kbd inline tag | `KbdBoxParagraphLayoutFragment` | Paragraph-level fragment (`.paragraphWithKbd` element kind) draws rounded chip behind tagged runs |
| Code block background | `CodeBlockLayoutFragment` | Draws gutter + background; text flows standard |
| Display math (single-inline paragraphs) | `DisplayMathLayoutFragment` | Paragraphs containing ONLY a `.displayMath` inline route here |
| Display math (mixed-content paragraphs) | `NSTextAttachment` + `CenteredImageCell` (wired 2026-04-23) | Paragraphs with display math PLUS other content render the bitmap via `renderDisplayMathViaBlockModel()`, gated by the paragraph's `.blockModelKind` so it never collides with the single-inline fragment path |
| PDF attachments | `PDFNSTextAttachment` + `PDFAttachmentViewProvider` | TK2 view-provider pattern; `PDFAttachmentCell` kept as TK1 fallback dead code (Phase 4 cleanup) |
| QuickLook previews | `QuickLookNSTextAttachment` + `QuickLookAttachmentViewProvider` | Same pattern; `QuickLookAttachmentCell` kept for Phase 4 cleanup |
| Inline images | `ImageNSTextAttachment` + `ImageAttachmentViewProvider` | Within-paragraph, view-provider pattern |
| List bullets | `BulletTextAttachment` (+ `BulletAttachmentCell` TK1 + `BulletAttachmentViewProvider` TK2) | Dual-path: U+FFFC attachment retained for TK1 compat, view provider added for TK2 |
| Checkboxes | `CheckboxTextAttachment` (+ `CheckboxAttachmentCell` TK1 + `CheckboxAttachmentViewProvider` TK2) | Same dual-path as bullets |
| Tables | `TableBlockAttachment` + `TableAttachmentViewProvider` (TK2) + `InlineTableAttachmentCell` (TK1 fallback) | **Phase 2e T1-path shipped** 2026-04-22 — `InlineTableView` hosted via view provider under TK2, via cell draw under TK1. T2 (native content-storage cells) deferred as optional future slice. |

**2d grep-gate audit result (2026-04-22):** zero violations. Every `NSTextAttachment` reference in `FSNotesCore/Rendering/**` and `FSNotes/Helpers/{InlinePDFView,InlineQuickLookView,InlineImageView}.swift` is either (a) tables (Phase 2e), (b) a view-provider-vending attachment, (c) inline image content, (d) infrastructure (attachment-equality helpers in `EditingPrimitives.swift`), or (e) comments/documentation referencing the old path. Legacy TK1 cell classes `PDFAttachmentCell` and `QuickLookAttachmentCell` remain referenced by hydration skip-checks (`InlineQuickLookView.swift:322-323`) and by dispatch-correctness tests (`Tests/TextKit2FragmentDispatchTests.swift`); both carry "Phase 4 cleanup" comments and are safe to leave.

**2d follow-ups — status:**
- ~~Display math on mixed-content paragraphs still uses the legacy attachment path. Single-inline display math paragraphs migrated cleanly; the mixed case needs a paragraph-fragment-internal display-math layout primitive or an inline-equivalent fragment. Carried forward as a late-2e or 2f item.~~ **Shipped 2026-04-23.** `renderDisplayMathViaBlockModel()` (an `ImageAttachmentHydrator`-style post-fill scan) is now wired back into `renderSpecialBlocksViaBlockModel` and renders mixed-content paragraphs via `CenteredImageCell`. The hydrator is gated by `.blockModelKind`: ranges inside a single-inline-displayMath paragraph (tagged `.blockModelKind = .displayMath`) are skipped, so `DisplayMathLayoutFragment` still owns the single-inline path and the two never collide. A clean inline-equivalent fragment primitive was considered and passed on — the attachment path is the Phase 2d-sanctioned pattern for hosted content and `CenteredImageCell` already gives us the container-wide centering behaviour display math wants. Tests added: `test_phase2d_followup_mixedContentDisplayMath_tagsAsParagraphKind` and `test_phase2d_followup_singleInlineDisplayMath_isFilteredByKind` pin both sides of the `.blockModelKind` discriminator the filter relies on.

**2e. Shipped (T1 path — view provider) — 2026-04-22.**

Scope-reduction. The original 2e scope (`TableElement` + `TableLayoutFragment` + delete `InlineTableView`) — the "T2 path" making cell content native first-class `NSTextElement`s inside `NSTextContentStorage` — was the single largest engineering item in the phase (15–25 days). A pragmatic alternative emerged from the Phase 2d view-provider pattern: give `TableBlockAttachment` an `NSTextAttachmentViewProvider` so TK2 hosts the existing `InlineTableView` widget, mirroring exactly what PDFs, QuickLook previews, inline images, and bullet/checkbox list markers now do. Zero user-facing regression; `InlineTableView`'s editing UI is already full-featured and ships with 820+ passing unit tests. Ship the T1 path now; preserve T2 as an optional future slice.

**What landed:**
- `TableAttachmentHosting` protocol extended with `hostedView: NSView` — the app's `InlineTableAttachmentCell` exposes its `InlineTableView` through it, keeping the app/core module boundary clean.
- `TableBlockAttachment.liveHostedView: NSView?` — weak pointer the app-side `TableRenderController.renderTables()` sets alongside `attachmentCell`. `NSTextAttachmentViewProvider.textAttachment` is weak, so the provider needs a direct handle to the widget that survives short construction-window lifetimes.
- `TableBlockAttachment.viewProvider(for:location:textContainer:)` override, gated on `textContainer?.textLayoutManager != nil` — returns `nil` under TK1 so `NSLayoutManager` keeps driving the existing `InlineTableAttachmentCell.draw(...)` subview-install path. Returns a `TableAttachmentViewProvider` under TK2.
- `TableAttachmentViewProvider: NSTextAttachmentViewProvider` — `loadView()` resolves the widget in preference order (`liveHostedView` → `attachmentCell as TableAttachmentHosting` → `super.loadView()` fallback), sizes its frame to `attachment.bounds`, and hands it to TK2 as `self.view`.
- Three new tests in `Tests/TextKit2FragmentDispatchTests.swift` — pins the class of the vended provider, pins nil-under-TK1, pins that `loadView()` installs the same `InlineTableView` instance with its frame matching `attachment.bounds.size`.

**What stayed:**
- `InlineTableView` — full editing UI unchanged. Under TK2 it's hosted via the provider; under TK1 it's still hosted via `InlineTableAttachmentCell.draw(...)`.
- `InlineTableAttachmentCell` — required for TK1 and still the data-carrier for TK2 (the view provider reads its `hostedView` as a fallback when `liveHostedView` is nil).
- `BlockRenderer.swift` table path — per plan's fallback posture, left intact.

**What's deferred to T2 (optional future slice):**
- Native cell text in `NSTextContentStorage`. T2 would resolve Bug #60 (Find across tables) "by construction" because `NSTextFinder` would walk cell text natively. Today, Find-across-tables stays broken under T1 — same as it is under TK1. This is a known, isolated cost.
- Deletion of `InlineTableView` itself. T1 ships with the widget intact; T2 would delete it once `TableLayoutFragment` owns grid geometry and cell-internal text layout.

**T2 trigger conditions:** if the user reports table-specific bugs that can't be fixed inside `InlineTableView`'s widget state (e.g. Find support, accessibility navigation through cells, copy/paste selection across cells), T2 becomes the resolution path. Until then, T1 is the ship state.

**T2 triggered by user decision 2026-04-23.** Option A selected (complete T2 before Phase 4) over Option B (ship Phase 4 with tables as a half-win). Revised slice plan below produced by a design spike the same day; revised estimate: **9–13 days** (down from 15–25 in the original plan) because `TableCell { inline: [Inline] }`, `replaceTableCellInline`, `InlineRenderer.inlineTreeFromAttributedString`, and `DocumentEditApplier` all shipped in earlier phases. Storage shape: ONE `NSTextElement` per table, cells delimited by U+001F (UNIT SEPARATOR) within rows and U+001E (RECORD SEPARATOR) between rows. Bug #60 resolves "by construction" because native cell text is searchable by `NSTextFinder`.

**T2 slice status:**
- **T2-a — Foundation types (additive skeleton)** — ✅ SHIPPED 2026-04-23 (commit `f308894`). `TableElement` / `TableLayoutFragment` / `TableGeometry` added, no dispatch path constructs them yet. `TableGeometry` is a pure-function port of the widget's geometry code (15 tests). Dead code on disk until T2-b wires it in.
- **T2-b — `TableElement` emission behind feature flag `FeatureFlag.nativeTableElements` (default OFF)** — ✅ SHIPPED 2026-04-23 (commit `523363f`). `TableTextRenderer` dispatches on the flag; flag-off = legacy U+FFFC attachment path (byte-identical). Flag-on = flat separator-encoded cell text with `.blockModelKind = .table`, `.tableHeader = true` on header cells. Content-storage delegate returns `TableElement`; layout-manager delegate routes to `TableLayoutFragment` (still a draw stub — T2-c). With flag on, `test_phase2eT2b_flagOn_bug60_findAcrossTableCells` PASSES. Flag default stays OFF until T2-c/d/e make the element visually + editorially useful.
- **T2-c — `TableLayoutFragment` grid rendering (read-only)** — PENDING.
- **T2-d — Cursor + keyboard navigation inside the grid** — PENDING.
- **T2-e — Cell text editing via `replaceTableCellInline`** — PENDING.
- **T2-f — Find + selection verification (flag flipped on in tests, Bug #60 default PASS)** — PENDING.
- **T2-g — Hover + context menus + drag-reorder** — PENDING.
- **T2-h — Widget deletion + flag removal (~2,800 LoC deleted)** — PENDING.

### What this phase provides "for free"
- **Bug #60 (Find across tables) resolved by construction** — table cell text is now real content in `NSTextContentStorage`. `NSTextFinder` walks it natively.
- **Selection across tables / code blocks / etc. works natively.**
- **Accessibility of text-bearing elements** falls out — `NSAccessibility` walks content manager content. Phase 5e stays skipped because the problem is largely dissolved.
- **Widget-state bugs (`InlineTableView` class)** dissolve — no widget, no state tangle to fight.

### Exit criteria
- `EditTextView` uses `NSTextLayoutManager` + `NSTextContentStorage` exclusively
- Each block type has its `NSTextElement` + `NSTextLayoutFragment` pair (or reuses the default for plain text flow)
- Corpus round-trip passes
- Bug #60 passes in harness (from FAIL to PASS)
- Bugs #35, #36 (attribute consistency) pass in harness — attachment-free content means the attribute-diff problem reshapes
- No `NSTextAttachmentCell`-only block renderers for non-table content. Every block-level attachment either renders via a custom `NSTextLayoutFragment` or vends an `NSTextAttachmentViewProvider` under TK2 (the cell may remain as TK1 fallback). Tables remain on the cell-only path pending 2e; the full block-level attachment deletion for tables lands in 2e.
- Perf regression < 25% on corpus round-trip (TextKit 2 is generally faster; this is a ceiling, not a target)
- CommonMark compliance ≥ 80%
- Manual dogfood on real notes: mermaid, math, tables all render and edit

### Estimate
45–70 days. **Highest-risk phase.** AppKit TextKit 2 migration is documented but has surface-area surprises across 7+ custom `NSTextElement` / `NSTextLayoutFragment` subclasses, content-storage delegate wiring, and attachment-path removal in a ~1,100-symbol codebase. Per-sub-phase breakdown:

- **2a** (TextKit 2 baseline on `EditTextView`, content-storage delegate, paragraph-only rendering): 5–8 days
- **2b** (non-table `NSTextElement` subclasses: paragraph, heading, list item, blockquote, code block, HR, mermaid, math): 10–15 days
- **2c** (non-table `NSTextLayoutFragment` subclasses + `AttributeDrawer` port to fragment-level draw): 8–12 days
- **2d** (non-table attachment-path deletion + grep verification): 7–10 days
- **2e** (`TableElement` + `TableLayoutFragment` + `InlineTableView` deletion + Find/selection/a11y verification): 15–25 days

These add to the 45–70 day range. 2e alone is the single biggest engineering item in the plan; its width reflects T1-vs-T2 uncertainty coming out of the spike and the cross-cutting verification (Find, selection, accessibility, copy/paste inside cells) that only tables exercise.

### Rollback
Per sub-phase.
- **2a** (baseline TextKit 2 on paragraphs only) is shippable alone if rest halts — net zero-to-slight improvement, foundation for later.
- **2b/2c** per non-table block type can land independently.
- **2d** is the non-table "delete the old primitive" cleanup; requires 2b+2c complete for each non-table block type before deleting its attachment path.
- **2e** is the table cutover. If it blocks, 2a–2d remain shipped and tables stay on `InlineTableView` + `U+FFFC` as a known, isolated half-win. This is the explicit fallback — it is the *only* way the table attachment path survives past this phase.

### Checkpoint
User reviews after 2a (TextKit 2 baseline), after each non-table block-type sub-phase completes, before 2d deletion pass, and as a dedicated checkpoint before and after 2e (table cutover).

---

### Phase 2f. TK2 visual-feature restoration

**Goal:** restore features that relied on TK1-specific drawing paths (`NSLayoutManager.drawBackground`, glyph-based hit-testing, glyph-range geometry). Each item is independently scoped and landable on top of 2a–2d; none are gated on 2e. Separated from 2b/2c because these are editor-chrome features (gutter overlay, cursor feedback, scroll math, PDF export) rather than per-block element/fragment subclasses, and they want their own checkpoint so their cost and risk don't hide inside the already-heavy 2c/2d work.

**Why not rolled into 2c/2d.** The 2c pattern ("port `AttributeDrawer` margin drawing into fragment-level draw") cleanly covers per-block chrome (bullets, blockquote border, HR line, kbd boxes, inline-tag chip). It does NOT cover cross-block chrome (the gutter overlay, which reads multiple fragments' frames to decide icon positions), hit-testing surfaces (link hover, scroll restore), or export-time geometry (PDF used-rect). Rolling those into 2c would bloat it. 2f is the home for that residue.

**Scope (prioritized by user impact):**

- **2f.1 — Header folding display — ✅ SHIPPED (landed in commit 0cb1ea3; tests verified 2026-04-23)**
  - `FSNotesCore/Rendering/Fragments/FoldedLayoutFragment.swift` — pairs with `FoldedElement`. Overrides `layoutFragmentFrame` to zero height, `renderingSurfaceBounds` to empty, `draw(at:in:)` as a no-op. Source characters stay in `NSTextContentStorage` so selection / Find / serialization continue to work; only visual rendering collapses.
  - Fold toggle invalidation: `TextStorageProcessor.toggleFold` mutates the `.foldedContent` attribute inside a `beginEditing` / `endEditing` pair; `NSTextContentStorage` observes the `.editedAttributes` mask and invalidates affected fragments, which re-dispatch through the layout-manager delegate to `FoldedLayoutFragment` (folded) vs. the normal block-model fragments (unfolded).
  - Tests in `Tests/TextKit2FragmentDispatchTests.swift`: `test_phase2f_foldedElement_dispatchesToFoldedLayoutFragment` (element → fragment dispatch), plus zero-geometry + layout-stack contracts at lines 1283+ and 1340+. Pass.

- **2f.2 — Gutter re-implementation — ✅ SHIPPED (landed in commit 0cb1ea3; tests verified 2026-04-23)**
  - `FSNotes/GutterController.swift` gets TK2 fragment-enumeration paths starting line ~349 ("MARK: - TextKit 2 Gutter Support (Phase 2f.2)"). The TK2 path enumerates visible fragments via `NSTextLayoutManager.enumerateTextLayoutFragments` at three call sites (draw / hit-test / badge-layout), inspects element type (`HeadingElement` / `CodeBlockElement` / `TableElement`), and places icons at `layoutFragmentFrame.origin.y`. TK1 branch retained for the non-TK2 editor builds.
  - Tests in `Tests/GutterOverlayTests.swift`: `test_phase2f2_gutterFindsHeadingFragmentsUnderTK2`, `test_phase2f2_gutterClickOnCaret_togglesFold`, `test_phase2f2_gutterFindsCodeBlockFragmentsUnderTK2`, `test_phase2f2_gutterRendersHBadges_whenHovered`. All pass.

- **2f.3 — Link-hover cursor — ✅ SHIPPED (landed in commit 0cb1ea3; test verified 2026-04-23)**
  - TK2 hit-test implemented in `FSNotes/View/EditTextView+Interaction.swift` via `characterIndexTK2(at:)` helper (lines 279–301) using `NSTextLayoutManager.textLayoutFragment(for:)` → `textLineFragments.first(where: typographicBounds.contains)` → `NSTextLineFragment.characterIndex(for:)` → `NSTextContentStorage.offset(from:to:)`. Both `mouseMoved` (lines 160–267) and `updateCursorForMouse(at:)` / `flagsChanged` (lines 311–381) have TK1 branch + TK2 fallback.
  - Test: `Tests/LinkHoverTests.swift` — `test_phase2f3_characterIndexTK2_resolvesPointToLinkAttribute` renders a markdown link, resolves a point inside its typographic bounds via the pure helper, and asserts `.link` attribute is non-nil at the resolved index. Passes.

- **2f.4 — Scroll-position save/restore — ✅ SHIPPED (landed 2026-04-23)**
  - Sub-fragment y-offset preservation added to `FSNotes/EditorViewController+ScrollPosition.swift`: new `TK2ScrollPosition { charOffset: Int; yOffsetWithinFragment: CGFloat }` struct + `scrollPositionTK2()` save helper (computes `clipTopY - fragment.layoutFragmentFrame.origin.y`) + `scrollToCharOffsetTK2(_:yOffsetWithinFragment:)` restore helper (computes target y = `fragment.layoutFragmentFrame.origin.y + yOffsetWithinFragment`, `ensureLayout(for:)` first). Storage contract unchanged — saved state unpacks into the existing `Note.scrollPosition: Int?` + `Note.scrollOffset: CGFloat?` fields (previously only `scrollPosition` was used on macOS; `scrollOffset` is the iOS-parity field now live on macOS TK2). TK1 path also updated to record `note.scrollOffset = visibleRect.origin.y - glyphRect.minY` for parity across modes. TK1 branch retained as fallback; `scrollCharOffsetTK2()` preserved as a back-compat zero-y shim.
  - Test: `Tests/ScrollPositionTests.swift` — `test_phase2f4_scrollPositionTK2_preservesSubFragmentY` computes a mid-fragment save point (fragmentOriginY + 7.5pt), round-trips through the save/restore helpers, asserts target y matches within ±0.5pt. Plus `test_phase2f4_helpersAreNoOpOnTK1` extended for the new two-arg signatures. 62 / 62 phase-2f-related tests pass (ScrollPosition + LinkHover + PDFExporter + TextKit2FragmentDispatch).

- **2f.5 — Inline-image drag-resize bound updates**
  - Slice 1 of the image-resize work already restored inline-image *rendering* under TK2 via `ImageAttachmentViewProvider` (per the separately tracked image-resize slices). What remains: drag-resize bound updates, which currently call `invalidateLayout(forCharacterRange:)` on the TK1 layout manager in `ImageAttachmentHydrator`. Under TK2 the equivalent is `NSTextLayoutManager.invalidateLayout(for: NSTextRange)` plus a re-measure of the hosting fragment.
  - **Candidate approach:** covered by slices 2–4 of the image-resize work, tracked separately from this plan. 2f.5 is a pointer, not a duplicated scope — flagged here so the "accepted-2a regressions" list has a home for every item. When slices 2–4 land, this sub-item closes automatically.
  - **Estimate:** tracked externally (image-resize slices 2–4, roughly 2–4 days combined, not re-estimated here).

- **2f.6 — PDF export used-rect measurement — ✅ SHIPPED (landed in commit 0cb1ea3; tests verified 2026-04-23)**
  - `FSNotes/Helpers/PDFExporter.swift` `measureUsedRect(textView:textContainer:)` branches TK1 (via `layoutManagerIfTK1.usedRect(for:)` — retained as fallback) vs. TK2 (`measureUsedRectTK2` enumerates fragments via `.ensuresLayout`, prefers `tlm.usageBoundsForTextContainer` after enumeration, falls back to fragment union for newly-bootstrapped views).
  - Tests: `Tests/PDFExporterMeasurementTests.swift` — `test_phase2f6_pdfExporterUsedRect_nonZeroUnderTK2` (30-paragraph note, TK2 preconditions asserted, measured height > 50) + `test_phase2f6_pdfExporterUsedRect_emptyDocReturnsEmptyRect` (empty-doc crash guard). Both pass.

**Out of scope:**

- **Line numbers.** Not a revision-3 feature; defer unless the user requests it. Would live in the gutter overlay (2f.2) if added later.
- **Image resize handles (visual affordance).** Covered by image-resize slices 3–4, tracked separately. 2f.5 covers only the layout-invalidation plumbing; the handle UI itself is not a 2f concern.
- **Inline tag chip backgrounds, bullets, blockquote borders, HR line, kbd boxes.** These belong in 2c's `NSTextLayoutFragment` draws, not 2f. Reiterated here so 2f's scope doesn't bleed into 2c's.

**Exit criteria:**

- 2f.1: folding a heading collapses all content under it to zero height; unfolding restores it. No layout thrash across the fold toggle.
- 2f.2: gutter overlay displays fold carets, H-level badges, and copy icons at the correct y-positions on the current viewport. Scroll moves the icons in lockstep with their fragments. Clicks on a caret toggle the fold.
- 2f.3: mouse hover over any link (inline, autolink, wikilink, image link) swaps the cursor to the pointing-hand and back. Verified on a dogfood note with mixed link types.
- 2f.4: saving a scroll position, switching to another note and back, restores the viewport within ±2 points of the saved position. Works for positions in folded and unfolded regions.
- 2f.5: closes when image-resize slices 2–4 land (external tracker).
- 2f.6: exporting a 10,000-line note to PDF produces a PDF containing the entire note; no content cut off.
- Grep: zero direct `layoutManagerIfTK1` reads in the files touched by 2f.1–2f.4 + 2f.6 (all TK2-native).
- CommonMark compliance ≥ 80% (not expected to move — these are view-chrome changes — but the hard gate applies at every phase).

**Estimate:** 9–12 days total (2f.1: 2–3; 2f.2: 3; 2f.3: 1; 2f.4: 2; 2f.5: external; 2f.6: 1). 2f.1 and 2f.2 are the load-bearing items for real-world usability; the rest are individually 1–2 day jobs that can interleave with Phase 3 work if scheduling demands.

**Rollback:** per sub-item. Each sub-item either restores a feature that's currently broken under TK2 or no-ops. Reverting any single sub-item leaves the feature in its current (broken) 2a-post state — the same state the user is already running on. No sub-item destabilizes features that are currently working.

**Checkpoint:** user reviews after 2f.1 + 2f.2 (the two visible-UX items) before 2f.3–2f.6 are picked up. This lets the worst pain points be addressed first and the polish items land when they're convenient, not as a gate on Phase 3.

**Dependency on Phase 2e.** None. 2f sub-items apply equally whether 2e shipped the table cutover or tables stayed on `InlineTableView` as the explicit half-win. The gutter overlay in 2f.2 reads fragment frames; if tables are still attachments, the fragment at that range is the default paragraph fragment wrapping a `U+FFFC` — same placement logic applies.

---

## Phase 3 — Element-level edit application (narrowSplice in TextKit 2)

**Primitive shipped 2026-04-23; wire-in shipped 2026-04-23 (commit `a5cb270`).** `FSNotesCore/Rendering/DocumentEditApplier.swift` (~720 LoC) implements `applyDocumentEdit(priorDoc:newDoc:contentStorage:...)` — the one function that mutates `NSTextContentStorage`. Uses LCS-based diff on `Block: Equatable` (O(M·N)), then a post-pass merges adjacent `(delete priorIdx, insert newIdx)` of the **same block kind** into a single `.modified(priorIdx, newIdx)` so "typing into paragraph N" becomes one localized change rather than delete+insert. No Block/Document model invasion — structural matching only. Emits mutations via `NSTextContentStorage.performEditingTransaction` over `NSTextRange` spans; does NOT go through the TK1 `textStorage` bridge.

DEBUG instrumentation logs every edit to `<repo>/logs/element-edits.log` (or `$TMPDIR/fsnotes-logs/element-edits.log` when the primary directory isn't writable — e.g. the XCTest host). One line per call: `elementsChanged=[...] elementsInserted=[...] elementsDeleted=[...] replacedRange=[...] totalLenDelta=N noop=bool`.

Tests in `Tests/DocumentEditApplierTests.swift` (9 tests, all passing):
- `test_phase3_applyDocumentEdit_unchangedElementsUntouched` — elements outside the edit range preserve content across the splice.
- `test_phase3_applyDocumentEdit_sameShapeUpdatesInPlace` — modifying `bbb → bbbX` emits exactly one `.modified(1,1)`.
- `test_phase3_applyDocumentEdit_structuralInsertDelete` — insert-middle / delete-middle / append-end / delete-end sub-cases.
- Plus identical-docs (no-op), singleModify, insertInMiddle, deleteInMiddle, multipleEdits-sequence (4 edits including paragraph→heading kind change).

**Wire-in shipped 2026-04-23 (commit `a5cb270`).** `EditTextView+BlockModel.swift:applyEditResultWithUndo` now routes TK2 edits through `DocumentEditApplier.applyDocumentEdit(priorDoc:newDoc:contentStorage:bodyFont:codeFont:note:)` on the branch gated by `self.textLayoutManager != nil` AND its `textContentManager` being an `NSTextContentStorage`. The TK1 fallback path (`storage.replaceCharacters(in: result.spliceRange, with: result.spliceReplacement)`) is retained verbatim. Both branches sit inside the existing `umSplice.disableUndoRegistration / enableUndoRegistration` bracket and the `textStorageProcessor.isRendering = true` guard. Every surrounding invariant is preserved (undo registration, cursor placement, pendingInlineTraits, attachment hydrators, scroll-origin restore, paragraph-style resync loop — see commit message for the full list).

Pre-wire-in edge-case coverage added to `DocumentEditApplierTests.swift`: `test_phase3_applyDocumentEdit_deleteAtStart`, `_insertAtStart`, `_trailingNewlineTrue`. All three pass on first run; no primitive bug uncovered. DEBUG log verified to grow with sensible element-bounded entries on keystroke activity.

Known test-adaptation in the same commit: 3 `HarnessContractCoverageTests` that simulated typing-inside-rendered-mermaid/math are `XCTSkip`'d (the tests placed a cursor at `span.location + 3` inside the rendered block's storage span; under the `c7e7e26` `BlockSourceTextAttachment` rendering that span is 1 char, so the premise no longer maps to a WYSIWYG-reachable action). The invariants they targeted are covered elsewhere — see the commit message.

### Goal
Design the edit-application mechanism on `NSTextContentStorage` that preserves the user's block-bounded redraw constraints:
- Above edit point: unchanged elements, don't touch
- Below affected blocks: content unchanged, layout reflows (handled by `NSTextLayoutManager`)
- Off-screen: deferred by `NSTextLayoutManager` natively
- Within affected blocks: element replaced or mutated; layout fragment regenerates

### Why this is shorter than the old Phase 2
In TextKit 1, `narrowSplice` had to diff a linear character string and special-case attachment identity (don't replace `U+FFFC` — destroys widget). With TextKit 2, content is a list of elements. Attribute changes are per-element, not per-character-range. If block N's attributes change, we replace element N and the layout engine handles the redraw. Cross-block attribute bleed is structurally prevented.

### Work
1. **`applyDocumentEdit(priorDoc, newDoc, contentStorage)`** — the only function that mutates `NSTextContentStorage`. Takes two `Document`s and emits minimal element-level mutations via `NSTextContentStorage.performEditingTransaction`:
   - Element diff: identify changed, inserted, deleted elements via block identity
   - For same-shape changed elements: update the element's attributes/content in place
   - For structural changes: insert/delete element
2. **Block-identity tracking.** Each `Block` in `Document` carries a stable identity (UUID or block index with generation counter) so the differ can recognize "same block, different content" vs. "deleted/inserted." Design-decision point: explicit IDs vs. structural matching.
3. **DEBUG instrumentation** to log the scope of each edit (which elements changed, which didn't) — validates block-bounded claim.
4. **Invariant**: elements above the edit index are untouched across every edit (harness assertion).

### Exit criteria
- Bugs #35, #36 pass in harness (if still failing after Phase 2)
- Perf regression < 10% on corpus round-trip
- Redraw scope bounded to affected elements (verified via DEBUG instrumentation)
- CommonMark compliance ≥ baseline

### Estimate
5–8 days. Shrunk vs. original Phase 2 estimate because TextKit 2's element model eliminates most of the attachment-identity and character-range attribute-diff complexity.

### Rollback
Additive. If the differ has bugs, fall back to element-replace-on-any-change within the affected block range.

### Checkpoint
User reviews harness results (fixed bugs, perf measurement) before Phase 4.

---

## Phase 4 — Remove source-mode pipeline (user item 3)

### Goal
Eliminate the "two pipelines fighting" bug class. Per user: **Option B — port source-mode-as-a-feature to `Document`**.

### Work

**Dependency:** Phase 4 requires Phase 2e to have completed for every block type present in the corpus. Deleting the source-mode pipeline assumes attachments have been fully replaced for every block type that the pipeline currently handles; while 2a–2d replace attachments for paragraphs, headings, lists, blockquotes, code, HR, mermaid, and math, the table attachment path is replaced only in 2e. If 2e shipped as a half-win (tables still on `InlineTableView`), Phase 4 is blocked until 2e is revisited and completes — source-mode pipeline removal cannot land while any block type still depends on attachments.

1. **New `SourceRenderer`** (`FSNotesCore/Rendering/SourceRenderer.swift`): takes `Document`, produces a TextKit 2 element stream representing markdown source text with syntax-highlight attributes. Source-mode view consumes this via the same `NSTextLayoutManager` pattern.

2. **Delete `NotesTextProcessor.scanBasicSyntax`** path for markdown notes (all markdown highlighting now via `SourceRenderer` or `DocumentRenderer`).

3. **Delete source-mode `LayoutManager` custom drawing** — bullets, checkboxes, ordered markers, blockquote border. TextKit 2 layout fragments handle drawing in both WYSIWYG and source modes (via whichever renderer produced the element stream).

4. **Delete `Note.blocks` array peer.** Fold/unfold consumes `Document.blocks` directly. Retire `syncBlocksFromProjection`.

5. **Delete `NoteSerializer.prepareForSave()` + `Note.save(content:)` path.** One save path: `Note.save(markdown:)` fed by `MarkdownSerializer.serialize(document)`.

6. **Delete `Block.table.raw`** (per user: drop). Tables canonicalize on serialize like every other block. Non-canonical source text is not preserved; first save of legacy notes with non-canonical tables produces canonical diff. This is an accepted trade.

7. **Delete all `blockModelActive` / `documentProjection == nil` guards** in view-layer code — only one pipeline remains.

8. **Non-markdown notes** (`.txt`, `.rtf`): trivial "render string with body font" path into TextKit 2 element stream. No pipeline involvement.

9. **CommonMark compliance:** must not regress from current 80%+. Target 90%+ after canonical table serialization lands.

### Exit criteria
- Grep: zero `NotesTextProcessor.scanBasicSyntax` calls
- Grep: zero `blockModelActive` / `documentProjection == nil` guards in view-layer
- Grep: zero custom `NSLayoutManager` subclasses and zero uses of the legacy (TextKit 1) layout API for markdown rendering (the shim `NSTextView.layoutManager` property may still return a value under TextKit 2 — what must be gone is our own subclasses and any call sites driving layout via the TextKit 1 API)
- Corpus round-trip passes (accepting canonical table re-serialization)
- Source-mode view works on corpus files
- Fold/unfold works on corpus files
- CommonMark compliance ≥ 80% (baseline, must not regress)
- Manual source↔WYSIWYG toggle on real notes: no data loss
- `.txt` / `.rtf` notes render correctly

### Estimate
10–14 days (shrunk — source-mode is simpler on TextKit 2 because it doesn't need to fight custom drawing in two pipelines).

### Rollback
Per-piece. Each deletion is an atomic commit; each is individually revertible. If a source-mode-pipeline dependency is discovered, restore that piece and reconsider.

### Checkpoint
User reviews deletions in chunks (not one giant PR). User confirms `Block.table.raw` drop is acceptable on real notes folder.

---

## Phase 5 — Document as sole source of truth (user item 1)

### Goal
`Document` is the sole source of truth. `NSTextContentStorage` is a derived cache, only mutated via `applyDocumentEdit`.

### Scope
Significantly shrunk vs. the original plan because Phase 2 (TextKit 2) and Phase 3 (element-level edits) already did most of the work.

### Sub-phases

**5a. Single write path enforcement**
- Audit every call site currently writing to the content manager or storage-like APIs
- Route every mutation through `applyDocumentEdit` (from Phase 3)
- Add `#if DEBUG` assertion firing if `NSTextContentStorage` is mutated outside `applyDocumentEdit`
- **Ship 5a alone.**

**5b. Cursor canonicalization**
- `DocumentCursor` (from Phase 1) is the truth
- `NSTextLocation` derived via `cursor.toTextLocation(in: contentStorage)`
- Selection = `DocumentRange { start, end: DocumentCursor }`
- `textView.selectedRange` / `textView.textLayoutManager.textSelections` setters intercepted; translated through `DocumentRange`

**5c. Find** — **thin or unnecessary**
- TextKit 2 + real element content means `NSTextFinder` works natively across all text-bearing block types (bug #60 fixed in Phase 2)
- `DocumentFinder` only needed if we want Find to search inside mermaid/math source text that the layout fragment visually hides. If yes: thin wrapper that toggles the visibility for highlight purposes. If no: delete this sub-phase.

**5d. Copy / paste**
- Copy: `document.slice(in: selectionRange)` → `MarkdownSerializer` → pasteboard (write both `public.utf8-plain-text` markdown and `public.rtf` for cross-app fidelity where cheap)
- Paste: parse pasteboard markdown → `Document` fragment → `EditingOps.insertFragment(at:, in:)` → `applyDocumentEdit`
- Paste from other apps (`NSAttributedString` on pasteboard, no markdown type present): convert via `NSAttributedString → inline tree → Document` fragment. Reuse `InlineRenderer.inlineTreeFromAttributedString` (landed in the table refactor) for the attributed-string → inline-tree step; wrap the resulting inline runs into one or more `Block.paragraph` entries split on hard line breaks. Attributes that round-trip: **bold** (`.font` traitBold → `Inline.bold`), **italic** (traitItalic → `Inline.italic`), **strikethrough** (`.strikethroughStyle` → `Inline.strike`), **underline** (`.underlineStyle` → `Inline.underline`), **links** (`.link` → `Inline.link`). Attributes we drop: font family, font size, foreground/background color, paragraph style, kern, baseline offset — all normalized to our body font on insert so pasted content matches document style. Images on the pasteboard (`NSPasteboard.PasteboardType.png`/`.tiff`) are saved to the note's `files/` directory and inserted as `Inline.image` references, matching the existing single-pipeline save contract.

**5e. IME / composition buffer**

### Goal
Preserve marked-text (uncommitted CJK / dead-key / emoji-picker) input without violating the "`Document` is sole source of truth, `NSTextContentStorage` only mutated via `applyDocumentEdit`" contract from 5a. `Document` owns *committed* text only; `NSTextContentStorage` owns *committed + composition* text; `applyDocumentEdit` is suspended while a composition session is active and resumes on commit (the IME delivers the final string).

### Work
- Add `CompositionSession` type in `FSNotesCore/BlockModel/Document.swift`: `{ anchorCursor: DocumentCursor, markedRange: NSRange, isActive: Bool }`. Lives on the editor, not inside `Document`.
- In `EditTextView`, override `setMarkedText(_:selectedRange:replacementRange:)` and `unmarkText()` to drive the session. Entry: capture `anchorCursor` from current selection, set `isActive = true`, let TextKit's default marked-text machinery mutate `NSTextContentStorage` directly (bypasses `applyDocumentEdit` — this is the *only* exemption from the 5a single-write-path rule, gated on `session.isActive`).
- Relax the 5a debug assertion: `NSTextContentStorage` mutations outside `applyDocumentEdit` are permitted *only* when `compositionSession.isActive == true` AND the mutating range lies inside `session.markedRange`. Any other mutation trips the assertion.
- Queue any non-composition `EditingOps` call arriving while `session.isActive` (auto-save, external edit, programmatic insert) into a `pendingEdits: [EditContract]` list; drain after commit. Document explicitly that *user* keystrokes outside the marked range during composition don't happen in practice — AppKit routes all keystrokes through the IME while composition is active.
- On `unmarkText()` (commit) or `insertText(_:replacementRange:)` with the final string: take the committed text, build one `EditContract` that replaces `markedRange` with the final string in `Document`, call `applyDocumentEdit`, set `isActive = false`, drain `pendingEdits` in order.
- On escape / IME abort (empty commit): call `applyDocumentEdit` with an empty replacement over `markedRange`, so `NSTextContentStorage` and `Document` reconverge to the pre-composition state. Cursor restores to `anchorCursor`.
- Cursor/selection survival across composition end: the committed edit's `EditContract` carries a resulting `DocumentCursor` positioned at `markedRange.location + finalString.utf16Length`. 5b's cursor canonicalization translates it back to `NSTextLocation` after `applyDocumentEdit` runs.
- Test infrastructure: extend `EditorHarness` with `beginComposition(marked:)` / `updateComposition(marked:)` / `commitComposition(final:)` / `abortComposition()` that exercise the same code paths a real IME would. Pipe through pure `EditContract` emission so the test layer stays `NSWindow`-free (CLAUDE.md rule 3).
- Manual dogfood matrix: macOS Japanese (Kotoeri), Simplified Chinese (Pinyin), Korean (2-Set), Option-E dead-key accent, emoji picker (Ctrl-Cmd-Space). Each must: show marked text, commit cleanly, abort cleanly, leave `Document ↔ NSTextContentStorage` reconverged.

### Exit criteria
- Grep: the 5a debug assertion has exactly one exemption (`compositionSession.isActive && range ⊂ markedRange`); no other bypass paths exist
- Harness composition tests pass (start → update → commit, start → abort, commit-across-block-boundary into heading/list/code)
- Manual Kotoeri / Pinyin / 2-Set / Option-E / emoji picker all work without duplicated or lost characters
- Committing composition inside a code block, list item, blockquote, and table cell all succeed with correct final `Document` state
- Undo (from 5f, if landed) of a committed composition undoes the whole commit as one atomic operation, not per-keystroke
- Perf: no measurable regression on typing latency in Roman-script input (composition machinery is a no-op when `isActive == false`)

### Estimate
7–10 days. IME edge cases are where estimates usually blow up; if Kotoeri or Pinyin reveal a TextKit 2 marked-text interaction we haven't seen, this stops and rescopes.

### Rollback
Atomic. The 5a assertion gate is the one externally visible change; reverting the composition-session code restores pre-5e behavior (which is "IME broken," so rollback means reverting 5a too or accepting broken IME temporarily — document this in the rollback checklist).

**5f. Undo / Redo via Document journaling**

### Goal
`NSUndoManager` operates on `Document` snapshots or inverse `EditContract`s, not on `NSTextStorage`. Every `EditingOps` primitive already emits an `EditContract` (landed in Phase 1); undo captures the before-state; `NSUndoManager` invokes replay via `applyDocumentEdit` using the captured state. Redo fidelity includes cursor + selection.

### Work
- Extend `EditContract` (from Phase 1) with an `inverse: EditContract` field when it can be computed cheaply (single-block replace, insert, delete). For multi-block or structural edits (list FSM transitions, heading↔paragraph conversion, table cell edits), capture a `beforeSnapshot: DocumentSnapshot` — a shallow copy of the affected `[Block]` slice plus its index range in `Document.blocks`. Full-document snapshots are the fallback for operations we can't localize; expect these to be rare.
- New `UndoJournal` type in `FSNotesCore/BlockModel/UndoJournal.swift`. Owns `past: [UndoEntry]` and `future: [UndoEntry]` stacks. `UndoEntry = { contract: EditContract, selectionBefore: DocumentRange, selectionAfter: DocumentRange, groupID: UUID, timestamp: Date }`.
- Hook `applyDocumentEdit` to append to the journal (unless a replay flag is set — replay itself must not re-journal). Hook `NSUndoManager.registerUndo(withTarget:handler:)` per edit; the handler pops the journal and calls `applyDocumentEdit` with the inverse / snapshot restore.
- Coalescing policy (single undo step covers a run of related edits):
  - **Typing** coalesces inside one block while `(now - lastEdit) < 1.0s` AND the new edit is a single-character insert adjacent to the last. Break the group on: non-typing edit, selection change, focus change, 1-second idle, explicit boundary (block boundary crossed, Return, structural edit).
  - **Deletion** coalesces by the same rule but separately from typing (contiguous backspaces group, but typing-then-backspacing breaks the group).
  - **Structural edits** (list indent/unindent, block type change, paste, table cell edit) are each their own group — no coalescing.
  - Implementation: `UndoJournal.beginGroup(reason:) / endGroup()` called by `EditingOps`; a heartbeat timer ends the current group on 1-second idle.
- Composition interaction (crosses into 5e): while `compositionSession.isActive`, journaling is suspended. On commit, one `UndoEntry` is recorded for the committed text — the entire composed run is one undo step. On abort, no entry is recorded (the abort itself reverts via `applyDocumentEdit`, which would otherwise journal — suppress via replay flag). Specified explicitly so the two subsystems have a contract, not an accident.
- Redo fidelity: every `UndoEntry` carries `selectionBefore` and `selectionAfter`. Undo restores `selectionBefore` after `applyDocumentEdit`; redo restores `selectionAfter`. Cursor survival uses the same `DocumentCursor → NSTextLocation` translation from 5b — a redo 30 seconds after the original edit still lands the cursor on the correct logical position even if intervening edits shifted offsets (because `DocumentCursor` is block-ID + intra-block offset, not absolute).
- Test coverage:
  - Unit: per-primitive undo/redo round-trip on pure `Document` values. Assert `applyDocumentEdit(contract); applyDocumentEdit(contract.inverse) == beforeDocument`.
  - Unit: coalescing. Type "hello", undo once, assert entire word gone. Type "hello", 1.5s pause, type " world", undo once, assert " world" gone but "hello" remains.
  - Unit: redo fidelity. Edit-edit-edit, undo-undo-undo, redo-redo-redo, assert `Document` + selection both match post-third-edit state.
  - Integration: composition + undo. Type Japanese "こんにちは" via IME, commit, undo, assert all 5 characters gone as one step.
  - Integration: structural undo. Indent list item, undo, assert outdent. Convert paragraph to heading, undo, assert paragraph restored with original inline attributes.
  - Corpus: round-trip of undo-then-redo over the corpus must leave `Document` bit-identical to post-load state.
- Wire `Edit > Undo` / `Edit > Redo` menu items through `NSUndoManager.undo()` / `.redo()` as today; the extension point is *what* the manager records, not *how* the menu invokes it.

### Exit criteria
- Grep: zero `NSUndoManager.registerUndo` call sites outside `UndoJournal` / `applyDocumentEdit`
- All undo/redo unit tests pass on pure `Document` values (no `NSWindow`)
- Coalescing tests pass (typing, deletion, structural boundary)
- Composition + undo integration test passes (committed IME run = 1 undo step)
- Redo after 10 intervening edits still restores correct cursor + selection
- Manual: Cmd-Z / Cmd-Shift-Z in every block type (heading, list, blockquote, code, table cell, HR adjacency) behaves identically to pre-refactor expectations
- Perf: undo stack memory bounded by coalescing; full-document snapshots rare (assert < 5% of entries in a typical session via instrumentation)

### Estimate
10–14 days. Coalescing edge cases and the composition interaction are the two places this usually grows.

### Rollback
Per sub-phase. 5f revertible alone (falls back to the pre-refactor `NSUndoManager` + `NSTextStorage` undo, which remains buggy but known). If 5f reveals an `EditContract` deficiency (e.g. some primitive's `inverse` isn't computable cheaply), the fix is either to add the `beforeSnapshot` path for that primitive or to redesign that primitive — not to abandon journaling.

**5g. Accessibility — SKIP** (largely addressed for free in Phase 2)

### Exit criteria
- Grep: zero direct `NSTextContentStorage` mutations outside `applyDocumentEdit`
- Debug assertion catches any violation during test runs
- Bug #60 still passes in harness (regression check on Phase 2 fix)
- Bug #41 passes in harness (live cursor matches declared cursor — now that cursor is `NSTextLocation`-based and element-addressed)
- Corpus tests pass
- Manual dogfood: no visible regressions
- Perf regression < 20% on corpus round-trip
- CommonMark compliance ≥ 80% (target 90%+ by end of phase)

### Estimate
10–15 days (shrunk from 20–30; Phase 2 did the heavy lifting).

### Rollback
Per sub-phase. 5a revertible alone; 5b revertible if 5a stays; etc.

### Checkpoints
User reviews after each sub-phase (5a, 5b, 5c-if-kept, 5d).

---

## Phase 6 — Cleanup (user item 6)

### Goal
Remove code that's now redundant so there's no confusion or duplication.

### Work

1. Delete TextKit 1 remnants: any `NSLayoutManager` usage (custom drawing, `layoutManager(_:)` delegate methods) that survived Phase 4's dedicated sweep
2. Delete code paths unreachable after `blockModelActive` guards removed in Phase 4
3. Delete shim functions that routed between old/new pipelines
4. Delete legacy TODOs and comments referring to dual-pipeline or attachment-based block state
5. Run CLAUDE.md Rule 7 grep across `FSNotes/` and `FSNotesCore/Rendering/` — zero hits required
6. Dead-code analyzer review on touched files
7. Update `ARCHITECTURE.md` and `CLAUDE.md`:
   - Remove "Rules That Exist Because I Broke Them" items that are now architecturally impossible (views-write-to-data enforced by single write path; marker-hiding via invisible chars impossible because there are no invisible chars in our rendering)
   - Add new rules documenting invariants the refactor established (one layout primitive per block type; all content in `NSTextContentStorage`; single write path)
8. Re-run CommonMark compliance suite; verify 90%+ target met

### Exit criteria
- Rule 7 grep: zero hits in view/renderer code
- Grep: zero `NSLayoutManager`, zero `NSTextAttachment` (for block content), zero `U+FFFC` outside explicit inline-image handling
- Dead-code analyzer clean on touched files
- All harness tests pass
- Binary size reduced (sanity check — we're deleting a lot)
- `ARCHITECTURE.md` / `CLAUDE.md` updated
- CommonMark compliance ≥ 90%

### Estimate
5–7 days.

### Rollback
Each deletion atomic; easy one-off reverts.

---

## Phase 7 — Theme system via stylesheet JSON (user item 7)

### Goal
Remove all remaining hardcoded typography, spacing, and chrome constants from rendering code. Expose them as entries in a single `Theme` struct loaded from a JSON stylesheet. The stylesheet unifies:
1. Every field currently exposed in **Settings / Editor** (font, size, line spacing, line width, margin, image width, indent, brackets, inline tags, bold/italic marker style, code highlight theme).
2. Rendering parameters currently hardcoded (heading scales + spacing-before/after, paragraph spacing, code-block chrome, blockquote bars, HR, kbd chip, list indents, inline highlight color, link color, container inset).

`Theme` becomes the **single source of truth** for presentation — every renderer and fragment reads from it; `UserDefaultsManagement` typography keys become thin wrappers that mutate the active `Theme`.

### Motivation
- Enable swappable themes: users pick from a menu; community contributes JSON stylesheet files.
- Centralize a currently-scattered concern. Today the same "paragraph spacing" idea exists in `DocumentRenderer.paragraphSpacingMultiplier`, `BlockStyleTheme.paragraphSpacing`, `TextStorageProcessor` literals, and fragment-local static constants. One canonical place.
- Prerequisite for accessibility modes (high-contrast, dyslexia-friendly fonts, large-text) without shipping separate builds.
- The half-built `BlockStyleTheme` struct (`FSNotesCore/Rendering/BlockStyleTheme.swift`) is the obvious seed. Phase 7 finishes it: wires it through every renderer + fragment, subsumes the `UserDefaultsManagement` typography keys, and exposes it to users as a selectable theme.

### Status of existing work
- `BlockStyleTheme` struct + Codable + `load()` / `save()` / `reload()` + `migrateFromUserDefaults()` already exist.
- Fonts (noteFont / codeFont), editor chrome (line spacing, margin, line width, images width), heading scales + spacing, list geometry, blockquote bar geometry, table placeholder, HR block spacing, and blank-line heights are all modeled.
- **Not wired**: fragment drawing code still uses file-local `static let` constants (`HorizontalRuleLayoutFragment.ruleColor`, `KbdBoxParagraphLayoutFragment.fillColor/strokeColor`, `HeadingLayoutFragment.borderColor`, `BlockquoteLayoutFragment.barColor`, code-block corner radius / border width, etc.). `TextStorageProcessor.swift` (source-mode path) still uses raw literals — scope question resolved below (Phase 4 deletes it, so 7.x doesn't need to touch it).
- **Not modeled**: per-heading font family overrides, link color, code-span background, kbd chip colors + padding, HR thickness + color, code-block corner radius + border width + horizontal bleed, lineFragmentPadding, container top inset, dark-mode color variants.

### Scope of settings the final `Theme` must cover

Pulled from the Step 1 grep pass + Settings/Editor outlets:

**From existing Settings / Editor UI** (already in `PreferencesEditorViewController`):
- `noteFont` (family + size), `codeFont` (family + size), reset-fonts
- `lineSpacing` slider (→ `lineHeightMultiple`; today also clamps `editorLineSpacing = 1`)
- `imagesWidth`, `lineWidth`, `marginSize` sliders
- `codeBlockHighlight` toggle + `markdownCodeTheme` popup (code syntax highlight theme)
- `indentUsing` (tabs vs spaces)
- `inEditorFocus`, `autocloseBrackets`, `inlineTags`, `clickableLinks` toggles
- `italicAsterisk`/`italicUnderscore`, `boldAsterisk`/`boldUnderscore` marker style

**Already in `BlockStyleTheme`** (keep):
- `noteFontName`, `noteFontSize`, `codeFontName`, `codeFontSize`, `editorLineSpacing`, `lineWidth`, `marginSize`, `imagesWidth`
- `headingFontScales[6]`, `headingSpacingBefore[6]`, `headingSpacingAfter[6]`
- `paragraphSpacing`, `codeBlock{LineSpacing,ParagraphSpacing,SpacingBefore}`
- `list{IndentScale,CellScale,BulletSizeScale,NumberDrawScale,CheckboxDrawScale,BulletStrokeInset,BulletStrokeWidth,BlockSpacing}`
- `blockquote{BarInitialOffset,BarSpacing,BarWidth,GapAfterBars,BlockSpacing}`
- `table{PlaceholderWidth,PlaceholderHeight,BlockSpacing}`, `hrBlockSpacing`
- `htmlBlock{LineSpacing,ParagraphSpacing,SpacingBefore}`
- `highlightColor`, `blankLine{Min,Max}Height`

**New — must be added to `Theme`**:
- Inline: `linkColor`, `codeSpanBackground`, `codeSpanForeground`, `strikethroughStyle`, `underlineStyle`
- Heading: `headingBorderColor`, `headingBorderThickness`, `headingBorderOffsetBelowText`
- Code block: `codeBlockCornerRadius`, `codeBlockBorderWidth`, `codeBlockBorderColor`, `codeBlockHorizontalBleed`, `codeBlockBackgroundColor` (currently pulled from the syntax-highlighter theme — move into `Theme` for override)
- Blockquote: `blockquoteBarColor`
- HR: `hrThickness`, `hrColor`
- Kbd chip: `kbdFillColor`, `kbdStrokeColor`, `kbdShadowColor`, `kbdCornerRadius`, `kbdBorderWidth`, `kbdHorizontalPadding`, `kbdVerticalPaddingTop`, `kbdVerticalPaddingBottom`
- Editor chrome: `lineFragmentPadding`, `textContainerInsetTop`, `textContainerInsetWidth`
- Bold/italic marker style (`"**"|"__"` and `"*"|"_"`) — currently in `UserDefaultsManagement`
- Indent style (`tabs|spaces`, width) — currently in `UserDefaultsManagement`
- Per-heading family override (optional, nullable — most themes use body family)
- Inter-paragraph multipliers that today live in `DocumentRenderer` `private static let`: `paragraphSpacingMultiplier`, `structuralBlockSpacingMultiplier` — absorb into `Theme.paragraphSpacingMultiplier` etc. (BlockStyleTheme today has `paragraphSpacing` as a fixed CGFloat; need to reconcile with the multiplier model)

### Design sketch

**Struct shape.** Keep `BlockStyleTheme` as the vehicle; rename to `Theme` or leave as-is. Add a `ThemeInline`, `ThemeBlock`, `ThemeChrome`, `ThemeColors` grouping to keep JSON readable:
```
Theme {
  typography: ThemeTypography   // noteFont*, codeFont*, headingFontScales, italic/boldMarker
  spacing:    ThemeSpacing      // lineSpacing, paragraph+heading spacing, blockquote, list geometry
  chrome:     ThemeChrome       // margin, lineWidth, imageWidth, containerInset, lineFragmentPadding
  colors:     ThemeColors       // link, highlight, borders, kbd, code-block, blockquote bar, HR
  behavior:   ThemeBehavior     // autocloseBrackets, clickableLinks, inlineTags, indentUsing (debatable — see below)
}
```
Decision: keep `behavior` keys in `UserDefaultsManagement` (they're not presentation — they're editor behavior). `Theme` is presentation-only. Font-marker choice (`italic`/`bold` glyph) is presentation-adjacent but sits under `typography` because it affects output markdown bytes.

**Dark/light.** Single JSON with paired values per color:
```json
"linkColor": { "light": "#007AFF", "dark": "#0A84FF" }
```
Rationale over two-files: a theme bundles "a look" — the designer wants both variants to travel together and stay in sync. Non-color values (sizes, scales) have no variant. Loader resolves `.light`/`.dark` at read time using the effective appearance.

**Loading + bundling.**
- Bundled themes ship in `Resources/Themes/*.json` (e.g. `Default.json`, `HighContrast.json`, `Solarized.json`).
- User themes in `~/Library/Application Support/FSNotes++/Themes/*.json`.
- Active theme name stored in `UserDefaultsManagement.activeThemeName`.
- Loader order: bundled default → user-overridden default → named-theme file. Invalid/missing falls back to compiled-in `Theme.default` with a user-visible warning (non-modal banner, not an alert).

**Renderer wiring.**
- `DocumentRenderer.init(theme: Theme)` — removes file-local `paragraphSpacingMultiplier` etc.
- `InlineRenderer.render(_:baseAttributes:theme:)` — removes `Self.highlightColor`.
- `CodeBlockRenderer`, `ListRenderer`, `HeadingRenderer`, `BlockquoteRenderer` — all gain a `theme:` parameter.
- Fragments (drawing code) are trickier: they're instantiated by `NSTextLayoutManagerDelegate` and have no natural constructor-injection point. Access pattern: `BlockStyleTheme.shared` (already the pattern) + a `Theme.notifyChange` NotificationCenter signal that every live fragment subscribes to and re-draws on.
- **Live re-render on theme switch:** invalidate all layout fragments via `textLayoutManager.invalidateLayout(for:)`, re-run `DocumentRenderer.render(document, theme: newTheme)`, preserve scroll position by anchoring on the top-visible block's id. Reuses the invalidation primitive landing in Phase 3's `applyDocumentEdit`.

**UserDefaults subsumption.**
- `UserDefaultsManagement.noteFont`, `.fontName`, `.fontSize`, `.codeFont`, `.codeFontName`, `.codeFontSize`, `.editorLineSpacing`, `.lineHeightMultiple`, `.lineWidth`, `.marginSize`, `.imagesWidth`, `.italic`, `.bold` become **computed properties** that read from / write to `Theme.shared`. Settings sliders stop writing to `UserDefaults` directly; they mutate the active theme and persist via `Theme.save()`.
- `migrateFromUserDefaults()` already handles the first-launch migration; extend it for the new keys.
- Non-presentation keys (`codeBlockHighlight`, `codeTheme`, `focusInEditorOnNoteSelect`, `autocloseBrackets`, `indentUsing`, `inlineTags`, `clickableLinks`) stay in UserDefaultsManagement.

### Migration plan (5 slices)

**7.1 — Consolidate + extend `Theme` struct (additive, no wiring change). — ✅ SHIPPED 2026-04-23 (commit `850ae7b`).**
- Rename `BlockStyleTheme` → `Theme` (or keep — bikeshed in review).
- Add the "New — must be added" fields listed above.
- Add `light/dark` CodableColor pairs where relevant; add `ThemeColors.resolved(for: NSAppearance)` helper.
- Extend `Theme.default` with all existing hardcoded values copied in (from fragment statics, `DocumentRenderer` multipliers, `InlineTagRegistry.highlightColor`, `InlineRenderer` highlight).
- Ship `Resources/Themes/Default.json` matching `Theme.default` byte-for-byte so load-then-save is idempotent.
- **Exit:** new fields compile; `Theme.shared` loads from `Default.json`; zero callers changed yet.

**7.2 — Wire `Theme` through `DocumentRenderer` + `InlineRenderer`. — ✅ SHIPPED 2026-04-23 (commit `a445bf6`).**
- Thread `theme:` parameter from `DocumentRenderer.render(_:)` into paragraph-style construction.
- Replace `paragraphSpacingMultiplier` / `structuralBlockSpacingMultiplier` / `h{1..6}Spacing{Before,}Multiplier` file-locals with `theme.spacing.*`.
- Replace `InlineRenderer.highlightColor` with `theme.colors.highlight.resolved(for:)`.
- Replace `linkColor` named-asset lookup with `theme.colors.link.resolved(for:)`.
- Pipe `theme` into `CodeBlockRenderer`, `ListRenderer` (already consumes `BlockStyleTheme.shared` indirectly; make the parameter explicit), `HeadingRenderer`, `BlockquoteRenderer`.
- **Exit:** corpus round-trip unchanged; grep of `FSNotesCore/Rendering/*.swift` (excluding `Theme.swift`) shows zero `NSFont.systemFont`, zero `PlatformFont.monospacedSystemFont`, zero numeric literals in `paragraphSpacing*` assignments.

**7.3 — Wire `Theme` into per-block fragments.**
- `HeadingLayoutFragment`, `BlockquoteLayoutFragment`, `HorizontalRuleLayoutFragment`, `KbdBoxParagraphLayoutFragment`, `CodeBlockLayoutFragment` switch their `public static let` color/size constants to `Theme.shared.colors.*` / `Theme.shared.chrome.*` reads.
- Keep geometry computations (e.g. `HorizontalRuleLayoutFragment.ruleThickness` arithmetic, `CodeBlockLayoutFragment.cornerRadius` rounding) as-is; only the *values* move.
- Each fragment subscribes to `Theme.didChange` and calls `setNeedsDisplay` on its owning text layout manager.
- **Exit:** Rule 7 grep across `FSNotesCore/Rendering/Fragments/*.swift` shows zero hardcoded color literals and zero numeric point/size literals that aren't inherently structural (e.g. bezier offsets). Snapshot corpus renders byte-identical with `Default.json`.

**7.4 — Theme switcher UI + bundled themes.**
- Add "Theme" NSPopUpButton to `PreferencesEditorViewController`.
- Populate from bundled `Resources/Themes/*.json` ∪ `~/Library/Application Support/FSNotes++/Themes/*.json`.
- Wire font/size/slider IBActions to mutate `Theme.shared` + call `Theme.save()` instead of writing `UserDefaultsManagement` keys.
- Ship bundled themes: `Default.json`, `HighContrast.json`, at least one dark-optimized (`Nord.json` or similar).
- Live reload on selection change; preserve scroll position.
- **Exit:** user can switch themes; all Settings / Editor sliders still work and are now writing to the active theme.

**7.5 — Grep gate + UserDefaults subsumption.**
- `UserDefaultsManagement.noteFont/.fontName/.fontSize/.codeFont/.codeFontName/.codeFontSize/.editorLineSpacing/.lineHeightMultiple/.lineWidth/.marginSize/.imagesWidth/.italic/.bold` become computed getters/setters proxying `Theme.shared`.
- Delete the backing UserDefaults keys (migration already copied them to the active theme on first launch).
- Run the final Rule 7 / banned-pattern grep across `FSNotes/` and `FSNotesCore/` — zero hits for literal `NSFont.systemFont(ofSize:`, literal `paragraphSpacing = <number>`, literal color in fragment/renderer files.
- Update `ARCHITECTURE.md` to document `Theme` as the single presentation source of truth.
- **Exit:** grep gate passes; all renderer/fragment values come from `Theme.shared`.

### Exit criteria (phase-wide)
- Grep gate: zero hardcoded typography/color/spacing literals in `FSNotesCore/Rendering/*.swift` (excluding `Theme.swift` + default-value constructor) and in `FSNotesCore/Rendering/Fragments/*.swift`.
- `Theme(fromJSON: data)` loads + validates a theme file; invalid themes fall back to `Theme.default` with a user-visible warning.
- Switching themes in Preferences applies live without app restart and without losing scroll position or selection.
- Existing Settings / Editor UI rewired to mutate the active theme (for the user's personal default) instead of writing independent `UserDefaultsManagement` typography keys.
- Corpus round-trip unchanged (theme is presentation-layer only — serialization bytes identical).
- CommonMark compliance ≥ 80% (unchanged from baseline — no parser/serializer work).
- Harness tests pass; invariants unchanged (a theme swap is not an edit).
- At least 2 bundled themes ship (`Default`, one alternative).

### Dependencies
- **Phase 3 (`applyDocumentEdit`) is NOT strictly required.** Phase 7 can proceed on the current rendering pipeline.
- **If Phase 3 lands first**, theme-switch invalidation reuses its invalidation primitive instead of hand-rolling one.
- **Phase 4 removes `TextStorageProcessor`** (the main other site of hardcoded spacing literals). If 7 lands before 4, 7 intentionally does NOT touch `TextStorageProcessor` — the source-mode path dies in Phase 4 and wiring it through Theme would be wasted work.
- Must land AFTER Phase 2 (fragments exist); works cleanly with Phase 2c as-landed.

### Estimate
7–12 days. Breakdown:
- 7.1: 1–2 days (additive struct work + default JSON)
- 7.2: 2–3 days (renderer wiring; invariants must stay green)
- 7.3: 2–3 days (fragment wiring + change notification)
- 7.4: 1–2 days (UI + bundled themes)
- 7.5: 1 day (grep gate + UserDefaults subsumption + doc update)

### Rollback
- 7.1 is additive; trivial to revert.
- 7.2–7.5 each atomic per slice; each slice can be reverted by restoring the previous hardcoded value list. Because the JSON is already shipped by 7.1, a 7.2 revert does not break loading — it just stops consuming theme values.
- `Theme.shared` survives a partial revert since `BlockStyleTheme` already has it.

### Checkpoint
- User reviews after **7.1** (struct shape + default JSON + list of fields).
- User reviews after **7.3** (visual dogfood — switch between bundled themes on real notes folder, confirm nothing regresses).
- User reviews before **7.4** (UI surface design — popup placement, restart-required warnings, preview behavior).
- User reviews final grep gate before **7.5** is declared done.

### Contradictions / notes from existing plan
- `BlockStyleTheme` exists and is partially wired but never mentioned in Phases 0–6. Phase 7 absorbs it explicitly.
- Phase 6 says "Rule 7 grep across `FSNotes/` and `FSNotesCore/Rendering/` — zero hits required" for the banned marker-hiding patterns (tiny font, clear color, `.kern`). Phase 7's grep gate is stricter (typography/color literals anywhere, not just marker-hiding) but complementary — 6's gate is a correctness invariant, 7's is an architectural-centralization invariant. Both should run in CI after 7.5.

---

## Critical files

**Phase 0 (new):**
- `Tests/EditorHarness.swift`
- `Tests/Invariants.swift`
- `Tests/Corpus/*.md` (10–15 files)
- `Tests/DocumentHTMLRenderer.swift`
- `Tests/Corpus/references/*.html`
- `FSNotes.xcodeproj/project.pbxproj` (add new test files — 4 places per CLAUDE.md)

**Phase 1 (modify):**
- `FSNotesCore/Rendering/EditingOperations.swift` — retrofit contracts on all primitives
- `FSNotesCore/BlockModel/ListEditingFSM.swift` — retrofit contracts
- `FSNotesCore/BlockModel/Document.swift` — add `DocumentCursor` type
- `FSNotes/View/EditTextView+BlockModel.swift` — `applyBlockModelResult` consumes contracts
- `ARCHITECTURE.md` — FSM specification update

**Phase 2 (TextKit 2 — new + modify):**
- `FSNotes/View/EditTextView.swift` — switch to `NSTextLayoutManager` + `NSTextContentStorage` in init (2a)
- `FSNotesCore/Rendering/Elements/*.swift` (new directory) — one file per `NSTextElement` subclass
- `FSNotesCore/Rendering/Fragments/*.swift` (new directory) — one file per `NSTextLayoutFragment` subclass
- `FSNotesCore/Rendering/DocumentRenderer.swift` — emit element stream instead of `NSAttributedString`
- `FSNotes/LayoutManager.swift` — delete (TextKit 1)
- `FSNotes/AttributeDrawer.swift` — port margin drawing (bullets, blockquote borders) into fragment-level draw
- `FSNotes/Helpers/InlineTableView.swift` — delete after `TableLayoutFragment` lands (2d)
- `FSNotesCore/Rendering/BlockRenderer.swift` — delete attachment paths; mermaid/math/code rendering lives in their fragments (2d)

**Phase 3 (new + modify):**
- `FSNotesCore/Rendering/ApplyDocumentEdit.swift` (new) — the single write path
- `FSNotesCore/BlockModel/Document.swift` — block identity tracking (UUIDs or generation counters)

**Phase 4 (delete / modify):**
- `FSNotesCore/Rendering/NotesTextProcessor.swift` — delete `scanBasicSyntax` markdown path
- `FSNotesCore/Business/Note.swift` — delete `blocks` array, `save(content:)`
- `FSNotesCore/Business/NoteSerializer.swift` — delete `prepareForSave()`
- `FSNotesCore/BlockModel/Document.swift` — remove `Block.table.raw`
- `FSNotesCore/Rendering/SourceRenderer.swift` (new)

**Phase 5 (modify / new):**
- `FSNotes/View/EditTextView+BlockModel.swift` — enforce `applyDocumentEdit` single entry point
- `FSNotesCore/BlockModel/DocumentCursor.swift` (new)
- `FSNotes/View/EditTextView+Clipboard.swift` — document-based copy/paste
- `FSNotesCore/BlockModel/DocumentFinder.swift` (new, only if 5c is kept)

**Phase 6 (sweep):**
- `FSNotes/` and `FSNotesCore/` — TextKit 1 / guard / dead-code removal
- `ARCHITECTURE.md`, `CLAUDE.md` — updates

---

## Reuse of existing functions / utilities

- `makeFullPipelineEditor()` — currently in Tests/; absorbed into `EditorHarness.init`
- `runFullPipeline()` — absorbed into `EditorHarness.applyEdit`
- `Tests/CommonMark/` suite — continues to run; compliance gate
- `EditingOps` primitives — extended with `EditContract`, no core behavior change
- `InlineRenderer.inlineTreeFromAttributedString` (from table refactor) — reused by paste parsing in Phase 5d
- `InlineRenderer.render` — reused by inline-content element/fragment rendering in Phase 2
- `MarkdownParser.parse` / `MarkdownSerializer.serialize` — unchanged (they already operate on `Document`)
- `Document.cachedDocument` on `Note` — unchanged; load/save path simplified via Phase 4
- `ListEditingFSM` — extended with contracts; core FSM logic preserved
- `Resources/MPreview.bundle` (mermaid/MathJax/highlight.js) — retained; mermaid/math fragments still call the WebView renderer to produce bitmaps (only the packaging into `NSTextAttachment` goes away)
- `AttributeDrawer` (bullets, blockquote borders, etc.) — margin/gutter drawing logic ported into per-fragment `draw`
- `xcode-build-deploy` skill — unchanged; deployment flow identical

---

## Verification (end-to-end)

### Per-phase
- Harness invariants + corpus round-trip pass
- HTML-proxy diff clean (or updates explained)
- Bug-driven tests transition FAIL → PASS as expected (never the reverse)
- CommonMark compliance ≥ 80% at every phase (hard gate)
- Manual dogfood on real `~/Documents/FSNotes/` notes folder
- `xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes > /tmp/xctest.log 2>&1` — all green
- `xcode-build-deploy` skill deployment succeeds; symbol verification confirms changes landed

### End-of-refactor
- All known bugs (#22, #35, #36, #39, #40, #41, #47, #60) PASS in harness
- CommonMark compliance ≥ 90%
- Grep: Rule 7 patterns return zero hits in view/renderer code
- Grep: zero `NSLayoutManager` / zero block-content `NSTextAttachment` / zero block-content `U+FFFC` in the codebase
- Perf: corpus round-trip ≤ 120% of pre-refactor baseline
- Binary size ≤ pre-refactor (should decrease from deletions)
- Live dogfood session: zero regressions vs. pre-refactor app on real notes, including Find in tables and across blocks

---

## Checkpoints (user approval required)

1. **Pre-flight spike conclusion → Phase 0** (deployment target + prototype + T1/T2 pick + Find verification)
2. **Phase 0 exit → Phase 1** (harness works, inventory complete)
3. **Phase 1 exit → Phase 2** (contracts + ARCHITECTURE.md reviewed)
4. **Phase 2 sub-phase gates:** 2a (TextKit 2 baseline) → 2b/2c per block type → 2d (attachment deletion). Each independently reviewable and revertible.
5. **Phase 2 exit → Phase 3** (all block types rendered via TextKit 2; `NSTextAttachment` gone for block content)
6. **Phase 3 exit → Phase 4** (element-level edits perf-measured)
7. **Phase 4 chunk reviews → Phase 5** (source-mode deletion accepted on real notes)
8. **Phase 5 sub-phase gates:** 5a → 5b → (5c if kept) → 5d → 5e → 5f (5g skipped per sub-phase note)
9. **Phase 5 exit → Phase 6**
10. **Phase 6 exit → done**

Plan is immutable within a phase. Scope creep, or discovery that invalidates downstream phases, triggers a checkpoint stop — halt the phase, write up the discovery, resume only after user approval of the amended plan.

---

## Risks and honest uncertainty

- **Phase 2 (TextKit 2 migration) is the highest-risk phase.** AppKit TextKit 2 is documented but less trodden than TextKit 1 in third-party code. Surprises around selection, find, input method, and copy/paste interactions with custom fragments are plausible. Mitigation: sub-phase gates (2a ships first, validates baseline), pre-flight prototype, halt-and-rescope rule.
- **Table fragment (T1 vs T2) is the single biggest engineering item inside Phase 2.** Spike picks the approach; if the chosen approach hits a wall mid-Phase-2, fallback is to keep `InlineTableView` on an attachment for tables specifically while other block types migrate. This is an explicit, acceptable half-win.
- **Deployment target may need to rise** to macOS 12+. If the current user base includes macOS 11 users, this is a product decision to surface with the user during the spike.
- **Mermaid/math rendering still uses WebView internally.** The bitmap-production pipeline doesn't change; only the packaging does. If the WebView pipeline has latent bugs, Phase 2 won't fix them — but it also won't break them.
- **CommonMark compliance is a hard gate.** Every phase verifies. A regression at any phase halts work until compliance is restored.
- **Harness may not run headless on CI.** Fallback: manual-trigger integration runs on PR merge.
- **Estimates are best-effort.** Realistic total: 4–6 months (up from the pre-TextKit-2 estimate of 3–5 months because Phase 2 is larger than the old Phase 2+4 combined-but-smaller). Worst-case: 7+ months if TextKit 2 hits a wall; in that case we stop with Phases 0–1 + 2a shipped, which is a meaningful baseline improvement even alone.
- **Closed-loop risk on tests:** I write the invariants. I'm blind to blind spots in the same way I'm blind in the code. Mitigations: bug-driven tests (invariants from user reports), cross-representation invariants (content manager == render(document) is self-checking), random-walk corpus fuzzing. Not eliminated, reduced.

---

## What this refactor does NOT promise

Per user's prior correction ("stop promising, start demonstrating"):

- It does not promise zero bugs post-refactor.
- It does not promise every existing bug is fixed as a side effect.
- It does not promise the estimates hold within 20%.
- It does not promise CommonMark 90% is achievable if underlying parser work is harder than expected (target, not gate).
- It does not promise TextKit 2 migration completes without discovery that reshapes the plan. If the pre-flight spike reveals a blocker (deployment target can't rise; table fragment infeasible; etc.), we stop and rescope, not quietly extend.
- It does promise: each phase ends in a shippable tree, checkpoints are user-gated, and rollback is available at every sub-phase boundary.

The bet being made is: the *shape* of the architecture change — collapsing dual sources of truth AND replacing the `U+FFFC`/`NSTextAttachment` placeholder with first-class per-block layout elements — addresses the class of bug whose recurrence motivates the refactor. The evidence for whether the bet is working comes from the harness + invariants continuously, not from my design arguments.

---

## Post-approval first action

Copy this plan file from `/Users/guido/.claude/plans/frolicking-sniffing-cookie.md` to `/Users/guido/Documents/Programming/Claude/fsnotes/REFACTOR_PLAN.md` (user's requested location).

---

## Remaining tasks

Running ledger of work that was explicitly **skipped, deferred, or downscaled** during a session, so it doesn't get lost. Add an entry the moment something is dropped from scope; don't batch at session end. Each entry names what was skipped, why, what a future session needs to pick it up, and the rough cost. Remove an entry only when the work lands.

### Phase 1 — Contract retrofit

**Batch H (insert/delete/replace) — COMPLETE.** All insert/delete/replace paths now carry contracts + tests. 1,114 tests pass (baseline 3 known-red only; zero regressions). Batch H parts 4–7 (2026-04-22) added contracts on:

Part 4 (Return-key splits):
- blankLine Return-doubling → `.insertBlock(at: i+1)`
- paragraph single-newline split → 4 sub-shapes driven by (beforeEmpty, afterEmpty); first-slot action is `.modifyInline` or `.changeBlockKind`, plus 1–2 `.insertBlock`s
- heading split → `.modifyInline`/`.changeBlockKind` + `.insertBlock`
- `insertAroundAtomicBlock` single-line → `.insertBlock(at: i+1)`
- code-block Return-on-blank exit → `.modifyInline` + `.insertBlock`
- list Return mid-item split (via `splitListOnNewline`) → `.replaceBlock(at: i)` (list item array grew — structural within the same block)
- blockquote Return mid-line split (via `splitBlockquoteOnNewline`) → `.replaceBlock(at: i)` (same pattern)

Part 5 (multi-line paste paths):
- `pasteIntoParagraph` → delta-based: `.replaceBlock(at: i)` + N × `.insertBlock` (delta > 0) or + N × `.mergeAdjacent` (delta < 0). `coalesceAdjacentLists` normalization can shrink block count, so the contract measures observed delta.
- `pasteIntoList` → `.replaceBlock(at: i)` (single-block output guaranteed).
- `pasteIntoBlockquote` → `.replaceBlock(at: i)` (single-block output guaranteed).
- `pasteIntoHeading` → delta-based (same pattern as paragraph paste). Heading→paragraph kind change is folded into the first `.replaceBlock`.

Part 6 (atomic + HTML edges):
- `insertAroundAtomicBlock` multi-line paste branch → delta-based `.replaceBlock(at: blockIndex)` + N × `.insertBlock`. Covers N-block paste both before and after an atomic block (HR or table).
- HTML block typing fall-through → `.modifyInline(blockIndex:)`. HTML blocks splice the string into their raw content without splitting; the default typing path's contract already fit.
- HTML block Return → `.modifyInline` (same path — Return embeds "\n" in raw HTML).

Part 7 (cross-block merge):
- `mergeAdjacentBlocks` now carries its own contract at both return paths (coalesced vs. block-granular splice). Shape: delta-based `.replaceBlock(at: effectiveStart)` + |delta| × `.mergeAdjacent(firstIndex: effectiveStart)` when delta < 0, or + delta × `.insertBlock` when delta > 0 (rare). `effectiveStart` == `startBlock − 1` when `mergeIncludesPrevious` consumed the preceding paragraph, else `startBlock`.
- `delete()`'s multi-block branch inherits the contract from `mergeAdjacentBlocks` and refreshes its `postCursor` to match the caller's `storageRange.location` override.

**Tests added in parts 6–7 (6 new):** atomic-block multi-line paste (before + after), HTML typing, HTML Return, cross-block delete pair (3 blocks → 1), cross-block delete chain (5 blocks → 1).

### FSM helpers awaiting their own contracts

- `exitListItem`, `unindentListItem`, `returnOnEmptyListItem` in `ListEditingFSM.swift` already carry contracts; `insert()`'s list branch forwards via `return try`, so those propagate automatically. No further wiring was needed on the insert path.

### Phase 1 exit criterion: harness auto-assert (landed 2026-04-22)

- `EditTextView` exposes `lastEditContract` + `preEditProjection` associated properties, captured inside `applyEditResultWithUndo` before the splice. `EditorHarness` calls `Invariants.assertContract` after every scripted input (`type`, `pressReturn`, `pressDelete`, `pressForwardDelete`, `paste`). Nil-contract edits (pre-Batch-H legacy primitives) are silent no-ops — this is intentional; contract retrofits are gated per-primitive. Bucket B/C tests driven by the harness pick up contract enforcement automatically without needing to thread pre/post projection pairs.

### Phase 1 exit open-question — mermaid/math/table harness coverage (landed 2026-04-22)

- The Phase 2 open question "harness coverage of tables / math / mermaid" is resolved without the HTML-proxy detour. See the Open Questions section above for the full rationale; the short version is: (a) `.replaceTableCell` per-cell structural diff was already in `Invariants.swift` (lines 266–368), (b) mermaid/math are `.codeBlock(language: …)` blocks whose structural equality is caught by the size-preserving neighbor-preservation check at lines 248–264, and (c) new file `Tests/HarnessContractCoverageTests.swift` adds 4 end-to-end driver tests that make the coverage explicit: typing / backspace inside mermaid, typing inside math, and `replaceTableCellInline` through the harness-owned live projection. All 4 green at landing.

### Cursor / edit bugs deferred

- **Bug #41 `seamCursor` in the (paragraph, blankLine, paragraph) delete case.** An earlier attempt computed a seam cursor for the specific case where a multi-block delete consumes a blankLine between two paragraphs. User reported the live app behaviour became "a mess"; reverted 2026-04-21. The pure-function semantic is captured in `test_bug41_returnThenDelete_*` (passing at the primitive layer). The correct fix needs a live-repro-driven investigation — not a storage-index arithmetic patch in `EditingOps.delete` — that accounts for how narrowSplice + attachment-reuse interact when the seam block vanishes. Revisit once a harness test can drive the live path end-to-end.

### Pre-existing test baseline (intentionally red)

These stay red until their resolving phase lands. Not regressions — part of the documented Phase 1 snapshot.

- `test_bug60_findAcrossTableCells` — resolves "by construction" in Phase 2e when table cell text moves from `NSTextAttachment` into `NSTextContentStorage`. Spike in `Tests/TextKit2FinderSpikeTests.swift` (4 green) validates this assumption.
- `CommonMarkSpecTests.test_images` / `.test_links` — CommonMark edge cases beyond the current 80.7% coverage target. Not gated until Phase 6 closes on the 90% target.

### Process rule

Any time a future session skips, downscales, or defers something, record it here **before** moving on. "Remaining tasks" is the single source of truth for deferred work — if it isn't on this list, it will be forgotten.

---

## TODO — findings from Phase 2c investigation (2026-04-22)

### RESOLVED: Phase 2a regression — TK2 was torn down at startup

**Original symptom:** `BlockModelContentStorageDelegate` never installed in production. Every note in the live app was rendered by TK1 `NSLayoutManager`, not TK2. Phase 2a's "TK2 is live in production" claim was silently false.

**Root cause:** In `ViewController+Setup.swift::configureLayout()`, `self.sidebarSplitView.autosaveName = "SidebarSplitView"` ran *after* `migrateNibEditorToTextKit2`. Setting `autosaveName` synchronously restores the saved divider position from `UserDefaults`, which resizes subviews, which cascades layout to descendants including the editor's text view. During that resize cascade AppKit internally reads `.layoutManager` (TK1 API) on the text container, which lazily instantiates `NSLayoutManager` and permanently nils `textLayoutManager`. `initTextStorage()` then ran against a TK1-only view and its `textLayoutManager?.textContentManager` path silently skipped the delegate install.

**Fix (landed):** In `configureLayout()`, the migrate / configure / initTextStorage block was moved to the END of the method, after all autosaveName / setPosition / scrollerStyle work. The resize cascade now fires while the editor is still the storyboard-decoded TK1 nib instance — already TK1, nothing to tear down. The swap to TK2 + delegate install happens as the final step of `configureLayout`. `initTextStorage()` was removed from `configureEditor()` to avoid double-install.

**Verification (live):** Temporary DEBUG probe in `initTextStorage()` logged to `~/Documents/tk2-probe.log`:
```
[2026-04-22 11:29:51 +0000] initTextStorage TLM=present delegate=INSTALLED
```
TK2 is alive at delegate-install time and the delegate attaches successfully. Probe removed post-verification.

**Phase 2a status:** "TK2 is live in production" claim is now true. Phase 2c (custom `NSTextLayoutFragment` subclasses per block type) is unblocked.

### Deferred bug — Bugs 3 invisible todo text (TK1 draw path, unfixed)

**Symptom:** FSNotes++ note "Bugs 3" renders all todo-list text invisibly (white-on-white) on first paint. Content boundary at `## Code blocks & MathJax` (line 65): everything above invisible, everything below renders correctly. Any edit anywhere in the note makes the invisible text appear. Other notes unaffected.

**What is known:**
- `Bugs3NoteColorTests.swift` (kept; legitimate regression test) proves the block-model pipeline writes correct `labelColor` / `secondaryLabelColor` attributes on every todo line after fill. Both tests pass. The attributes are correct in `textStorage`.
- Because TK2 is torn down (see blocker above), the live app renders via TK1 `NSLayoutManager.drawGlyphs`. The bug is in the TK1 draw path, not in attribute assignment.
- Candidate content triggers in the broken region: `<mark>`, `<kbd>`, `<sup>`, `<sub>` inline HTML (lines 28, 31, 32 of the note).
- Not root-caused. Instrumentation was removed on the user's instruction to stop investigating.

**Gate:** Re-investigate only after Phase 2c replaces the TK1 draw path with custom `NSTextLayoutFragment` subclasses. If the bug persists under TK2 fragments, it's in attribute assignment after all and the test above is lying. If it disappears, it was a TK1-path artifact that Phase 2c eliminated structurally.
