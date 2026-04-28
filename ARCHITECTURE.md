# FSNotes++ Architecture

## Overview

FSNotes++ is a WYSIWYG markdown editor for macOS (forked from FSNotes). Rendering happens in a single `NSTextView` on TextKit 2 — no HTML preview pane. The `Document` block model is the single source of truth; two render paths consume it:

- **WYSIWYG path** (`hideSyntax == true`, the default): `MarkdownParser` → `Document` → `DocumentRenderer` → `NSAttributedString` with markers consumed. The user sees bold/italic/headings as visual formatting.
- **Source path** (`hideSyntax == false`): same `Document` → `SourceRenderer` → `NSAttributedString` with markers preserved and tagged `.markerRange`. `SourceLayoutFragment` paints those runs in the theme's marker color on top of the default text draw.

Both paths feed a single TK2 `NSTextContentStorage` / `NSTextLayoutManager` pair. Element dispatch and layout-fragment dispatch are per-block-kind (see "TextKit 2 adoption" below). Edits in WYSIWYG route through `EditingOps`, mutate the `Document`, and apply to `NSTextContentStorage` via `DocumentEditApplier`. Source mode edits flow into storage directly (the widget is a plain editable text view with marker coloring).

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

**Key invariant (WYSIWYG)**: `textStorage.string` contains only displayed characters. Markdown markers (`#`, `**`, `-`, `>`, fences) exist only in the `Document` model and on disk. Edits mutate the `Document`; `DocumentEditApplier` emits a minimal element-bounded splice to patch the content storage.

**Key invariant (source mode)**: `textStorage.string` is the raw markdown byte-for-byte. `SourceRenderer` tags marker runs with `.markerRange`; `SourceLayoutFragment` overpaints them in the theme's marker color without mutating `.foregroundColor`.

### Document Model

Nine block types (`FSNotesCore/Rendering/Document.swift`):

- `paragraph(inline:)`
- `heading(level:suffix:)` — ATX or setext; level 1-6
- `codeBlock(language:content:fence:)` — fenced only (CommonMark indented code blocks are low priority)
- `list(items:loose:)` — `ListItem` carries `indent`, `marker`, `afterMarker`, optional `checkbox`, inline content, and `children` for nesting
- `blockquote(lines:)` — each `BlockquoteLine` stores its `>`-prefix verbatim
- `horizontalRule(character:length:)` — source character + run length preserved for byte-equal round-trip
- `htmlBlock(raw:)` — raw HTML source, verbatim
- `table(header:alignments:rows:columnWidths:)` — `TableCell` values (inline trees), per-column `TableAlignment`, and optional persisted drag-resize widths (T2-g.4). **`raw` was deleted in Phase 4.2** — tables now serialize canonically on every write via `MarkdownSerializer`, regardless of whether the table was edited. Legacy non-canonical source formatting is rewritten on the first save of a note that contains tables.
- `blankLine` — structural separator (renders to empty string — see "Blank Lines and Zero-Length Blocks")

Each content block contains `[Inline]` trees for rich text. Inline nodes: `.text`, `.bold`, `.italic`, `.strikethrough`, `.underline`, `.highlight`, `.code`, `.link`, `.image`, `.autolink`, `.wikilink(target:display:)`, `.rawHTML`, `.entity`, `.escapedChar`, `.lineBreak`, `.math`, `.displayMath`, `.kbd`, `.superscript`, `.subscript`.

**Parser / serializer round-trip contract**: `MarkdownSerializer.serialize(MarkdownParser.parse(x))` is byte-equal to `x` for supported constructs. The blocks that preserve exact source (blockquote prefix, HR character/length, list `indent`/`marker`/`afterMarker`, checkbox text, blockquote-line prefix) exist specifically so the serializer can replay the user's typing without rewriting unrelated whitespace. The two deliberate exceptions are tables (canonical since Phase 4.2) and the `columnWidths` sentinel (see "Table edit primitive" below).

Wikilinks parse from `[[target]]` or `[[target|display]]` and render as styled clickable text using the `wiki:<target>` URL scheme — the `[[ ]]` brackets never appear in rendered storage. The click handler in the view layer dispatches `wiki:` URLs to the note resolver.

### Blank Lines and Zero-Length Blocks

**Critical**: `Block.blankLine` renders to an empty string (`""`), producing a `blockSpan` with `length == 0`. This has important consequences:

1. **Range overlap checks fail**: The standard overlap test `span.location < rangeEnd && spanEnd > range.location` returns `false` for zero-length spans because `spanEnd == span.location`. `blockIndices(overlapping:)` works around this with a fallback to `blockContaining(storageIndex:)` for zero-length selections.

2. **Cursor position checks fail**: A check like `cursorLoc >= span.location && cursorLoc < span.location + span.length` can never be true for zero-length blocks (since `span.location + 0 == span.location`). Code operating on zero-length blocks must special-case `span.length == 0` and use `span.location` directly.

3. **Blank lines are structural, not visual**: In the rendered output, blank lines exist only as the `"\n"` separator between adjacent blocks. They carry no content of their own. The separator uses the same paragraph style as empty paragraphs (`paragraphSpacing = 12`) to ensure consistent line metrics and prevent visual jumps when typing begins.

4. **No fallback path between WYSIWYG and source**: When `documentProjection` is non-nil (WYSIWYG), ALL editing must route through `EditingOps`. Returning `false` from a block-model function does NOT fall through to a source-mode code path — it typically results in a no-op or broken state. The two rendering paths share the `Document`, but their edit mechanisms are independent.

5. **Return key creates blank lines**: When Return is pressed at the end of a paragraph, `splitParagraphOnNewline` produces `[paragraph(before), .blankLine]`. The cursor ends up on the blank line, which has zero rendered length. Toolbar operations targeting the cursor must handle this case explicitly.

### Save Path

Post-Phase 4.7, **every save routes through `Note.save(markdown: String)`**. There is no second save entry point and no `NoteSerializer` / `prepareForSave`; they were deleted.

- **WYSIWYG save**: `MarkdownSerializer.serialize(projection.document)` → `Note.save(markdown:)`. The `Document` is the sole source of truth at serialize time. The previous save-path walker that read live `InlineTableView` state and rewrote `Block.table.raw` has been deleted; it is the cautionary tale in `CLAUDE.md` for why views must never be read back into data.
- **Source-mode save**: `textStorage.string` is already byte-preserving markdown. `Note.save()` (no arg) restores rendered block placeholders and unloads attachments in-place, then writes the file. No round-trip through `MarkdownParser` / `MarkdownSerializer`, so a source-mode user's exact bytes are preserved.

`save(markdown:)` invalidates `Note.cachedDocument`, updates `modifiedLocalAt`, and clears `isBlocked` so the file-system watcher can resume detecting external changes.

## Architecture Principles

1. **Storage is rendered output (WYSIWYG)**: `textStorage.string` has no markers. Markdown lives in `Document` and on disk. In source mode `textStorage.string` IS the markdown — but marker coloring is a view-layer concern (`SourceLayoutFragment`), never a mutation of `.foregroundColor`.
2. **Each stage owns its attributes**: `DocumentRenderer` owns `.font`, `.paragraphStyle`, `.foregroundColor` on the WYSIWYG path; `SourceRenderer` owns them on the source path. Don't set these elsewhere. Theme is the single source of every presentation literal (see "Theme" below).
3. **Fix at the source stage**: Trace which stage sets a wrong attribute; fix there, never patch downstream. When saved output is wrong, trace which edit failed to update the projection and fix *there*, not in the save path.
4. **Editing mutates Document**: User keystrokes → `EditingOps` → mutated `Document` → `DocumentEditApplier.applyDocumentEdit` → element-bounded splice. This is the single write path for block-model WYSIWYG storage; mechanically enforced by `StorageWriteGuard` + a DEBUG assertion in `TextStorageProcessor.didProcessEditing` (see "Edit Application" below). `CLAUDE.md` Invariant A is authoritative.
5. **One general solution**: Solve recurring patterns once (e.g., typing attributes after Return for ALL transitions).
6. **Views render data; views never write to data**. The projection → renderer → element → fragment chain is one-way. Views capture user intent (clicks, keystrokes) and call pure `EditingOps` primitives that return a new `Document`; the applier re-renders just the affected element range.

## Per-Block-Kind Editor Dispatch (Phase 12.B)

Every `Block` kind has a dedicated `BlockEditor` conformer under `FSNotesCore/Rendering/BlockEditors/`:

| Block kind | Editor file |
|---|---|
| `.paragraph` | `BlockEditors/ParagraphBlockEditor.swift` |
| `.heading` | `BlockEditors/HeadingBlockEditor.swift` |
| `.codeBlock` | `BlockEditors/CodeBlockBlockEditor.swift` |
| `.htmlBlock` | `BlockEditors/HtmlBlockBlockEditor.swift` |
| `.blankLine`, `.horizontalRule`, `.table` (atomic / read-only kinds) | `BlockEditors/AtomicBlockEditors.swift` (one file, three editors) |
| `.list` | `BlockEditors/ListBlockEditor.swift` (wraps `EditingOps.{insertIntoList,deleteInList,replaceInList}`) |
| `.blockquote` | `BlockEditors/BlockquoteBlockEditor.swift` (wraps `EditingOps.{insertIntoBlockquote,deleteInBlockquote,replaceInBlockquote}`) |

The protocol (`FSNotesCore/Rendering/EditingOperations.swift:173`):
```
public protocol BlockEditor {
    static func insert(into block: Block, offsetInBlock: Int, string: String) throws -> Block
    static func delete(in block: Block, from: Int, to: Int) throws -> Block
    static func replace(in block: Block, from: Int, to: Int, with: String) throws -> Block
}
```

`EditingOps.{insertIntoBlock, deleteInBlock, replaceInBlock}` — formerly 23 block-kind switches with ~100-150 LoC bodies each — now collapse to one polymorphic call per kind. Each switch is exhaustive over the 9 block kinds: no `default: throw .notSupported` patterns. The compiler enforces that any new block kind must add an explicit branch.

The retired `EditableBlock` / `BlockAction` / `BlockActionResult` scaffold (172 LoC at `EditingOperations.swift` lines 173-244 prior to commit `ebfc764`) was deleted as part of Phase 12.B.1; the new `BlockEditor` protocol takes its place with a tighter shape that matches the existing primitive contracts (pure functions on `Block`, not `mutating` methods on a protocol existential).

## Parser Combinator Infrastructure (Phase 12.C)

`FSNotesCore/Rendering/Combinators/Parser.swift` provides the bespoke parser combinator library used by the bucket-by-bucket port of `MarkdownParser` (Phase 12.C.2 → 12.C.6). ~250 LoC. The infrastructure ships independently from any production parser changes.

API surface:
- Value type `Parser<A>` carrying `parse: (Substring) -> ParseResult<A>`.
- Result enum `ParseResult<A>` with `.success(value, remainder)` and `.failure(message, remainder)` plus `.isSuccess` / `.value` / `.remainder` accessors.
- Primitives: `pure`, `fail`, `satisfy`, `char`, `oneOf`, `noneOf`, `string`, `eof`.
- Combinators: `map`, `flatMap`, `<|>` (alternative), `seq2`, `seq3`, `then`, `thenSkip`, `between`, `many`, `many1`, `optional`, `sepBy`, `sepBy1`, `lookahead`, `notFollowedBy`.
- `parseAll` for full-input matching (returns failure on partial consumption).

Why bespoke and not a Pod: existing Swift combinator libraries (PointFree's swift-parsing, SwiftParsec) lean on existential / protocol-witness machinery that's heavy in Swift. ~250 LoC of bespoke value types + closures is faster to compile, easier to debug, and removes the dependency surface. The library is also tuned to CommonMark — backtracking is non-mutating by construction (a failed alternative leaves the input intact because no input was consumed), `many`'s zero-consumption infinite-loop guard is explicit, all primitives are non-throwing.

The bridge between `MarkdownParser`'s `[Character] + Int` cursor convention and the combinator API's `Substring` shape lives in each ported file as a `match(_ chars:from:)` (or `read(lines:from:…)` for block readers) static method.

### Inline tokenizer chain (Phases 12.C.2 + 12.C.3)

`MarkdownParser.tokenizeNonEmphasis` walks each character of paragraph text once, dispatching to a series of detectors. All 11 `tryMatch*` functions that previously lived in MarkdownParser have been moved out to dedicated files in `Combinators/`. Each detector exposes a `match(_ chars: [Character], from: Int) -> Match?` API; the bridge converts the slice to `Substring`, runs the combinator, and returns the consumed range.

| Slice | File | Replaces | Spec bucket |
|---|---|---|---|
| 12.C.2 | `HardLineBreakParser.swift` | `\\\n` + ≥2-space-newline `if`-branches | Hard line breaks 15/15 (100%) |
| 12.C.3.a | `CodeSpanParser.swift` | `tryMatchCodeSpan` | Code spans 22/22 (100%) |
| 12.C.3.b | `MathParser.swift` | `tryMatchInlineMath` + `tryMatchDisplayMath` | FSNotes++ extension |
| 12.C.3.c | `StrikethroughParser.swift` | `tryMatchStrikethrough` | GFM extension |
| 12.C.3.d | `WikilinkParser.swift` | `tryMatchWikilink` | FSNotes++ extension |
| 12.C.3.e | `EntityParser.swift` | `tryMatchEntity` + 50-entry HTML5 named-entity table | Entity refs 17/17 (100%) |
| 12.C.3.f | `AutolinkParser.swift` | `tryMatchAutolink` | Autolinks 19/19 (100%) |
| 12.C.3.g | `RawHTMLParser.swift` (5 sub-grammars) | `tryMatchRawHTML` | Raw HTML 20/20 (100%) |
| 12.C.3.h | `LinkParser.swift` (carries `LinkParser` + `ImageParser`) | `tryMatchLink` + `tryMatchImage` | Links 76/90, Images 21/22 (floor held) |

How "combinator" the port is varies with grammar shape. Hard-line-break, code-span, math, strikethrough, wikilink, autolink — all use real combinator chains (`seq2`, `<|>`, `between`, `many1`, `flatMap`). Entity is a lookahead dispatch into three sub-`Parser<String>`s. Raw HTML is the same shape but with five sub-grammars. Link / image are a deliberate exception: the bracket-match-with-code-span-skipping requires `codeSpanRanges` from the caller, which is more naturally expressed as an imperative `Int` walk than as a state-monad threading through `Parser<…>`. The structure is still per-block-kind file isolation, just not literal combinators inside that file. Each file ships its own per-bucket regression test under `Tests/<Kind>ParserTests.swift`.

### Inline emphasis (Phase 12.C.4)

`Combinators/EmphasisResolver.swift` carries the CommonMark §6.2 delimiter-stack algorithm. Three responsibilities live in this file:

- `InlineToken` enum and `DelimiterRun` final class — the data types that flow between Phase A (`MarkdownParser.tokenizeNonEmphasis`) and Phase B (resolve). Both are public so Phase A can construct them.
- `EmphasisResolver.flanking(delimChar:before:after:)` — left/right-flanking rules with `*` permissive vs `_` intra-word strict, and the v0.31.2 punctuation broadening that includes Sc/Sk/Sm/So categories so currency symbols (£, €) are treated as punctuation for flanking. Called from Phase A at delimiter-run construction time.
- `EmphasisResolver.resolve(tokens:refDefs:)` — the doubly-walked token rewrite. For each closer, scans backwards for a matching opener obeying Rule of 3 (skip if `(canOpen || canClose) && sum % 3 == 0 && opener.originalCount % 3 != 0 && closer.originalCount % 3 != 0`); collects content between them as the emphasis container's children; replaces the opener slot with the new `.bold` / `.italic`; rebuilds the delimiter-index list and continues.

Not a literal `Parser<…>` port — the algorithm is a stateful linked-list rewrite over tokens, not a backtracking parse over characters. A `Parser<…>` shape would obscure the spec text. The port's value is structural: 240 LoC of stateful logic now lives in a dedicated file with its own per-bucket regression tests (`Tests/EmphasisResolverTests.swift`, 15 tests). `MarkdownParser.parseInlines` is now a thin three-phase orchestrator: `tokenizeNonEmphasis` → `EmphasisResolver.resolve` → `resolveHTMLTagPairs`. CommonMark "Emphasis and strong emphasis" bucket: 132/132 (100%).

### Block readers (Phase 12.C.5)

`MarkdownParser.parse` walks the input line-by-line, dispatching to per-block-kind branches. Block readers are extracted from the monolithic `parse` into dedicated files in `Combinators/`, mirroring the inline-tokenizer port pattern. Each reader exposes:

- `detect(_ line: String) -> …?` — single-line detection helper, public so cross-cutting callers (list continuation, ref-def collection, lazy-continuation interrupt, blockquote inner-content scan) can call it directly without re-implementing the rules.
- `read(lines: [String], from: Int, …) -> ReadResult?` — multi-line read (when applicable) returning the parsed `Block` and the next line index.

| Slice | File | Replaces | Spec bucket |
|---|---|---|---|
| 12.C.5.a | `FencedCodeBlockReader.swift` | `detectFenceOpen` + `isFenceClose` + `Fence` struct + the fenced-code branch of `parse` | Fenced code blocks 29/29 (100%) |
| 12.C.5.b | `HorizontalRuleReader.swift` | `detectHorizontalRule` + the HR branch of `parse` | Thematic breaks 19/19 (100%) |
| 12.C.5.b | `ATXHeadingReader.swift` (carries ATX `detect`/`read` + `detectSetextUnderline`) | `detectHeading` + `detectSetextUnderline` + the ATX branch of `parse` | ATX headings 18/18 (100%), Setext headings 27/27 (100%) |
| 12.C.5.c | `HtmlBlockReader.swift` | `detectHTMLBlock` + `htmlBlockEndsOnLine` + `htmlBlockTags` + `extractHTMLTagName` + `isCompleteHTMLTag` + the HTML-block branch of `parse` (7 sub-types: pre/script/style/textarea, comment, processing instruction, declaration, CDATA, block-level tag, type-7 complete tag) | HTML blocks 43/44 (98%) |
| 12.C.5.d | `BlockquoteReader.swift` | `detectBlockquoteLine` + `blockquoteInnerAllowsLazyContinuation` + the blockquote branch of `parse`. The `read` method takes `parseInlines` and `interruptsLazyContinuation` as injected closures (both depend on parser state — refDef table, list-marker rules — the reader doesn't own). | Block quotes 24/25 (96%) |
| 12.C.5.e | `TableReader.swift` | `detectTable` + `TableDetection` struct + `isTableRow` + `isTableSeparator` + `parseAlignments` + `parseTableRow` + the GFM-pipe-table branch of `parse`. Covers both detection modes (a: header on current line, b: header buffered as paragraph). | GFM extension; not part of base CommonMark |
| 12.C.5.f | `ListReader.swift` (per-line classifier only — see below) | `parseListLine` + `listMarkerType` + `isOrderedListMarkerWithNonOneStart` + `ParsedListLine` struct (now `public`, lives on the reader). Cross-cutting callers in MarkdownParser qualified as `ListReader.X`. | List items 42/48 (88%), Lists 19/26 (73%) |

Setext heading promotion stays in `MarkdownParser.parse` because it depends on the paragraph buffer state (`rawBuffer`) — not a self-contained line read. Only the underline detector moved.

**ListReader scope deliberately conservative.** The per-line classifier surface ports cleanly. The ~320-line block-loop multi-line list collection code, `buildItemTree` (recursive item-tree builder that calls back into `MarkdownParser.parse` for item-content re-parsing), `deepestOwner`, `leadingSpaceCount`, and `stripLeadingSpaces` STAY in `MarkdownParser`. They weave through container-block continuation rules, blank-line semantics, and recursive parser entry; porting them cleanly is its own slice (potentially 12.C.5.g, optional follow-up — the gain is structure, not LoC).

Across the six reader slices, `MarkdownParser.swift` shrank from ~3,974 LoC to 1,994 LoC (−1,980 LoC, ~50%) while spec compliance held flat at 620/652 (95.1%). Phase 12.C.6 (residual spec compliance) is now in progress and benefits from the decomposition.

### Container-aware ref-def discovery (Phase 12.C.6.a)

CommonMark §4.7 allows link reference definitions to live inside any container block, including blockquotes. The pre-decomposition parser collected ref-defs by scanning raw lines, which missed `> [foo]: /url` (the `>` prefix prevented the ref-def regex from matching). Phase 12.C.6.a closes this without re-architecting the collector:

- `collectLinkRefDefs` builds a `strippedLines: [String]` view alongside the source — every line carrying a blockquote prefix has its prefix stripped to expose the inner content for ref-def matching.
- When the line at position `i` carries a `>` prefix AND `tryParseLinkRefDef(strippedLines, startIndex: i, ...)` succeeds AND every line consumed by the parse also carries a `>` prefix (a multi-line nested ref-def must stay inside the same container), the def is registered in `refDefs` and its source-line indices are accumulated into a new `blockquoteRefDefLines: Set<Int>` return value.
- The top-level block-parse loop unpacks the three-tuple `(refDefs, consumed, blockquoteRefDefLines)` and threads `blockquoteRefDefLines` to `BlockquoteReader.read(..., skipLines: …)`. The reader walks past those line indices without emitting `BlockquoteLine`s, preserving the (now empty) blockquote container while the ref-def is hoisted to document scope.
- `BlockquoteReader.read(...)` gains a `skipLines: Set<Int> = []` parameter (default-empty for back-compat with all other callers).

Closes spec example #218. Bucket: Link reference definitions 26/27 → 27/27 (100%). Overall CommonMark 620/652 → 621/652 (95.2%).

### Unicode case fold for ref label normalization (Phase 12.C.6.b)

CommonMark §4.7 specifies that link reference labels are normalized by Unicode case folding before matching. The previous implementation used Swift's `String.lowercased()`, which performs only single-codepoint case mapping. Multi-codepoint folds — most notably ẞ (U+1E9E, capital sharp S) folding to "ss" (two codepoints) — fall outside `lowercased()`'s capability and produce label mismatches when a definition uses one form and a reference uses the other.

`normalizeLabel(_:)` now uses `.folding(options: .caseInsensitive, locale: nil)` instead. Both definition-registration and reference-lookup pass through the same helper, so the change is symmetric.

Closes spec example #540. Bucket: Links 76/90 → 78/90 (87%) — the targeted fix plus one bonus example that fell out of the same change. Overall CommonMark 621/652 → 623/652 (95.6%).

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

Tables are a GFM extension (not core CommonMark). Cell content is an inline tree — `Block.table` holds `[TableCell]` values where each cell is a `[Inline]` tree, the same type backing `Block.paragraph`. Cell editing routes through the block-model pipeline the same way paragraph editing does. Since Phase 2e (T2-h) the render path is native TK2 `TableElement` + `TableLayoutFragment` — there is no `InlineTableView` NSTextAttachment widget anymore.

- **Element dispatch**: `DocumentRenderer` emits the table as a paragraph range carrying `.blockModelKind = .table` plus a `.tableAuthoritativeBlock` boxed reference to the `Block.table` value. `BlockModelContentStorageDelegate` reads the attribute and returns a `TableElement` (not a `BlockModelElement`) — the boxed authoritative block preserves alignments and structure that the flat cell text alone couldn't convey.
- **Display**: `TableLayoutFragment` draws the grid directly on TK2 — resize handles, column separators, alignment — without an NSView attachment. Cells are rendered via `InlineRenderer.render(cell.inline, baseAttributes:)` — the same code path paragraphs use. Zero markdown markers appear; formatting lives entirely in `.font`, `.underlineStyle`, `.strikethroughStyle`, `.backgroundColor`, and `.link` attributes.
- **Cell-content editing**: field-editor edits flow through `InlineRenderer.inlineTreeFromAttributedString(_:)` (the pure inverse of `render`) and route through `EditingOps.replaceTableCellInline(blockIndex:at:inline:in:)`. No raw-markdown round-trip.
- **Structural editing**: five primitives on `EditingOps` — `insertTableRow`, `insertTableColumn`, `deleteTableRow`, `deleteTableColumn`, `setTableColumnAlignment`, plus T2-g.4's `setTableColumnWidths` — all mutate `Document` and return a contract-carrying `EditResult`. Hover handles (T2-g.1/2) invoke these via `EditingOps`, not by widget-state mutation.
- **Column widths**: `setTableColumnWidths` persists drag-resize widths on `Block.table.columnWidths`. `MarkdownSerializer` emits an adjacent HTML comment sentinel `<!-- fsnotes-col-widths: [100.5, 200, 150.25] -->`; the parser reads the sentinel back into the `columnWidths` field.

| Action | Result |
|--------|--------|
| **Return** | Within a cell: insert newline (stored as `<br>`, rendered as `\n`). Outside a cell: unsupported. |
| **Backspace at start** | Remove table; merge surrounding blocks. |
| **Tab / Shift-Tab** | Cell navigation inside the table (handled by `TableLayoutFragment` focus logic). |
| **Inline format** | Edits the cell's field-editor attributed storage, converts to inline tree, flushes through `EditingOps.replaceTableCellInline`. |
| **Set heading level** | Unsupported. |
| **Toggle list** | Unsupported. |
| **Toggle blockquote** | Unsupported. |
| **Insert HR** | Insert HR after table. |
| **Toggle todo** | Unsupported. |
| **Structural (add/remove row/col, alignment, width)** | `EditingOps.{insert,delete}Table{Row,Column}` / `setTableColumnAlignment` / `setTableColumnWidths` — all contract-aware. |

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

Copy reads `EditTextView.copyAsMarkdownViaBlockModel()` which walks `blockIndices(overlapping: selection)` and either serializes each fully-covered block through `MarkdownSerializer.serialize(Document(blocks: [block]))` or (for partial paragraph overlaps) calls `splitInlines` to isolate the covered inline sub-tree and runs it through `serializeInlines`. The result is pushed to the pasteboard as markdown and — for cross-app fidelity into TextEdit / Pages / Mail — as `.rtf`.

Paste dispatches on pasteboard type in this order (first match wins, later branches fall through to `super.paste()`):

1. **Markdown pasteboard type present** — `insertMarkdownFragmentViaBlockModel(_:)` parses the pasteboard string as a full `Document` via `MarkdownParser.parse` (not a per-line split) and splices it via `EditingOps.replaceFragment(range: selectedRange, with: fragment, in:)` through `applyEditResultWithUndo → DocumentEditApplier.applyDocumentEdit`. Paragraph boundaries, headings, lists, code blocks, and inline formatting are all preserved. One undo step per paste regardless of selection state.
2. **`.png` or `.tiff` image pasteboard type present** — saves the bytes to the note's files directory (`<note>.textbundle/files/<uuid>.<ext>` for textbundle notes, legacy `<note>_files/<uuid>.<ext>` otherwise) and inserts `Inline.image(url: <relative-path>, alt: "")` via the same `replaceFragment` path. If an attributed string is also present, the image wins — the attributed string usually carries only an attachment run that IS the image.
3. **`NSAttributedString` pasteboard type present (no markdown, no image)** — `insertAttributedStringFragmentViaBlockModel(_:)` calls `EditTextView.documentFromAttributedString(_:)` to convert runs into a `Document`. The converter preserves bold / italic / strike / underline / link traits; drops font family/size, foreground/background color, paragraph style, kern, baseline offset; strips `NSTextAttachment` runs (their rich equivalent is handled by branch 2). Paragraph split on `\n\n` and `\u{2028}` (Unicode line separator — Pages / Safari emit this on Shift+Enter). Routes through `replaceFragment`.
4. **Fallback** — `super.paste(...)` / `insertText(_:)`.

All four branches route writes through `applyDocumentEdit` — no direct storage mutation, no `StorageWriteGuard.performingLegacyStorageWrite`. The `EditingOps.replaceFragment` primitive is the fused delete+insert added in Phase 5d Commit 4: an empty range degenerates to `insertFragment`, an empty fragment degenerates to `delete`, and both non-empty compose into a single `EditResult` with one `EditContract` (fixing the pre-C4 two-undo-steps bug that affected paste-over-selection on the markdown branch too).

## Inline Re-parsing (RC4)

Character-by-character typing can complete inline patterns (e.g., typing `*` completes `*bold*`). After inserting closing delimiters (`)`, `]`, `}`, `` ` ``, `>`, `*`, `_`, `~`), `reparseInlinesIfNeeded` serializes the block's inlines and re-parses them. If the parse tree differs, the block is replaced with the re-parsed version.

## TextKit 2 Adoption

The app is fully on TextKit 2 (`NSTextView` backed by `NSTextLayoutManager` + `NSTextContentStorage`). All per-block-kind visuals run through TK2's element / fragment dispatch. Phase 4.5 deleted `FSNotes/LayoutManager.swift`; the `AttributeDrawer` protocol and its five conformers (`BulletDrawer`, `HorizontalRuleDrawer`, `BlockquoteBorderDrawer`, `KbdBoxDrawer`, `ImageSelectionHandleDrawer`) in `FSNotes/Rendering/` survive as dormant helpers but have no live call site — they are candidates for deletion in a follow-up slice.

### Content-storage delegate

`BlockModelContentStorageDelegate` (`FSNotesCore/Rendering/BlockModelElements.swift`) implements `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)`. For each paragraph range it:

1. Checks for `.foldedContent` first — if present, returns `FoldedElement` (zero-height no-op fragment) regardless of underlying block kind.
2. Reads the `.blockModelKind` attribute tagged by `DocumentRenderer` / `SourceRenderer`.
3. For `.table`, unwraps the `.tableAuthoritativeBlock` boxed `Block.table` and constructs a `TableElement` directly; synthesizes a placeholder from the flat cell text on the edit-reconciliation race where the attribute is momentarily absent.
4. Otherwise dispatches through `BlockModelElementFactory` to the matching `NSTextParagraph` subclass: `ParagraphElement`, `ParagraphWithKbdElement`, `HeadingElement`, `ListItemElement`, `BlockquoteElement`, `CodeBlockElement`, `HorizontalRuleElement`, `MermaidElement`, `MathElement`, `DisplayMathElement`, `SourceMarkdownElement`.

Untagged ranges (mid-splice windows) fall back to TK2's default `NSTextParagraph`.

### Layout-manager delegate

`BlockModelLayoutManagerDelegate` (`FSNotesCore/Rendering/Fragments/BlockModelLayoutManagerDelegate.swift`) dispatches by element class (not by attribute) to:

- `FoldedLayoutFragment` (zero-height; wins over every other dispatch)
- `HorizontalRuleLayoutFragment` — 4pt gray bar
- `BlockquoteLayoutFragment` — depth-stacked left bars
- `HeadingLayoutFragment` — H1/H2 hairline below, reads `.headingLevel`
- `MermaidLayoutFragment` — diagram widget; reads `.renderedBlockSource`
- `MathLayoutFragment` — MathJax bitmap; reads `.renderedBlockSource`
- `DisplayMathLayoutFragment` — centered equation for inline `$$…$$` paragraph shape
- `TableLayoutFragment` — native TK2 table grid with resize handles
- `KbdBoxParagraphLayoutFragment` — rounded boxes behind `.kbdTag` runs
- `CodeBlockLayoutFragment` — gray rounded-rect background + 1pt border
- `SourceLayoutFragment` (Phase 4.4) — paints `.markerRange` runs in `theme.chrome.sourceMarker` over the default text draw

Plain paragraphs (`ParagraphElement`, `ListItemElement`) fall back to the default `NSTextLayoutFragment` — zero dispatch overhead for the common case.

## Edit Application (`DocumentEditApplier`)

`DocumentEditApplier.applyDocumentEdit(priorDoc:newDoc:contentStorage:…)` (`FSNotesCore/Rendering/DocumentEditApplier.swift`) is the single mutation entry point for the TK2 content storage. It takes the two `Document` values (before and after an `EditingOps` primitive) and emits a minimal element-bounded splice inside a single `performEditingTransaction`.

**Block identity is structural, not UUID-based.** The differ runs a Longest-Common-Subsequence pass keyed on `Block: Equatable` (O(M·N) on block count, comfortably under the perf budget for any realistic note). A post-LCS pass merges adjacent `(delete priorIdx, insert newIdx)` pairs of the same block kind at the same relative position into a single `.modified` change — this is the "typing into a paragraph" case, which should be reported as one element update, not delete+insert. Non-contiguous changes fall back to a single contiguous `[firstChange … lastChange]` replacement (the v1 default; finer-grained splits can land later if perf metrics demand).

**The applier's guarantee**: elements above the first changed block are untouched across every edit. This is what makes typing into a long note cheap — TK2's layout engine does not re-query paragraphs it didn't touch.

**Wire-in**: `EditTextView.applyEditResultWithUndo` (on TK2 — always today) calls `DocumentEditApplier.applyDocumentEdit` and attaches the `EditResult.contract` + the pre-edit projection to associated objects. `EditorHarness` reads those back after every scripted input and runs `Invariants.assertContract(before:after:contract:)` against the live post-edit projection — the same harness invariants run on the real editor that the contract unit tests enforce on pure calls.

**Single-write-path enforcement (Phase 5a).** `StorageWriteGuard` (`FSNotesCore/Rendering/StorageWriteGuard.swift`) exposes three scoped authorization flags — `applyDocumentEditInFlight`, `fillInFlight`, `legacyStorageWriteInFlight` — each set by a `performing*` wrapper for the duration of its body. `applyDocumentEdit` runs its `performEditingTransaction` inside `performingApplyDocumentEdit`; fill paths (`fillViaBlockModel`, `fillViaSourceRenderer`, `fill(note:)` clears, `lockEncryptedView`, `clear()`) run under `performingFill`; **18 production call sites across 6 logical categories** run under `performingLegacyStorageWrite` with TODOs: fold re-splice; async attachment hydration for inline math, display math, PDF (×2), QuickLook; 9 formatting-IBAction `insertText` sites in `EditTextView+Formatting.swift` (commit `e1e700d` + follow-ups, added to close the `_insertText:replacementRange:` bypass class that Phase 5a's assertion exposed via a user-reported crash); 1 input-path bypass in `EditTextView+Input.swift`. Audit live: `rg -c 'performingLegacyStorageWrite' FSNotes/ FSNotesCore/ -g '*.swift'`. Phase 5f retired the former "undo/redo state restore" category by removing `restoreBlockModelState`; a Phase 5f follow-up retired the former drag-and-drop category by re-routing the two `EditTextView+DragOperation.swift` drop handlers through `handleEditViaBlockModel`. A DEBUG assertion in `TextStorageProcessor.didProcessEditing` traps when `editedMask.contains(.editedCharacters) && blockModelActive && !sourceRendererActive && !StorageWriteGuard.isAnyAuthorized && !compositionSession.isActive` — it dumps `editedRange`, `editedMask`, and a 12-frame call stack for self-debugging. Release builds compile to no-ops. `scripts/rule7-gate.sh` has a `bypassStorageWrite` pattern flagging any `performEditingTransaction` outside `DocumentEditApplier.swift`. `CLAUDE.md` Invariant A is the authoritative rule text.

## IME Composition (`CompositionSession`)

`FSNotesCore/Rendering/CompositionSession.swift` (Phase 5e) is a value type attached to `EditTextView` via associated-object storage, capturing the state of a marked-text composition (Kotoeri, Pinyin, Korean 2-Set, Option-E dead-key accent, emoji picker). Fields: `anchorCursor: DocumentCursor` (pre-composition caret), `markedRange: NSRange` (current storage range of the marked run), `isActive: Bool`, plus a `pendingEdits` queue and a `preSessionFoldState` snapshot for fold save/restore across composition.

Lifecycle: `EditTextView.setMarkedText(_:selectedRange:replacementRange:)` enters the session; repeated calls update it; `unmarkText()` or `insertText(_:replacementRange:)` with the committed string commits — the final text is folded into `Document` via one `applyEditResultWithUndo` call, the same 5a-authorized path as any other edit. Escape / empty commit aborts the session and reverts to `anchorCursor` via an empty-string replace. Pinned by 25 tests in `Tests/Phase5eCompositionSessionTests.swift`.

**5a interaction**: `TextStorageProcessor.didProcessEditing` relaxes the single-write-path assertion for mutations strictly inside `markedRange` while `compositionSession.isActive == true` — this is the one sanctioned architectural exemption to Invariant A, gated by an assertion predicate (not by `performingLegacyStorageWrite`). Exactly one `compositionSession.isActive` check survives in `TextStorageProcessor.swift`, enforced as a grep invariant.

## Undo / Redo (`UndoJournal`)

`FSNotesCore/Rendering/UndoJournal.swift` (Phase 5f) is a reference-typed per-editor journal with `past: [UndoEntry]` and `future: [UndoEntry]` stacks. Each `UndoEntry` carries an `EditContract.InverseStrategy` — Tier A (cheap inverse `EditContract`), Tier B (`[Block]` snapshot of the affected block range), or Tier C (full `Document` snapshot, rare). `EditingOps` primitives populate the strategy at result-construction time; `applyEditResultWithUndo` records one `UndoEntry` per edit unless journaling is suspended.

State machine with 5 coalesce classes: `typing` (merge adjacent single-char inserts within 1s), `deletion` (same for backspace runs), `structural` (Return, Tab, toolbar — own group), `formatting` (inline trait toggles — own group), `composition` (IME commit — own group via Phase 5e suspension). A 1-second heartbeat timer finalizes the current group on idle (mockable via `advanceTime(by:)` for tests).

**Wire-in**: `applyEditResultWithUndo` calls `journal.record(entry, on: self)`. Inside that method lives the **one surviving** `NSUndoManager.registerUndo(withTarget:handler:)` site in the editor path — the handler pops the journal and replays the inverse via `DocumentEditApplier.applyDocumentEdit` with a `replayDepth += 1` guard so the replay doesn't re-journal. The pre-5f `restoreBlockModelState` closure path is retired. Grep invariant: `rg 'registerUndo|beginUndoGrouping|endUndoGrouping' FSNotes/ FSNotesCore/` returns the one `UndoJournal.record` hit plus two out-of-scope sites on `notesListUndoManager` (note-list delete/reorder). Pinned by 33 tests in `Tests/UndoJournalTests.swift`.

**5e interaction**: while `compositionSession.isActive == true`, `journal.record` is a no-op (the Phase 5e composition commit produces exactly one `composition`-class entry; an abort produces zero).

## Attachment Handling

Inline images, PDFs, and QuickLook-previewed files render as `NSTextAttachment` with a `NSTextAttachmentViewProvider` subclass attached per attachment:

- `ImageAttachmentViewProvider` (`FSNotes/Helpers/InlineImageView.swift`) — includes the Phase 2f.5 live-resize path: `mouseDragged` on the resize handle fires `onResizeLiveUpdate(NSSize)`, which the provider routes to the pure static `ImageAttachmentViewProvider.applyLiveResize(attachment:newSize:textLayoutManager:location:)`. That helper mutates `NSTextAttachment.bounds` and calls `NSTextLayoutManager.invalidateLayout(for: NSTextRange)` so surrounding text reflows during the drag, not only at `mouseUp`. Pinned by `Tests/Phase2f5ImageResizeInvalidationTests.swift` (5 tests: happy path + nil-attachment + nil-TLM + doc-end boundary + widget-wiring).
- `PDFAttachmentViewProvider` (`FSNotes/Helpers/InlinePDFView.swift`)
- `QuickLookAttachmentViewProvider` (`FSNotes/Helpers/InlineQuickLookView.swift`)

List bullets and todo checkboxes are also attachments so the glyph can be sized independently of the body font without affecting line height:

- `BulletAttachmentViewProvider` / `CheckboxAttachmentViewProvider` (`FSNotesCore/Rendering/ListRenderer.swift`)

### Transparent-placeholder pattern

Between TK2's first layout pass and a view provider's `loadView` completing, AppKit draws its generic document-icon glyph — visible as a brief flash on every attachment on initial render. The fix (commit `c033b46`) is to initialize each attachment's `.image` property with a **transparent, correctly-sized placeholder NSImage** so the glyph has a blank backing during the loadView window. Placeholders are memoized by size in an `NSCache` (see `ListRenderer.transparentPlaceholder`) so a bullet-heavy document reuses the same NSImage instance per distinct cell size instead of allocating fresh.

## Fold System

Fold state persists per-note via `Note.cachedFoldState: Set<Int>?` (block storage offsets in the post-render text). A fold toggle sets the `.foldedContent` attribute on the folded range; `BlockModelContentStorageDelegate` checks for the attribute first and returns `FoldedElement` → `FoldedLayoutFragment` (zero-height) regardless of the underlying block kind. One element class + one fragment cover every foldable block type with zero per-kind code.

Post-Phase 4.6, there is no `syncBlocksFromProjection` bridge — fold state reads directly off the `Document` projection. The source-mode `blocks` mirror array has been deleted.

## Source-Mode Pipeline (`hideSyntax == false`)

Source mode shares the `Document` model and the TK2 layer with WYSIWYG but renders via `SourceRenderer` instead of `DocumentRenderer`:

1. `MarkdownParser.parse(markdown)` → `Document`.
2. `SourceRenderer.render(document, bodyFont:, codeFont:)` → `NSAttributedString` with **every marker the parser consumed re-injected** (`#` prefixes on headings, `**…**` around bolds, `` `…` `` around code spans, `>` blockquote prefixes, fence lines, `---` HR lines, list markers + checkboxes, table pipes + alignment rows, `<br>` in cells). Marker runs are tagged with `.markerRange`; the renderer does NOT set a marker `.foregroundColor`.
3. Each paragraph is tagged `.blockModelKind = .sourceMarkdown`. `BlockModelContentStorageDelegate` returns `SourceMarkdownElement`; `BlockModelLayoutManagerDelegate` returns `SourceLayoutFragment`.
4. `SourceLayoutFragment.draw` delegates to super for the default text draw, then overpaints each `.markerRange` run in `Theme.shared.chrome.sourceMarker`.

Source-mode edits flow into `textStorage` directly (no `EditingOps`, no `DocumentEditApplier` — the widget is a plain editable text view with marker coloring). `TextStorageProcessor` runs minor post-edit work (attachment restore on save, fold attribute propagation) but has no highlight responsibility; the `NotesTextProcessor.highlightMarkdown` / `phase5_paragraphStyles` stages are no longer part of the source-mode path post-Phase 4.4.

## Theme — single source of truth for presentation

Every value that describes how the editor *looks* — font family, font size, line
spacing, margins, paragraph spacing, block colors, border widths, heading
hairlines, kbd fills, HR line color, blockquote bar, code-block chrome, inline
link color, highlight color — lives on `BlockStyleTheme` (see
`FSNotesCore/Rendering/ThemeSchema.swift`). The active theme is `Theme.shared`;
all renderers and fragments read their values from it at render time. There is
exactly one place literal presentation values are allowed: theme JSON files and
`ThemeSchema.swift`'s default-value constructors. Everything else is a read.

### Load order

1. **Bundled defaults** ship inside the app bundle: the `Default` theme is
   `Resources/default-theme.json`; siblings `Dark` and `High Contrast` live
   under `Resources/Themes/*.json`. (The two paths are discovered separately
   by `ThemeDiscovery` but merged in `Theme.availableThemes`.)
2. **User overrides** live at
   `~/Library/Application Support/FSNotes++/Themes/*.json`. A user theme with
   the same basename as a bundled theme replaces the bundled entry in
   `Theme.availableThemes(...)` — user-override-wins.
3. **Selection** persists via `UserDefaultsManagement.currentThemeName` and is
   applied in `AppDelegate.applicationDidFinishLaunching` before
   `applyAppearance()`.

If a named theme is missing or its JSON is corrupt, `Theme.load(named:)` falls
back to the bundled default rather than propagating the error to the UI.

### Who owns what

| Layer | Reads from theme |
|---|---|
| `DocumentRenderer` | block-level fills, borders, margins, paragraph spacing, heading font sizes, list/blockquote/code-block chrome |
| `InlineRenderer` | link color, highlight background, inline code color, strike / underline / mark styles |
| Per-block fragments (`HeadingLayoutFragment`, `BlockquoteLayoutFragment`, `HorizontalRuleLayoutFragment`, `KbdBoxParagraphLayoutFragment`, `CodeBlockLayoutFragment`) | the block's own section of the theme |
| `TableElement` / `TableLayoutFragment` | table handle color, resize preview color, column separator color |

Geometry that is inherently structural (e.g. an HR's arithmetic around line
thickness, bezier curve offsets in a code-block border path) stays as-is; only
the *values* flow through Theme.

### Write-through from Preferences

IBActions on `PreferencesEditorViewController` (font family, font size, margin,
line width, line spacing, images width, italic, bold) mutate `Theme.shared` in
place and persist via `Theme.saveActiveTheme(...)`, which writes the active
theme to `~/Library/Application Support/FSNotes++/Themes/<name>.json`. When the
user is on the read-only bundled `Default`, the override file is written under
the same name so subsequent launches pick it up via user-override-wins.

Every save posts `Theme.didChangeNotification`. Each live `EditTextView`
installs one observer per view (associated-object token, idempotent) via
`EditTextView+ThemeObserver.swift` and re-runs `fillViaBlockModel(note:)` on
theme-change without flushing scroll.

### UserDefaults subsumption

The legacy `UserDefaultsManagement` typography/layout accessors
(`noteFont`, `fontName`, `fontSize`, `codeFont`, `codeFontName`, `codeFontSize`,
`editorLineSpacing`, `lineHeightMultiple`, `lineWidth`, `marginSize`,
`imagesWidth`, `italic`, `bold`) are **computed-property proxies** over
`Theme.shared` — no independent storage. The first-launch migration copies any
pre-7.5 legacy UD values into the active theme, then deletes the backing UD
keys. To change any of these values programmatically, mutate `Theme.shared` and
call `Theme.saveActiveTheme(...)`; do not write UD keys.

### Whitelist: UI-only literals

One documented literal survives in presentation code:
`PreferencesEditorViewController.previewFontSize: CGFloat = 13` is used to
render the font-preview label in the Preferences sheet. This is UI chrome for
the preference UI itself, not for note rendering, and is explicitly exempt from
the gate (file-level exclusion). Any new literal in render-path code is a
violation.

### Grep gate

`scripts/rule7-gate.sh` scans `FSNotes/` and `FSNotesCore/` for the banned
patterns that enforce this invariant:

- Marker-hiding tricks (0.1pt font, `NSColor.clear` foreground, `.kern`
  attribute, widget-local `parseInlineMarkdown`) — CLAUDE.md Rule 7 proper.
- View→model bidirectional data flow inside `InlineTableView.swift` and
  `TableRenderController.swift` (reads of `.stringValue` into `rows[]` /
  `headers[]`).
- Literal presentation values in `FSNotesCore/Rendering/*` — hardcoded
  `NSFont.systemFont(ofSize: <number>)`, hardcoded `paragraphSpacing = <number>`,
  hex color literals in `Fragments/` or `Elements/`.

Files that belong to the theme definition itself (`ThemeSchema.swift`,
`ThemeAccess.swift`, `Theme.swift`) and the still-retired source-mode pipeline
(`TextStorageProcessor.swift`, `NotesTextProcessor.swift`, `NSTextStorage++.swift`,
`TextFormatter.swift`, `ImagesProcessor.swift` — see Phase 4 of
`REFACTOR_PLAN.md` for retirement) are excluded at the file level. Any
individual line can be exempted with a `// rule7-gate:allow` comment on the
preceding line; use sparingly and always with a rationale.

Run locally: `./scripts/rule7-gate.sh` — exit 0 on pass, 1 on violations with a
`file:line: label: source` report per hit. The script is pure shell (no
xcodebuild, no state), so it is CI-ready; wiring it into a pre-build phase or a
GitHub Actions step is a separate slice (deferred to avoid an
`FSNotes.xcodeproj/project.pbxproj` race with concurrent refactor work).

## Code-Block Edit Toggle

Obsidian-style `</>` hover button that swaps a code block between its rendered form (syntax-highlighted or mermaid/math bitmap) and an editable raw-fenced-source form. Lives on `EditTextView.editingCodeBlocks: Set<BlockRef>` — a per-editor-session content-hash-keyed set.

- **`BlockRef`** (`FSNotesCore/Rendering/BlockRef.swift`): content-hash reference keyed off `MarkdownSerializer.serializeBlock(block)`. Stable across structural edits that insert blocks above the ref'd block — content-hash doesn't shift on index changes. Not persisted; membership is session-local.
- **Renderer wire-through** (Slice 1): `DocumentRenderer.render(…, editingCodeBlocks:)` emits code blocks in the set as raw fenced source in the plain code font with no bitmap attachment. Blocks not in the set render in today's default form. Pure function of the input set — no separate toggle-write path.
- **Applier promotion** (Slice 1): `DocumentEditApplier.applyDocumentEdit(…, priorEditingBlocks:, newEditingBlocks:)` promotes `.unchanged` LCS entries to `.modified` when the block's editing-set membership flipped between prior and new calls, so the byte-differing renders are reflected in a single block-level diff.
- **Hover button** (Slice 3, `b693a42`): `CodeBlockEditToggleOverlay` (`FSNotes/Helpers/CodeBlockEditToggleOverlay.swift`) pools `CodeBlockEditToggleView` subviews and positions one `</>` button per visible code block at the first fragment's top-right. Click flips the ref's membership in `editingCodeBlocks` and calls `applyDocumentEdit` with `priorDoc == newDoc` but different editing-set — the Slice-1 `promoteToggledBlocksToModified` pass reifies this into a single `.modified` block-level diff.
- **Cursor-leaves auto-collapse** (Slice 4, `9ba0d44`): `EditTextView.collapseEditingCodeBlocksOutsideSelection` drops any ref whose span no longer contains the current selection. Guarded against the infinite "observer fires on re-render, re-renders, fires on re-render" cycle by an `oldSet == newSet` early-return.

## CommonMark Compliance

Serializer compliance against CommonMark 0.31.2 spec: **620 / 652 passing (95.1%)** as of Phase 10 Slice A (shipped 2026-04-24, commits `f9aa284 → 3018ff0`, +19 examples). The refactor's 90% target is met. Live breakdown per spec section is in `CLAUDE.md`; remaining 32 failures cluster in Links (14 — delimiter-stack rewrite territory, Phase 12 candidate), List items + Lists (13 — multi-block list-item content where the continuation is fenced code / blockquote / HTML block, requires `ListItem.children: [ListItem]` → `[Block]` redesign with ~107 call-site updates, Phase 11 Slice B candidate), plus 5 long-tail edge cases (HR-vs-list precedence, lazy continuation in blockquote, image-vs-wikilink ambiguity, etc.).

The full conformance corpus is in `Tests/CommonMark/`; per-section pass/fail reports dump to `~/unit-tests/commonmark-compliance.txt`. Every phase is gated against "must not regress from current baseline."

## Test Infrastructure

~1,800+ test functions across ~150 files in `Tests/`. Four complementary harnesses:

**Pure-function unit tests** — `BlockParserTests`, `EditingOperationsTests`, `BlockModelFormattingTests`, `MarkdownSerializer*Tests`, `ListEditingFSMTests`, `EditContractTests`, `DocumentEditApplierTests`, etc. — call `EditingOps.*` / `MarkdownParser.parse` / `MarkdownSerializer.serialize` / `DocumentEditApplier.diffDocuments` directly on value-typed `Document`s. No AppKit setup.

**HTML Parity** (`EditorHTMLParityTests.swift`, 85 tests): "expected" (fresh parse of target markdown) and "live" (editor after a sequence of simulated edits) `Document`s both render to HTML via `DocumentHTMLRenderer` and are asserted byte-equal. Also verifies `HTML(doc) == HTML(parse(serialize(doc)))` — the serializer round-trip property. The canonical live-edit harness.

**EditorHarness** (`Tests/EditorHarness.swift`): edit-script DSL — `.type("text")`, `.pressReturn`, `.backspace`, `.select(range)`, `.toggleBold`, `.setHeading(level:)`, `.toggleList`, `.toggleQuote`, `.insertHR`, `.toggleTodo`. After each scripted input the harness reads `EditTextView.preEditProjection` + `.lastEditContract` (set by `applyEditResultWithUndo`) and runs `Invariants.assertContract(before:after:contract:)` on the live projection — the same invariant contract-unit-tests enforce on pure calls. `HarnessContractCoverageTests.swift` covers mermaid typing/backspace, math typing, and `replaceTableCellInline` end-to-end.

**TK2 fragment dispatch** (`TextKit2FragmentDispatchTests.swift`, 55 tests; `TextKit2ElementDispatchTests.swift`, 10 tests): construct a minimal `NSTextContentStorage` + layout manager with the real `BlockModelContentStorageDelegate` / `BlockModelLayoutManagerDelegate`, feed it rendered output, and assert the correct element / fragment class comes back per paragraph range.

**Rule-7 grep gate**: `scripts/rule7-gate.sh` (pure shell, zero xcodebuild) runs on demand and in CI. Exit 1 on any banned-pattern hit (marker-hiding tricks, view→model bidirectional flow, literal presentation values in render-path files). See the Theme section's "Grep gate" above.

```bash
xcodebuild test -workspace FSNotes.xcworkspace -scheme FSNotes \
  -destination 'platform=macOS' -only-testing:FSNotesTests > /tmp/xctest.log 2>&1
./scripts/rule7-gate.sh
```

## Supporting Infrastructure

`EditingOperations.swift` carries several typed-safety layers used throughout the editing primitives:

- **Phantom-typed storage indices** — `StorageIndex<OldStorage>` vs. `StorageIndex<NewStorage>` prevents mixing pre-edit and post-edit offsets at compile time.
- **`EditorError` enum** — structured error context (invalid block index, read-only block, cross-block selection, etc.) instead of stringly-typed errors.
- **`TextBuffer` protocol** — abstraction over `NSTextStorage` so primitive-layer tests can run against an `InMemoryTextBuffer` without instantiating AppKit.
- **Per-block-kind editor dispatch** — see "Per-Block-Kind Editor Dispatch (Phase 12.B)" above. Each `Block` enum case has a dedicated `BlockEditor` conformer in `FSNotesCore/Rendering/BlockEditors/`; the public `EditingOps.insert/replace/delete` switches are exhaustive (no `default: throw .notSupported` patterns). Replaced the unused `EditableBlock` / `BlockAction` / `BlockCapabilities` scaffold that was retired in Phase 12.B.1.

The Redux-style `EditorStore` / `EditorAction` / `EditorReducer` / `EditorEffect` types that briefly lived in `EditingOperations.swift` were deleted in Phase 6 Tier C (commit `f72ee0d`) — the scaffold predated Phase 5a's `StorageWriteGuard` + Phase 5f's `UndoJournal` and never had a production caller. The actual editor-side unidirectional flow is `EditingOps` (pure primitives) → `applyEditResultWithUndo` → `DocumentEditApplier.applyDocumentEdit` (single write path, `StorageWriteGuard`-gated) → `UndoJournal` (per-editor coalescing FSM, single `registerUndo` site).

## AI Chat / MCP

FSNotes++ embeds an AI chat panel that the user can drive through three providers (Anthropic, OpenAI, Ollama). The Ollama path supports tool calling via an in-process MCP (Model Context Protocol) server, giving the LLM read/write access to notes, folders, and editor state. The full surface (Phases 1–4 plus the AppBridge wire-up) follows the same single-write-path discipline as the rest of the editor.

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

`FSNotes/Helpers/AIChatStore.swift` owns the chat conversation state. `AIChatState` carries `messages`, `isStreaming`, `error`, `pendingToolCalls`, `pendingConfirmations`, and `streamingResponse`. `AIChatAction` enumerates `sendMessage` / `receiveToken` / `completeResponse` / `toolCallRequested` / `toolCallCompleted` / `toolCallConfirmRequested` / `toolCallApproved` / `toolCallRejected` / `loadConversation` / `clearChat`. The `reduce(state:action:)` function is pure and tested directly (`AIChatStoreTests`, `AIChatStoreConfirmationTests`). The store does NOT call providers — the view layer drives the provider and feeds results back via `dispatch(...)`. Threading: every public method asserts main-queue.

### MCPServer

`FSNotes/Helpers/MCP/MCPServer.swift` is the singleton tool registry. Tools conform to `MCPTool` (name, description, JSON-schema input, async `execute(input:) -> ToolOutput`). `handleToolCalls(_:)` dispatches a batch of tool calls and returns `[ToolResult]` in order. Schemas flow into the Ollama request body via `MCPServer.shared.toolSchemasForLLM()` so the LLM has up-to-date tool descriptions on every turn — no hardcoded list.

Tools (15 today, growing):
- **Read tools** (filesystem-only, no AppBridge dep): `ReadNoteTool`, `SearchNotesTool`, `ListFoldersTool`, `GetFolderNotesTool`, `ListNotesTool`, `GetProjectsTool`, `GetTagsTool`, `GetCurrentNoteTool`.
- **Write tools** (route through AppBridge for open notes): `EditNoteTool`, `CreateNoteTool`, `DeleteNoteTool`, `MoveNoteTool`, `AppendToNoteTool`, `ApplyFormattingTool`, `ExportPDFTool`.

Path safety: `NotePathResolver` standardizes URLs and validates `relativePath(of:under:)` against the storage root, so a malicious LLM passing `path: "../../../../etc/passwd"` resolves to nil. Encrypted notes (`.etp` extension or encrypted-bundle metadata) return `ToolOutput.error("Note is encrypted")` from every tool.

### AppBridge

`FSNotes/Helpers/MCP/AppBridge.swift` defines the protocol that lets the (out-of-view-context) MCP layer query and mutate the live editor. Implemented by `AppBridgeImpl` in `FSNotes/Helpers/MCP/AppBridgeImpl.swift`. Methods split into:

- **Read** (always safe): `currentNotePath`, `hasUnsavedChanges(path:)`, `editorMode(for:)` (`.wysiwyg` / `.source` / `.none`), `cursorState(for:)`.
- **Write** (gated): `notifyFileChanged(path:)`, `requestWriteLock(path:)`, `appendMarkdown(toPath:markdown:)`, `applyStructuredEdit(toPath:request:)`, `applyFormatting(toPath:command:)`, `exportPDF(fromPath:to:)`.

Each write method dispatches WYSIWYG mutations through `editor.applyEditResultWithUndo(...)` → `DocumentEditApplier.applyDocumentEdit` (the canonical single write path), and source-mode mutations through `note.content = ...` + `notifyFileChanged`. **Refuses with `BridgeEditOutcome.failed(reason:)` if `editor.compositionSession?.isActive == true`** — the IME composition window is the one sanctioned exemption to Invariant A and racing with `setMarkedText` corrupts the marked range. `AppBridgeImpl` is documented as main-thread-only; callers (notably `OllamaProvider.dispatchToolCallsAndContinue` running on a `Task.detached` queue) must marshal via `MainActor`.

### OllamaProvider tool-calling loop

`FSNotes/Helpers/Ollama/OllamaProvider.swift` adds tool calling on top of the Ollama `/api/chat` NDJSON stream. Each round:

1. Send `messages` + `tools: [...schemas...]` to `/api/chat` with `stream: true`.
2. Parse the streamed NDJSON. `message.content` chunks dispatch `.receiveToken`. `message.tool_calls` arrays buffer.
3. On `done: true` with no tool_calls → dispatch `.completeResponse(.success(...))`.
4. With tool_calls → for each call:
   a. If the tool name is in `needsConfirm = ["delete_note", "move_note"]`, dispatch `.toolCallConfirmRequested(call)` and suspend on `withCheckedContinuation` until the chat panel resolves it via Approve/Reject. Reject → synthetic `ToolOutput.error("user rejected")` skips the tool. Approve → continue.
   b. Run the call through `MCPServer.shared.handleToolCalls([call])`.
   c. Append a `role: "tool"` message with the result.
5. Re-issue the chat request and continue.
6. Cap iteration at `maxToolRounds = 10`; on cap-hit, dispatch `.completeResponse(.failure(.apiError("Tool-calling exceeded 10 rounds...")))`.

### AIPromptContext (system prompt enrichment)

`FSNotes/Helpers/AIService.swift` exposes `aiSystemPrompt(_ ctx: AIPromptContext, mcpServer: MCPServer = .shared)` shared by all three providers. `AIPromptContext` carries `noteTitle?`, `noteContent`, `noteFolder?`, `projectName?`, `allTags`, `editorMode`, `isTextBundle`. The chat panel resolves the context per-message in `AIChatPanelView.makePromptContext()` from `note.project` / `Storage.shared().tags` / `NotesTextProcessor.hideSyntax`. Tool descriptions are read at runtime from `mcpServer.registeredTools.sorted` — adding a tool updates the prompt automatically.

### Conversation persistence

Per-note JSON in `~/Library/Application Support/FSNotes++/AIChats/<sha256-of-note-url>.json` (mirrors `Themes/`). `AIChatPersistence.save(noteId:messages:)` debounces by 500ms; `clearChat` deletes the on-disk file. Malformed/missing → `nil`, never blocks the user. Implemented in `FSNotes/Helpers/AIChatPersistence.swift` (173 LoC, 12 tests).

### Keyboard

Cmd+Shift+A toggles the panel via the View menu's "Hide/Show AI Chat" item (storyboard, action `toggleAIChat:` on `ViewController`).

### Test coverage

- `AIChatStoreTests` (16) + `AIChatStoreConfirmationTests` (11) — reducer + subscribe/dispatch + confirmation flow
- `AIPromptContextTests` — full-context prompt rendering + provider parity
- `AIChatPersistenceTests` (12) — per-note JSON round-trip + debounce + clearChat-deletes
- `Phase1OllamaClientTests` (12) + `Phase1OllamaProviderTests` (10) — model listing + reachability + request body shape
- `Phase2OllamaToolCallingTests` (11) — tool_calls parsing + dispatch loop + iteration cap
- `MCPServerTests` (9) + per-tool tests (one suite per of the 15 tools, ~75 tests total)
- `AppBridgeImplTests` (34) — including 8 IME-composition-refusal tests
- `AIToolCallE2ETests` (5) — end-to-end Ollama → MCP → AppBridge → editor → save through `URLProtocol` mocks
- `AIChatPanelToolBubblesTests` (10) — tool-call bubble rendering + status update + confirmation bubble
- `AIChatKeyboardShortcutTests` (3) — menu-item key equivalent + action target
