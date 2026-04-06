# CLAUDE.md — FSNotes++ Project Rules

Read `ARCHITECTURE.md` in this same directory for the full technical architecture (pipeline stages, block model, state machine, test infrastructure, build/deploy).

## App Identity

- **Original FSNotes**: `/Applications/FSNotes.app` — don't touch this
- **FSNotes++** (our fork): `~/Applications/FSNotes++.app` — this is what we build and deploy
- Both share the same bundle ID (`co.fluder.FSNotes`), same notes folder, same iCloud container
- Quote paths in shell: `~/Applications/"FSNotes++.app"` (the `++` requires quotes)

## Build Environment

- **Workspace**: `FSNotes.xcworkspace` (not `.xcodeproj` — Pods won't resolve)
- **Pods are pre-installed** in the repo. Do NOT run `pod install`. If you get "unable to resolve module dependency" errors, you're using `-project` instead of `-workspace`
- Use the `xcode-build-deploy` skill for ALL builds. Don't improvise the sequence
- Debug builds are **NOT sandboxed** despite entitlements having `app-sandbox = true`. `NSHomeDirectory()` resolves to `/Users/guido` (real home). Ad-hoc codesigning doesn't enforce sandbox.

## Logging & Debugging

### Diagnostic logging
- **NEVER use NSLog()** — output doesn't reliably appear in `log show` for GUI apps
- **Use file-based logging** via `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)` which resolves to `~/Documents/` for FSNotes++
- **ALWAYS write a timestamp + sentinel on app launch** — if the log file doesn't exist after launch, the logging code isn't executing
- **Search for logs with `find`** — don't assume you know the exact path
- Current block-model diagnostic log: `~/Documents/block-model.log`
- Unit test output goes to: `NSHomeDirectory() + "/unit-tests"` → `~/unit-tests/` (not sandboxed)

## Debugging Rules

### Before writing ANY fix:
1. **Which pipeline stage is responsible?** (see ARCHITECTURE.md for stages)
2. **Am I modifying THAT stage, or patching somewhere else?**
3. If #2 is "somewhere else" — STOP. Go back to #1.

### No post-hoc patches
Never set attributes AFTER an operation to override what a rendering stage already applied. Fix the stage that applies the wrong attribute. Every time you catch yourself writing `storage.addAttribute` or `textView.typingAttributes = ...` after an `insertText` call, you're patching — find which stage ran during `insertText` and fix it there.

### After 3 failed attempts, write a unit test
If a bug isn't fixed after 3 tries, STOP coding and write a unit test that captures the bug. For rendering bugs, checking attribute values is insufficient — you need to verify the rendered visual output (see test patterns in ARCHITECTURE.md).

### `cacheDisplay` does NOT capture LayoutManager drawing
`bitmapImageRepForCachingDisplay` / `cacheDisplay` captures the view's `draw()` method but does NOT trigger `LayoutManager.drawBackground`. This means AttributeDrawer rendering (bullets, blockquote borders, horizontal rules) won't appear in test snapshots. Verify these by checking attributes exist, or by deploying to the live app.

### Read before writing
Before writing ANY code in this project:
- Read every function in the call chain
- Search for existing mechanisms before adding new ones (grep for the method name, read the parent class, read the callers)
- Trace the full execution path ONCE before making changes
- Never use `== .none` on a Swift Optional — use `== nil`

## Architecture Principles

1. **Storage is markdown**: Never mutate text storage for display. Rendering is attributes + drawing only.
2. **Each stage owns specific attributes**: Don't set `.paragraphStyle` outside phase5/DocumentRenderer. Don't set `.font` outside the highlighter. Block model renders without `.kern` or clear-color hiding (phase4 has been removed).
3. **Fix at the source stage**: When an attribute is wrong, trace which stage sets it and fix there.
4. **Generalize, don't specialize**: When fixing a problem that recurs across cases (e.g., typing attributes after Return for ALL transition types), build one parameterized solution, not N special cases.
5. **Never change working behavior** without telling the user or asking first.

## State Machine: Return Key

The Return key state machine defines what happens on every line type. When adding new transitions:
- Add the case to `NewLineTransition` enum
- Add detection logic to `newLineTransition()` (pure function — no side effects)
- Add execution logic to `applyTransition()`
- The post-transition block at the end of `newLine()` sets typing attributes for ALL cases — don't duplicate this in individual cases

## Test Patterns

### Test output location
```swift
let outputDir = NSHomeDirectory() + "/unit-tests"
// Resolves to ~/unit-tests/ (debug builds are NOT sandboxed)
```

### Full pipeline test setup
```swift
let editor = makeFullPipelineEditor()  // Creates EditTextView + window + initTextStorage
editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
NotesTextProcessor.hideSyntax = true
runFullPipeline(editor)  // Sets note.content, triggers didProcessEditing, pumps RunLoop
```

### Pump the run loop for async operations
BulletProcessor (now removed) and some image loading use `DispatchQueue.main.async`. After any operation that might trigger async processing:
```swift
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
```

### A/B comparison pattern
Always compare "loaded note" (known-good) vs "live editing" (what you're testing). If they differ, the live editing path has a bug. Measure line fragment heights, paragraph styles, attribute values — not just string content.

## Common Mistakes (from this session)

1. **Using `-project` instead of `-workspace`**: Pods won't resolve. Always use `-workspace FSNotes.xcworkspace`
2. **Setting typing attributes before insertText**: `didProcessEditing` runs synchronously during `insertText` and overwrites. Set AFTER.
3. **Assuming cacheDisplay captures everything**: It doesn't capture LayoutManager custom drawing.
4. **Hardcoding attachment widths**: Measure actual attachment cell size from storage, don't use magic numbers.
5. **Full reparse on every keystroke**: The incremental parser works. If heading detection fails, the bug is in `adjustBlocks` boundary conditions, not in the parser itself.
6. **Ignoring the `isRendering` flag**: `isRendering = true` is set during block-model splice operations. `process()` bails out when `isRendering` is true. Don't add code that depends on `process()` running during a `replaceCharacters` call inside `isRendering = true`.

## Current State

### Block-Model Pipeline (live in app, ALL block types)
- Parser: `MarkdownParser` → `Document` (block model) → `MarkdownSerializer` round-trip
- Renderer: `DocumentRenderer` renders ALL block types to `NSAttributedString` (no markdown markers in storage)
- Editing: `EditingOps` handles insert/delete/split/merge/paste for ALL block types:
  - Paragraphs, headings, code blocks: full editing (insert, delete, split, merge, paste)
  - Lists: insert/delete, Return splits item, Tab/Shift-Tab indent/unindent via FSM, Return-on-empty exits/unindents
  - Blockquotes: insert/delete within line inline content, Return splits line
  - Horizontal rules: read-only (inserts throw, deletes are no-op, cross-block merge handles removal)
  - Block merges: all block types can be merged (heading+paragraph, list→paragraph, etc.)
- **Toolbar formatting via block model** (Phase 5):
  - Inline traits: bold/italic/code toggle via `EditingOps.toggleInlineTrait()` — wraps/unwraps selection in the inline tree
  - Heading level: `EditingOps.changeHeadingLevel()` — paragraph↔heading conversion, level change, toggle off
  - List toggle: `EditingOps.toggleList()` — paragraph↔list conversion
  - Blockquote toggle: `EditingOps.toggleBlockquote()` — paragraph↔blockquote conversion
  - HR insertion: `EditingOps.insertHorizontalRule()` — adds HR after current block
  - Todo list: `EditingOps.toggleTodoList()` — paragraph→todo, list↔todo conversion
  - Todo checkbox toggle: `EditingOps.toggleTodoCheckbox()` — checked↔unchecked, click-to-toggle wired
  - Clear completed todos: block-model path removes checked items from Document
  - All wired into `EditTextView+Formatting.swift` — block-model path tried first, legacy fallback if unavailable
- **List Editing FSM** (`ListEditingFSM.swift`): pure state machine for structural list operations (indent, unindent, exit, newItem)
- Integration: `EditTextView+BlockModel.swift` wires pipeline into live editor
- **ALL notes use the block model** — legacy `allBlocksSupported()` gate removed
- **Save path**: block-model notes save via `Note.save(markdown:)` which bypasses `NoteSerializer.prepareForSave()`. Legacy notes go through `save(content:)` + `NoteSerializer`. All call sites route through `EditorDelegate.save()`.
- **Document caching**: `Note.cachedDocument` avoids re-parsing on every fill. Invalidated on save/load/reload. Preserved after block-model save.
- **Legacy pipeline retained for source mode / non-markdown**: `TextStorageProcessor.process()` is bypassed when `blockModelActive == true` (always true for markdown WYSIWYG). The legacy pipeline still runs for source mode and non-markdown notes.
- **Fold/unfold bridged**: `syncBlocksFromProjection()` populates the legacy `blocks` array from the Document model so fold/unfold operations work in block-model mode. Called after every fill and edit.
- **Dark mode / highlight guards**: All `NotesTextProcessor.highlight()` calls guarded by `documentProjection == nil`. LayoutManager legacy drawing (bullets, checkboxes, ordered markers) skipped when `blockModelActive == true`.
- **Dead code removed**: `loadTasks()`/`unloadTasks()` stubs, `deprecated/` directories (5 orphaned files), duplicate `EditorDelegate` protocol, stale tracer-bullet/Slice comments, `phase4_hideSyntax` + helpers, `BlockquoteProcessor.swift`, `HorizontalRuleProcessor.swift`, `BlockProcessor` protocol
- Diagnostic log: `~/Documents/block-model.log`
- System integrity tests: 24 tests, List FSM tests: 30 tests, Formatting tests: 51 tests (incl. 18 todo + 6 fold sync), 507 total

### Completed (pre-block-model)
- App renamed to FSNotes++
- Toolbar toggle buttons (pushOnPushOff) for all formatting
- Return key state machine with NewLineTransition enum
- Unified `toggleMarkers(open:close:)` for all formatting toggles
- Save safety (getFileWrapper throws, serialization empty-check)

### Known Issues
- One pre-existing test failure: TableLayoutTests.test_copyButton_existsOnHover (UI test)
- `cacheDisplay` can't verify AttributeDrawer output in tests
- TextFormatter.swift `deinit` save call now routes through `EditorDelegate.save()` (fixed)
