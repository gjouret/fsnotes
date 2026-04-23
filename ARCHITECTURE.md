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

Each block contains `[Inline]` trees for rich text. Inline nodes: `.text`, `.bold`, `.italic`, `.strikethrough`, `.underline`, `.highlight`, `.code`, `.link`, `.image`, `.autolink`, `.wikilink(target:display:)`, `.rawHTML`, `.entity`, `.escapedChar`, `.lineBreak`, `.math`, `.displayMath`.

Wikilinks parse from `[[target]]` or `[[target|display]]` and render as styled clickable text using the `wiki:<target>` URL scheme — the `[[ ]]` brackets never appear in rendered storage. The click handler in the view layer dispatches `wiki:` URLs to the note resolver.

### Blank Lines and Zero-Length Blocks

**Critical**: `Block.blankLine` renders to an empty string (`""`), producing a `blockSpan` with `length == 0`. This has important consequences:

1. **Range overlap checks fail**: The standard overlap test `span.location < rangeEnd && spanEnd > range.location` returns `false` for zero-length spans because `spanEnd == span.location`. `blockIndices(overlapping:)` works around this with a fallback to `blockContaining(storageIndex:)` for zero-length selections.

2. **Cursor position checks fail**: A check like `cursorLoc >= span.location && cursorLoc < span.location + span.length` can never be true for zero-length blocks (since `span.location + 0 == span.location`). Code operating on zero-length blocks must special-case `span.length == 0` and use `span.location` directly.

3. **Blank lines are structural, not visual**: In the rendered output, blank lines exist only as the `"\n"` separator between adjacent blocks. They carry no content of their own. The separator uses the same paragraph style as empty paragraphs (`paragraphSpacing = 12`) to ensure consistent line metrics and prevent visual jumps when typing begins.

4. **No fallback to source mode**: The block-model and source-mode pipelines are completely separate. When `documentProjection` is non-nil, ALL operations must route through `EditingOps`. Returning `false` from a block-model function does NOT fall back to source mode — it typically results in a no-op or broken state.

5. **Return key creates blank lines**: When Return is pressed at the end of a paragraph, `splitParagraphOnNewline` produces `[paragraph(before), .blankLine]`. The cursor ends up on the blank line, which has zero rendered length. Toolbar operations targeting the cursor must handle this case explicitly.

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
|| **Toggle todo** | Unsupported. |

### Code Block

Per CommonMark 4.5: fenced code blocks open with `` ` `` or `~` (3+ chars). Content is verbatim literal text — no inline parsing. Closes with matching fence or end of document.

| Action | Result |
|--------|--------|
| **Return** | Insert literal newline within code content. No structural change. *Special:* Return at the end of the content with a trailing `\n` exits the code block and inserts a new empty paragraph after — the keyboard escape from fenced code (bug 88). |
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

**Ordered List Numbering**: All ordered list items store and serialize with marker `1.` (regardless of their rendered position). The `ListRenderer` maintains a running counter at each nesting level to display sequential numbers (1, 2, 3...). This allows split lists to re-merge naturally when the separating block is deleted — no special merge logic required.

Structural operations route through **ListEditingFSM** (see below).

| Action | Result |
|--------|--------|
| **Return (non-empty item)** | FSM `newItem`: split item at cursor. New item inherits marker; checkbox resets to unchecked. Children stay with original. |
| **Return (empty item, depth 0)** | FSM `exitToBody`: remove empty item from list and convert to paragraph. Cursor positioned at start of new paragraph. |
| **Return (empty item, depth > 0)** | FSM `unindent`: move item one level shallower (L4→L3, L3→L2, L2→L1). |
| **Backspace at start (depth 0)** | FSM `exitToBody`: convert item to paragraph. |
| **Backspace at start (depth > 0)** | FSM `unindent`: move item one level shallower. |
| **Tab (has previous sibling)** | FSM `indent`: item becomes child of previous sibling. Indent = parent indent + `"  "`. |
| **Tab (no previous sibling)** | FSM `noOp`. |
| **Shift-Tab (depth 0)** | FSM `exitToBody`: convert to paragraph. |
| **Shift-Tab (depth > 0)** | FSM `unindent`: move one level shallower. |
| **Inline format** | Toggle trait on item's inline content. |
| **Set heading level** | Unsupported (items stay as items). |
| **Toggle list** | Cursor in single item (no multi-selection): convert ONLY that item to paragraph, splitting the list. See Multi-Selection FSM for multi-block behavior. |
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

### HTML Block

Per CommonMark 4.6: HTML blocks begin with specific tags (`<script`, `<pre`, `<style`, HTML comments, etc.) and contain raw HTML until a closing condition. Content is verbatim literal text — no inline parsing. Renders with code font.

| Action | Result |
|--------|--------|
| **Return** | Insert literal newline within HTML content. No structural split (unlike code blocks, no keyboard escape). |
| **Backspace at start** | Delete within HTML content. If content empty and at boundary, merge with previous (falls back to paragraph). |
| **Tab / Shift-Tab** | Insert literal tab character (like code block). |
| **Inline format** | Unsupported (HTML blocks are verbatim). |
| **Set heading level** | Unsupported. |
| **Toggle list** | Unsupported. |
| **Toggle blockquote** | Unsupported. |
| **Insert HR** | Insert HR after HTML block. |
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

### Multi-Selection

When multiple blocks are selected (spanning a range), operations apply to all selected blocks as a unit. The selection is defined by `blockIndices(overlapping:)` — all blocks touched by the selection range.

| Action | Result |
|--------|--------|
| **Return** | Delete selected content; merge first partial block with last partial block (see Cross-Block Merge). |
| **Backspace** | Same as Return (delete selection, merge boundaries). |
| **Delete** | Delete selected content without merge (content removed, blocks collapse). |
| **Tab** | Indent all selected blocks that support indentation (lists indent current items; other blocks no-op). |
| **Shift-Tab** | Outdent all selected blocks (lists unindent current items; other blocks no-op). |
| **Inline format** (bold/italic/code/strike) | Toggle trait across entire selection. Preserves block boundaries; each block's inlines are formatted. |
| **Set heading level** | Convert all selected paragraphs/headings to target level. Non-paragraph/heading blocks unchanged. |
| **Toggle list** | Convert all selected blocks to a single list with one item per block. Each block's content becomes a list item. |
| **Toggle blockquote** | Wrap all selected blocks in a single blockquote. Each block becomes a quoted line. |
| **Insert HR** | Insert HR after the last selected block. |
| **Toggle todo** | If all selected list items have checkboxes → remove them. Otherwise add `[ ]` to items lacking checkboxes. Non-list blocks converted to todo list items. |
| **Copy** | Serialize all selected blocks to markdown; push to pasteboard. |
| **Paste** | Replace selection with parsed markdown document; merge first/last boundaries if partial. |

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
| any | htmlBlock | HTML block removed (content lost) |
| any | blockquote | Blockquote removed (first line's inlines appended) |

## FSM and Edit Contracts

### Why this exists

Every `EditingOps` primitive used to return an opaque `EditResult` that described the *textual* outcome — a splice range, a replacement string, and a cursor `Int`. The *structural* outcome (which blocks were created, deleted, merged, split, or renumbered) was implicit in the diff between the before and after projections. That meant a bug like "toggleList accidentally deleted a neighbor block" or "renumberList touched an adjacent ordered list that should have been untouched" was only caught by code review: nothing in the primitive's signature declared what it was allowed to change. Phase 1 introduces `EditContract`, a declarative statement each primitive attaches to its result. The harness holds the primitive to exactly what it promised — undeclared changes and missing declared changes both surface as invariant failures at the pure-function layer.

### DocumentCursor

A cursor expressed in document terms rather than storage terms. `blockPath` identifies a block (flat today, nestable tomorrow without a migration). `inlineOffset` is a UTF-16 character offset into the block's rendered inline text — the *same* coordinate `DocumentRenderer` emits into `NSAttributedString`. Conversion between `DocumentCursor` and a storage `Int` goes through the projection, which owns `blockSpans` and knows where every block lives. This is the natural representation for the eventual TextKit 2 / `NSTextLocation` switchover: Phase 2 replaces the storage-int translation, not the cursor type.

```swift
public struct DocumentCursor: Equatable {
    public let blockPath: [Int]
    public let inlineOffset: Int
}
```

For block kinds whose storage representation is a single attachment (`.horizontalRule`, `.table`), `inlineOffset` is ignored and canonically 0.

### EditAction

The enumeration of structural changes a primitive may declare. Actions are coarse-grained — they describe *what* changed, not *how*.

| Case | Meaning |
|------|---------|
| `.insertBlock(at:)` | A new block appeared at this post-edit top-level index. |
| `.deleteBlock(at:)` | The block at this pre-edit top-level index was removed. |
| `.replaceBlock(at:)` | Same position, same-or-different kind, different content. |
| `.mergeAdjacent(firstIndex:)` | Two adjacent blocks were merged; post-edit doc is one shorter. |
| `.splitBlock(at:inlineIndex:offset:)` | A block was split in two; post-edit doc is one longer. |
| `.renumberList(startIndex:)` | An ordered list's markers were resequenced from this index. |
| `.reindentList(range:)` | Indent/outdent changed across a range of list items. |
| `.modifyInline(blockIndex:)` | Inline-level change within a single block (typing, formatting, inline delete). |
| `.changeBlockKind(at:)` | Block kind changed (paragraph ↔ heading, list marker change, heading level, todo toggle). Same top-level index. |
| `.replaceTableCell(blockIndex:rowIndex:colIndex:)` | A table cell's inline content changed; shape unchanged. |

### EditContract

What the primitive promises. Populated by the primitive and attached to `EditResult`.

```swift
public struct EditContract: Equatable {
    public var declaredActions: [EditAction]
    public var postCursor: DocumentCursor
    public var postSelectionLength: Int
}
```

Empty `declaredActions` means "no structural change" — a pure-inline edit that doesn't change block count or kind (e.g. `toggleInlineTrait` on a non-empty selection inside a single paragraph).

### Invariant: `assertContract`

`Invariants.assertContract(before:after:contract:)` is the enforcement mechanism. Called from every contract-aware test, it checks three things:

1. **Count-delta matches declared size-changing actions.** The sum of `+1` for each `.insertBlock` / `.splitBlock` and `-1` for each `.deleteBlock` / `.mergeAdjacent` must equal `afterBlocks.count - beforeBlocks.count`. If a primitive declares one insertion but actually added two blocks, the mismatch fails here.
2. **Size-preserving contracts leave neighbors untouched.** When every declared action is in-place (`.changeBlockKind`, `.modifyInline`, `.replaceBlock`, `.replaceTableCell`), every block index *not* named in the contract must be bit-identical before and after. This is the "toggleList leaked to a neighbor" detector.
3. **`postCursor` resolves in-bounds.** The declared post-edit cursor must resolve to a storage index inside the new projection's total length. A primitive that claims to leave the cursor on a block that no longer exists gets caught here.

The empty-contract case is enforced strictly: if `declaredActions` is empty, `beforeBlocks` and `afterBlocks` must be equal.

### Retrofitted primitives

The following `EditingOps` primitives populate `result.contract` today:

- `changeHeadingLevel`
- `toggleInlineTrait`
- `toggleList`, `toggleListRange` (via its per-block calls into `toggleList`)
- `toggleBlockquote`
- `toggleTodoList`, `toggleTodoCheckbox`
- `insertHorizontalRule`
- `wrapInCodeBlock`
- `insertImage`, `setImageSize`
- `insertWithTraits`
- `indentListItem`, `unindentListItem`, `exitListItem`
- `reparseInlinesIfNeeded`
- `swapBlocks` / `rerenderSingleBlockSwap` (the private helpers under `moveBlockUp` / `moveBlockDown` / `moveListItemOrBlockUp` / `moveListItemOrBlockDown`)
- `replaceTableCellInline` (and the raw-string `replaceTableCell` forwarder)
- `insert` — every return path (Return-key splits across all block kinds, multi-line paste into paragraph/list/blockquote/heading, atomic-block sibling insertion, HTML block typing, blankLine doubling, code-block Return-on-blank exit)
- `delete` — single-block delete paths, atomic-block full-select, and the multi-block merge path (inherits contract from `mergeAdjacentBlocks`)
- `mergeAdjacentBlocks` — delta-based `.replaceBlock(at: effectiveStart)` + |delta| × `.mergeAdjacent` on both the coalesced and block-granular splice return paths

### Observed-delta pattern

Several primitives go through `replaceBlocksSlow`, which runs a coalescence pass that merges adjacent same-kind blocks (paragraph+paragraph, list+list) after the splice lands. The primitive can't know statically how many neighbors will coalesce — that depends on what's *around* the target block in the input document. The pattern these primitives use:

```swift
let delta = newProj.document.blocks.count - projection.document.blocks.count
var actions: [EditAction] = [.changeBlockKind(at: blockIndex)]
for _ in 0..<(-delta) {
    actions.append(.mergeAdjacent(firstIndex: blockIndex))
}
result.contract = EditContract(declaredActions: actions, postCursor: ...)
```

Each coalesced neighbor contributes one `.mergeAdjacent`, so the count-delta invariant passes without the primitive having to predict surroundings. `toggleList`, `toggleTodoList`, `indentListItem`, `unindentListItem`, and `exitListItem` all use this pattern.

### Coverage

As of 2026-04-22, `EditContractTests` contains 66 tests covering every retrofitted primitive above. Several use `XCTExpectFailure` as negative controls: contracts that claim no structural change fail when the primitive actually changed count, contracts naming the wrong block fail when the primitive modified a different one, and contracts over `.replaceTableCell` fail on cross-cell leak or table shape change. The negative tests are the proof that the harness catches a lying contract — without them, the whole apparatus would be decorative.

Batch H (the insert/delete/replace retrofit) landed on 2026-04-22 and is complete: every `insert`, `delete`, and `replace` return path either populates `result.contract` directly or forwards to a primitive that does. On the same date the harness auto-assert wired contracts into the live editor path: `EditTextView` captures `preEditProjection` + `lastEditContract` inside `applyEditResultWithUndo`, and `EditorHarness` calls `Invariants.assertContract` after every scripted input. A dedicated coverage file `Tests/HarnessContractCoverageTests.swift` (4 tests) drives mermaid typing / backspace, math typing, and `replaceTableCellInline` through the harness-owned live projection — verifying the contract-diff invariants (per-cell structural equality for tables, neighbour bit-equality for mermaid/math code blocks) hold end-to-end through the same path the app uses. Regression gate: zero regressions against the 3 baseline known-red tests (`test_bug60_findAcrossTableCells`, `CommonMarkSpecTests.test_images`, `.test_links`).

## Paste Pipeline

Copy reads `EditTextView.copyAsMarkdownViaBlockModel()` which walks `blockIndices(overlapping: selection)` and either serializes each fully-covered block through `MarkdownSerializer.serialize(Document(blocks: [block]))` or (for partial paragraph overlaps) calls `splitInlines` to isolate the covered inline sub-tree and runs it through `serializeInlines`. The result is pushed to the pasteboard as markdown — bold/italic/links/wikilinks survive a copy → paste round-trip.

Paste reads the clipboard string and calls `insertText(markdown)`, which routes through `handleEditViaBlockModel` → `EditingOps.insert` → `pasteIntoParagraph`. That primitive parses the pasted text as a full `Document` via `MarkdownParser.parse` (not a per-line split) so paragraph boundaries (`\n\n`), headings, lists, code blocks, and inline formatting are all preserved. The `before` and `after` halves of the original paragraph merge into the first and last pasted blocks when they are paragraphs, otherwise they wrap as new sibling paragraphs.

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

## A-Grade Architecture (Fully Implemented)

All 6 architecture improvements have been implemented directly in `EditingOperations.swift`:

### 1. Phantom Types for Compile-Time Offset Safety

```swift
public struct StorageIndex<T>: Equatable, Comparable, Hashable {
    private let rawValue: Int
    public init(_ value: Int)
    public var value: Int { rawValue }
}

public enum OldStorage {}  // Type tag for pre-edit indices
public enum NewStorage {}  // Type tag for post-edit indices

public struct StorageRange<T>: Equatable {
    public let start: StorageIndex<T>
    public let end: StorageIndex<T>
}
```

Prevents mixing old and new storage indices at compile time.

### 2. Typed Error Handling

```swift
public enum EditorError: Error, Equatable {
    case invalidStorageIndex(Int)
    case invalidBlockIndex(Int)
    case unsupportedBlockType(BlockType)
    case readOnlyBlock(BlockType)
    case crossBlockSelection
    case crossInlineSelection
    // ... 9 more cases
}
```

Structured error context replaces string-based `EditingError`.

### 3. Abstract TextBuffer Protocol

```swift
public protocol TextBuffer: AnyObject {
    var length: Int { get }
    var string: String { get }
    func attributedSubstring(from range: NSRange) -> NSAttributedString
    func replaceCharacters(in range: NSRange, with attrString: NSAttributedString)
    // ... 5 more methods
}

// Test double
public final class InMemoryTextBuffer: TextBuffer { ... }

// Platform adapters
extension NSTextStorage: TextBuffer {}
```

Enables unit testing without `NSTextStorage` and supports mock objects.

### 4. Protocol-Oriented Block Editing

```swift
public struct BlockCapabilities: OptionSet {
    static let editableInline = BlockCapabilities(rawValue: 1 << 0)
    static let splittable = BlockCapabilities(rawValue: 1 << 1)
    static let mergable = BlockCapabilities(rawValue: 1 << 2)
    static let formattable = BlockCapabilities(rawValue: 1 << 3)
    static let listItem = BlockCapabilities(rawValue: 1 << 4)
    static let hasChildren = BlockCapabilities(rawValue: 1 << 5)
    static let readOnly = BlockCapabilities(rawValue: 1 << 6)
}

public protocol EditableBlock {
    var capabilities: BlockCapabilities { get }
    func canHandle(action: BlockAction) -> Bool
    mutating func perform(action: BlockAction, ...) throws -> BlockActionResult
}

extension Block {
    public var capabilities: BlockCapabilities { ... }
}
```

Replaces switch-statement dispatch with capability-based polymorphism.

### 5. Unidirectional Data Flow

```swift
public enum EditorAction {
    case insertText(String, at: Int)
    case deleteRange(NSRange)
    case toggleBold, toggleItalic, toggleStrikethrough, toggleCode
    case setHeadingLevel(Int)
    case toggleList, toggleBlockquote, toggleTodo
    case indentListItem, unindentListItem, exitListItem
    case undo, redo
}

public struct EditorState {
    public var document: Document
    public var cursorPosition: Int
    public var selectionRange: NSRange?
    public var pendingTraits: Set<InlineTrait>
    public var history: [DocumentSnapshot]
    public var historyIndex: Int
}

public final class EditorStore {
    private(set) public var state: EditorState
    public func dispatch(_ action: EditorAction)
    public func subscribe(_ callback: @escaping (EditorState) -> Void)
}

public struct EditorReducer {
    public func reduce(state: EditorState, action: EditorAction) -> (EditorState, [EditorEffect])
}
```

Redux-style architecture with pure reducer functions and centralized state.

### 6. Centralized Effect System

```swift
public enum EditorEffect {
    case saveSnapshot
    case restorePreviousSnapshot
    case restoreNextSnapshot
    case reparseInlines(blockIndex: Int)
    case renderBlock(blockIndex: Int)
    case toggleFormat(InlineTrait)
    case notifyChange
    case updateTypingAttributes
}

public protocol EffectHandler {
    func canHandle(_ effect: EditorEffect) -> Bool
    func handle(_ effect: EditorEffect, store: EditorStore)
}

public final class DefaultEffectHandler: EffectHandler { ... }
```

Side effects are declared, not executed inline, enabling better testability and logging.

### Migration Status

| # | Improvement | Status | Lines Added |
|---|-------------|--------|-------------|
| 1 | Phantom types | ✅ Complete | ~50 |
| 2 | Typed error handling | ✅ Complete | ~30 |
| 3 | Abstract TextBuffer | ✅ Complete | ~80 |
| 4 | Protocol-oriented blocks | ✅ Complete | ~100 |
| 5 | Unidirectional data flow | ✅ Complete | ~150 |
| 6 | Centralized Effect system | ✅ Complete | ~120 |

**Total: 6/6 implemented, 0 remaining**

## Test Infrastructure

**HTML Parity** (`EditorHTMLParityTests.swift`): canonical test harness. Both "expected" (fresh parse of markdown) and "live" (after editor mutations) Documents are rendered to HTML via `CommonMarkHTMLRenderer`. AssertEqual catches structural divergence. Also verifies round-trip: `HTML(doc) == HTML(parse(serialize(doc)))`.

**Edit-script DSL**: `.type("text")`, `.pressReturn`, `.backspace`, `.select(range)`, `.toggleBold`, `.setHeading(level:)`, `.toggleList`, `.toggleQuote`, `.insertHR`, `.toggleTodo` — declarative sequences that exercise real editor entry points.

**Visual Snapshot**: `makeFullPipelineEditor()` + `runFullPipeline()` + `cacheDisplay`. Note: `cacheDisplay` does NOT capture `LayoutManager.drawBackground` (AttributeDrawer output).

**A/B Comparison**: Editor A loads content; Editor B loads then simulates user action. Compare line fragments, paragraph styles, attribute values.

```bash
xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes \
  -destination 'platform=macOS' -only-testing:FSNotesTests
```
