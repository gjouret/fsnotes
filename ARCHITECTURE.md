# FSNotes++ Architecture

## Overview

FSNotes++ is a WYSIWYG markdown editor for macOS (forked from FSNotes). Rendering happens in a single `NSTextView` on TextKit 2 — no HTML preview pane. The `Document` block model is the single source of truth; two render paths consume it:

- **WYSIWYG path** (`hideSyntax == true`, the default): `MarkdownParser` → `Document` → `DocumentRenderer` → `NSAttributedString` with markers consumed. The user sees bold/italic/headings as visual formatting.
- **Source path** (`hideSyntax == false`): same `Document` → `SourceRenderer` → `NSAttributedString` with markers preserved and tagged `.markerRange`. `SourceLayoutFragment` paints those runs in the theme's marker color over the default text draw.

Both paths feed a single TK2 `NSTextContentStorage` / `NSTextLayoutManager` pair. Element dispatch and layout-fragment dispatch are per-block-kind. Edits in WYSIWYG route through `EditingOps`, mutate the `Document`, and apply to `NSTextContentStorage` via `DocumentEditApplier`. Source mode edits flow into storage directly.

## Block-Model Pipeline

```
raw markdown ──► MarkdownParser ──► Document (block tree)
                                        │
                        ┌───────────────┼───────────────┐
                        ▼               ▼               ▼
               DocumentRenderer   SourceRenderer   MarkdownSerializer
               (WYSIWYG path)     (source path)   (save / copy)
                        │               │               │
                        ▼               ▼               │
                 NSAttributedString + .blockModelKind   │
                        │               │               │
                        ▼               ▼               │
              NSTextContentStorage  ←────┘              │
                        │   (BlockModelContentStorageDelegate)
                        ▼   → per-kind NSTextElement subclass
              NSTextLayoutManager
                        │   (BlockModelLayoutManagerDelegate)
                        ▼   → per-kind NSTextLayoutFragment subclass
                       NSTextView
                        │
                        ▼
                   DocumentProjection (blockSpans, index mapping)
                        │
                        ▼
                     EditingOps (insert/delete/split/merge/format)
                        │
                        ▼
                   DocumentEditApplier ──► NSTextContentStorage splice
```

## Architecture Invariants

These are facts about the codebase. They are mechanically enforced where possible (DEBUG assertions, `scripts/rule7-gate.sh`) and load-bearing for everything else.

**A. Single write path into `NSTextContentStorage`.** `DocumentEditApplier.applyDocumentEdit(priorDoc:newDoc:contentStorage:…)` is the one function that mutates TK2 content storage for WYSIWYG edits. It consumes two `Document` values and emits a minimal element-bounded splice inside `performEditingTransaction`. The fill paths (`fillViaBlockModel`, `fillViaSourceRenderer`, `fill(note:)`) are the other authorized writers (initial-load, not edit-time). Enforced by `StorageWriteGuard`'s four scoped flags (`applyDocumentEditInFlight`, `fillInFlight`, `attachmentHydrationInFlight`, `legacyStorageWriteInFlight`) and a DEBUG assertion in `TextStorageProcessor.didProcessEditing` that traps any unauthorized character-edit while `blockModelActive && !sourceRendererActive`. Release builds compile to no-ops. The grep gate flags any `performEditingTransaction` caller outside `DocumentEditApplier.swift`.

Two sanctioned permanent exemptions exist alongside the canonical write path:

1. **IME composition** (Phase 5e) — `setMarkedText` writes inside `markedRange` while `compositionSession.isActive == true` are allowed via the `compositionAllowsEdit` predicate; commit folds the final string into `Document` via one `applyEditResultWithUndo` call.
2. **Async attachment hydration** (display math + mermaid) — wrapped in `StorageWriteGuard.performingAttachmentHydration { ... }`. After `BlockRenderer`'s WebView completes, source text is replaced with a rendered NSTextAttachment. Document doesn't change (presentation-only state) so it can't route through `applyDocumentEdit`; character count differs from U+FFFC so it can't be made attribute-only; and for mermaid an attribute-only refactor would hurt UX (user wants to see source syntax during the render).

`performingLegacyStorageWrite` (the original Phase 5a escape hatch) has zero production call sites — all 14 original bypasses retired or reclassified into dedicated scopes. It's retained as a fallback for backwards compatibility but is deprecated for new code.

**B. One layout primitive per block type.** Every per-block visual runs through TK2's element + fragment dispatch. Each block kind maps to exactly one `NSTextParagraph` subclass and at most one `NSTextLayoutFragment` subclass. If a block's rendering is wrong, the fragment class for that kind is where the fix lives. There is no second draw path.

**C. All block content lives in `NSTextContentStorage`.** Tables carry cell text as live character runs; mermaid and math keep their source text in storage and hide it visually via their fragments. `NSTextFinder` / Cmd+F / accessibility traverse everything by construction. No block kind routes through `NSTextAttachment` as its *only* source of text.

**D. No marker-hiding tricks in storage.** WYSIWYG storage contains only displayed characters — markdown markers (`**`, `#`, `` ` ``, `>`, list prefixes, fence lines, HR lines, cell pipes) do not exist in `textStorage.string`. Source mode contains markers but renders them via `SourceLayoutFragment` overpainting `.markerRange` runs in `Theme.shared.chrome.sourceMarker`; the default `.foregroundColor` is never mutated to hide or dim markers. The grep gate bans tiny-font / clear-foreground / negative-kern / invisible-character tricks.

**E. Views read data; views never write data.** The projection → renderer → element → fragment chain is one-way. Views capture user intent (clicks, keystrokes, selections) and call a pure `EditingOps.*` primitive that returns a new `Document`; `applyDocumentEdit` delivers the minimal splice. Widget-level read-back into the model (the cautionary `InlineTableView` pattern, deleted) is grep-banned.

**F. Theme is the sole presentation source of truth.** Every font size, color, paragraph spacing, border width, margin, and line-height literal is defined in `ThemeSchema.swift` + bundled JSON files. Renderers and fragments *read* from `Theme.shared`; they do not hardcode values. The grep gate bans literal `systemFont(ofSize:)`, `paragraphSpacing`, and hex color literals in render-path files.

**G. `EditContract` checks every edit.** Every `EditingOps` primitive returns an `EditResult` carrying an `EditContract` (declared structural actions, post-cursor, post-selection length). `Invariants.assertContract(before:after:contract:)` runs in pure unit tests *and* in the live `EditorHarness` after every scripted input — the same invariant on both layers.

## Document Model

Nine block types (`FSNotesCore/Rendering/Document.swift`):

- `paragraph(inline:)`
- `heading(level:suffix:)` — ATX or setext; level 1-6
- `codeBlock(language:content:fence:)` — fenced; indented code blocks parse to fenced for round-trip
- `list(items:loose:)` — `ListItem` carries `indent`, `marker`, `afterMarker`, optional `checkbox`, inline content, and `body: [Block]` for nested children + continuation in CommonMark source order
- `blockquote(lines:)` — each `BlockquoteLine` stores its `>`-prefix verbatim
- `horizontalRule(character:length:)` — source character + run length preserved for byte-equal round-trip
- `htmlBlock(raw:)` — raw HTML source, verbatim
- `table(header:alignments:rows:columnWidths:)` — `TableCell` values (inline trees), per-column `TableAlignment`, optional persisted drag-resize widths. Tables serialize canonically on every write; legacy non-canonical formatting is rewritten on first save.
- `blankLine` — structural separator (renders to empty string)

Each content block contains `[Inline]` trees: `.text`, `.bold`, `.italic`, `.strikethrough`, `.underline`, `.highlight`, `.code`, `.link`, `.image`, `.autolink`, `.wikilink(target:display:)`, `.rawHTML`, `.entity`, `.escapedChar`, `.lineBreak`, `.math`, `.displayMath`, `.kbd`, `.superscript`, `.subscript`.

**Round-trip contract**: `MarkdownSerializer.serialize(MarkdownParser.parse(x))` is byte-equal to `x` for supported constructs. The fields that preserve exact source (blockquote prefix, HR character/length, list `indent`/`marker`/`afterMarker`, checkbox text) exist specifically so the serializer can replay the user's typing without rewriting unrelated whitespace. Tables (canonical since the table refactor) and the `columnWidths` HTML-comment sentinel are the deliberate exceptions.

Wikilinks parse from `[[target]]` or `[[target|display]]` and render as styled clickable text using the `wiki:<target>` URL scheme — the brackets never appear in rendered storage. The click handler dispatches `wiki:` URLs to the note resolver.

### Blank Lines and Zero-Length Blocks

`Block.blankLine` renders to an empty string (`""`), producing a `blockSpan` with `length == 0`. Consequences:

1. **Range overlap checks fail**: `span.location < rangeEnd && spanEnd > range.location` returns `false` for zero-length spans. `blockIndices(overlapping:)` falls back to `blockContaining(storageIndex:)` for zero-length selections.
2. **Cursor position checks fail**: `cursorLoc >= span.location && cursorLoc < span.location + span.length` is never true for zero-length blocks. Code operating on zero-length blocks must special-case `span.length == 0`.
3. **Blank lines are structural, not visual**: in rendered output, blank lines are the `"\n"` separator between adjacent blocks. Empty paragraphs use the same paragraph style for consistent line metrics.
4. **No fallback path between WYSIWYG and source**: when `documentProjection` is non-nil (WYSIWYG), all editing must route through `EditingOps`. Returning `false` from a block-model function does NOT fall through to source mode.
5. **Return at end of paragraph creates blank lines**: `splitParagraphOnNewline` produces `[paragraph(before), .blankLine]`; the cursor lands on the zero-length blank.

### Save Path

Every save routes through `Note.save(markdown: String)`. There is no second save entry point.

- **WYSIWYG save**: `MarkdownSerializer.serialize(projection.document)` → `Note.save(markdown:)`. The `Document` is the sole source of truth at serialize time.
- **Source-mode save**: `textStorage.string` is already byte-preserving markdown. `Note.save()` (no arg) restores rendered block placeholders and unloads attachments in-place, then writes the file — no round-trip through `MarkdownParser` / `MarkdownSerializer`.

`save(markdown:)` invalidates `Note.cachedDocument`, updates `modifiedLocalAt`, and clears `isBlocked` so the file-system watcher can resume detecting external changes. The grep gate bans `prepareForSave` / `.save(content:)` patterns to prevent reintroduction of the legacy save-path widget walker.

## Per-Block-Kind Editor Dispatch

Every `Block` kind has a dedicated `BlockEditor` conformer under `FSNotesCore/Rendering/BlockEditors/`:

| Block kind | Editor file |
|---|---|
| `.paragraph` | `ParagraphBlockEditor.swift` |
| `.heading` | `HeadingBlockEditor.swift` |
| `.codeBlock` | `CodeBlockBlockEditor.swift` |
| `.htmlBlock` | `HtmlBlockBlockEditor.swift` |
| `.blankLine`, `.horizontalRule`, `.table` (atomic / read-only kinds) | `AtomicBlockEditors.swift` |
| `.list` | `ListBlockEditor.swift` (wraps `EditingOps.{insertIntoList,deleteInList,replaceInList}`) |
| `.blockquote` | `BlockquoteBlockEditor.swift` |

Protocol shape (`EditingOperations.swift`):
```swift
public protocol BlockEditor {
    static func insert(into block: Block, offsetInBlock: Int, string: String) throws -> Block
    static func delete(in block: Block, from: Int, to: Int) throws -> Block
    static func replace(in block: Block, from: Int, to: Int, with: String) throws -> Block
}
```

`EditingOps.{insertIntoBlock, deleteInBlock, replaceInBlock}` switches are exhaustive over the 9 block kinds: no `default: throw .notSupported` patterns. The compiler enforces that any new block kind must add an explicit branch.

## Parser Combinator Infrastructure

`FSNotesCore/Rendering/Combinators/Parser.swift` (~250 LoC) provides a bespoke parser-combinator library: `Parser<A>` value type, primitives (`char`, `string`, `oneOf`, `satisfy`, `eof`), combinators (`<|>`, `seq2`, `between`, `many`, `optional`, `sepBy`, `lookahead`, `notFollowedBy`). Backtracking is non-mutating — a failed alternative leaves the input intact. `many` has an explicit zero-consumption infinite-loop guard.

Bespoke rather than a Pod because existing Swift combinator libraries lean on existential / protocol-witness machinery that compiles slowly. ~250 LoC of value types + closures is faster to compile, easier to debug, and removes the dependency surface.

The bridge between `MarkdownParser`'s `[Character] + Int` cursor convention and the combinator API's `Substring` shape lives in each ported file as a `match(_ chars:from:)` (or `read(lines:from:…)` for block readers) static method.

### Inline tokenizer chain

`MarkdownParser.tokenizeNonEmphasis` walks each character of paragraph text once, dispatching to detectors in `Combinators/`. Each detector exposes `match(_ chars: [Character], from: Int) -> Match?`.

| File | Replaces | Spec bucket (current) |
|---|---|---|
| `HardLineBreakParser.swift` | `\\\n` + ≥2-space-newline | Hard line breaks 15/15 |
| `CodeSpanParser.swift` | `tryMatchCodeSpan` | Code spans 22/22 |
| `MathParser.swift` | `tryMatchInlineMath` + `tryMatchDisplayMath` | FSNotes++ extension |
| `StrikethroughParser.swift` | `tryMatchStrikethrough` | GFM extension |
| `WikilinkParser.swift` | `tryMatchWikilink` | FSNotes++ extension |
| `EntityParser.swift` | `tryMatchEntity` + 50-entry HTML5 named-entity table | Entity refs 17/17 |
| `AutolinkParser.swift` | `tryMatchAutolink` | Autolinks 19/19 |
| `RawHTMLParser.swift` (5 sub-grammars) | `tryMatchRawHTML` | Raw HTML 20/20 |
| `LinkParser.swift` (carries `LinkParser` + `ImageParser`) | `tryMatchLink` + `tryMatchImage` | Links 90/90, Images 21/22 |

How "combinator" the port is varies with grammar shape. Hard-line-break, code-span, math, strikethrough, wikilink, autolink use real combinator chains. Entity is a lookahead dispatch into three sub-`Parser<String>`s. Raw HTML is the same shape with five sub-grammars. Link/image are an exception: the bracket-match-with-code-span-skipping requires `codeSpanRanges` from the caller, which is more naturally an imperative `Int` walk than a state-monad threading.

### Inline emphasis

`Combinators/EmphasisResolver.swift` carries the CommonMark §6.2 delimiter-stack algorithm. Three responsibilities:

- `InlineToken` enum and `DelimiterRun` final class — data types between Phase A (`MarkdownParser.tokenizeNonEmphasis`) and Phase B (resolve).
- `EmphasisResolver.flanking(...)` — left/right-flanking rules with `*` permissive vs `_` intra-word strict, plus the v0.31.2 punctuation broadening for Sc/Sk/Sm/So categories (currency symbols `£`, `€` count as punctuation for flanking).
- `EmphasisResolver.resolve(tokens:refDefs:)` — the doubly-walked token rewrite. For each closer, scans backwards for a matching opener obeying Rule of 3; collects content; replaces the opener slot with the new `.bold` / `.italic`; rebuilds the index list and continues.

Not a literal `Parser<…>` port — the algorithm is a stateful linked-list rewrite over tokens, not a backtracking parse over characters. `MarkdownParser.parseInlines` is now a thin three-phase orchestrator: `tokenizeNonEmphasis` → `EmphasisResolver.resolve` → `resolveHTMLTagPairs`.

`Combinators/LinkResolver.swift` carries the §6.4 inactive-link delimiter-stack algorithm. A pre-pass walks the inline character stream, tracking `[` and `![` openers on a stack; on each `]` it tries to match a link/image body. On success a `[` opener flips every earlier `[` opener to `active = false` so nested `[a [b](u1)](u2)` cannot re-activate as a link. `![` openers stay active because spec §6.4 only inactivates link openers.

### Block readers

`MarkdownParser.parse` is a thin block-loop dispatcher. Each block kind has a dedicated reader in `Combinators/` exposing `detect(_ line:)` (single-line) and `read(lines:from:…)` (multi-line). Readers in the system:

| File | Owns |
|---|---|
| `FencedCodeBlockReader.swift` | fence open/close detection + body read |
| `HorizontalRuleReader.swift` | HR detection |
| `ATXHeadingReader.swift` | ATX heading + setext-underline detection |
| `HtmlBlockReader.swift` | 7 HTML-block sub-types (pre/script/style, comment, PI, declaration, CDATA, block tag, type-7 complete tag) |
| `BlockquoteReader.swift` | `>` prefix + lazy continuation; injected closures `parseInlines` + `interruptsLazyContinuation` |
| `TableReader.swift` | GFM pipe tables (header-on-current-line + header-buffered modes) |
| `ListReader.swift` | per-line classifier (`parseListLine`) + multi-line collection (`read`) + `buildItemTree`. Owns helpers `leadingSpaceCount`, `stripLeadingSpaces`, `canAppendListMarker`, `deepestOwner`, `isEmphasisOnlyParagraph`. Closure surface: `parseInlines`, `interruptsLazyContinuation`, `parseRecursive` (callback to `MarkdownParser.parse`), `refDefs`. |

The recursive callback `parseRecursive: { MarkdownParser.parse($0) }` is how `ListReader.read` and `BlockquoteReader.read` re-enter the parser for inner item bodies.

Setext heading promotion stays in `MarkdownParser.parse` because it depends on the paragraph buffer (`rawBuffer`) — not a self-contained line read. Only the underline detector moved.

After full decomposition, `MarkdownParser.swift` shrank from ~3,974 LoC to ~1,454 LoC. The parser owns: line splitter, paragraph buffer, link-ref-def first pass, inline tokenizer entry, indented-code-block branch, `interruptsLazyContinuation`, `isBlankLine`. Everything else delegates to a reader.

## Editing FSMs by Block Type

Each table shows what every editing action does on that block type. "Unsupported" means no-op or throws.

### Paragraph

CommonMark §4.8: paragraphs are interrupted by blank lines, headings, thematic breaks, block quotes, list items, and fenced code blocks.

| Action | Result |
|--------|--------|
| **Return** | Split at cursor → two paragraphs. Cursor at start → blankLine + paragraph. Cursor at end → paragraph + blankLine. |
| **Backspace at start** | Merge with previous block (see Cross-Block Merge). |
| **Tab / Shift-Tab** | No block-model operation (passthrough). |
| **Inline format** | Toggle trait on selection or set pending trait at cursor. |
| **Set heading level** | Paragraph → heading(level). Content becomes heading suffix. |
| **Toggle list** | Paragraph → single-item list. |
| **Toggle blockquote** | Paragraph → blockquote with one line. |
| **Insert HR** | Insert blankLine + HR after paragraph. |
| **Toggle todo** | Paragraph → single-item todo list with `[ ]`. |

### Heading

CommonMark §4.2 (ATX) / §4.3 (setext). Headings are single-line; opening `#` count determines level (1-6).

| Action | Result |
|--------|--------|
| **Return** | Split → heading(same level) + paragraph. Cursor moves to the new paragraph. |
| **Backspace at start** | Merge with previous block. |
| **Inline format** | Toggle trait on heading suffix inlines. |
| **Set heading level** | Change level (1-6). Same level or level 0 → convert to paragraph. |
| **Toggle list / blockquote / todo** | Unsupported. |
| **Insert HR** | Insert blankLine + HR after heading. |

### Code Block

CommonMark §4.5: fenced code blocks open with `` ` `` or `~` (3+). Content is verbatim — no inline parsing.

| Action | Result |
|--------|--------|
| **Return** | Insert literal newline within code content. *Special:* Return at end-of-content with trailing `\n` exits the block and inserts a new empty paragraph. |
| **Backspace at start** | Delete within content. If content empty at boundary, merge with previous. |
| **Tab** | Insert literal tab. |
| **Inline format / heading / list / blockquote / todo** | Unsupported (verbatim content). |
| **Insert HR** | Insert HR after code block. |

### List

CommonMark §5.2-5.3. Structural operations route through **ListEditingFSM**.

**Ordered list numbering**: all ordered list items store and serialize with marker `1.` regardless of rendered position. `ListRenderer` maintains a running counter at each nesting level to display sequential numbers. Split lists re-merge naturally when the separating block is deleted — no special merge logic required.

| Action | Result |
|--------|--------|
| **Return (non-empty item)** | FSM `newItem`: split item at cursor. New item inherits marker; checkbox resets to unchecked. Children stay with original. |
| **Return (empty item, depth 0)** | FSM `exitToBody`: convert empty item to paragraph. |
| **Return (empty item, depth > 0)** | FSM `unindent`. |
| **Backspace at start (depth 0)** | FSM `exitToBody`. |
| **Backspace at start (depth > 0)** | FSM `unindent`. |
| **Tab (has previous sibling)** | FSM `indent`: item becomes child of previous sibling. |
| **Tab (no previous sibling)** | FSM `noOp`. |
| **Shift-Tab (depth 0)** | FSM `exitToBody`. |
| **Shift-Tab (depth > 0)** | FSM `unindent`. |
| **Inline format** | Toggle trait on item's inline content. |
| **Toggle list** | Convert ONLY the cursor's item to paragraph, splitting the list. (Multi-selection differs — see Multi-Selection.) |
| **Insert HR** | Insert HR after list block. |
| **Toggle todo** | All items have checkbox → unwrap. Otherwise → add `[ ]` to items lacking. |

### ListEditingFSM

Pure function: `(State, Action) → Transition`. State: `.bodyText` or `.listItem(depth: Int, hasPreviousSibling: Bool)`.

| State | Action | Transition |
|-------|--------|------------|
| `.bodyText` | any | `noOp` |
| `.listItem(0, _)` | `.tab` with sibling | `indent` |
| `.listItem(0, false)` | `.tab` | `noOp` |
| `.listItem(0, _)` | `.shiftTab` / `.deleteAtHome` / `.returnOnEmpty` | `exitToBody` |
| `.listItem(>0, _)` | `.tab` with sibling | `indent` |
| `.listItem(>0, false)` | `.tab` | `noOp` |
| `.listItem(>0, _)` | `.shiftTab` / `.deleteAtHome` / `.returnOnEmpty` | `unindent` |
| any `.listItem` | `.returnKey` | `newItem` |

### Blockquote

CommonMark §5.1. Lazy continuation: a line without `>` continues the blockquote if it would be a paragraph continuation. Nested blocks allowed.

| Action | Result |
|--------|--------|
| **Return** | Split blockquote line at cursor; both lines stay in same blockquote block. |
| **Backspace at start** | Merge with previous block. |
| **Inline format** | Toggle trait on line's inline content. |
| **Toggle blockquote** | Blockquote → paragraph (all lines merged). |
| **Insert HR** | Insert HR after blockquote. |

### Horizontal Rule

CommonMark §4.1. Read-only.

| Action | Result |
|--------|--------|
| **Backspace at start** | Remove HR; merge surrounding blocks. |
| **Insert HR** | Insert another HR after (with blankLine separator). |
| All others | Unsupported. |

### HTML Block

CommonMark §4.6. Verbatim content; renders with code font.

| Action | Result |
|--------|--------|
| **Return** | Insert literal newline. No structural split (unlike code blocks, no keyboard escape). |
| **Backspace at start** | Delete within content. If empty at boundary, merge with previous (falls back to paragraph). |
| **Tab** | Insert literal tab. |
| All inline-formatting / structural | Unsupported. |
| **Insert HR** | Insert HR after. |

### Table

GFM extension. Cell content is an inline tree; cells are stored as `[TableCell]` where each cell is `[Inline]`. The render path is native TK2 `TableElement` + `TableLayoutFragment`.

- **Element dispatch**: `DocumentRenderer` tags the table's paragraph range with `.blockModelKind = .table` plus a `.tableAuthoritativeBlock` boxed reference to the `Block.table` value. The content-storage delegate reads the attribute and constructs a `TableElement` (boxed authoritative block carries alignments and structure that flat cell text alone couldn't convey).
- **Display**: `TableLayoutFragment` draws the grid directly on TK2 — resize handles, column separators, alignment — with no NSView attachment. Cells are rendered via `InlineRenderer.render(cell.inline, baseAttributes:)` — the same code path paragraphs use.
- **Cell editing**: field-editor edits flow through `InlineRenderer.inlineTreeFromAttributedString(_:)` (the pure inverse of `render`) and route through `EditingOps.replaceTableCellInline(blockIndex:at:inline:in:)`. No raw-markdown round-trip.
- **Structural editing**: `EditingOps.{insertTableRow, insertTableColumn, deleteTableRow, deleteTableColumn, setTableColumnAlignment, setTableColumnWidths}`. Hover handles invoke these via `EditingOps`, not by widget-state mutation.
- **Column widths**: `setTableColumnWidths` persists drag-resize widths on `Block.table.columnWidths`. `MarkdownSerializer` emits an HTML-comment sentinel `<!-- fsnotes-col-widths: [100.5, 200, 150.25] -->`; the parser reads it back.

| Action | Result |
|--------|--------|
| **Return inside cell** | Insert `<br>` (rendered as `\n`). Outside a cell: unsupported. |
| **Backspace at start** | Remove table; merge surrounding blocks. |
| **Tab / Shift-Tab inside cell** | Cell navigation handled by `TableLayoutFragment` focus logic. |
| **Inline format** | Edits the cell's field-editor storage, converts to inline tree, flushes through `replaceTableCellInline`. |
| **Insert HR** | Insert HR after table. |

### Multi-Selection

When multiple blocks are selected, operations apply to all selected blocks. Selection defined by `blockIndices(overlapping:)`.

| Action | Result |
|--------|--------|
| **Return / Backspace** | Delete selection; merge first partial block with last partial block. |
| **Delete** | Delete content without merge. |
| **Tab / Shift-Tab** | Indent / outdent all selected (lists support; other blocks no-op). |
| **Inline format** | Toggle trait across selection; per-block. |
| **Set heading level** | Apply to first overlapping non-blank block only (deliberate departure from list/quote/todo). |
| **Toggle list** | Convert all selected to a single list (one item per block). |
| **Toggle blockquote** | Wrap all in single blockquote. |
| **Insert HR** | Insert after last selected block. |
| **Toggle todo** | All have checkboxes → remove; otherwise → add to items lacking. Non-list blocks → todo items. |
| **Copy / Paste** | Serialize selection to markdown / replace with parsed `Document`. |

## Cross-Block Merge Rules

When backspace crosses a block boundary, `mergeAdjacentBlocks` combines the tail of one with the head of the next:

| Block A (tail) | Block B (head) | Result |
|---------------|----------------|--------|
| paragraph | paragraph | Single merged paragraph (inlines concatenated) |
| heading | paragraph | Heading with paragraph's inlines appended |
| paragraph | heading | Paragraph with heading suffix appended |
| heading | heading | First heading with second's suffix appended |
| list | paragraph | Paragraph inlines appended to last list item |
| paragraph | list | Paragraph with list's first item inlines appended |
| any | blankLine | BlankLine removed; if adjacent paragraphs result, they merge |
| any | horizontalRule | HR removed |
| any | codeBlock | Code block removed (content lost) |
| any | htmlBlock | HTML block removed (content lost) |
| any | blockquote | Blockquote removed (first line's inlines appended) |

## Edit Contracts

Every `EditingOps` primitive returns an `EditResult` carrying an `EditContract` that *declares* what changed structurally. `Invariants.assertContract(before:after:contract:)` runs in pure unit tests AND in the live editor harness after every scripted input.

### DocumentCursor

A cursor in document terms rather than storage terms:
```swift
public struct DocumentCursor: Equatable {
    public let blockPath: [Int]
    public let inlineOffset: Int
}
```

`blockPath` identifies a block (flat today, nestable later without migration). `inlineOffset` is a UTF-16 character offset into the block's rendered inline text — the same coordinate `DocumentRenderer` emits. Conversion to a storage `Int` goes through the projection. For atomic-attachment block kinds (`.horizontalRule`, `.table`), `inlineOffset` is canonically 0.

### EditAction

Coarse-grained — describes *what* changed, not *how*:

| Case | Meaning |
|------|---------|
| `.insertBlock(at:)` | New block at this post-edit top-level index. |
| `.deleteBlock(at:)` | Block at this pre-edit index removed. |
| `.replaceBlock(at:)` | Same position, different content. |
| `.mergeAdjacent(firstIndex:)` | Two adjacent blocks merged; doc one shorter. |
| `.splitBlock(at:inlineIndex:offset:)` | Block split in two; doc one longer. |
| `.renumberList(startIndex:)` | Ordered list markers resequenced. |
| `.reindentList(range:)` | Indent/outdent across range. |
| `.modifyInline(blockIndex:)` | Inline-level change within a single block. |
| `.changeBlockKind(at:)` | Block kind changed (paragraph ↔ heading, etc.). |
| `.replaceTableCell(blockIndex:rowIndex:colIndex:)` | Cell content changed; table shape unchanged. |

### EditContract

```swift
public struct EditContract: Equatable {
    public var declaredActions: [EditAction]
    public var postCursor: DocumentCursor
    public var postSelectionLength: Int
}
```

Empty `declaredActions` means "no structural change" — pure-inline edit on a single block. Strictly enforced: empty contract requires `beforeBlocks == afterBlocks`.

### Invariant: `assertContract`

Three checks:

1. **Count-delta matches declared size-changing actions.** Sum of `+1` per `.insertBlock`/`.splitBlock` and `-1` per `.deleteBlock`/`.mergeAdjacent` must equal `afterBlocks.count - beforeBlocks.count`.
2. **Size-preserving contracts leave neighbors untouched.** When every action is in-place (`.changeBlockKind`, `.modifyInline`, `.replaceBlock`, `.replaceTableCell`), every block index *not* named must be bit-identical before and after. This is the "toggleList leaked to a neighbor" detector.
3. **`postCursor` resolves in-bounds.**

### Observed-delta pattern

Several primitives go through `replaceBlocksSlow`, which runs a coalescence pass merging adjacent same-kind blocks. The primitive can't statically know how many neighbors will coalesce — it depends on what's around the target. The pattern:

```swift
let delta = newProj.document.blocks.count - projection.document.blocks.count
var actions: [EditAction] = [.changeBlockKind(at: blockIndex)]
for _ in 0..<(-delta) {
    actions.append(.mergeAdjacent(firstIndex: blockIndex))
}
result.contract = EditContract(declaredActions: actions, postCursor: ...)
```

`toggleList`, `toggleTodoList`, `indentListItem`, `unindentListItem`, and `exitListItem` all use this pattern.

## Paste Pipeline

Copy reads `EditTextView.copyAsMarkdownViaBlockModel()` which walks `blockIndices(overlapping: selection)` and either serializes each fully-covered block through `MarkdownSerializer.serialize(Document(blocks: [block]))` or (for partial paragraph overlaps) calls `splitInlines` to isolate the covered inline sub-tree. The result is pushed to the pasteboard as markdown plus `.rtf` (cross-app fidelity into TextEdit, Pages, Mail).

Paste dispatches on pasteboard type in this order (first match wins):

1. **Markdown pasteboard type** — `insertMarkdownFragmentViaBlockModel(_:)` parses the string as a full `Document` and splices via `EditingOps.replaceFragment(range:with:in:)`. One undo step regardless of selection state.
2. **`.png` / `.tiff`** — saves bytes to `<note>.textbundle/files/<uuid>.<ext>` (textbundle) or `<note>_files/<uuid>.<ext>` (legacy) and inserts `Inline.image(url:alt:)` via `replaceFragment`.
3. **`NSAttributedString`** (no markdown, no image) — `documentFromAttributedString(_:)` converts runs preserving bold/italic/strike/underline/link traits; drops font/colors/spacing; strips attachments. Paragraph split on `\n\n` and `\u{2028}`. Routes through `replaceFragment`.
4. **Fallback** — `super.paste(...)`.

All four branches route writes through `applyDocumentEdit`. `EditingOps.replaceFragment` is the fused delete+insert primitive: empty range degenerates to `insertFragment`, empty fragment degenerates to `delete`, both non-empty compose into one `EditResult` with one `EditContract` (one undo step).

## Inline Re-parsing (RC4)

Character-by-character typing can complete inline patterns (typing `*` completes `*bold*`). After inserting closing delimiters (`)`, `]`, `}`, `` ` ``, `>`, `*`, `_`, `~`), `reparseInlinesIfNeeded` serializes the block's inlines and re-parses. If the parse tree differs, the block is replaced.

## TextKit 2 Adoption

`EditTextView` is fully on TextKit 2 (`NSTextLayoutManager` + `NSTextContentStorage`). `FSNotes/LayoutManager.swift` and the TK1 `AttributeDrawer` protocol are deleted; only `ImageSelectionHandleDrawer` survives as a hit-testing helper.

### Content-storage delegate

`BlockModelContentStorageDelegate` (`FSNotesCore/Rendering/BlockModelElements.swift`) implements `textContentStorage(_:textParagraphWith:)`. For each paragraph range:

1. Checks `.foldedContent` first — if present, returns `FoldedElement` (zero-height) regardless of underlying block kind.
2. Reads `.blockModelKind` tagged by the renderer.
3. For `.table`, unwraps `.tableAuthoritativeBlock` and constructs a `TableElement` directly.
4. Otherwise dispatches through `BlockModelElementFactory` to the matching `NSTextParagraph` subclass: `ParagraphElement`, `ParagraphWithKbdElement`, `HeadingElement`, `ListItemElement`, `BlockquoteElement`, `CodeBlockElement`, `HorizontalRuleElement`, `MermaidElement`, `MathElement`, `DisplayMathElement`, `SourceMarkdownElement`.

Untagged ranges (mid-splice windows) fall back to TK2's default `NSTextParagraph`.

### Layout-manager delegate

`BlockModelLayoutManagerDelegate` dispatches by element class:

- `FoldedLayoutFragment` (zero-height; wins over every other dispatch)
- `HorizontalRuleLayoutFragment` — gray bar
- `BlockquoteLayoutFragment` — depth-stacked left bars
- `HeadingLayoutFragment` — H1/H2 hairline + folded `[...]` chip
- `MermaidLayoutFragment` — diagram widget; reads `.renderedBlockSource`
- `MathLayoutFragment` — MathJax bitmap
- `DisplayMathLayoutFragment` — centered equation for inline `$$…$$` paragraph
- `TableLayoutFragment` — native TK2 grid with resize handles
- `KbdBoxParagraphLayoutFragment` — rounded boxes behind `.kbdTag` runs
- `CodeBlockLayoutFragment` — gray rounded-rect background + 1pt border
- `SourceLayoutFragment` — paints `.markerRange` runs in `theme.chrome.sourceMarker`

Plain paragraphs (`ParagraphElement`, `ListItemElement`) fall back to the default `NSTextLayoutFragment` — zero dispatch overhead for the common case.

### TK2 gotchas (learned the hard way)

1. **TK2 adoption happens at `NSTextView` construction.** `NSTextView` fixes its TextKit version when the initial `NSTextContainer` is attached. A post-hoc `replaceTextContainer(_:)` does NOT flip an already-TK1 view. For storyboard-decoded views, construct a fresh TK2 instance and re-point `scrollView.documentView`.

2. **Reading `NSTextView.layoutManager` on a TK2 view permanently disables TK2.** AppKit lazily instantiates a TK1 `NSLayoutManager` compatibility shim and `textLayoutManager` becomes `nil` — silent fallback with no API to detect. Use the `layoutManagerIfTK1` accessor (returns nil under TK2, the TK1 manager otherwise) for any code path that needs TK1 behavior.

3. **`cacheDisplay` does NOT capture fragment-level drawing.** `bitmapImageRepForCachingDisplay` invokes `view.draw()` but does not invoke `NSTextLayoutFragment.draw`. Per-block chrome (HR line, blockquote border, heading hairline, kbd box, code-block border) won't appear in test snapshots taken this way. Verify these by asserting fragment-class dispatch (see `TextKit2FragmentDispatchTests`) or via live deployment.

4. **Element-vs-fragment attribute ownership.** `DocumentRenderer` / `SourceRenderer` tag `.blockModelKind` + per-kind payload (`.headingLevel`, `.tableAuthoritativeBlock`, `.renderedBlockSource`) at render time. The content-storage delegate reads these and constructs the right element class; the layout-manager delegate dispatches by element class to the right fragment.

## Edit Application (`DocumentEditApplier`)

`DocumentEditApplier.applyDocumentEdit(priorDoc:newDoc:contentStorage:…)` is the single mutation entry point for TK2 content storage. Takes two `Document` values (before/after `EditingOps`) and emits a minimal element-bounded splice inside one `performEditingTransaction`.

**Block identity is structural, not UUID-based.** The differ runs LCS keyed on `Block: Equatable` (O(M·N) on block count). A post-LCS pass merges adjacent `(delete priorIdx, insert newIdx)` pairs of the same kind at the same relative position into a single `.modified` change — the "typing into a paragraph" case is one element update, not delete+insert. Non-contiguous changes fall back to a single contiguous `[firstChange … lastChange]` replacement.

**Guarantee**: elements above the first changed block are untouched across every edit. This is what makes typing into a long note cheap — TK2's layout engine does not re-query paragraphs it didn't touch.

`EditTextView.applyEditResultWithUndo` calls `applyDocumentEdit` and attaches `EditResult.contract` + the pre-edit projection to associated objects. `EditorHarness` reads those back after every scripted input and runs `Invariants.assertContract` against the live post-edit projection — same harness invariants as on pure calls.

**Stale-projection guard.** `applyDocumentEdit` accepts an optional `priorRenderedOverride: RenderedDocument?` parameter for cases where async hydration (inline-math swap, image resize) has mutated `NSTextContentStorage` since the last `priorDoc.render()`. Callers that know their projection is stale (the inline-math callback path, image-resize commit) pass `oldProjection.rendered` so span-offset math uses the post-swap rendered layout instead of re-rendering from a stale `priorDoc`. `priorDoc` still drives the LCS block-diff (block-value equality is unaffected by rendered-form drift).

## IME Composition (`CompositionSession`)

`FSNotesCore/Rendering/CompositionSession.swift` is a value type attached to `EditTextView` via associated-object storage, capturing the state of a marked-text composition (Kotoeri, Pinyin, Korean 2-Set, Option-E dead-key accent, emoji picker). Fields: `anchorCursor: DocumentCursor` (pre-composition caret), `markedRange: NSRange`, `isActive: Bool`, plus a `pendingEdits` queue and a `preSessionFoldState` snapshot.

Lifecycle: `setMarkedText(...)` enters; repeated calls update; `unmarkText()` or `insertText(_:replacementRange:)` with the committed string folds the final text into `Document` via one `applyEditResultWithUndo`. Escape / empty commit aborts and reverts to `anchorCursor`.

**Invariant A interaction**: `TextStorageProcessor.didProcessEditing` relaxes the single-write-path assertion for mutations strictly inside `markedRange` while `compositionSession.isActive == true` — the one sanctioned architectural exemption, gated by an assertion predicate (not by `performingLegacyStorageWrite`).

## Undo / Redo (`UndoJournal`)

`FSNotesCore/Rendering/UndoJournal.swift` is a per-editor reference type with `past: [UndoEntry]` and `future: [UndoEntry]` stacks. Each `UndoEntry` carries an `EditContract.InverseStrategy`:

- **Tier A** — cheap inverse `EditContract` (e.g. invert insert↔delete with swapped ranges)
- **Tier B** — `[Block]` snapshot of the affected block range
- **Tier C** — full `Document` snapshot (rare)

5-class coalescing FSM:
- `typing` — adjacent single-char inserts within 1s merge into one entry
- `deletion` — same for backspace runs
- `structural` — Return, Tab, toolbar (own group)
- `formatting` — inline trait toggles (own group)
- `composition` — IME commit (own group via Phase 5e suspension)

A 1-second heartbeat finalizes the current group on idle (mockable for tests).

**Wire-in**: `applyEditResultWithUndo` calls `journal.record(entry, on: self)`. The **one surviving** `NSUndoManager.registerUndo(withTarget:handler:)` site in the editor path lives inside `UndoJournal.record`. The handler pops the journal and replays the inverse via `applyDocumentEdit` with a `replayDepth += 1` guard so the replay doesn't re-journal. Grep invariant: `rg 'registerUndo|beginUndoGrouping|endUndoGrouping' FSNotes/ FSNotesCore/` returns the one `UndoJournal.record` hit plus two out-of-scope sites on `notesListUndoManager` (note-list delete/reorder).

While `compositionSession.isActive`, `journal.record` is a no-op (the composition commit produces exactly one `composition`-class entry; abort produces zero).

## Attachment Handling

Inline images, PDFs, and QuickLook-previewed files render as `NSTextAttachment` with an `NSTextAttachmentViewProvider` subclass:

- `ImageAttachmentViewProvider` (`InlineImageView.swift`)
- `PDFAttachmentViewProvider` (`InlinePDFView.swift`)
- `QuickLookAttachmentViewProvider` (`InlineQuickLookView.swift`)

List bullets and todo checkboxes are also attachments so the glyph can be sized independently of the body font:

- `BulletAttachmentViewProvider` / `CheckboxAttachmentViewProvider` (`ListRenderer.swift`)

### Transparent-placeholder pattern

Between TK2's first layout pass and a view provider's `loadView` completing, AppKit draws its generic document-icon glyph — visible as a brief flash on every attachment. Fix: initialize each attachment's `.image` with a transparent, correctly-sized placeholder `NSImage` so the glyph has a blank backing during the loadView window. Placeholders are memoized by size in an `NSCache`.

### View-provider state must be value-typed

A latent bug class: storing a pre-built live view on the attachment causes thumbnail loss when TK2 detaches the view from its window on scroll and re-attaches on scroll-back. The TK2 contract is that `loadView()` builds a fresh view per call. Store only value types (URL + size) on the `NSTextAttachment`; build the inline view inside `loadView()`. (Caught when QuickLook + PDF thumbnails disappeared after scroll-recycle; `ImageAttachmentViewProvider` already followed this pattern, both others didn't.)

### Inline-image live resize

`ImageAttachmentViewProvider.applyLiveResize(attachment:newSize:textLayoutManager:location:)` — pure static helper — mutates `NSTextAttachment.bounds` AND calls `NSTextLayoutManager.invalidateLayout(for: NSTextRange)` on the attachment's single-character range. Both steps are needed: `tracksTextAttachmentViewBounds` only reflows when the view's observable bounds change, but TK2 reads `attachment.bounds` (not the view frame) for line-fragment sizing. Without the explicit invalidation, surrounding text only reflows on commit (visible "text jump" at mouseUp).

## Fold System

Fold state lives in two places:

- **In-memory canonical**: `TextStorageProcessor.collapsedStorageOffsets: Set<Int>` — set of `block.range.location` values for blocks that are currently collapsed. Storage offset is more stable than block index across edits above the folded block (inserting a paragraph above a folded heading shifts indices but not offsets). Public query API: `processor.isCollapsed(blockIndex:)` / `isCollapsed(storageOffset:)` / `collapsedBlockIndices: Set<Int>` (computed) / `collapsedBlockOffsets: Set<Int>`. The Phase 6 Tier B′ ladder retired the per-block `MarkdownBlock.collapsed` field entirely (Sub-slice 7.A); the side-table is the sole source of truth and the discipline test `test_phase46_noMarkdownBlockCollapsed_reads` enforces zero `.collapsed` reads anywhere in production code.
- **Persistent**: `Note.cachedFoldState: Set<Int>?` — set of **storage offsets** (Phase 6 Tier B′ Sub-slice 3), persisted per-URL in `UserDefaults` under the V2 key `fsnotes.foldStateOffsets.<path>`. Storage-offset-keyed end to end — no conversion at the persistence boundary. The legacy V1 index-keyed format (`fsnotes.foldState.<path>`) is read once on first load into a transient `Note.legacyFoldStateIndices` field; the editor's restore path migrates it to offsets via the freshly-built `blockSpans` and writes the result back as V2, after which the V1 key is deleted.

A fold toggle sets `.foldedContent` on the folded range; `BlockModelContentStorageDelegate` checks for it first and returns `FoldedElement` → `FoldedLayoutFragment` (zero-height) regardless of underlying block kind. One element class + one fragment cover every foldable block type with zero per-kind code.

Folded headers paint a trailing `[...]` chip via `HeadingLayoutFragment.drawFoldedIndicator`, theme-driven through `ThemeChrome.foldedHeaderIndicator{Foreground,Background,CornerRadius,...}`.

## Render-Mode Side-Table

`TextStorageProcessor.renderedStorageOffsets: Set<Int>` is the canonical store for "is this code block currently rendered as a bitmap / fragment widget" — set of `block.range.location` values for blocks classified as `.rendered`. Mirrors the fold-state side-table's offset-keyed pattern (Sub-slice 4). Two state sources feed it:

- **WYSIWYG language-based classification** — `rebuildBlocksFromProjection` walks each `Document.Block` and inserts the offset for any code block whose language is `mermaid` / `math` / `latex`. Those blocks render via `MermaidLayoutFragment` / `MathLayoutFragment` / `DisplayMathLayoutFragment` (fragment dispatch); `codeBlockRanges` excludes them from the gray-background gate via the side-table check.
- **Source-mode async render swap** — `renderSpecialCodeBlocks`'s WebView callback replaces fenced-code text with a centred `NSTextAttachment` once `BlockRenderer` completes, then calls `setRendered(true, storageOffset:)` to record the transition. The click-to-edit handler in `EditTextView+Interaction` flips it back via `processor.setRenderMode(.source, forBlockAtOffset: index)` — operating purely on storage offsets so this site doesn't read `processor.blocks`.

Public query API: `isRendered(blockIndex:) / isRendered(storageOffset:) / renderedBlockOffsets`. Public mutators: `setRenderMode(_:forBlockAt:)` and `setRenderMode(_:forBlockAtOffset:)`. The Phase 6 Tier B′ ladder retired the per-block `MarkdownBlock.renderMode` field (Sub-slice 7.B.1); the discipline test `test_phase6Bprime_subslice7B1_noMarkdownBlockRenderMode_reads` enforces zero `.renderMode` reads in production. Source-mode parser methods (`MarkdownBlockParser.parsePreservingRendered / adjustBlocks / reparseBlocks`) accept the side-table as a `renderedOffsets: Set<Int>` parameter for their preserve / skip / splice-extension decisions.

Side-table consistency across `adjustBlocks`'s offset-shift uses a UUID snapshot pattern: `updateBlockModel` captures the IDs of currently-rendered blocks before the parse, then re-derives the side-table from those IDs after — picking up each block's possibly-shifted `range.location` while gracefully dropping rendered blocks the splice replaced.

## Source-Mode Pipeline (`hideSyntax == false`)

Source mode shares `Document` and the TK2 layer with WYSIWYG but renders via `SourceRenderer`:

1. `MarkdownParser.parse(markdown)` → `Document`.
2. `SourceRenderer.render(document, bodyFont:, codeFont:)` → `NSAttributedString` with **every marker the parser consumed re-injected** (`#` prefixes on headings, `**…**` around bolds, fence lines, list markers + checkboxes, table pipes + alignment rows, `<br>` in cells). Marker runs are tagged `.markerRange`; the renderer does NOT set a marker `.foregroundColor`.
3. Each paragraph is tagged `.blockModelKind = .sourceMarkdown`. The content-storage delegate returns `SourceMarkdownElement`; the layout-manager delegate returns `SourceLayoutFragment`.
4. `SourceLayoutFragment.draw` delegates to super for default text, then overpaints `.markerRange` runs in `Theme.shared.chrome.sourceMarker`.

Source-mode edits flow into `textStorage` directly (no `EditingOps`, no `DocumentEditApplier`). `TextStorageProcessor` runs minor post-edit work (attachment restore on save, fold attribute propagation) but has no highlight responsibility — the legacy `NotesTextProcessor.highlightMarkdown` path is retired.

## Theme — single source of truth

Every value that describes how the editor *looks* — font, size, line spacing, margins, paragraph spacing, block colors, border widths, heading hairlines, kbd fills, HR line color, blockquote bar, code-block chrome, inline link color, highlight color — lives on `BlockStyleTheme` (`FSNotesCore/Rendering/ThemeSchema.swift`). Renderers and fragments read `Theme.shared` at render time. The only places literal presentation values are allowed: theme JSON files and `ThemeSchema.swift`'s default-value constructors.

### Load order

1. **Bundled defaults** — `Resources/default-theme.json`, `Resources/Themes/Dark.json`, `Resources/Themes/High Contrast.json`.
2. **User overrides** — `~/Library/Application Support/FSNotes++/Themes/*.json`. Same basename as a bundled theme replaces the bundled entry.
3. **Selection** — `UserDefaultsManagement.currentThemeName`, applied in `AppDelegate.applicationDidFinishLaunching` before `applyAppearance()`.

If a named theme is missing or its JSON is corrupt, `Theme.load(named:)` falls back to the bundled default rather than propagating the error.

### Who owns what

| Layer | Reads from theme |
|---|---|
| `DocumentRenderer` | block-level fills, borders, margins, paragraph spacing, heading font sizes, list/blockquote/code-block chrome |
| `InlineRenderer` | link color, highlight background, inline code chrome, strike/underline/mark styles |
| Per-block fragments | the block's own section of the theme |
| `TableElement` / `TableLayoutFragment` | table handle color, resize preview, column separator |

Geometry that is inherently structural (HR arithmetic around line thickness, bezier offsets in code-block borders) stays as-is; only *values* flow through Theme.

### Write-through from Preferences

IBActions on `PreferencesEditorViewController` (font family, size, margin, line width, line spacing, image width, italic, bold) mutate `Theme.shared` and persist via `Theme.saveActiveTheme(...)`. When the user is on the read-only bundled `Default`, the override file is written under the same name so subsequent launches pick it up via user-override-wins.

Every save posts `Theme.didChangeNotification`. Each live `EditTextView` installs one observer (associated-object token, idempotent) and re-runs `fillViaBlockModel(note:)` on theme-change without flushing scroll.

### UserDefaults subsumption

The legacy `UserDefaultsManagement` typography accessors (`fontName`, `fontSize`, `codeFontName`, `codeFontSize`, `editorLineSpacing`, `lineHeightMultiple`, `lineWidth`, `marginSize`, `imagesWidth`, `italic`, `bold`) are computed-property proxies over `Theme.shared` — no independent storage. First-launch migration copies pre-7.5 legacy values into the active theme then deletes the backing UD keys.

### Whitelist: UI-only literals

One documented literal: `PreferencesEditorViewController.previewFontSize: CGFloat = 13` for the preference-sheet preview label. UI chrome for the pref UI itself, file-level exempt.

### Grep gate

`scripts/rule7-gate.sh` (pure shell, CI-ready) scans `FSNotes/` and `FSNotesCore/` for:

- Marker-hiding tricks (0.1pt font, `NSColor.clear` foreground, `.kern` attribute, widget-local `parseInlineMarkdown`)
- View→model bidirectional reads (`.stringValue` into `rows[]` / `headers[]` in table widgets)
- Literal presentation values in render-path files (hardcoded `NSFont.systemFont(ofSize:)`, hardcoded `paragraphSpacing`, hex color literals in `Fragments/`)
- `performEditingTransaction` callers outside `DocumentEditApplier.swift` (Phase 5a)

Files in the theme definition itself (`ThemeSchema.swift`, `Theme.swift`, `ThemeAccess.swift`) and the source-mode pipeline (`TextStorageProcessor.swift`, `NotesTextProcessor.swift`, `NSTextStorage++.swift`, `TextFormatter.swift`, `ImagesProcessor.swift`) are excluded at the file level. Any individual line can be exempted with `// rule7-gate:allow`.

Run: `./scripts/rule7-gate.sh` — exit 0 on pass, 1 on violations with `file:line: label: source`.

## Code-Block Edit Toggle

Obsidian-style `</>` hover button that swaps a code block between rendered (syntax-highlighted or mermaid/math bitmap) and editable raw-fenced-source form. Lives on `EditTextView.editingCodeBlocks: Set<BlockRef>` — per-editor-session content-hash-keyed set.

- **`BlockRef`** — content-hash reference keyed off `MarkdownSerializer.serializeBlock(block)`. Stable across structural edits that insert blocks above the ref'd block. Not persisted; session-local.
- **Renderer wire-through** — `DocumentRenderer.render(…, editingCodeBlocks:)` emits code blocks in the set as raw fenced source with no bitmap attachment.
- **Applier promotion** — `applyDocumentEdit(…, priorEditingBlocks:, newEditingBlocks:)` promotes `.unchanged` LCS entries to `.modified` when membership flipped, so the byte-differing renders surface as a single block-level diff.
- **Hover button** — `CodeBlockEditToggleOverlay` pools `CodeBlockEditToggleView` subviews and positions one `</>` button per visible code block. Click flips the ref's membership and calls `applyDocumentEdit` with `priorDoc == newDoc` but different editing-set.
- **Cursor-leaves auto-collapse** — `collapseEditingCodeBlocksOutsideSelection` drops any ref whose span no longer contains the current selection. Guarded by `oldSet == newSet` early-return against re-render observer cycles.
- **Fragment-class filter** — the overlay enumerates layout fragments and accepts `CodeBlockLayoutFragment`, `MermaidLayoutFragment`, `MathLayoutFragment`, and `DisplayMathLayoutFragment` — all four present underlying `Block.codeBlock` instances (mermaid is `language:"mermaid"`, fenced math is `language:"math"`/`"latex"`, plain code is no-language). The per-block `case .codeBlock` filter further down is the authoritative gate; paragraphs containing `Inline.displayMath` from `$$…$$` syntax are correctly rejected. The same fragment-class set is also applied in `GutterController` for the gutter copy-icon.

## CommonMark Compliance

Serializer compliance against CommonMark 0.31.2: **651 / 652 passing (99.8%)** — the practical ceiling for FSNotes++ given the wikilink-extension boundary case (#590 — `![[foo]]` resolves to a wikilink rather than literal text by product design).

Every bucket is at 100% except Images (21/22). The conformance corpus is in `Tests/CommonMark/`; per-section pass/fail reports dump to `~/unit-tests/commonmark-compliance.txt`. Every commit is gated against "must not regress."

Compliance was lifted from a 92.2% baseline by a series of small grammar edits and one renderer-side fix in the `LinkResolver` and `ListReader` paths. The arc is documented in `REFACTOR_PLAN.md` for archaeological purposes. Forward-looking: any new CommonMark spec failure should be reproducible as a per-bucket regression test in `Tests/CommonMark/` and gated against the bucket's current floor.

## Test Infrastructure

~1,800+ test functions across ~150 files in `Tests/`. Four complementary harnesses:

**Pure-function unit tests** — `BlockParserTests`, `EditingOperationsTests`, `BlockModelFormattingTests`, `MarkdownSerializer*Tests`, `ListEditingFSMTests`, `EditContractTests`, `DocumentEditApplierTests`. Call `EditingOps.*` / `MarkdownParser.parse` / `MarkdownSerializer.serialize` / `DocumentEditApplier.diffDocuments` directly on value-typed `Document`s. No AppKit setup.

**HTML Parity** (`EditorHTMLParityTests.swift`, ~85 tests). "Expected" (fresh parse of target markdown) and "live" (editor after simulated edits) `Document`s both render to HTML via `DocumentHTMLRenderer` and are asserted byte-equal. Also verifies `HTML(doc) == HTML(parse(serialize(doc)))` — the round-trip property. Canonical live-edit harness.

**EditorHarness** (`Tests/EditorHarness.swift`). Edit-script DSL: `.type(_:)`, `.pressReturn`, `.backspace`, `.select(_:)`, `.toggleBold`, `.setHeading(level:)`, `.toggleList`, `.toggleQuote`, `.insertHR`, `.toggleTodo`, `.beginComposition`, etc. After each input the harness reads `preEditProjection` + `lastEditContract` (set by `applyEditResultWithUndo`) and runs `Invariants.assertContract(before:after:contract:)` on the live projection.

**TK2 fragment dispatch** (`TextKit2FragmentDispatchTests.swift`, ~55 tests). Construct a minimal `NSTextContentStorage` + layout manager with the real delegates, feed rendered output, and assert the correct element / fragment class comes back per paragraph range.

**Rule-7 grep gate** — `scripts/rule7-gate.sh`. Pure shell, runs on demand and in CI.

```bash
xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes \
  -destination 'platform=macOS' -only-testing:FSNotesTests > /tmp/xctest.log 2>&1
./scripts/rule7-gate.sh
```

## Operational Patterns

Recurring failure modes that surfaced during the refactor and their fixes. The TK2-adoption gotchas (silent fallback to TK1, adoption-time fixity, `cacheDisplay` not capturing fragment draws, element-vs-fragment attribute ownership) live inline under **TK2 Adoption** above; the attachment patterns (transparent-placeholder, value-typed view-provider state, inline-image live resize) live under **Attachment Handling**. The patterns below cut across the system and are catalogued centrally.

### Attribute change without layout invalidation

**Symptom**: visual element doesn't repaint after a state change (folded chip, list bullets after unfold, caret after table-cell edit). User has to scroll to force a redraw.

**Cause**: setting `.foldedContent` / similar attribute on a range without firing layout invalidation. TK2's element-and-fragment dispatch only re-runs on the next layout pass.

**Recipe**: after mutating an attribute that affects element/fragment dispatch, call `textLayoutManager.invalidateLayout(for: NSTextRange(location:length:))` on the affected range. For attachment-driven views, this also forces `NSTextAttachmentViewProvider.loadView` re-execution. The unfold path in `TextStorageProcessor.toggleFold` is the reference (heading line + fold range are unioned and invalidated together so both the chip and the bullet/checkbox attachments below it reload).

### Coordinate-space mismatches

**Symptom**: visual element drawn at a small consistent offset from where it should be (caret above the cell instead of inside; chip offset rightward; selection border one column off).

**Cause**: producer returns coords in space A; consumer drew in space B; missing transform = `originOf(B in A)`.

**Recipe**: identify which space each side is in. The FSNotes++ stack is fragment-local → container (+ `fragment.origin`) → view (+ `textContainerOrigin`) → window (+ frame origins) → screen. Apply this checklist FIRST when caret/chip/click is offset — it's almost always a single missing transform, not a more elaborate bug.

### Stale projection drift after async storage swap

**Symptom**: edit lands at the wrong storage offset after an inline-math callback or image resize completes; subsequent edits corrupt unrelated content.

**Cause**: `applyDocumentEdit` assumes `DocumentRenderer.render(priorDoc)` matches what's currently in `NSTextContentStorage`. Async hydration paths (MathJax, image resize, attachment swap) mutate storage and patch `proj.rendered.attributed` + `proj.rendered.blockSpans` but leave `proj.document` stale. On the next edit, span-offset math places the splice at the wrong byte.

**Recipe**: pass `priorRenderedOverride: oldProjection.rendered` to `applyDocumentEdit` from any caller whose projection might be stale. The override forces span-offset math to use the post-swap rendered layout; `priorDoc` still drives the LCS block-diff (block-value equality is unaffected by rendered-form drift). See **Edit Application → Stale-projection guard** for the parameter shape and call sites.

### Lazy-continuation rule tension with editor round-trip

**Symptom**: a CommonMark spec example fails because the editor's `Document` round-trip would re-merge content that was structurally separate, OR a user-typed paragraph after a list bleeds into the list.

**Cause**: strict CommonMark §5.1 lazy continuation merges any non-block-starter, non-blank line into an open paragraph regardless of indent. That's wrong for editor-produced `[list, paragraph]` Documents which serialize without an explicit `.blankLine` separator and would re-merge at load time.

**Recipe**: use a *narrow* lazy-continuation rule that requires `lineIndent > last.indent.count`, and add multi-block-evidence look-ahead for the spec cases that need strict behavior — scan forward through consecutive lazy-continuation candidates and any blank gap; if the next non-blank line is indented to ≥ contentCol, the item has multi-block content and lazy merge is licensed. The well-formed spec cases (#254, #286–#291) fire the narrow rule; multi-block spec cases (#290) fire the look-ahead; editor round-trip (`- foo\nbar` with no deep follower) parses as `[list, paragraph]`. Pattern lives in `ListReader.read`.

## Supporting Infrastructure

`EditingOperations.swift` carries typed-safety layers used throughout the primitives:

- **Phantom-typed storage indices** — `StorageIndex<OldStorage>` vs. `StorageIndex<NewStorage>` prevents mixing pre-edit and post-edit offsets at compile time.
- **`EditorError` enum** — structured error context (invalid block index, read-only block, cross-block selection, etc.) instead of stringly-typed errors.
- **`TextBuffer` protocol** — abstraction over `NSTextStorage` so primitive-layer tests can run against an `InMemoryTextBuffer` without instantiating AppKit.
- **Per-block-kind editor dispatch** — see "Per-Block-Kind Editor Dispatch" above.

## AI Chat / MCP

FSNotes++ embeds an AI chat panel that the user can drive through three providers (Anthropic, OpenAI, Ollama). The Ollama path supports tool calling via an in-process MCP (Model Context Protocol) server, giving the LLM read/write access to notes, folders, and editor state. The full surface follows the same single-write-path discipline as the rest of the editor.

```
User → AIChatPanelView ──► AIChatStore ──► dispatch action
                              │
                              ▼
                    AIProvider (Ollama / Anthropic / OpenAI)
                              │  (Ollama only:)
                              ▼
                    OllamaProvider tool-call loop
                              │   maxToolRounds = 10
                              ▼
                    MCPServer.handleToolCalls
                              │
                  ┌───────────┼─────────────┐
                  ▼           ▼             ▼
            filesystem    AppBridge    Note metadata
            (read tools)  (writes)     (search / list)
                              │
                              ▼
                    AppBridgeImpl
              (refuses during IME composition)
                              │
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
         WYSIWYG path     source path     filesystem path
         EditingOps  →    note.content =  FileManager
         applyEditResult  + notify        + AppBridge.notify
         WithUndo
```

### AIChatStore (Redux-style state)

`FSNotes/Helpers/AIChatStore.swift` owns conversation state. `AIChatState` carries `messages`, `isStreaming`, `error`, `pendingToolCalls`, `pendingConfirmations`, `streamingResponse`. `AIChatAction` enumerates `sendMessage` / `receiveToken` / `completeResponse` / `toolCallRequested` / `toolCallCompleted` / `toolCallConfirmRequested` / `toolCallApproved` / `toolCallRejected` / `loadConversation` / `clearChat`. The `reduce(state:action:)` function is pure and tested directly. The store does NOT call providers — the view layer drives the provider and feeds results back via `dispatch(...)`. Threading: every public method asserts main-queue.

### MCPServer

`FSNotes/Helpers/MCP/MCPServer.swift` is the singleton tool registry. Tools conform to `MCPTool` (name, description, JSON-schema input, async `execute(input:) -> ToolOutput`). Schemas flow into the Ollama request body via `MCPServer.shared.toolSchemasForLLM()` — no hardcoded list.

Tools (15, growing):
- **Read tools** (filesystem-only): `ReadNoteTool`, `SearchNotesTool`, `ListFoldersTool`, `GetFolderNotesTool`, `ListNotesTool`, `GetProjectsTool`, `GetTagsTool`, `GetCurrentNoteTool`.
- **Write tools** (route through AppBridge for open notes): `EditNoteTool`, `CreateNoteTool`, `DeleteNoteTool`, `MoveNoteTool`, `AppendToNoteTool`, `ApplyFormattingTool`, `ExportPDFTool`.

Path safety: `NotePathResolver` validates `relativePath(of:under:)` against the storage root, so a malicious LLM passing `path: "../../../../etc/passwd"` resolves to nil. Encrypted notes (`.etp` extension or encrypted-bundle metadata) return `ToolOutput.error("Note is encrypted")`.

### AppBridge

`AppBridge` lets the (out-of-view-context) MCP layer query and mutate the live editor. `AppBridgeImpl` (main-thread-only):

- **Read** (always safe): `currentNotePath`, `hasUnsavedChanges(path:)`, `editorMode(for:)`, `cursorState(for:)`.
- **Write** (gated): `notifyFileChanged(path:)`, `requestWriteLock(path:)`, `appendMarkdown(toPath:markdown:)`, `applyStructuredEdit(toPath:request:)`, `applyFormatting(toPath:command:)`, `exportPDF(fromPath:to:)`.

Each write dispatches WYSIWYG through `editor.applyEditResultWithUndo(...)` → `applyDocumentEdit` (canonical single write path), source-mode through `note.content = ...` + `notifyFileChanged`. **Refuses with `BridgeEditOutcome.failed(reason:)` if `editor.compositionSession?.isActive == true`** — racing with `setMarkedText` corrupts the marked range. Callers (notably `OllamaProvider.dispatchToolCallsAndContinue` running on `Task.detached`) must marshal via `MainActor`.

### OllamaProvider tool-calling loop

`OllamaProvider.swift` adds tool calling on top of the Ollama `/api/chat` NDJSON stream:

1. Send `messages` + `tools: [...schemas...]` with `stream: true`.
2. Parse streamed NDJSON. `message.content` chunks dispatch `.receiveToken`. `message.tool_calls` arrays buffer.
3. On `done: true` with no tool_calls → `.completeResponse(.success(...))`.
4. With tool_calls — for each:
   - If name in `needsConfirm = ["delete_note", "move_note"]`, dispatch `.toolCallConfirmRequested(call)` and suspend on `withCheckedContinuation` until panel resolves Approve/Reject. Reject → synthetic `ToolOutput.error("user rejected")` skips the tool. Approve → continue.
   - Run via `MCPServer.shared.handleToolCalls([call])`.
   - Append `role: "tool"` message with the result.
5. Re-issue chat request and continue.
6. Cap at `maxToolRounds = 10`; cap-hit → `.completeResponse(.failure(.apiError("Tool-calling exceeded 10 rounds...")))`.

### AIPromptContext

`AIService.aiSystemPrompt(_ ctx: AIPromptContext, mcpServer: MCPServer = .shared)` shared by all three providers. `AIPromptContext` carries `noteTitle?`, `noteContent`, `noteFolder?`, `projectName?`, `allTags`, `editorMode`, `isTextBundle`. Tool descriptions are read at runtime from `mcpServer.registeredTools.sorted` — adding a tool updates the prompt automatically.

### Conversation persistence

Per-note JSON in `~/Library/Application Support/FSNotes++/AIChats/<sha256-of-note-url>.json`. `AIChatPersistence.save(noteId:messages:)` debounces by 500ms; `clearChat` deletes the file. Malformed/missing → nil, never blocks the user.

### Keyboard

Cmd+Shift+A toggles the panel via the View menu's "Hide/Show AI Chat" item (storyboard, action `toggleAIChat:` on `ViewController`).
