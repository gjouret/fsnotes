# FSNotes++ Architecture

## Overview

FSNotes++ is a WYSIWYG markdown editor for macOS, forked from FSNotes. The app renders markdown in a single NSTextView — there is no separate HTML preview. The text storage always contains the original markdown; rendering is done via attributed string attributes, syntax hiding (clear color + negative kern), and custom drawing in the LayoutManager.

**Bundle ID**: `co.fluder.FSNotes` (shared with original FSNotes for same notes folder)
**Product Name**: `FSNotes++`
**Deploy Path**: `~/Applications/FSNotes++.app`
**Workspace**: `FSNotes.xcworkspace`
**Scheme**: `FSNotes`

## Targets

| Target | Path | Purpose |
|--------|------|---------|
| FSNotes | `FSNotes/` | macOS app: views, LayoutManager, drawers, toolbar |
| FSNotesCore | `FSNotesCore/` | Framework: parsing, highlighting, formatting, serialization |
| FSNotesTests | `Tests/` | Unit tests, visual snapshots, A/B comparisons |

## Rendering Pipeline

Every text change triggers `NSTextStorage.didProcessEditing` → `TextStorageProcessor.process()`. The pipeline runs in this order:

### Stage 1: Markdown Highlighting
**File**: `FSNotesCore/NotesTextProcessor.swift`
**Method**: `highlightMarkdown(attributedString:paragraphRange:codeBlockRanges:)`
**Owns**: `.font` (heading sizes, bold/italic traits), `.foregroundColor` (syntax color), `.link`, `.strikethroughStyle`, `.underlineStyle`

Applies heading fonts (excluding trailing `\n` — root cause fix for cursor height after Return). Detects bold, italic, strikethrough, links, inline HTML tags.

### Stage 2: Code Block Highlighting
**File**: `FSNotesCore/SwiftHighlighter/`
**Method**: `getHighlighter().highlight(in:fullRange:)`
Language-specific syntax coloring inside fenced code blocks.

### Stage 3: Phase 4 — Syntax Hiding & Block Processing
**File**: `FSNotesCore/TextStorageProcessor.swift` → `phase4_hideSyntax()`
**Owns**: `.kern` (negative, collapses hidden chars), `.foregroundColor` (clear for hidden text), `.bulletMarker`, `.blockquote`, `.horizontalRule`

Hides markdown syntax characters (e.g., `#`, `**`, `~~`, `` ``` ``) using clear color + per-character negative kern. Dispatches to registered `BlockProcessor` implementations:
- `BlockquoteProcessor` — sets `.blockquote` with nesting depth
- `HorizontalRuleProcessor` — sets `.horizontalRule`

For unordered lists: hides `-` with clear color (NO negative kern — preserves width for BulletDrawer), hides trailing space with kern, sets `.bulletMarker`.

**Global flag**: `NotesTextProcessor.hideSyntax` controls whether WYSIWYG mode is active.

### Stage 4: Phase 5 — Paragraph Styles
**File**: `FSNotesCore/TextStorageProcessor.swift` → `phase5_paragraphStyles()`
**Owns**: `.paragraphStyle` (lineSpacing, headIndent, firstLineHeadIndent, paragraphSpacing, paragraphSpacingBefore)

Sets block-type-specific paragraph styles:
- **Headings**: Progressive spacing (H1: 0.67em, H2: 16px, etc.)
- **Lists (tabs-as-metadata model)**: `firstLineHeadIndent` = slotWidth (constant), `headIndent` = slotWidth + depth*listStep, per-depth `NSTextTab` stops at slotWidth + i*listStep. Leading tab chars advance the pen through the tab stops; wrapped lines align at `headIndent`. Marker glyph is drawn by LayoutManager into the slot to the left of the text, not rendered as text.
- **Todo items**: Same indent pattern as lists, measures checkbox attachment width
- **Empty blocks**: Explicit body paragraph style (prevents inheritance from headings/lists)
- **Paragraphs**: `paragraphSpacing` = 12

**Range expansion**: Phase5's range includes the previous AND next paragraph beyond the edit, so boundary transitions (heading→body, list exit) get correct styles.

### Stage 5: Drawing — AttributeDrawers
**File**: `FSNotes/LayoutManager.swift` → `drawBackground(forGlyphRange:at:)`
**Protocol**: `FSNotes/Rendering/AttributeDrawer.swift`

Custom visual elements drawn during layout, without modifying storage:
- `BulletDrawer` — draws `•` at `.bulletMarker` positions (uses `boundingRect` since `-` has preserved width)
- `HorizontalRuleDrawer` — draws 4px gray line for `.horizontalRule`
- `BlockquoteBorderDrawer` — draws left border for `.blockquote`
- `KbdBoxDrawer` — draws rounded box for `.kbdTag`

**Fold gate**: `unfoldedRanges(in:)` filters ALL rendering — folded content never reaches any drawer.

## Block Model

**File**: `FSNotesCore/MarkdownBlockParser.swift`

### MarkdownBlock
```
type: MarkdownBlockType    — heading, paragraph, list, codeBlock, etc.
range: NSRange             — full range including syntax
contentRange: NSRange      — visible content only
syntaxRanges: [NSRange]    — characters to hide in WYSIWYG
collapsed: Bool            — fold state
renderMode: BlockRenderMode — .source or .rendered (mermaid/math)
```

### Block Types
`paragraph`, `heading(level: 1-6)`, `headingSetext(level: 1-2)`, `codeBlock(language:)`, `blockquote`, `unorderedList`, `orderedList`, `todoItem(checked:)`, `horizontalRule`, `table`, `yamlFrontmatter`, `empty`

### Parsing
- **Full parse**: `MarkdownBlockParser.parse(string:)` — on initial load or when blocks are empty
- **Incremental**: `adjustBlocks(forEditAt:delta:)` shifts ranges, marks dirty blocks; `reparseBlocks(dirtyIndices:string:)` re-parses only affected blocks
- **Boundary fix**: `adjustBlocks` uses `<` (not `<=`) so edits at the end of a block extend it rather than creating orphan characters
- Blocks stored in `TextStorageProcessor.blocks: [MarkdownBlock]`

## Return Key State Machine

**File**: `FSNotesCore/TextFormatter.swift`

### NewLineTransition Enum
| Transition | When | What happens |
|-----------|------|-------------|
| `.bodyText` | After heading, default | Insert `\n`, reset typing attrs to body font/paragraph style |
| `.continueUnorderedList(prefix)` | After bullet with content | Insert `\n` + prefix (e.g., `"- "`) |
| `.continueNumberedList(next)` | After numbered item | Insert `\n` + incremented prefix (e.g., `"2. "`) |
| `.continueCheckbox(prefix, todoLocation)` | After checkbox with content | Insert `\n` + prefix + unchecked checkbox |
| `.continueIndent(prefix)` | After indented line | Insert `\n` + tabs/spaces |
| `.exitList(paragraphRange)` | Empty bullet line | Delete line, insert `\n` |
| `.exitTodo(paragraphRange)` | Empty checkbox line | Delete line, insert `\n` |

### Flow
1. `newLine()` gets current paragraph, calls `newLineTransition()` (pure function)
2. `applyTransition()` executes the transition (text insertion)
3. Post-transition: sets typing attributes based on target state:
   - Exit transitions → body paragraph style
   - Continue transitions → copy paragraph style from previous line

### Key Principle
Typing attributes are set AFTER `insertText` (not before), because `didProcessEditing` runs synchronously during insertion and overwrites pre-set attributes. The post-transition block in `newLine()` handles ALL transitions in one place.

## Formatting Toggle System

**File**: `FSNotesCore/TextFormatter.swift` → `toggleMarkers(open:close:)`

Single generic method for all marker-based formatting:
- `bold()` → `toggleMarkers(open: "**", close: "**")`
- `italic()` → `toggleMarkers(open: "*", close: "*")`
- `underline()` → `toggleMarkers(open: "<u>", close: "</u>")`
- `strike()` → `toggleMarkers(open: "~~", close: "~~")`
- `highlight()` → `toggleMarkers(open: "<mark>", close: "</mark>")`

**Detection**: Checks characters immediately before/after selection, then searches backward/forward for markers. If found → remove. If not → wrap.

**Toolbar state**: `FormattingToolbar.updateButtonStates(for:)` reads `typingAttributes` (when cursor is a point) or storage attributes (when selection exists). Called from `textViewDidChangeSelection`.

## Save Pipeline

**File**: `FSNotesCore/Rendering/NoteSerializer.swift` → `prepareForSave()`

```
1. restoreRenderedBlocks() — mermaid/math images → original markdown
2. unloadTasks()           — checkbox attachments → - [ ] / - [x]
3. unloadImagesAndFiles()  — image attachments → ![](path)
```

**Safety**: `getFileWrapper()` throws on error (never returns empty FileWrapper). `save(content:)` blocks writes where serialization produces empty from non-empty input.

**Note**: Bullets no longer need restoration — storage always contains original `-` (BulletProcessor removed, replaced by BulletDrawer).

## Gutter Icons

**File**: `FSNotes/GutterController.swift`

The 32pt-wide gutter on the left of the editor hosts: fold carets (▶/▼), H-level badges, code-block copy icons, and table copy icons. All icons render at 26pt, `calibratedWhite: 0.55` gray, same font family — only the glyph changes on state (⎘ → ✓ after copy, 1.5s feedback).

**Code block copy**: Iterates `processor.blocks`, finds `.codeBlock` in source mode, draws ⎘ at the fence line. Click copies `contentRange` (between fences) as plain text.

**Table copy**: Enumerates `.renderedBlockType == "table"` attributes in the visible range (tables are always single-char rendered attachments). Click parses `.renderedBlockOriginalMarkdown` via `TableUtility.parse()` and writes TSV + HTML + plain-string to the pasteboard. HTML output lets Excel/Numbers/Word/Google Docs receive a proper table.

## Search ↔ Selection FSM

**Files**: `FSNotes/ViewController.swift` (state fields), `FSNotes/View/SearchTextField.swift` (search trigger), `FSNotes/View/NotesTableView.swift` (selection change)

State fields on ViewController:
- `preSearchNote: Note?` — snapshot of active note when search begins
- `searchWasActive: Bool` — tracks search field transitions
- `isProgrammaticSearchSelection: Bool` — distinguishes FSM-driven selection from user clicks

Transitions:
1. **Search on** (empty → non-empty): snapshot `preSearchNote = editor.note`, auto-select top filtered result (flag as programmatic).
2. **User clicks a different note during active search**: `tableViewSelectionDidChange` clears `preSearchNote` (deliberate choice takes priority).
3. **Search off** (non-empty → empty): if `preSearchNote` is still set, restore it.

## Pin Persistence

**File**: `FSNotesCore/Extensions/Storage+Persistence.swift` → `CloudPinStore`

Pins persist to `UserDefaults.standard` synchronously on every toggle (with `synchronize()`). Pre-fork code gated this behind `#if CLOUD_RELATED_BLOCK` making `save()` a no-op in non-cloud builds; pins only lived in the periodic project cache and were lost on crash. iCloud `NSUbiquitousKeyValueStore` is still used as an additional layer when the flag is active.

## Fold System

**File**: `FSNotesCore/TextStorageProcessor.swift` → `toggleFold(headerBlockIndex:textStorage:)`

- Fold range: from after heading's `\n` to next heading of same or higher level
- `.foldedContent` attribute gates ALL rendering in LayoutManager
- InlineTableView subviews hidden directly during fold
- Gutter shows `▶`/`▼` carets, H-level badges, `⋯` ellipsis for collapsed headers

## Table Widget

**File**: `FSNotes/Helpers/InlineTableView.swift`

Three focus states: `.unfocused`, `.hovered`, `.editing`. Rendered as NSTextAttachment inside the editor. `TableRenderController` manages creation from markdown table blocks. Grid drawn by `GridDocumentView`. Column/row handles are `GlassHandleView` (frosted glass effect with `⋮⋮` grip icons, cornerRadius=8).

**Grid drawing order** (in `drawGridLines`): header fill → alternating row fills → stroke. Backgrounds are painted first so grid lines stay full-strength (translucent fills on top dilute the stroke color). Boundary horizontal/vertical lines are inset by `gridLineWidth/2` so strokes aren't clipped by the parent bounds. Grid lines: solid `calibratedWhite: 0.4`. Header fill: solid `calibratedWhite: 0.85`. Alt-row fill (starting at row 0): solid `calibratedWhite: 0.95`. Top margin is always reserved to prevent layout jump on hover.

**Copy button**: drawn in the gutter next to the table attachment (not on the table itself). See Gutter Icons below.

## Custom Attribute Keys

**File**: `FSNotesCore/Extensions/NSAttributedStringKey+.swift`

| Key | Type | Set by | Used by |
|-----|------|--------|---------|
| `.bulletMarker` | Bool | Phase4 | BulletDrawer |
| `.horizontalRule` | Bool | HorizontalRuleProcessor | HorizontalRuleDrawer |
| `.blockquote` | Int (depth) | BlockquoteProcessor | BlockquoteBorderDrawer |
| `.kbdTag` | Bool | InlineTagRegistry | KbdBoxDrawer |
| `.todo` | Int (0/1) | AttributedBox | Checkbox click handling |
| `.listBullet` | String | (legacy) | (legacy) |
| `.foldedContent` | Bool | toggleFold | LayoutManager gate |
| `.renderedBlockOriginalMarkdown` | String | Mermaid/math/table renderer | Save pipeline, table copy |
| `.renderedBlockType` | String | Mermaid/math/table renderer | Table click/copy routing |
| `.codeFence` | Bool | Phase4 | Code block styling |

## Paste Handling

**File**: `FSNotes/View/EditTextView+Clipboard.swift` → `paste(_:)`

Paste priority order (first match wins):
1. RTFD attributed string
2. File URL (save into note)
3. **TSV** (`public.utf8-tab-separated-values-text`) → markdown table via `tsvToMarkdownTable()`, then `renderTables()`
4. **HTML with `<table>`** → markdown table via `htmlTableToMarkdown()`, then `renderTables()`
5. PDF (save with thumbnail attachment)
6. PNG/TIFF (insert as image)
7. Plain string

TSV/HTML table checks run **before** PDF/image because Excel/Numbers/web pages put all types on the clipboard simultaneously. Preferring tabular data means table cells round-trip as markdown tables instead of PDF thumbnails.

## Menu Action Routing

Storyboard menu items point their action target at the `ViewController` customObject `L4m-js-agn`, which is a **placeholder instance** with only `showInSidebar` and `sortByOutlet` outlets connected. Actions that need outlets wired to the real main-window VC (e.g. `editor`) must route through `ViewController.shared()` (which returns `AppDelegate.mainWindowController?.window?.contentViewController as? ViewController`), otherwise force-unwrapping an IBOutlet on the placeholder crashes with `_assertionFailure`.

Also avoid selector names that collide with AppKit (`fold:`, `unfold:` conflict with NSTextView). Renamed to `foldCurrentHeader:` / `unfoldCurrentHeader:` (⌥⌘← / ⌥⌘→).

## Test Infrastructure

### Running Tests
```bash
xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes \
  -destination 'platform=macOS' -only-testing:FSNotesTests
```

### Test Output
Test host is sandboxed. Write output to container:
```swift
let outputDir = NSHomeDirectory() + "/unit-tests"
// Resolves to ~/Library/Containers/co.fluder.FSNotes/Data/unit-tests/
```

### Key Test Patterns

**Visual Snapshot** (verify rendered output):
1. Create `EditTextView` with `initTextStorage()` (full pipeline)
2. Set content via `textStorage?.setAttributedString()`
3. Call `runFullPipeline()` — sets note.content, triggers didProcessEditing, pumps RunLoop for async ops
4. `cacheDisplay(in:to:)` captures bitmap (NOTE: does NOT capture LayoutManager.drawBackground)
5. Check pixel values or save PNG for inspection

**A/B Comparison** (loaded vs typed):
1. Editor A: load content via `setAttributedString` + `runFullPipeline`
2. Editor B: load same content, then simulate user action (newLine(), insertText, etc.)
3. Compare line fragment positions, paragraph styles, attribute values
4. Assert gap/height/indent match between A and B

**Important**: `cacheDisplay` does NOT trigger LayoutManager's `drawBackground`. AttributeDrawer rendering (bullets, blockquote borders, etc.) won't appear in test snapshots. Test these by checking attributes exist, not by pixel verification.

### Test Files
| File | Tests | What it verifies |
|------|-------|-----------------|
| `BlockParserTests.swift` | 35 | Block type detection, ranges, edge cases |
| `NewLineTransitionTests.swift` | 26+ | Return key transitions, A/B visual comparisons, CMD+T simulation |
| `TableLayoutTests.swift` | 13 | Table geometry, padding, sizing, visual snapshots |
| `NoteSerializerTests.swift` | 9 | Save pipeline round-trip |
| `FoldSnapshotTests.swift` | 2 | Pixel-level fold visibility |
| `RendererComparisonTests.swift` | 2 | NSTextView rendering |

## Build & Deploy

Use the `xcode-build-deploy` skill. Key steps:
1. Quit app: `osascript -e 'tell application "FSNotes++" to quit'`
2. Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData/FSNotes-*`
3. Build: `xcodebuild build -workspace FSNotes.xcworkspace -scheme FSNotes -configuration Debug -destination 'platform=macOS'`
4. Deploy: `rm -rf ~/Applications/"FSNotes++.app" && cp -R .../FSNotes++.app ~/Applications/`
5. Sign: `codesign --force --deep --sign - ~/Applications/"FSNotes++.app"`
6. Launch: `open ~/Applications/"FSNotes++.app"`

**Critical**: Debug builds put code in `.debug.dylib`, not main executable. Always `rm -rf` before `cp -R` (POSIX nests instead of replacing).

## Architecture Principles

1. **Storage is markdown**: The text storage always contains original markdown. Rendering is visual only — attributes, hiding, drawing. Never mutate storage for display purposes.
2. **Each pipeline stage owns specific attributes**: Don't set `.paragraphStyle` outside phase5. Don't set `.font` outside the highlighter. Don't apply `.kern` outside phase4.
3. **Fix at the source stage**: When an attribute is wrong, find which stage sets it and fix there. Never patch downstream.
4. **One general solution**: When a pattern recurs (e.g., typing attributes after Return), solve it once for all cases, not per-case.
5. **Verify with rendered output**: Unit tests must check actual rendered output (pixels, attribute values), not just data model state.

## In-Progress Work

### Bullet Rendering Refactor (Step 1 of 5)
Bullets now use non-destructive rendering: `-` stays in storage, hidden by clear color (width preserved), `•` drawn by BulletDrawer. BulletProcessor (destructive `-`→`•` replacement) removed. `restoreBulletMarkers()` removed from save pipeline.

**Remaining steps**:
- Step 2: Checkbox rendering without storage mutation (CheckboxDrawer)
- Step 3: Update Phase5 indent + block parser (remove attachment detection)
- Step 4: Update state machine transitions for raw markdown
- Step 5: Clean up dead code (AttributedBox, .listBullet, loadTasks)

### Known Issues
- BulletDrawer positioning needs verification in live app
- `cacheDisplay` doesn't capture LayoutManager.drawBackground — test snapshots miss AttributeDrawer output
- Two pre-existing test failures: FoldSnapshotTests, RendererComparisonTests
