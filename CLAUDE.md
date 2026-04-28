# CLAUDE.md — FSNotes++ Project Rules

Read `ARCHITECTURE.md` in this same directory for the full technical architecture (TK2 element / fragment dispatch, block model, FSMs per block type, edit contracts, theme, test infrastructure).

---

## Invariants Established by the Refactor

These are facts about the post-refactor codebase. The earlier iteration of this file phrased them as defensive rules against bugs that had shipped; the refactor has since made the violations either architecturally impossible or automatically caught. Read these before editing — they tell you what the code now guarantees so you don't write defensive patches against conditions that can't arise.

### A. Single write path into `NSTextContentStorage`

`DocumentEditApplier.applyDocumentEdit(priorDoc:newDoc:contentStorage:…)` (`FSNotesCore/Rendering/DocumentEditApplier.swift`) is the one function that mutates TK2 content storage for WYSIWYG edits. It consumes two `Document` values and emits a minimal element-bounded splice inside `performEditingTransaction`. The fill paths (`EditTextView.fillViaBlockModel` / `fillViaSourceRenderer` / `fill(note:)`) are the other authorized writers (initial-load, not edit-time).

Phase 5a (commit `7dc480d`) landed the mechanical enforcement: `StorageWriteGuard` (in `FSNotesCore/Rendering/StorageWriteGuard.swift`) exposes three scoped authorization flags (`applyDocumentEditInFlight`, `fillInFlight`, `legacyStorageWriteInFlight`); `TextStorageProcessor.didProcessEditing` traps in `#if DEBUG` when a character-edit happens in WYSIWYG mode (`blockModelActive && !sourceRendererActive`) with no authorization active. Release builds compile to no-ops. **14 production call sites across 6 logical categories** are wrapped in `StorageWriteGuard.performingLegacyStorageWrite { ... }` with TODOs: fold re-splice (`TextStorageProcessor.swift` ×1); async attachment hydration for inline math and display math (`EditTextView+BlockModel.swift` ×2), PDF (`InlinePDFView.swift` ×2), QuickLook (`InlineQuickLookView.swift` ×1); 8 formatting-IBAction `insertText` bypasses in `EditTextView+Formatting.swift` (link, wikiLink, code span, code block, table) — added by commit `e1e700d` to close the Phase 5a-caught `_insertText:replacementRange:` bypass class. The former drag-and-drop category (2 sites in `EditTextView+DragOperation.swift`) was retired in a Phase 5f follow-up that re-routed both drop handlers through `handleEditViaBlockModel` + a pure `markdownForDroppedURL` helper, and the former "undo/redo state restore" category was retired by Phase 5f's removal of `restoreBlockModelState` (journal replay now handles replay cleanly). Verify with `grep -c "StorageWriteGuard.performingLegacyStorageWrite" FSNotes/ FSNotesCore/ --include="*.swift" -r`. Each remaining site is a candidate for Phase 5f (undo/redo journaling) or a follow-up slice to route through `applyDocumentEdit` properly. The Phase 5e composition-session window will add one more sanctioned exemption, gated on `compositionSession.isActive && range ⊂ markedRange`.

`scripts/rule7-gate.sh` enforces the invariant at grep level: the `bypassStorageWrite` pattern flags any `performEditingTransaction` caller outside `FSNotesCore/Rendering/DocumentEditApplier.swift`.

Consequence: you cannot route an edit around the block model by reaching into storage directly — the DEBUG assertion traps it at runtime, the gate traps it at commit time. If a new editing feature tempts you to, build the `EditingOps` primitive and let the applier deliver it.

### B. One layout primitive per block type

Every per-block visual runs through TK2's element + fragment dispatch (`BlockModelContentStorageDelegate` → `BlockModelLayoutManagerDelegate` in `FSNotesCore/Rendering/`). Each block kind maps to exactly one `NSTextParagraph` subclass and at most one `NSTextLayoutFragment` subclass: `TableElement` / `TableLayoutFragment`, `CodeBlockElement` / `CodeBlockLayoutFragment`, `HeadingElement` / `HeadingLayoutFragment`, `BlockquoteElement` / `BlockquoteLayoutFragment`, `HorizontalRuleElement` / `HorizontalRuleLayoutFragment`, `MermaidElement` / `MermaidLayoutFragment`, `MathElement` / `MathLayoutFragment`, `DisplayMathElement` / `DisplayMathLayoutFragment`, `ParagraphWithKbdElement` / `KbdBoxParagraphLayoutFragment`, `SourceMarkdownElement` / `SourceLayoutFragment`, `FoldedElement` / `FoldedLayoutFragment`. Plain paragraphs and list items fall back to the default fragment.

Consequence: there is no second draw path for any block kind. If a block's rendering is wrong, the fragment class for that kind is where the fix lives. Don't add a parallel drawer.

### C. All block content lives in `NSTextContentStorage`

Tables carry cell text as live character runs in content storage (Phase 2e T2-f, default `true` since 2026-04-23 commit `957dc7e`). Mermaid and math keep their source text in storage and hide only visually via their fragments. `NSTextFinder` / Cmd+F / accessibility traverse everything by construction — Bug #60 ("find across table cells") is now a passing test, not a feature request.

Consequence: no block kind should route through `NSTextAttachment` as its *only* source of text. Attachments are for inline images, PDFs, QuickLook previews, list bullets, and checkboxes — not for block content that needs to participate in text search.

### D. No marker-hiding tricks in storage

WYSIWYG storage contains only displayed characters — markdown markers (`**`, `#`, `` ` ``, `>`, list prefixes, fence lines, HR lines, cell pipes) do not exist in `textStorage.string`. There is nothing to hide, so the tiny-font / clear-foreground / negative-kern / invisible-character tricks of earlier iterations cannot arise. Source mode *does* contain markers but renders them via `SourceRenderer` + `SourceLayoutFragment.draw` overpainting `.markerRange` runs in `Theme.shared.chrome.sourceMarker`; the default text-layer `.foregroundColor` is never mutated to hide or dim markers.

`scripts/rule7-gate.sh` enforces this as a grep gate: `systemFont(ofSize: 0.…)`, `ofSize: 0`, `foregroundColor ... NSColor.clear`, `addAttribute(.kern`, `func parseInlineMarkdown` all exit 1. Run it before editing any file under `FSNotes/Rendering/` or `FSNotesCore/Rendering/`.

### E. Views read data; views never write data

The projection → renderer → element → fragment chain is one-way. Views capture user intent (clicks, keystrokes, selections) and call a pure `EditingOps.*` primitive that returns a new `Document`; `applyDocumentEdit` delivers the minimal splice. The rule-7 gate catches the view-read half via banned patterns for `headers[…] = …stringValue` / `rows[…][…] = …stringValue`. The storage-write half is now caught by Phase 5a's debug assertion (see Invariant A above).

The `InlineTableView` / `TableRenderController` widget files that historically violated this (mutable `rows`/`headers`/`alignments` state, `collectCellData` reading `cell.stringValue` back into the model, `serializeViaBlockModel` walking live attachments at save time) were deleted on 2026-04-23 in Phase 2e T2-h (commit `de1f146`, ~4,524 LoC removed). They are the cautionary tale in the Historical Record below, not live code.

### F. Theme is the sole presentation source of truth

Every font size, color, paragraph spacing, border width, margin, and line-height literal is defined in `FSNotesCore/Rendering/ThemeSchema.swift` and `Resources/default-theme.json` (+ `Resources/Themes/Dark.json`, `HighContrast.json`). Renderers and fragments *read* from `Theme.shared`; they do not hardcode values. The rule-7 gate enforces this with `literalSystemFont`, `literalParaSpacing`, and `hexColorLiteral` patterns scoped to `FSNotesCore/Rendering/`. User theme overrides at `~/Library/Application Support/FSNotes++/Themes/*.json` replace the bundled entry of the same basename.

Consequence: if you need a new presentation value, extend `ThemeSchema.swift` and the JSON defaults; don't inline a literal in a fragment.

### G. `EditContract` checks every edit

Every `EditingOps` primitive returns an `EditResult` carrying an `EditContract` (before-span, after-span, replacement bytes, resulting cursor). `Invariants.assertContract(before:after:contract:)` runs in the pure unit tests *and* in the `EditorHarness` live harness after every scripted input. Both the pipeline tests and the live-editor tests share the same invariant check — a pure-layer pass implies a live-layer pass for the same primitive.

---

## Rules That Still Apply

The refactor cannot enforce these; they are discipline rules for Claude and anyone writing code in this repo.

### 1. When you're about to violate a principle, stop and tell the user.

If a task seems to require routing around the architecture (a second write path, a view reading back into the model, a literal presentation value outside Theme), stop the tool call and write a paragraph to the user: "the clean fix requires X, the shortcut would be Y, here's the tradeoff." Wait for a decision. The user's time budget is theirs to spend, not yours. The refactor's invariants exist because the last time this rule was skipped, the compounding shortcuts in `InlineTableView` accumulated into a widget that had to be deleted wholesale.

### 2. Never fabricate historical or technical reasoning.

When asked why a piece of code looks a certain way, the honest answer starts with either "I wrote it that way because <actual reason>" or "I don't remember — let me look at git blame." Do not invent a plausible-sounding history ("this predates the refactor," "this was a constraint from an earlier design") to paper over not remembering. You don't have reliable in-the-moment access to history; if you invent one it will be wrong.

### 3. A passing test suite with shipping bugs means the tests cover the wrong layer.

~1330+ tests passing while the user reports live bugs means the test suite is pure-layer only and the bug is in the widget/view glue. The fix is not to add more pipeline tests — it's to identify the pure function that represents the feature's core logic and test *that*. If no such pure function exists yet, extracting it is the first fix. This principle is what made the pre-refactor `InlineTableView` bugs invisible to the then-556-test suite.

### 4. New widgets and new renderers must be unit-testable as pure functions on value types.

If a test for your feature's core logic needs an `NSWindow`, a real field editor, or synthetic mouse events, the logic is in the wrong layer. Move it into a pure primitive on `Document` / `Block` / `Inline` values and test that. Keep the widget thin — it captures intent and calls the primitive.

### 5. Run the rule-7 grep gate before editing files under `FSNotes/Rendering/` or `FSNotesCore/Rendering/`.

```bash
./scripts/rule7-gate.sh        # exit 0 = clean, 1 = violation
```

It's fast (pure shell, no xcodebuild). The gate enforces the marker-hiding and literal-presentation-value bans automatically. If the baseline isn't clean, stop — the existing code is already violating an invariant and pattern-matching from it will extend the violation.

The "inherited violation" failure mode is the reason this is mechanical rather than discretionary: discipline fails under load. Running the gate is cheap and catches the whole class.

### 6. Debug flow: identify the stage, fix at the stage.

Before writing any fix:

1. Which pipeline stage is responsible? (parser, `EditingOps` primitive, `DocumentRenderer`, element class, fragment class, `applyDocumentEdit`, theme lookup)
2. Am I modifying THAT stage, or patching somewhere else?
3. If #2 is "somewhere else" — stop. Go back to #1.

Never set attributes after an operation to override what a stage already applied. Never patch the save path to rewrite state at serialization time. If the projection is wrong at save, the edit that produced it was wrong.

### 7. After 3 failed attempts, write a test.

If a bug isn't fixed after 3 tries, stop coding and write a pure-function unit test that captures the bug. If you can't express the bug as a pure function on value types, that's the bug — the logic is tangled in the view layer and needs extraction first.

### 8. Read before writing.

Before writing ANY code:

- Read every function in the call chain.
- Search for existing mechanisms before adding new ones (grep the method name, read the parent class, read the callers).
- Trace the full execution path ONCE before making changes; don't patchwork-fix.
- Never use `== .none` on a Swift `Optional` — it conflates `Optional.none` with an enum case named `.none`. Use `== nil`.

---

## App Identity

- **Original FSNotes**: `/Applications/FSNotes.app` — don't touch this
- **FSNotes++** (our fork): `~/Applications/FSNotes++.app` — this is what we build and deploy
- Both share the same bundle ID (`co.fluder.FSNotes`), same notes folder, same iCloud container
- Quote paths in shell: `~/Applications/"FSNotes++.app"` (the `++` requires quotes)

## Build Environment

- **Workspace**: `FSNotes.xcworkspace` (not `.xcodeproj` — Pods won't resolve)
- **Pods are pre-installed** in the repo. Do NOT run `pod install`. If you get "unable to resolve module dependency" errors, you're using `-project` instead of `-workspace`.
- Use the `xcode-build-deploy` skill for ALL builds. Don't improvise the sequence.
- **ALWAYS redirect xcodebuild output to a file.** xcodebuild (build AND test) produces thousands of lines per invocation — dumping into context burns budget. Redirect to a temp log and grep for what matters:
  ```bash
  xcodebuild -workspace FSNotes.xcworkspace -scheme FSNotes build > /tmp/xcbuild.log 2>&1
  # then: tail -n 50 /tmp/xcbuild.log, or: grep -E "error:|warning:|BUILD" /tmp/xcbuild.log
  xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes > /tmp/xctest.log 2>&1
  # then: grep -E "Test Case|failed|passed|error:" /tmp/xctest.log | tail -n 100
  ```
  NEVER let xcodebuild output stream directly into the tool result. Same for `swift build` / `swift test`.
- Debug builds are **NOT sandboxed** despite entitlements having `app-sandbox = true`. `NSHomeDirectory()` resolves to `/Users/guido` (real home). Ad-hoc codesigning doesn't enforce sandbox.
- **`Resources/MPreview.bundle` MUST remain in git.** It contains mermaid.min.js, MathJax (tex-mml-chtml.js + woff fonts), highlight.js, and syntax theme CSS. `BlockRenderer.swift` depends on it at runtime for diagram/math/code rendering. Do NOT delete it.

### Worktrees: CocoaPods symlinks required

Git worktrees do NOT copy `.gitignored` files. `Pods/`, `Podfile`, and `Podfile.lock` are all `.gitignored`. **After creating any worktree**, you MUST symlink these from the main repo:

```bash
MAIN_REPO="/Users/guido/Documents/Programming/Claude/fsnotes"
WORKTREE="$MAIN_REPO/.claude/worktrees/<name>"
ln -s "$MAIN_REPO/Pods" "$WORKTREE/Pods"
ln -s "$MAIN_REPO/Podfile" "$WORKTREE/Podfile"
ln -s "$MAIN_REPO/Podfile.lock" "$WORKTREE/Podfile.lock"
```

Without these, `xcodebuild` fails with "unable to resolve module dependency". This is the correct way to handle gitignored dependencies in worktrees.

### Worktrees: prune after the batch lands

The Claude Code harness creates an `isolation: "worktree"` worktree per agent and locks it (`locked claude agent agent-* (pid <harness>)`). It does NOT auto-clean. They accumulate at ~37 MB each; 24 worktrees = ~870 MB of waste. Prune proactively as part of cleanup after each batch:

```bash
# for each non-live worktree whose branch is merged OR is a pre-refactor stale-base branch:
git worktree unlock <wt-path>
git worktree remove --force <wt-path>
git branch -d worktree-<name>      # or -D if confirmed safe-to-discard
git worktree prune
```

Classify before removing:
- **MERGED** (branch is ancestor of master): zero-risk, remove + `-d`
- **UNMERGED at fork base** (e.g., 18 commits ahead of master but at `593ad79` or other pre-refactor): these are upstream-fork commits, not agent work — safe to remove + `-D`, verify once with `git log master..<branch>` to confirm
- **LIVE** (agent still running): leave alone

Also: **verify the worktree base before relying on it**. The harness sometimes spawns a worktree at a stale commit rather than current master. Agent first-step should do `git log --oneline -1` + `ls REFACTOR_PLAN.md` (or equivalent critical file); STOP if not on expected base. If the harness's `isolation: "worktree"` is unreliable, fall back to solo main-repo work with commit-as-you-go (Phase 5a / Batch N+8 pattern).

### Adding new Swift files to the Xcode project

When creating ANY new `.swift` file, you MUST add it to `FSNotes.xcodeproj/project.pbxproj` in FOUR places:

1. **PBXBuildFile** — `<ID_B1> /* File.swift in Sources */ = {isa = PBXBuildFile; fileRef = <ID_F1> /* File.swift */; };`
2. **PBXFileReference** — `<ID_F1> /* File.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = File.swift; sourceTree = "<group>"; };`
3. **PBXGroup children** — add `<ID_F1>` to the appropriate group's `children` array
4. **PBXSourcesBuildPhase** — add `<ID_B1>` to the target's Sources build phase `files` array

For test files, the target is `FSNotesTests` (build phase ID: `TEST00000000000000000005`). For app files, use the main `FSNotes` target.

**Files on disk but not in pbxproj are silently ignored by xcodebuild.** Always verify after adding.

## Runtime Environment (Debug Builds)

### NOT sandboxed — critical implications

- `NSHomeDirectory()` → `/Users/guido` (real home, NOT a container)
- `UserDefaults` reads/writes → `~/Library/Preferences/co.fluder.FSNotes.plist`
- Documents directory → `~/Documents/`
- To change a UserDefaults value from the command line:
  ```bash
  # Kill cfprefsd FIRST (it caches aggressively), then write
  killall cfprefsd 2>/dev/null
  /usr/libexec/PlistBuddy -c "Set :keyName value" ~/Library/Preferences/co.fluder.FSNotes.plist
  ```
- **cfprefsd caches UserDefaults values in memory.** If you write to the plist while the daemon is running, it may overwrite your changes. Always `killall cfprefsd` before `PlistBuddy` writes.

### Diagnostic logging

- **NEVER use NSLog()** — output doesn't reliably appear in `log show` for GUI apps.
- **Use file-based logging** via `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)` which resolves to `~/Documents/` for FSNotes++.
- **ALWAYS write a timestamp + sentinel on app launch** — if the log file doesn't exist after launch, the logging code isn't executing.
- Unit test output goes to `NSHomeDirectory() + "/unit-tests"` → `~/unit-tests/` (not sandboxed).

## Debugging Rules

See "Rule 6 — Debug flow" above for the stage-first fix discipline. A few TK2-specific reminders:

- **`cacheDisplay` does NOT capture fragment-level drawing.** `bitmapImageRepForCachingDisplay` / `cacheDisplay` invokes the view's `draw()` method but does not invoke `NSTextLayoutFragment.draw`. Per-block chrome (HR line, blockquote border, heading hairline, kbd box, code-block border) won't appear in test snapshots taken this way. Verify these by asserting the fragment class dispatches correctly (see `TextKit2FragmentDispatchTests`) or deploying to the live app.

- **Element-vs-fragment attribute ownership.** `DocumentRenderer` / `SourceRenderer` tag `.blockModelKind` + any per-kind payload (`.headingLevel`, `.tableAuthoritativeBlock`, `.renderedBlockSource`) at render time. `BlockModelContentStorageDelegate` reads those and constructs the right element class; `BlockModelLayoutManagerDelegate` dispatches by element class to the right fragment. Untagged mid-splice windows fall back to default TK2 paragraphs.

- **Marked-text composition bypasses `applyDocumentEdit`.** This is the documented Phase 5e exemption to the single-write-path rule — during IME / dead-key / emoji-picker input `setMarkedText` lets TK2 write to `NSTextContentStorage` directly; on commit (`unmarkText`) the committed run is folded into `Document` via one `applyDocumentEdit` call. The 5a debug assertion is relaxed on `compositionSession.isActive && range ⊂ markedRange`.

## State Machine: Return Key

`EditingOps.newLine(in:projection:)` is the entry point. When adding a new transition:

- Add the case to `NewLineTransition` enum.
- Add detection logic to `newLineTransition()` (pure function — no side effects).
- Add execution logic to `applyTransition()`.
- The post-transition block at the end of `newLine()` sets typing attributes for ALL cases — don't duplicate this in individual cases.

Per-block Return behavior is tabulated in `ARCHITECTURE.md` → "Editing FSMs by Block Type".

## Test Patterns

### Tests exercise pure primitives, not widgets.

The pure-function tests (`BlockParserTests`, `EditingOperationsTests`, `BlockModelFormattingTests`, `MarkdownSerializer*Tests`, `ListEditingFSMTests`, `EditContractTests`, `DocumentEditApplierTests`) call `EditingOps.*` / `MarkdownParser.parse` / `MarkdownSerializer.serialize` / `DocumentEditApplier.diffDocuments` directly on value-typed `Document`s with no AppKit setup. Use this layer by default.

### HTML Parity harness

`EditorHTMLParityTests.swift` renders "expected" (fresh parse of target markdown) and "live" (editor after simulated edit script) `Document`s to HTML via `DocumentHTMLRenderer` and asserts byte-equal. Also verifies the `HTML(doc) == HTML(parse(serialize(doc)))` round-trip property. This is the canonical live-edit harness.

### EditorHarness DSL

`Tests/EditorHarness.swift` — script edits with `.type(…)`, `.pressReturn`, `.backspace`, `.select(…)`, `.toggleBold`, `.setHeading(level:)`, `.toggleList`, `.toggleQuote`, `.insertHR`, `.toggleTodo`. After every input the harness reads `EditTextView.preEditProjection` + `.lastEditContract` (set by `applyEditResultWithUndo`) and runs `Invariants.assertContract(before:after:contract:)` on the live projection — the same invariant the pure-function tests enforce.

### TK2 dispatch tests

`TextKit2FragmentDispatchTests.swift` / `TextKit2ElementDispatchTests.swift` construct a minimal `NSTextContentStorage` + layout manager with the real delegates, feed rendered output, and assert the correct element / fragment class comes back per paragraph range.

### Test output location

```swift
let outputDir = NSHomeDirectory() + "/unit-tests"
// Resolves to ~/unit-tests/ (debug builds are NOT sandboxed)
```

### A/B comparison pattern

Compare "loaded note" (known-good) vs "live editing" (what you're testing). If they differ, the live editing path has a bug. Measure fragment class dispatch, paragraph styles, attribute values — not just string content.

## Current State

### Block-Model Pipeline (WYSIWYG, all block types)

- Parser: `MarkdownParser` → `Document` (block model) → `MarkdownSerializer` round-trip.
- Renderer: `DocumentRenderer` renders all block types to `NSAttributedString` — no markdown markers in storage. `.blockModelKind` + per-kind payload attributes tag each paragraph for element dispatch.
- Editing: `EditingOps` handles insert / delete / split / merge / paste for every block kind:
  - Paragraphs, headings, code blocks: full editing.
  - Lists: structural ops via `ListEditingFSM` (indent, unindent, exit, newItem).
  - Blockquotes: line-level editing inside the block.
  - Horizontal rules: read-only (cross-block merge handles removal).
  - Tables: cell-level editing via `EditingOps.replaceTableCellInline` (takes `[Inline]`, NOT raw markdown).
  - Block merges: heading+paragraph, list→paragraph, etc.
- Toolbar formatting (block-model path): `toggleInlineTrait`, `changeHeadingLevel`, `toggleList`, `toggleBlockquote`, `insertHorizontalRule`, `toggleTodoList`, `toggleTodoCheckbox`. Wired in `EditTextView+Formatting.swift`.
- TK2 stack: `NSTextLayoutManager` + `NSTextContentStorage` + `BlockModelContentStorageDelegate` + `BlockModelLayoutManagerDelegate`. One element class + at most one fragment class per block kind (see Invariant B).
- Edit application: every WYSIWYG edit flows through `DocumentEditApplier.applyDocumentEdit` (see Invariant A).
- Save path: block-model notes save via `Note.save(markdown:)` which serializes the projection. `NoteSerializer.prepareForSave` has been retired; `.save(content:)` remains as a legacy source-mode path and is grep-gated against reintroduction.
- Document caching: `Note.cachedDocument` avoids re-parsing on every fill; invalidated on save/load/reload.
- Fold state: `Note.cachedFoldState: Set<Int>?` (block storage offsets). A fold toggle sets `.foldedContent`; the content-storage delegate returns `FoldedElement` / `FoldedLayoutFragment` regardless of underlying block kind. No `syncBlocksFromProjection` bridge — fold reads directly off the projection.
- IME composition: `FSNotesCore/Rendering/CompositionSession.swift` (Phase 5e) — marked-text session attached to `EditTextView` via associated-object storage. `setMarkedText` enters the session, commit folds the final text into `Document` via one `applyEditResultWithUndo` call. The Phase 5a DEBUG assertion is relaxed for storage mutations strictly inside `session.markedRange` while `isActive`; this is the only sanctioned architectural exemption to the single-write-path rule. See `ARCHITECTURE.md` → "IME Composition".
- Undo / redo: `FSNotesCore/Rendering/UndoJournal.swift` (Phase 5f) — per-editor journal with `past`/`future` stacks, each entry carrying an `EditContract.InverseStrategy` (Tier A cheap inverse / Tier B block-snapshot / Tier C full-document). `applyEditResultWithUndo` records one `UndoEntry` per edit unless replay or composition is in flight. 5-class coalescing FSM (typing / deletion / structural / formatting / composition). Exactly one `NSUndoManager.registerUndo` site survives in the editor path (inside `UndoJournal.record`). `restoreBlockModelState` retired. See `ARCHITECTURE.md` → "Undo / Redo".

### Source-mode pipeline (`hideSyntax == false`)

- Shares `Document` and TK2 with WYSIWYG but renders via `SourceRenderer` (markers re-injected, tagged `.markerRange`).
- Each paragraph tagged `.blockModelKind = .sourceMarkdown`; delegates dispatch to `SourceMarkdownElement` + `SourceLayoutFragment`.
- `SourceLayoutFragment.draw` calls super for default text, then overpaints `.markerRange` runs in `Theme.shared.chrome.sourceMarker`. No `.foregroundColor` mutation.
- `TextStorageProcessor` does minor post-edit work (attachment restore, fold-attribute propagation) — not highlighting. The `NotesTextProcessor.highlight*` markdown path was retired in Phase 4.4 (commit `6b875ab`); the rule-7 gate pattern `legacyMarkdownHighlight` prevents reintroduction.

### Attachment handling

- `NSTextAttachmentViewProvider` subclasses: `ImageAttachmentViewProvider`, `PDFAttachmentViewProvider`, `QuickLookAttachmentViewProvider`, `BulletAttachmentViewProvider`, `CheckboxAttachmentViewProvider`.
- Transparent-placeholder pattern: each attachment initializes `.image` with a size-matched transparent `NSImage` memoized in an `NSCache`, so TK2's first-layout-pass document-icon-glyph flash is invisible (commit `c033b46`).
- Block-level attachments that previously existed for tables / mermaid / math have been replaced: tables are native content-storage cells (Phase 2e T2-f); mermaid and math render via their own fragments reading `.renderedBlockSource` from storage.

### Theme

Single source of truth for every presentation literal. See `ARCHITECTURE.md` → "Theme". Bundled defaults at `Resources/default-theme.json`, `Resources/Themes/Dark.json`, `Resources/Themes/HighContrast.json`. User overrides at `~/Library/Application Support/FSNotes++/Themes/*.json` — user-override-wins on basename match. `Theme.shared` + `Theme.didChangeNotification` for live-reload. Preferences IBActions mutate the theme and persist via `Theme.saveActiveTheme` (Phase 7.5.a, commit `fb0c3a5`).

### Diagnostic log

`~/Documents/block-model.log` — file-based (NSLog doesn't work in GUI apps; see Diagnostic logging above). Written by `bmLog` helper.

### CommonMark Spec Compliance (v0.31.2)

Serializer compliance: **631 / 652 passing (96.8%)** — Phase 10 Slice A baseline (620) advanced by Phase 12.C.6.a–g (+11, seven slices closing spec examples #218, #540, #541, #548, #559, #568, #238, #524, #526, #536, #538). Two additional buckets reached 100% in 12.C.6: Block quotes (25/25 via #238) and Link reference definitions (27/27 via #218).

- Perfect (100%): Precedence, Textual content, Inlines, Code spans, Soft line breaks, Hard line breaks, Blank lines, ATX headings, Setext headings, Backslash escapes, Entity refs, Paragraphs, Fenced code blocks, Autolinks, Indented code blocks, Emphasis, Raw HTML, Thematic breaks, **Link reference definitions** (12.C.6.a), **Block quotes** (12.C.6.f).
- Near-perfect (90%+): Tabs (10/11, 91%), HTML blocks (43/44, 98%), Links (85/90, 94%), Images (21/22, 95%).
- Moderate (70–89%): List items (42/48, 88%), Lists (19/26, 73%).
- All failing buckets above 70%.

Remaining 21 failing examples by bucket:
- **Links (5)**: delimiter-stack rewrite for link-in-link literalization (#518, #519, #520, #532, #533). Pre-existing TODO; tracked for potential follow-up.
- **List items (6)** + **Lists (7)**: multi-block list items where the continuation is a *fenced* code block, blockquote, or HTML block inside the item body (#278, #289, #290, #292, #293, #300, #312, #313, #318, #320, #321, #324, #325). The current `ListItem.children: [ListItem]` shape only nests sub-lists; arbitrary per-item block children require redesigning `ListItem.children` to `[Block]` with ~107 call-site updates across EditingOps / SourceRenderer / ListEditingFSM. Tracked for potential Phase 11 (Slice B).
- **Tabs (1)**: mixed space-tab list-nesting indent case (#9, tied to multi-block list family).
- **HTML blocks (1)**: `<div>` as list-item first-line content (#175 — same Slice B family).
- **Images (1)**: wikilink-extension bleed through image ref-def pattern (#590, accepted FSNotes++ extension non-conformance).

Phase 10 Slice A trajectory: **601 → 620 / 652 (+19)** in 12 commits (`f9aa284 → 3018ff0`, 2026-04-24). Each commit locks in one or more bucket fixes: short HTML comment forms, ref-def URL/title separator, multi-line ref-def labels, tight-list heuristic refinement, HR-beats-list-item precedence, setext-underline-on-lazy guard, Unicode S-category as punctuation, indented-code trailing-whitespace preservation, blockquote tab partial-consumption, list-item first-line indented-code detection, `stripLeadingSpaces` virtual-column preservation, HTML-block 3-space indent cap, first-item-blankLineBefore exclusion, empty-content item lazy continuation.

Full corpus in `Tests/CommonMark/`; per-section reports dump to `~/unit-tests/commonmark-compliance.txt`, per-failure dumps (md / expected / actual triples) to `~/unit-tests/commonmark-failures.txt` via `test_000_dumpAllFailures`. Every phase is gated against "must not regress from current baseline."

---

## Historical Record

These are the bugs and anti-patterns that motivated the refactor. They are preserved here as teaching material; the code they describe has been deleted.

### The `InlineTableView` cautionary tale

`InlineTableView` was built with its own mutable `rows` / `headers` / `alignments` state, and cell edits mutated that state directly. `serializeViaBlockModel()` was then patched to reach sideways into live view state at save time and rewrite `Block.table.raw` before serialization. `collectCellData` walked the table at edit time and copied `cell.stringValue` back into the model — which, because the cell rendered with `attributedStringValue` (markers stripped by the widget's local `parseInlineMarkdown`), silently overwrote formatted data with flattened text. Editing one cell wiped formatting in another. Saving a note required a live-tables check in `save()` to force a view walk. Every bug required an `NSWindow` + field editor to reproduce.

Progression of fixes:

- Stage 1 (data shape): `Block.table` carries `TableCell` values with `inline: [Inline]`.
- Stage 2 (rendering): widgets renders cells via `InlineRenderer.render` — same code path paragraphs use. Widget-local regex parser deleted.
- Stage 3 (editing): `InlineRenderer.inlineTreeFromAttributedString` as the inverse of `render`; `EditingOps.replaceTableCellInline(blockIndex:at:inline:in:)` as the pure primitive; `EditTextView.applyTableCellInlineEdit` as the editor entry point. 24 round-trip converter tests + 15 primitive tests + 2 cross-cell persistence contract tests.
- Stage 4 (cleanup): widget-local `parseInlineMarkdown`, `collectCellData`, `generateMarkdown`, `skipCollect` flag, `prepareRenderedTablesForSave` (the save-path walker), `hideMarker` / `applyLiveAttributes` all deleted.
- Phase 2e T2 (2026-04-23, commits `957dc7e` + `452d1f2` + `de1f146`): table cells moved into `NSTextContentStorage` as native characters. `TableElement` / `TableLayoutFragment` render natively. `FSNotes/Helpers/InlineTableView.swift` (~2,319 LoC) and `FSNotes/TableRenderController.swift` (~471 LoC) deleted along with `TableBlockAttachment`, `TableAttachmentViewProvider`, `TableAttachmentHosting`, and the `nativeTableElements` feature flag. Bug #60 ("Find across table cells") now passes by construction.

The meta-lesson: the first line of `InlineTableView` was the mistake. There was no "I'll do it properly later" — the correct time to design the block-model primitive for tables was before the widget was written. This is what invariants A–E are meant to prevent recurring.

### The `LayoutManager.drawBackground` drawer stack

`FSNotes/LayoutManager.swift` was a custom `NSLayoutManager` subclass that drew bullet dots, blockquote borders, HR lines, and kbd box backgrounds via `drawBackground` — a TK1-only pathway. An `AttributeDrawer` protocol in `FSNotes/Rendering/` had five conformers (`BulletDrawer`, `HorizontalRuleDrawer`, `BlockquoteBorderDrawer`, `KbdBoxDrawer`, `ImageSelectionHandleDrawer`).

Under TK2 this whole stack is wrong: TK2 uses `NSTextLayoutFragment.draw`, not layout-manager background draws, and the drawer files had no path to get called. Phase 2c/2d ported every per-block draw into a fragment class. Phase 4.5 deleted `LayoutManager.swift`. The four bullet / HR / blockquote-border / kbd-box drawers were absorbed into fragment-level draws and deleted; the `AttributeDrawer` protocol itself is gone. Only `FSNotes/Rendering/ImageSelectionHandleDrawer.swift` survives, and it is actively used (`InlineImageView.swift:411`, `EditTextView.swift:161`, `EditTextView+Interaction.swift:583`) — image-selection hit-testing still lives in the helper rather than in a fragment.

Rule-7 gate pattern `tk1LayoutManager` (`class LayoutManager : NSLayoutManager` / `layoutManagerIfTK1`) prevents reintroduction.

### The `NoteSerializer.prepareForSave` / `save(content:)` pair

The source-mode save path used to run a view walk at save time to reconcile widget state back into markdown. Retired in Phase 4.7; the rule-7 gate pattern `legacySaveContent` (matching `.save(content:` and `prepareForSave`) prevents reintroduction. All saves route through `Note.save(markdown:)` on the projection.

### The `syncBlocksFromProjection` bridge

A helper that copied `Document.blocks` into a source-mode mirror array on `TextStorageProcessor` so fold/unfold could read it. Retired in Phase 4.6; fold state now reads directly off the projection via the `documentProjection` setter's auto-sync. The rule-7 gate pattern `legacyBlocksPeer` prevents reintroduction.

### The phase-4 marker-hiding attempt

An earlier iteration tried to preserve markers in WYSIWYG storage and hide them visually via tiny-font / clear-foreground / negative-kern attributes so Cmd+F could find them. This failed in several ways (cursor invisibility, layout flicker, find-result ranges pointing at invisible runs). The replacement design: markers don't live in WYSIWYG storage at all; find-across-markers is addressed by source mode (where markers are real content) and by the authoritative `Document` being searchable independently of presentation. The rule-7 gate's marker-hiding patterns enforce that this mistake can't be reintroduced piecemeal.

---

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **fsnotes** (20921 symbols, 385102 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/fsnotes/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "auth validation"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |
| `rename` | Safe multi-file rename | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher` | Custom graph queries | `gitnexus_cypher({query: "MATCH ..."})` |

## Impact Risk Levels

| Depth | Meaning | Action |
|-------|---------|--------|
| d=1 | WILL BREAK — direct callers/importers | MUST update these |
| d=2 | LIKELY AFFECTED — indirect deps | Should test |
| d=3 | MAY NEED TESTING — transitive | Test if critical path |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/fsnotes/context` | Codebase overview, check index freshness |
| `gitnexus://repo/fsnotes/clusters` | All functional areas |
| `gitnexus://repo/fsnotes/processes` | All execution flows |
| `gitnexus://repo/fsnotes/process/{name}` | Step-by-step execution trace |

## Self-Check Before Finishing

Before completing any code modification task, verify:
1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## Keeping the Index Fresh

After committing code changes, the GitNexus index becomes stale. Re-run analyze to update it:

```bash
npx gitnexus analyze
```

If the index previously included embeddings, preserve them by adding `--embeddings`:

```bash
npx gitnexus analyze --embeddings
```

To check whether embeddings exist, inspect `.gitnexus/meta.json` — the `stats.embeddings` field shows the count (0 means no embeddings). **Running analyze without `--embeddings` will delete any previously generated embeddings.**

> Claude Code users: A PostToolUse hook handles this automatically after `git commit` and `git merge`.

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
