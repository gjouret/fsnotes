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
- Debug builds are sandboxed (entitlements have `app-sandbox = true`). `NSHomeDirectory()` resolves to the container: `~/Library/Containers/co.fluder.FSNotes/Data/`

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
2. **Each stage owns specific attributes**: Don't set `.paragraphStyle` outside phase5. Don't set `.font` outside the highlighter. Don't apply `.kern` outside phase4.
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
// Resolves to ~/Library/Containers/co.fluder.FSNotes/Data/unit-tests/
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
6. **Ignoring the `isRendering` flag**: BulletProcessor's async dispatch sets `isRendering = true` during `beginEditing/endEditing`. `process()` bails out when `isRendering` is true. Don't add code that depends on `process()` running during a `replaceCharacters` call inside `isRendering = true`.

## Current State

### Completed
- App renamed to FSNotes++
- Toolbar toggle buttons (pushOnPushOff) for all formatting
- Return key state machine with NewLineTransition enum
- Unified `toggleMarkers(open:close:)` for all formatting toggles
- Save safety (getFileWrapper throws, serialization empty-check)
- Non-destructive bullet rendering (Step 1 of 5): BulletDrawer replaces BulletProcessor

### In Progress
- BulletDrawer positioning (bullet renders but needs position/size tuning)
- Steps 2-5 of list refactor (checkboxes, phase5 updates, state machine transitions, dead code cleanup)

### Known Issues
- BulletDrawer: `•` glyph positioning needs work in live app
- Two pre-existing test failures: FoldSnapshotTests, RendererComparisonTests
- `cacheDisplay` can't verify AttributeDrawer output in tests
