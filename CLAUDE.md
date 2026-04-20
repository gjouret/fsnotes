# CLAUDE.md — FSNotes++ Project Rules

Read `ARCHITECTURE.md` in this same directory for the full technical architecture (pipeline stages, block model, state machine, test infrastructure, build/deploy).

---

## Rules That Exist Because I Broke Them

These rules are here because I violated them on the `InlineTableView` / table cell editing work and shipped a chain of bugs as a result. Read them first. They override convenience every time.

### 1. No architectural shortcuts. Ever.

If the correct path is "parse → mutate projection → re-render → save" and you're tempted to do "mutate view state directly and reconcile later," **stop**. That temptation is the signal that you're about to do something wrong.

The block model is the single source of truth for every block type. There is no exception for "hard" widgets. If a new widget can't fit the block-model contract cleanly, the answer is to design the primitive that lets it fit — not to route around the architecture and promise to come back later. You won't come back later. You'll patch the symptoms until the file is unfixable.

**The table widget is the cautionary tale.** `InlineTableView` was built with its own mutable `rows`/`headers`/`alignments` state, and cell edits mutated that state directly. `serializeViaBlockModel()` was then patched to reach sideways into live view state at save time and rewrite `Block.table.raw` before serialization. This violated every architecture principle in this file. It produced: (a) a cross-cell data-loss bug where editing one cell wiped formatting in another, (b) a save-persistence hole that required a live-tables check in `save()`, (c) zero testability because every bug required an `NSWindow` + field editor to reproduce. The "I'll do it properly later" was a lie to myself — the correct time to design the primitive was before the first line of `InlineTableView`.

**The rule:** if routing through `EditingOps.replaceBlock` requires a new primitive, design the primitive. If it requires new infrastructure to "re-render one piece of a block without rebuilding the attachment," build that infrastructure. Do not ship the shortcut and plan to refactor later.

### 2. Views render data. Views never write to data.

Unidirectional data flow is not optional. The projection → renderer → view chain is one-way. Views capture user intent (clicks, keystrokes, selections) and call a pure function on the projection that returns a new projection. The new projection flows back through the renderer and updates the view. Views must **never** be read by the data layer.

The `collectCellData()` function in `InlineTableView` used to walk every cell in the table and copy its `stringValue` back into the `rows`/`headers` arrays. This is a bidirectional data flow, and it produced the exact class of bug you would expect: a cell rendered with `attributedStringValue` (with bold markers stripped by `parseInlineMarkdown`) was later read back via `stringValue`, silently overwriting the data model with the stripped text. Bold gone. That's not a race condition or a subtle timing bug — it's the direct consequence of letting the view be a source of truth.

**The rule:** if you're writing code that reads state out of an `NSView` subclass and assigns it back into a model struct, stop. The model is the source of truth. The view is a projection of the model. If the user's edit isn't already in the model, you captured it at the wrong layer.

### 3. If you can't unit-test it without an `NSWindow`, it's in the wrong layer.

Every bug in the table cell edit path required a real window, a real field editor, and manual clicking to reproduce. That's a direct consequence of rule 2: because the data lived in the view, you needed the view to exercise the data. The pipeline-layer tests (parser, renderer, `EditingOps`) are strong because those layers are pure functions operating on value types — you can write a test that calls `EditingOps.toggleInlineTrait(.bold, at: range, in: projection)` and assert on the resulting projection without any AppKit at all.

**The rule:** when you add a feature, the core logic must be testable as a pure function on value types. If your test needs to instantiate a window, attach a field editor, and send synthetic mouse events, the logic is in the wrong place. Move it to a pure primitive and leave the view thin.

### 4. When you're about to violate a principle, stop and tell the user.

The correct response to "routing this properly requires more work than I want to do right now" is to tell the user that, explain the tradeoff, and let them decide. It is never to quietly ship the shortcut and hope the user doesn't notice. If they don't notice, the shortcut compounds. If they do notice, you will be caught in a position where defending the shortcut requires lying about why you took it.

**The rule:** if you catch yourself about to write code that violates a rule in this file, stop the tool call, write a paragraph to the user that says "doing this properly requires X, the shortcut would be Y, here's the tradeoff," and wait. The user's time budget is theirs to spend, not yours.

### 5. Never fabricate historical or technical reasoning.

When asked why a shortcut exists, the honest answer is "I took it because the correct path required more work." That is always the truth. Do not invent a plausible-sounding alternative history ("the widget predates the architecture," "this was a constraint from an earlier design") to make the shortcut look forced. You don't have reliable access to git history in the moment of the question, and if you invent one it will be wrong.

**The rule:** if the user asks why a piece of code looks wrong, the answer starts with "I wrote it that way because" followed by the actual reason. Not an invented one. If you don't remember, say "I don't remember, let me look at git blame" and actually look. The CLAUDE.md source-verification rules exist specifically to prevent this failure mode — honor them.

### 6. A passing test suite with shipping bugs means the tests cover the wrong layer.

556+ tests all passing while the user reports 30+ live bugs means the test suite is testing the pipeline and ignoring the live paths. That's not "the tests are good, the product is bad" — it's "the tests are in the wrong place." The fix is not to write more pipeline tests. The fix is to move the logic that's currently hiding in views into pure primitives, then test those primitives. See rule 3.

### 7. Mechanical pre-edit check for banned-pattern keywords.

Rule 4 ("catch yourself before violating a principle") fails when you're in fix-the-bug flow and reading existing code for "what tools are available." You pattern-match from what's already in the file. If what's in the file is itself a violation, you inherit and extend the violation. This has a name: **inherited-violation**, and every compound bug in `InlineTableView` / `TableRenderController` is an instance of it.

The fix is not more discipline. Discipline fails under load. The fix is mechanical: before editing a file that renders block-model content, grep the file and the diff for these tokens. If any match, stop and check against the architectural rules *before* writing.

**Banned patterns in view-layer and renderer code** (anything in `FSNotes/` or `FSNotesCore/Rendering/` that's not explicitly the inline renderer):

```bash
# Marker-hiding via visual attributes — the banned phase-4 pattern.
# If you catch these in code you're writing or extending, STOP.
grep -nE 'systemFont\(ofSize: 0\.[0-9]|ofSize: ?0\b|foregroundColor.*clear|NSColor\.clear.*foreground|addAttribute\(\.kern' <file>

# Bidirectional data flow: reading back view state into the model.
grep -nE '\.stringValue\s*$|cell\.attributedStringValue\s*[^=]|fieldEditor\.string.*=.*rows\[|headers\[.*\]\s*=.*\.stringValue' <file>

# Re-implementations of InlineRenderer inside widgets.
grep -nE 'NSRegularExpression.*(\\\\\*\\\\\*|~~|<mark>|<u>|parseInlineMarkdown' <file>
```

The first hit on any of these in a file I'm editing means I stop writing and check:
- Is this existing code a violation I'm about to extend? (Read rules 1–3 against it.)
- Is the fix I'm planning going to add more matches?

If yes to either, stop the tool call, tell the user exactly which rule is in tension, and propose the architecturally clean fix *before* the minimal-change one.

**Meta-rule**: when editing `InlineTableView.swift`, `TableRenderController.swift`, or any file whose name contains `Inline` or `Table`, assume the existing code is a violation until proven otherwise. Read the file's function you're about to extend, check it against rules 1–3, and only then proceed. Do not pattern-match from what's there. The whole point of the cautionary tale in rule 1 is that the existing shortcuts compound.

**The rule:** before claiming a feature is done, identify the pure function that represents its core logic and write a test against that function. If no such function exists, the feature isn't done — the logic is still tangled in the view layer.

---

## App Identity

- **Original FSNotes**: `/Applications/FSNotes.app` — don't touch this
- **FSNotes++** (our fork): `~/Applications/FSNotes++.app` — this is what we build and deploy
- Both share the same bundle ID (`co.fluder.FSNotes`), same notes folder, same iCloud container
- Quote paths in shell: `~/Applications/"FSNotes++.app"` (the `++` requires quotes)

## Build Environment

- **Workspace**: `FSNotes.xcworkspace` (not `.xcodeproj` — Pods won't resolve)
- **Pods are pre-installed** in the repo. Do NOT run `pod install`. If you get "unable to resolve module dependency" errors, you're using `-project` instead of `-workspace`
- Use the `xcode-build-deploy` skill for ALL builds. Don't improvise the sequence
- **ALWAYS redirect xcodebuild output to a file.** xcodebuild (build AND test) produces thousands of lines per invocation — dumping that into context burns budget. Redirect to a temp log and grep for what matters:
  ```bash
  xcodebuild -workspace FSNotes.xcworkspace -scheme FSNotes build > /tmp/xcbuild.log 2>&1
  # then: tail -n 50 /tmp/xcbuild.log, or: grep -E "error:|warning:|BUILD" /tmp/xcbuild.log
  xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes > /tmp/xctest.log 2>&1
  # then: grep -E "Test Case|failed|passed|error:" /tmp/xctest.log | tail -n 100
  ```
  NEVER let xcodebuild output stream directly into the tool result. Same for `swift build` / `swift test`.
- Debug builds are **NOT sandboxed** despite entitlements having `app-sandbox = true`. `NSHomeDirectory()` resolves to `/Users/guido` (real home). Ad-hoc codesigning doesn't enforce sandbox.
- **`Resources/MPreview.bundle` MUST remain in git.** It contains mermaid.min.js, MathJax (tex-mml-chtml.js + woff fonts), highlight.js, and syntax theme CSS. `BlockRenderer.swift` depends on it at runtime for diagram/math/code rendering. Do NOT delete it even when removing legacy preview code.

### Worktrees: CocoaPods symlinks required
Git worktrees do NOT copy `.gitignored` files. `Pods/`, `Podfile`, and `Podfile.lock` are all `.gitignored`. **After creating any worktree**, you MUST symlink these from the main repo:
```bash
MAIN_REPO="/Users/guido/Documents/Programming/Claude/fsnotes"
WORKTREE="$MAIN_REPO/.claude/worktrees/<name>"
ln -s "$MAIN_REPO/Pods" "$WORKTREE/Pods"
ln -s "$MAIN_REPO/Podfile" "$WORKTREE/Podfile"
ln -s "$MAIN_REPO/Podfile.lock" "$WORKTREE/Podfile.lock"
```
Without these, `xcodebuild` fails with "unable to resolve module dependency" errors. This is NOT a kludge — it's the correct way to handle gitignored dependencies in worktrees.

### Adding new Swift files to the Xcode project
When creating ANY new `.swift` file, you MUST add it to `FSNotes.xcodeproj/project.pbxproj` in THREE places:
1. **PBXBuildFile section** — `<ID_B1> /* File.swift in Sources */ = {isa = PBXBuildFile; fileRef = <ID_F1> /* File.swift */; };`
2. **PBXFileReference section** — `<ID_F1> /* File.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = File.swift; sourceTree = "<group>"; };`
3. **PBXGroup children** — add `<ID_F1>` to the appropriate group's `children` array
4. **PBXSourcesBuildPhase** — add `<ID_B1>` to the target's Sources build phase `files` array

For test files, the target is `FSNotesTests` (build phase ID: `TEST00000000000000000005`). For app files, use the main `FSNotes` target.
**Files on disk but not in pbxproj are silently ignored by xcodebuild.** Always verify after adding.

## Runtime Environment (Debug Builds)

### NOT sandboxed — critical implications
Debug builds with ad-hoc codesigning do NOT enforce sandboxing. This means:
- `NSHomeDirectory()` → `/Users/guido` (real home, NOT a container)
- `UserDefaults` reads/writes → `~/Library/Preferences/co.fluder.FSNotes.plist`
- Pinned notes stored in → `~/Library/Preferences/co.fluder.FSNotes.plist` under key `PinnedNotes` (or similar)
- Documents directory → `~/Documents/`
- To change a UserDefaults value from the command line:
  ```bash
  # Kill cfprefsd FIRST (it caches aggressively), then write, then relaunch
  killall cfprefsd 2>/dev/null
  /usr/libexec/PlistBuddy -c "Set :keyName value" ~/Library/Preferences/co.fluder.FSNotes.plist
  ```
- **cfprefsd caches UserDefaults values in memory.** If you write to the plist while the daemon is running, it may overwrite your changes. Always `killall cfprefsd` before `PlistBuddy` writes.

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
4. **Is the state I'm reading in a view, or in the projection?** If it's in a view, see rule 2 above — you're reading the wrong source of truth and the fix belongs one layer up.

### No post-hoc patches
Never set attributes AFTER an operation to override what a rendering stage already applied. Fix the stage that applies the wrong attribute. Every time you catch yourself writing `storage.addAttribute` or `textView.typingAttributes = ...` after an `insertText` call, you're patching — find which stage ran during `insertText` and fix it there.

This rule extends to **save-path patches**. If saving produces wrong output, the fix is to ensure the projection was correct *when the edit happened*, not to walk the view tree at save time and rewrite what's about to be serialized. The `serializeViaBlockModel` live-table walk is exactly this anti-pattern; it exists as a warning, not a template.

### After 3 failed attempts, write a unit test
If a bug isn't fixed after 3 tries, STOP coding and write a unit test that captures the bug. The test must be at the pure-function layer — if you find yourself needing an `NSWindow` to reproduce the bug, the fix is not a new test, it's moving the buggy logic into a pure primitive and testing that. See Rule 3 in the top section.

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
2. **Projection is the single source of truth**: `DocumentProjection.document` is where the content lives. Views render it; edits produce new projections via `EditingOps`. There is no exception for any block type. If a widget appears to need its own mutable state, the widget is wrong.
3. **Each stage owns specific attributes**: Don't set `.paragraphStyle` outside phase5/DocumentRenderer. Don't set `.font` outside the highlighter. Block model renders without `.kern` or clear-color hiding (phase4 has been removed).
4. **Fix at the source stage**: When an attribute is wrong, trace which stage sets it and fix there. When saved output is wrong, trace which edit failed to update the projection and fix *there*, not in the save path.
5. **Generalize, don't specialize**: When fixing a problem that recurs across cases (e.g., typing attributes after Return for ALL transition types), build one parameterized solution, not N special cases.
6. **Never change working behavior** without telling the user or asking first.
7. **Views are pure renderers of projection state**. They capture intent and call `EditingOps`. They do not own data. They are not read from.

## State Machine: Return Key

The Return key state machine defines what happens on every line type. When adding new transitions:
- Add the case to `NewLineTransition` enum
- Add detection logic to `newLineTransition()` (pure function — no side effects)
- Add execution logic to `applyTransition()`
- The post-transition block at the end of `newLine()` sets typing attributes for ALL cases — don't duplicate this in individual cases

## Test Patterns

### Tests must exercise pure primitives, not widgets

The 556-test suite caught zero of the table cell editing bugs because every table test was at the pipeline layer (parser, renderer, round-trip) while the bugs lived in the widget's own mutable state. When you add a feature, the test must call into the pure function that represents the feature's core logic — not drive a widget and check side effects.

If the feature's core logic is not currently callable as a pure function on value types, that's the first problem to fix. Don't write a widget-driving test to cover for it.

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

## Common Mistakes (from real bugs shipped on this project)

1. **Using `-project` instead of `-workspace`**: Pods won't resolve. Always use `-workspace FSNotes.xcworkspace`
2. **Setting typing attributes before insertText**: `didProcessEditing` runs synchronously during `insertText` and overwrites. Set AFTER.
3. **Assuming cacheDisplay captures everything**: It doesn't capture LayoutManager custom drawing.
4. **Hardcoding attachment widths**: Measure actual attachment cell size from storage, don't use magic numbers.
5. **Full reparse on every keystroke**: The incremental parser works. If heading detection fails, the bug is in `adjustBlocks` boundary conditions, not in the parser itself.
6. **Ignoring the `isRendering` flag**: `isRendering = true` is set during block-model splice operations. `process()` bails out when `isRendering` is true. Don't add code that depends on `process()` running during a `replaceCharacters` call inside `isRendering = true`.
7. **Giving a widget its own mutable data state** (InlineTableView's `rows`/`headers`/`alignments`). The projection is the data. Widgets render it. See top section.
8. **Reading view state back into the data model** (`collectCellData` pulling from `cell.stringValue`). Views render data — they are never read from. See top section.
9. **Patching the save path to reach into live view state** (`serializeViaBlockModel` walking live table attachments). If the projection is wrong at save time, the edit that produced it was wrong. Fix the edit. See top section.

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
  - All wired into `EditTextView+Formatting.swift` — block-model path tried first, source-mode fallback if unavailable
- **List Editing FSM** (`ListEditingFSM.swift`): pure state machine for structural list operations (indent, unindent, exit, newItem)
- Integration: `EditTextView+BlockModel.swift` wires pipeline into live editor
- **ALL notes use the block model** — old `allBlocksSupported()` gate removed
- **Save path**: block-model notes save via `Note.save(markdown:)` which bypasses `NoteSerializer.prepareForSave()`. Source-mode notes go through `save(content:)` + `NoteSerializer`. All call sites route through `EditorDelegate.save()`.
- **Document caching**: `Note.cachedDocument` avoids re-parsing on every fill. Invalidated on save/load/reload. Preserved after block-model save.
- **Source-mode pipeline retained for source mode / non-markdown**: `TextStorageProcessor.process()` is bypassed when `blockModelActive == true` (always true for markdown WYSIWYG). The source-mode pipeline still runs for source mode and non-markdown notes.
- **Fold/unfold bridged**: `syncBlocksFromProjection()` populates the source-mode `blocks` array from the Document model so fold/unfold operations work in block-model mode. Called after every fill and edit.
- **Dark mode / highlight guards**: All `NotesTextProcessor.highlight()` calls guarded by `documentProjection == nil`. LayoutManager source-mode drawing (bullets, checkboxes, ordered markers) skipped when `blockModelActive == true`.
- Diagnostic log: `~/Documents/block-model.log`

### Table cell editing (Stage 1–4 refactor, landed)

The InlineTableView cautionary tale described in the top section of this file has been resolved end to end. The refactor landed in four stages, each test-first and live-verified:

**Stage 1 — data shape.** `Block.table` now carries `TableCell` values (`{ inline: [Inline] }`) — the same inline-tree type backing `Block.paragraph`. The parser populates cells via `MarkdownParser.parseInlines` per cell string. `raw: String` is retained for B1 byte-identical preservation of untouched tables (non-canonical source text) and gets recomputed canonically by `EditingOps.rebuildTableRaw` on any edit.

**Stage 2 — rendering.** `InlineTableView.configureCell` renders every cell via `InlineRenderer.render(cell.inline, baseAttributes:)` — the same code path paragraphs use. The widget's local regex re-implementation of inline parsing (`parseInlineMarkdown`) has been deleted. Column widths and row heights measure via the attributed string's `boundingRect`, so visually-invisible markers don't contribute to layout.

**Stage 3 — editing.**
- New pure function `InlineRenderer.inlineTreeFromAttributedString(_:)` is the inverse of `render`. 24 round-trip unit tests cover every formatting combination (plain, bold, italic, strike, underline, highlight, code, link, nested bold+italic, mixed nesting, multi-line `<br>/\n`, literal asterisks, empty strings).
- New primitive `EditingOps.replaceTableCellInline(blockIndex:at:inline:in:)` takes `[Inline]` directly; the raw-string variant `replaceTableCell(newSourceText:)` forwards to it.
- New editor entry point `EditTextView.applyTableCellInlineEdit(from:at:inline:)` is the sibling of `applyTableCellEdit`. It holds the attachment-reuse contract: splice-free in-place update on same-shape edits.
- `InlineTableView.controlTextDidChange` reads `fieldEditor.textStorage` as an `NSAttributedString`, converts to an inline tree via the new pure function, and routes through the inline primitive. Zero raw-markdown round-trips; zero `.string` reads of attributed field editors.
- `TableRenderController.applyInlineTableCellFormat` toggles attributes on the field-editor storage (e.g. `.font` bold/italic, `.strikethroughStyle`, `.underlineStyle`, `.backgroundColor` highlight) and flushes through the inline primitive. No marker insertion, no marker hiding, no `.kern` / tiny font / `.clear` foreground tricks.
- Cells are configured with `allowsEditingTextAttributes = true` so the field editor preserves attribute runs on attach. Without this flag, `NSTextField` downgrades the attributed string to plain text + default cell font on edit mode entry — which was the "formatting disappears when cursor enters cell" symptom.

**Stage 4 — cleanup.** Deleted: `InlineTableView.parseInlineMarkdown`, `InlineTableView.collectCellData` (silent corruption vector under Stage 3 — it read `fieldEditor.string` plain and stripped all formatting), `InlineTableView.generateMarkdown`, the `skipCollect` parameter on `rebuild`, `TableRenderController.prepareRenderedTablesForSave` (the save-path walker that was the cautionary tale), the `EditTextView.prepareRenderedTablesForSave` forwarder, the `EditTextView.attributedStringForSaving` call to it, the old string-based `EditTextView.applyTableCellEdit` entry point (zero live callers), `hideMarker` + `applyLiveAttributes` in `TableRenderController` (the banned tiny-font marker-hiding helpers). The rule 7 grep-conscience returns zero matches in both widget files.

**What the refactor left behind.** Cell rendering, measurement, and editing all flow through the same primitives as paragraph content — "a paragraph inside a cell." 820 unit tests pass including 24 new converter round-trip tests, 15 primitive tests, and the 2 cross-cell persistence contract tests that opened this whole effort.

### CommonMark Spec Compliance (v0.31.2)
- **Overall: 526/652 (80.7%)**
- Perfect sections (100%): Precedence, Textual content, Inlines, Code spans, Soft line breaks, Images, Hard line breaks
- Near-perfect (90%+): Emphasis (99%), Fenced code blocks (97%), Autolinks (95%), Raw HTML (95%), Entity refs (94%), HTML blocks (91%)
- Strong (70-89%): Links (86%), ATX headings (83%), Setext headings (81%), Link ref defs (81%), Thematic breaks (79%), Backslash escapes (77%)
- Moderate (50-69%): Block quotes (68%), Paragraphs (62%)
- Low (<50%): Lists (38%), List items (25%), Tabs (18%), Indented code blocks (8%), Blank lines (0%)
- Block model supports: paragraphs, headings (ATX + setext), code blocks, lists (tight/loose, marker splitting, empty items), blockquotes (lazy continuation), HR, HTML blocks (types 1-7), blank lines
- Inline model supports: bold/italic (* and _ with delimiter stack), strikethrough, code spans (multi-backtick), links (inline + reference), images (inline + reference), autolinks (extended URI schemes), escaped chars, line breaks (hard + soft), raw HTML (validated attributes, multiline), entities (validated + decoded)
- Unsupported: Indented code blocks, list sub-block parsing, nested blocks in list items
- See `Tests/CommonMark/` for the full test suite and `~/unit-tests/commonmark-compliance.txt` for detailed reports

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **fsnotes** (1122 symbols, 1107 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

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
