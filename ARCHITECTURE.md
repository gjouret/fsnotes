# FSNotes++ Architecture

## Overview

FSNotes++ is a WYSIWYG markdown editor for macOS (forked from FSNotes). Rendering happens in a single `NSTextView` — no HTML preview pane. Two pipelines coexist:

- **Block-model pipeline** (WYSIWYG mode): `MarkdownParser` → `Document` tree → `DocumentRenderer` → `NSAttributedString` with clean display text (no markdown markers in storage). All editing routes through `EditingOps`.
- **Source-mode pipeline** (source mode / non-markdown): `TextStorageProcessor.process()` → `NotesTextProcessor` highlighting → paragraph styles → `LayoutManager` custom drawing. Bypassed when `blockModelActive == true`.

## Block-Model Pipeline

```
raw markdown ──► MarkdownParser ──► Document (block tree)
                                        │
                                        ├──► DocumentRenderer ──► NSAttributedString
                                        │         (block renderers + InlineRenderer)
                                        │
                                        ├──► DocumentProjection (view model: blockSpans, index mapping)
                                        │
                                        ├──► EditingOps (insert/delete/split/merge/format)
                                        │
                                        └──► MarkdownSerializer ──► markdown string (for save)
```

**Key invariant**: `textStorage.string` contains only displayed characters. Markdown markers (`#`, `**`, `-`, `>`, fences) exist only in the `Document` model and on disk. Edits mutate the `Document`; the renderer produces a splice to patch `textStorage`.

### Document Model

Seven block types: `paragraph`, `heading(level:suffix:)`, `codeBlock(fence:info:content:)`, `list(items:)`, `blockquote(lines:)`, `horizontalRule`, `table(header:separator:rows:)`. Plus `blankLine` and `htmlBlock` for structural fidelity.

Each block contains `[Inline]` trees for rich text. Inline nodes: `.text`, `.emphasis`, `.strong`, `.code`, `.strikethrough`, `.link`, `.image`, `.html`, `.softBreak`, `.hardBreak`, `.escaped`.

### Save Path

WYSIWYG: `Document` → `MarkdownSerializer.serialize()` → `Note.save(markdown:)` (bypasses `NoteSerializer`).
Source mode: `NoteSerializer.prepareForSave()` → `Note.save(content:)`.

## Architecture Principles

1. **Storage is rendered output**: `textStorage.string` has no markers. Markdown lives in `Document` and on disk.
2. **Each stage owns its attributes**: Renderer sets `.font`, `.paragraphStyle`, `.foregroundColor`. Don't set these elsewhere.
3. **Fix at the source stage**: Trace which stage sets a wrong attribute; fix there, never patch downstream.
4. **Editing mutates Document**: User keystrokes → `EditingOps` → mutated `Document` → splice → `textStorage` update.
5. **One general solution**: Solve recurring patterns once (e.g., typing attributes after Return for ALL transitions).

## Editing FSMs by Block Type

Each table shows what happens for every editing action on that block type. "Unsupported" means the operation throws or is a no-op. CommonMark spec references are noted where they constrain behavior.

### Paragraph

Per CommonMark 4.8: paragraphs are interrupted by blank lines, headings, thematic breaks, block quotes, list items, and fenced code blocks.

| Action | Result |
|--------|--------|
| **Return** | Split at cursor → two paragraphs. Cursor at start → blankLine + paragraph. Cursor at end → paragraph + blankLine. |
| **Backspace at start** | Merge with previous block (see Cross-Block Merge). |
| **Tab / Shift-Tab** | No block-model operation (passthrough). |
| **Inline format** (bold/italic/code/strike) | Toggle trait on selection or set pending trait at cursor. |
| **Set heading level** | Paragraph → heading(level). Content becomes heading suffix. |
| **Toggle list** | Paragraph → single-item list. Inline content becomes item content. |
| **Toggle blockquote** | Paragraph → blockquote with one line. |
| **Insert HR** | Insert blankLine + HR after paragraph. (BlankLine prevents `---` setext ambiguity per CommonMark 4.3.) |
| **Toggle todo** | Paragraph → single-item todo list with `[ ]` checkbox. |

### Heading

Per CommonMark 4.2 (ATX): headings are single-line. Opening `#` sequence determines level (1-6). Closing `#`s optional. Per 4.3 (setext): underline `===` or `---` under a paragraph.

| Action | Result |
|--------|--------|
| **Return** | Split → heading(same level) + paragraph(afterText). Cursor at end → heading + empty paragraph. Cursor moves to the new paragraph. No blankLine between — paragraphSpacing provides the visual gap and the serializer emits a blank separator between non-blank siblings anyway. |
| **Backspace at start** | Merge with previous block. |
| **Tab / Shift-Tab** | No operation. |
| **Inline format** | Toggle trait on heading suffix inlines. |
| **Set heading level** | Change level (1-6). Same level or level 0 → convert to paragraph. |
| **Toggle list** | Unsupported (heading stays as heading). |
| **Toggle blockquote** | Unsupported. |
| **Insert HR** | Insert blankLine + HR after heading. |
| **Toggle todo** | Heading → todo list item (heading content becomes item). |

### Code Block

Per CommonMark 4.5: fenced code blocks open with `` ` `` or `~` (3+ chars). Content is verbatim literal text — no inline parsing. Closes with matching fence or end of document.

| Action | Result |
|--------|--------|
| **Return** | Insert literal newline within code content. No structural change. |
| **Backspace at start** | Delete within code content. If content empty and at boundary, merge with previous. |
| **Tab** | Insert literal tab character. |
| **Shift-Tab** | No operation. |
| **Inline format** | Unsupported (code blocks are verbatim). |
| **Set heading level** | Unsupported. |
| **Toggle list** | Unsupported. |
| **Toggle blockquote** | Unsupported. |
| **Insert HR** | Insert HR after code block. |
| **Toggle todo** | Unsupported. |

### List

Per CommonMark 5.2-5.3: list items start with bullet (`-`, `*`, `+`) or ordered marker (`1.`, `1)`). Continuation lines indented to content column. Blank line between items → loose list. Nested lists require sufficient indentation.

Structural operations route through **ListEditingFSM** (see below).

| Action | Result |
|--------|--------|
| **Return (non-empty item)** | FSM `newItem`: split item at cursor. New item inherits marker; checkbox resets to unchecked. Children stay with original. |
| **Return (empty item, depth 0)** | FSM `exitToBody`: convert item to paragraph. |
| **Return (empty item, depth > 0)** | FSM `unindent`: move item one level shallower. |
| **Backspace at start (depth 0)** | FSM `exitToBody`: convert item to paragraph. |
| **Backspace at start (depth > 0)** | FSM `unindent`: move item one level shallower. |
| **Tab (has previous sibling)** | FSM `indent`: item becomes child of previous sibling. Indent = parent indent + `"  "`. |
| **Tab (no previous sibling)** | FSM `noOp`. |
| **Shift-Tab (depth 0)** | FSM `exitToBody`: convert to paragraph. |
| **Shift-Tab (depth > 0)** | FSM `unindent`: move one level shallower. |
| **Inline format** | Toggle trait on item's inline content. |
| **Set heading level** | Unsupported (items stay as items). |
| **Toggle list** | List → multiple paragraphs (one per top-level item). |
| **Toggle blockquote** | Unsupported. |
| **Insert HR** | Insert HR after list block. |
| **Toggle todo** | All items have checkbox → unwrap to paragraphs. Otherwise → add `[ ]` to items lacking checkboxes. |

### ListEditingFSM

Pure function: `(State, Action) → Transition`. No side effects.

**State**: `.bodyText` or `.listItem(depth: Int, hasPreviousSibling: Bool)`

| State | Action | Transition |
|-------|--------|------------|
| `.bodyText` | any | `noOp` |
| `.listItem(0, _)` | `.tab` with sibling | `indent` |
| `.listItem(0, false)` | `.tab` | `noOp` |
| `.listItem(0, _)` | `.shiftTab` | `exitToBody` |
| `.listItem(0, _)` | `.deleteAtHome` | `exitToBody` |
| `.listItem(0, _)` | `.returnOnEmpty` | `exitToBody` |
| `.listItem(>0, _)` | `.tab` with sibling | `indent` |
| `.listItem(>0, false)` | `.tab` | `noOp` |
| `.listItem(>0, _)` | `.shiftTab` | `unindent` |
| `.listItem(>0, _)` | `.deleteAtHome` | `unindent` |
| `.listItem(>0, _)` | `.returnOnEmpty` | `unindent` |
| any `.listItem` | `.returnKey` | `newItem` |

### Blockquote

Per CommonMark 5.1: block quotes start with `>` (optional space after). Lazy continuation: a line without `>` continues the blockquote if it would be a continuation line of a paragraph. Nested blocks allowed inside blockquotes.

| Action | Result |
|--------|--------|
| **Return** | Split blockquote line at cursor. Both lines stay in same blockquote block. |
| **Backspace at start** | Merge with previous block. |
| **Tab / Shift-Tab** | No operation. |
| **Inline format** | Toggle trait on line's inline content. |
| **Set heading level** | Unsupported. |
| **Toggle list** | Unsupported. |
| **Toggle blockquote** | Blockquote → paragraph (all lines merged). |
| **Insert HR** | Insert HR after blockquote. |
| **Toggle todo** | Unsupported. |

### Horizontal Rule

Per CommonMark 4.1: thematic breaks are `---`, `***`, or `___` (3+ chars, optional spaces). They have no content.

| Action | Result |
|--------|--------|
| **Return** | Unsupported (no editable content). |
| **Backspace at start** | Remove HR; merge surrounding blocks. |
| **Tab / Shift-Tab** | Unsupported. |
| **Inline format** | Unsupported (read-only). |
| **Set heading level** | Unsupported. |
| **Toggle list** | Unsupported. |
| **Toggle blockquote** | Unsupported. |
| **Insert HR** | Insert another HR after (with blankLine separator). |
| **Toggle todo** | Unsupported. |

### Table

Tables are a GFM extension (not core CommonMark). They render as `InlineTableView` (NSTextAttachment). Cell content is an inline tree — `Block.table` holds `[TableCell]` values where each cell is a `[Inline]` tree, the same type backing `Block.paragraph`. Cell editing routes through the block-model pipeline the same way paragraph editing does.

- **Display**: `InlineTableView.configureCell` renders every cell via `InlineRenderer.render(cell.inline, baseAttributes:)` — the same code path paragraphs use. Zero markdown markers appear in the display; formatting lives entirely in `.font`, `.underlineStyle`, `.strikethroughStyle`, `.backgroundColor`, and `.link` attributes. Cells are configured with `allowsEditingTextAttributes = true` so the field editor preserves those attributes on attach.
- **Editing**: `controlTextDidChange` reads the field editor's `attributedString()`, converts to an inline tree via `InlineRenderer.inlineTreeFromAttributedString(_:)` (the pure inverse of `render`), and routes through `EditingOps.replaceTableCellInline(blockIndex:at:inline:in:)`. No raw-markdown round-trip.
- **Formatting**: `TableRenderController.applyInlineTableCellFormat` toggles attributes on the field editor's storage directly (e.g. `.font` bold, `.backgroundColor` highlight). Then it reads the updated attributed string, converts to inline tree, and pushes through the same primitive. No marker insertion.
- **Structural changes** (add row, delete column, move, alignment): widget mutates its `headers`/`rows`/`alignments` arrays in place, calls `notifyChanged()`, which builds a new `Block.table` from the current widget state and pushes it into `documentProjection.document` via `EditTextView.pushTableBlockToProjection`.

| Action | Result |
|--------|--------|
| **Return** | Within a cell: insert newline (stored as `<br>`, rendered as `\n`). Outside a cell: unsupported. |
| **Backspace at start** | Remove table; merge surrounding blocks. |
| **Tab / Shift-Tab** | Routes to table widget (cell navigation). |
| **Inline format** | Toggles attributes on the field editor's storage, then flushes through `EditingOps.replaceTableCellInline`. |
| **Set heading level** | Unsupported. |
| **Toggle list** | Unsupported. |
| **Toggle blockquote** | Unsupported. |
| **Insert HR** | Insert HR after table. |
| **Toggle todo** | Unsupported. |

## Cross-Block Merge Rules

When backspace crosses a block boundary, `mergeAdjacentBlocks` combines the tail of one block with the head of the next. The result depends on the pair:

| Block A (tail) | Block B (head) | Result |
|---------------|----------------|--------|
| paragraph | paragraph | Single merged paragraph (inlines concatenated) |
| heading | paragraph | Heading with paragraph's inlines appended to suffix |
| paragraph | heading | Paragraph with heading suffix appended |
| heading | heading | First heading with second's suffix appended |
| list | paragraph | Paragraph inlines appended to last list item |
| paragraph | list | Paragraph (list's first item inlines appended) |
| any | blankLine | BlankLine removed; if adjacent paragraphs result, they merge |
| blankLine | any | BlankLine removed; adjacent paragraphs merge |
| any | horizontalRule | HR removed |
| any | codeBlock | Code block removed (content lost) |
| any | blockquote | Blockquote removed (first line's inlines appended) |

## Inline Re-parsing (RC4)

Character-by-character typing can complete inline patterns (e.g., typing `*` completes `*bold*`). After inserting closing delimiters (`)`, `]`, `}`, `` ` ``, `>`, `*`, `_`, `~`), `reparseInlinesIfNeeded` serializes the block's inlines and re-parses them. If the parse tree differs, the block is replaced with the re-parsed version.

## Fold System

Fold state persists per-note via `Note.cachedFoldState: Set<Int>?` (block indices). `TextStorageProcessor.toggleFold` sets `.foldedContent` attribute which gates ALL rendering in LayoutManager. Block-model bridge: `syncBlocksFromProjection()` populates source-mode `blocks` array from the Document so existing fold code works.

## Source-Mode Pipeline (source mode only)

When `blockModelActive == false`: text change → `didProcessEditing` → `process()`:
1. **Stage 1**: `NotesTextProcessor.highlightMarkdown` — `.font`, `.foregroundColor`, `.link`
2. **Stage 2**: `SwiftHighlighter` — language-specific syntax coloring in code blocks
3. **Stage 3**: `phase5_paragraphStyles` — `.paragraphStyle` per block type
4. **Stage 4**: `LayoutManager.drawBackground` → `AttributeDrawer` protocol (bullets, HR, blockquote borders)

## Test Infrastructure

**HTML Parity** (`EditorHTMLParityTests.swift`): canonical test harness. Both "expected" (fresh parse of markdown) and "live" (after editor mutations) Documents are rendered to HTML via `CommonMarkHTMLRenderer`. AssertEqual catches structural divergence. Also verifies round-trip: `HTML(doc) == HTML(parse(serialize(doc)))`.

**Edit-script DSL**: `.type("text")`, `.pressReturn`, `.backspace`, `.select(range)`, `.toggleBold`, `.setHeading(level:)`, `.toggleList`, `.toggleQuote`, `.insertHR`, `.toggleTodo` — declarative sequences that exercise real editor entry points.

**Visual Snapshot**: `makeFullPipelineEditor()` + `runFullPipeline()` + `cacheDisplay`. Note: `cacheDisplay` does NOT capture `LayoutManager.drawBackground` (AttributeDrawer output).

**A/B Comparison**: Editor A loads content; Editor B loads then simulates user action. Compare line fragments, paragraph styles, attribute values.

```bash
xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes \
  -destination 'platform=macOS' -only-testing:FSNotesTests
```
