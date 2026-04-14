# DEBUG.md — Root Cause Analysis for FSNotes++ Bugs 3

**Source**: Note "FSNotes++ Bugs 3" (2026-04-13 13:30 CET)
**Scope**: ~40 open bugs across headers, lists, tables, links, formatting, fold, attachments

---

## Summary

8 root causes account for all ~40 open bugs. They are ordered by impact (bugs resolved). Fixing all 8 would resolve or substantially improve every open bug. Several interact — the fix-order section at the bottom maps dependencies.

**RC8 is cross-cutting**: insufficient HTML-parity test coverage for FSM transitions means bugs in the *execution* of correct FSM decisions go undetected. The FSM pure functions are correct, but the code that applies their decisions to the Document has gaps — and there are no tests that would catch them.

---

## RC1: Missing `typingAttributes` sync after block-level operations

**Impact: ~5 bugs** | **Priority: HIGH** | **Difficulty: Easy**

### Description
After `applyEditResultWithUndo()` places the cursor (line 243), **nothing** updates `self.typingAttributes` to match the block type at the new position. NSTextView inherits typingAttributes from the character *before* the cursor — which after a block split (Return) or block conversion (toggle list/heading) belongs to the **old** block. The new line shows the old block's font size, paragraph style, and checkbox state until the first character triggers re-rendering.

`updateTypingAttributesForPendingTraits()` (line 762) only handles inline traits (bold/italic toggles), not block-level formatting.

### Evidence
| File | Line | What's missing |
|------|------|----------------|
| `EditTextView+BlockModel.swift` | 243 | `setSelectedRange` but no `typingAttributes = ...` |
| `EditTextView+BlockModel.swift` | 812 | `applyBlockModelResult` delegates to `applyEditResultWithUndo` — same gap |
| `EditTextView+BlockModel.swift` | 762-804 | `updateTypingAttributesForPendingTraits` only touches inline traits |

### Bugs caused
- **Headers**: Return after H2 → cursor/line height stays at H2 size until first char typed
- **Headers**: CMD+3 on blank line after H2 → gutter shows H2 (inherited paragraph style)
- **Headers**: Heading button on blank line → raw markdown shown (typing attrs don't match block)
- **Lists**: New Todo checkbox appears checked when previous was checked (inherits `.todo` attribute)
- **Lists**: Cursor stays at list indent after Delete converts empty list to body text

### Where to fix
Add `syncTypingAttributesToCursorBlock()` that reads the rendered attributes at the cursor position from the new projection. Call at end of `applyEditResultWithUndo()` (after line 278).

---

## RC2: `blockContaining()` boundary ambiguity at block edges

**Impact: ~7 bugs** | **Priority: CRITICAL** | **Difficulty: Medium**

### Description
`blockContaining()` uses inclusive upper bound: `idx >= lower && idx <= upper`. When cursor is at the exact boundary (end of block A == start of separator before block B), it always maps to block A with `offsetInBlock = block.length`. This offset is out-of-bounds for list operations: `listEntryContaining()` returns `nil` when offset equals item length (exclusive check on line 1518: `offset < inlineEnd`). The `nil` return causes `clearBlockModelAndRefill()` or wrong-item selection.

The fallback (line 116-121) maps cursor past all spans to the last block with `offsetInBlock = lastSpan.length` — always a boundary value.

### Evidence
| File | Line | Issue |
|------|------|-------|
| `DocumentProjection.swift` | 108 | `idx <= upper` — inclusive bound creates ambiguity |
| `DocumentProjection.swift` | 116-121 | Fallback: `offsetInBlock = lastSpan.length` — always boundary |
| `EditingOperations.swift` | 1518 | `offset < inlineEnd` (exclusive) — fails when offset == length |
| `EditingOperations.swift` | 1513 | `offset <= inlineEnd` (inclusive for insertion) — inconsistent |

### Bugs caused
- **Lists**: Delete in list → cursor jumps to end of note (lookup returns nil → clearBlockModelAndRefill)
- **Lists**: Delete in multi-level list deletes more than selected
- **Lists**: Delete list item → cursor jumps to end of note (recurring)
- **Lists**: Move Item Up/Down moves entire list
- **Headers**: CMD+2 on selected paragraph converts wrong paragraph
- **Lists**: Creating Todo after paragraphs changes line 3-4 above
- **General**: Typing at exact block boundary appends to wrong block

### Where to fix
- `DocumentProjection.swift:108`: When `idx == upper`, check if there's a next block starting at `idx + 1` (separator). If so, return the next block at offset 0 for operations that insert/format (not for append-to-current).
- `EditingOperations.swift:1507-1526`: Make `listEntryContaining` handle `offset == totalLength` by clamping to last entry at its end.

---

## RC3: Toolbar operations use single cursor location, not full selection range

**Impact: ~8 bugs** | **Priority: CRITICAL** | **Difficulty: Medium**

### Description
Every block-level toolbar operation extracts only `selectedRange().location` (a single `Int`) and passes it to `EditingOps`. The selection length is discarded. Multi-paragraph selections are ignored.

Additionally, `insertCodeBlock` (line 389) wraps text in fence markdown and calls `insertText()`, which routes through `handleEditViaBlockModel` as a plain text replacement — not a structural code-block operation. The block model can't handle multi-line markdown syntax insertion, throws, and falls back to `clearBlockModelAndRefill()` which loses the text.

### Evidence
| File | Line | Single-point usage |
|------|------|-------------------|
| `EditTextView+BlockModel.swift` | 945 | `changeHeadingLevelViaBlockModel` → `selectedRange().location` |
| `EditTextView+BlockModel.swift` | 963 | `toggleListViaBlockModel` → `selectedRange().location` |
| `EditTextView+BlockModel.swift` | 981 | `toggleBlockquoteViaBlockModel` → `selectedRange().location` |
| `EditTextView+BlockModel.swift` | 1018 | `toggleTodoViaBlockModel` → `selectedRange().location` |
| `EditTextView+Formatting.swift` | 394-406 | `insertCodeBlock` → `insertText(mutable, replacementRange:)` |

### Bugs caused
- **Lists**: Select multiple paragraphs + Bullet List → only first converts
- **Lists**: Select multiple lines in multi-level list + Delete → deletes ALL items
- **Headers**: Select multiple paragraphs + CMD+2 → wrong one converts
- **Formatting**: Select text + Code Block button → deletes text
- **Lists**: Multi-paragraph selection + Todo → only first converts
- **Lists**: Select body text paragraphs, one becomes Todo 3-4 lines above
- **Formatting**: Move Selected Lines Up/Down → moves entire list, not selected item
- **Lists**: Entering new Todo when below-item is completed → new item inherits checked state

### Where to fix
- All `ViaBlockModel` methods: accept `NSRange` (full selection), enumerate all blocks in range via `blockContaining`, apply operation to each.
- `EditingOps`: Add `changeHeadingLevel(level:range:in:)`, `toggleList(marker:range:in:)` etc. that iterate blocks.
- `insertCodeBlock`: Add `EditingOps.wrapInCodeBlock(range:in:)` that wraps the selected blocks in a code fence.

### Depends on
- **RC2**: Block boundary resolution must be correct before iterating multiple blocks.

---

## RC4: No live inline re-rendering after text insertion

**Impact: ~5 bugs** | **Priority: HIGH** | **Difficulty: Hard**

### Description
When markdown inline syntax (`[text](url)`, `[[wikilink]]`, bare URLs) is typed or inserted, `EditingOps.insert()` splices raw text into an existing `.text()` inline node. The inline tree is never re-parsed. `parseInlinesFromText()` (line 3773) wraps everything as `[.text(text)]` — no syntax detection at all.

Links only become clickable after `clearBlockModelAndRefill()` (note reload), which re-parses from disk through the full `MarkdownParser.parseInlines()` pipeline.

### Evidence
| File | Line | Issue |
|------|------|-------|
| `EditingOperations.swift` | 3773-3778 | `parseInlinesFromText` → `[.text(text)]`, no inline parsing |
| `EditTextView+Formatting.swift` | 57 | `linkMenu` → `insertText(markdown)` → plain text splice |
| `EditTextView+Formatting.swift` | 236 | `wikiLinks` → `insertText("[[text]]")` → plain text splice |

### Bugs caused
- **Links**: Insert Link via toolbar → not clickable until app reload
- **Links**: WikiLinks `[[...]]` stay visible and not clickable
- **Links**: Typed URLs only partially render as links (scheme not included in link)
- **Links**: Insert Link button → markdown visible until reload
- **Lists**: Bullet list button inserts `- ` when toggle fails → stays as text

### Where to fix
After any text insertion that completes a recognizable inline pattern, re-parse the affected block's full inline tree from its rendered text. Two approaches:
1. **Post-edit hook**: In `handleEditViaBlockModel`, after splice, check if the block's rendered text contains link/image/wikilink patterns → re-parse inlines → re-render block.
2. **Smart `parseInlinesFromText`**: Replace the trivial wrapper with the full `InlineParser` from `MarkdownParser`.

### Depends on
- **RC7**: Re-rendering triggers layout. Batch layout should be in place first.

---

## RC5: Fold state not persisted across note switches

**Impact: ~2 bugs** | **Priority: LOW** | **Difficulty: Easy**

### Description
Fold state lives in `TextStorageProcessor.foldedHeaders` (in-memory `Set`). When switching notes, `fillViaBlockModel()` replaces the entire blocks array. The previous note's fold state is lost. There is no persistence to disk or cache.

### Evidence
| File | Line | Issue |
|------|------|-------|
| `TextStorageProcessor.swift` | 164-169 | `previousCollapsed` keyed by block index, same-note only |
| `EditTextView+BlockModel.swift` | 165-167 | `fillViaBlockModel` replaces blocks — old fold state gone |

### Bugs caused
- Fold state lost when switching notes and returning
- Space between header text and `[...]` fold indicator (fold attribute range issue)

### Where to fix
- Per-note fold state cache: `Note.foldedHeaderIndices: Set<Int>?`
- `fillViaBlockModel`: After sync, restore fold state from cache
- `toggleFold`: After toggle, save to cache

---

## RC6: Table widget layout and editing gaps

**Impact: ~4 bugs** | **Priority: MEDIUM** | **Difficulty: Medium**

### Description
Table cells are `NSTextField` (line 46-48), not `NSTextView`. NSTextField doesn't support rich text editing commands. Row highlight width includes `L.leftMargin` but positions at `x: 0`, causing a 1-2px offset. Cell vertical alignment differs between display mode (custom layout) and edit mode (NSTextField baseline).

### Evidence
| File | Line | Issue |
|------|------|-------|
| `InlineTableView.swift` | 46-48 | Cells are `NSTextField` arrays |
| `InlineTableView.swift` | 464-467 | Highlight width includes margin, position starts at 0 |
| `InlineTableView.swift` | 769-775 | Display rendering uses custom padding; NSTextField differs |
| `InlineTableView.swift` | 127-132 | `cellFrame` insets don't match NSTextField internal padding |

### Bugs caused
- Can't apply bold/italic to table cells
- Row focus extends too far right, starts offset by 1-2px
- Cell text shifts down when clicking to edit
- Table under H1 without blank line doesn't render (block boundary/spacing issue)

### Where to fix
- Cell formatting: Either switch to `NSTextView` for cells, or implement markdown-marker insertion that re-renders on edit-end
- Highlight: Adjust `x` offset to match handle padding; cap width to `L.gridWidth`
- Vertical alignment: Set explicit NSTextField vertical alignment or match custom padding

---

## RC7: `ensureLayout` called per-replacement instead of batched

**Impact: ~2 bugs** | **Priority: LOW** | **Difficulty: Easy**

### Description
Mermaid/math rendering loops call `ensureLayout` after each block replacement. N replacements = N full layout passes. Additionally, `applyEditResultWithUndo` (line 260-276) invalidates only `blockIdx` to `blockIdx+1`, which can be too narrow when a splice shifts all subsequent blocks.

### Evidence
| File | Line | Issue |
|------|------|-------|
| `EditTextView+BlockModel.swift` | ~1187 | `ensureLayout` inside mermaid rendering loop |
| `EditTextView+BlockModel.swift` | ~1340 | `ensureLayout` inside math rendering loop |
| `EditTextView+BlockModel.swift` | 260-276 | Invalidation range: only `blockIdx` to `blockIdx+1` |

### Bugs caused
- `ensureLayout` called 3x for 3 mermaid/math replacements
- Juddering when editing in middle of note (narrow invalidation range)

### Where to fix
- Collect all mermaid/math replacement ranges → single `beginEditing`/`endEditing` cycle → one `ensureLayout` for union range
- `applyEditResultWithUndo`: Extend invalidation from `spliceRange.location` to end of storage

---

## RC8: FSM transition execution paths lack HTML-parity test coverage

**Impact: cross-cutting (all ~40 bugs)** | **Priority: CRITICAL** | **Difficulty: Medium**

### Description
The `ListEditingFSM` pure function is 100% correct — all 13 documented transitions are implemented and have unit tests. However, the **execution layer** (code that *applies* FSM decisions to the Document and textStorage) has minimal test coverage through the HTML-parity harness.

`EditorHTMLParityTests` has the right architecture: drive the editor through real entry points (`handleEditViaBlockModel`, toolbar `*ViaBlockModel` methods), then compare the live Document's HTML against the expected markdown's HTML. But it only has **8 edit-script tests** covering a fraction of the FSM transition space:

| Transition | HTML Parity Test? |
|------------|:-----------------:|
| Return after heading → paragraph | YES |
| Return in list → new item | YES |
| Toggle bold on selection | YES |
| Paragraph → heading | YES |
| Paragraph → list | YES |
| Type into heading | YES (2 tests) |
| **Return on empty list → exit to body** | **NO** |
| **Return on empty nested list → unindent** | **NO** |
| **Tab → indent list item** | **NO** |
| **Shift-Tab → unindent list item** | **NO** |
| **Delete at home in list → unindent/exit** | **NO** |
| **Delete at block boundary → merge (14 rules)** | **NO** |
| **Toggle todo** | **NO** |
| **Toggle blockquote** | **NO** |
| **Insert HR** | **NO** |
| **Heading level change (H2→H3)** | **NO** |
| **Heading toggle off (H2→paragraph)** | **NO** |
| **Bold toggle OFF** | **NO** |
| **Multiple Returns (blank lines)** | **NO** |
| **Paragraph → numbered list** | **NO** |
| **List → paragraph (toggle off)** | **NO** |
| **Delete in multi-level list** | **NO** |
| **Todo checkbox toggle** | **NO** |
| **Return on checked todo → unchecked** | **NO** |

The FSM *decides* correctly, but the code that *executes* the decision (EditingOps methods, splice generation, cursor positioning) is where the actual bugs live. Without HTML-parity tests for each transition, regressions in the execution layer go undetected.

### Evidence
| File | Line | What exists |
|------|------|-------------|
| `Tests/EditorHTMLParityTests.swift` | 152-179 | EditStep DSL supports: cursorAt, select, type, pressReturn, backspace, toggleBold/Italic, setHeading, toggleList/Quote/Todo, insertHR |
| `Tests/EditorHTMLParityTests.swift` | 339-443 | Only 8 edit-script tests |
| `Tests/ListEditingFSMTests.swift` | all | 44 tests — but test FSM pure function only, not the full editor pipeline |
| `Tests/EditingOperationsTests.swift` | 483-668 | 9 merge tests — but test EditingOps directly, not through editor |

### What's needed
The EditStep DSL already supports all the operations. What's missing is tests that:
1. Start from specific markdown
2. Execute a sequence of EditSteps through the real editor
3. Assert the live Document's HTML matches expected markdown's HTML
4. Assert the Document round-trips (serialize → parse → same HTML)

Each untested transition above needs at minimum one test. The 14 block merge rules need one test each. The DSL needs one new step: `.tab` and `.shiftTab` for list indent/unindent.

### Bugs this would catch
Every bug in RC1, RC2, RC3 manifests as the live Document diverging from expected markdown after an editing operation. HTML-parity tests would have caught:
- Return after header: line shows heading-level content (HTML would show `<h2>` where `<p>` expected)
- Delete in list jumping to wrong position (HTML would show wrong list structure)
- CMD+2 converting wrong paragraph (HTML would show heading on wrong block)
- Bold toggle stuck on (HTML would show `<strong>` wrapping everything)
- New Todo inheriting checked state (HTML would show `[x]` where `[ ]` expected)

### Where to fix
- `Tests/EditorHTMLParityTests.swift`: Add ~25 new edit-script tests (one per untested transition)
- `Tests/EditorHTMLParityTests.swift:152`: Add `.tab` and `.shiftTab` EditStep cases that route through the FSM

---

## Fix-Order Dependencies

```
Phase 0 — Test Infrastructure (do FIRST — catches regressions from all other fixes):
  RC8 (HTML-parity tests)         Write tests BEFORE fixing RC1-RC7; tests prove the fix works

Phase 1 — Foundation (no dependencies, unblocks everything):
  RC1 (typingAttributes sync)     Easy, independent, immediate UX improvement
  RC2 (blockContaining boundary)  Unblocks correct behavior for all operations

Phase 2 — Core Operations (depends on Phase 1):
  RC3 (multi-block selection)     Depends on RC2; biggest bug count
  RC7 (batch ensureLayout)        Prepares for RC4's extra layout passes

Phase 3 — Features (depends on Phase 2):
  RC4 (inline re-rendering)       Depends on RC7 for perf; hardest fix
  RC5 (fold persistence)          Independent, easy
  RC6 (table widget)              Independent, medium effort
```

### Why RC8 comes first
The HTML-parity tests should be written BEFORE fixing RC1-RC7. Each test will initially **fail** (proving the bug exists), then **pass** after the corresponding RC fix (proving the fix works). This is test-driven development: write the test that captures the bug, then fix the bug. Without RC8, we have no regression safety net — fixing RC2 could break something RC1 fixed, and we'd never know.

### Interaction Matrix

|     | RC1 | RC2 | RC3 | RC4 | RC5 | RC6 | RC7 | RC8 |
|-----|-----|-----|-----|-----|-----|-----|-----|-----|
| RC1 |  -  |     |     |     |     |     |     | RC8 tests verify |
| RC2 |     |  -  | RC3 needs RC2 |     |     |     |     | RC8 tests verify |
| RC3 |     | depends |  -  |     |     |     |     | RC8 tests verify |
| RC4 |     |     |     |  -  |     |     | needs RC7 | RC8 tests verify |
| RC5 |     |     |     |     |  -  |     |     |     |
| RC6 |     |     |     |     |     |  -  |     |     |
| RC7 |     |     |     | RC4 perf |     |     |  -  |     |
| RC8 | verifies | verifies | verifies | verifies |     |     |     |  -  |

---

## Bug-to-Root-Cause Mapping (Open Bugs Only)

### Headers
| Bug | RC |
|-----|----|
| Return after H2: line height wrong | RC1 |
| CMD+3 on blank line: gutter shows H2 | RC1, RC2 |
| H2 button on new note blank line: shows raw markdown | RC1, RC4 |
| Fold header: space before [...] | RC5 |
| Fold state lost on note switch | RC5 |

### Note editing & formatting
| Bug | RC |
|-----|----|
| Delete in empty L1 list: cursor stays indented | RC1 |
| CMD+B toggle stuck on | RC1 (pendingInlineTraits not cleared after selection op — minor variant) |
| Delete in Todo list removes line instead of checkbox | RC2 |
| Remove blank line between header/code breaks rendering | RC2, RC7 |
| Delete in list: cursor jumps to end | RC2 |
| Juddering when typing in list | RC7 |
| Copy list with formatting: paste loses formatting | RC3 |
| `<kbd>` tags don't render | Separate (missing inline parser for HTML tags) |
| `<sup>/<sub>` not implemented | Separate (feature request) |
| Cursor position mismatch WYSIWYG ↔ Markdown mode | RC2 |
| Select text + Code Block button deletes text | RC3 |

### Lists
| Bug | RC |
|-----|----|
| Bullet List button: inserts `- ` but no bullet | RC4 (or RC3 if toggle failed) |
| Todo checkbox moves 1-2px on first char | RC1 |
| New Todo 3-4 lines above cursor | RC2, RC3 |
| New Todo inherits checked state | RC1 |
| Multi-paragraph + Bullet List: only first converts | RC3 |
| Multi-level list select + Delete: deletes all | RC2, RC3 |
| When cursor in list + Move Up/Down: moves all | RC3 |

### Tables
| Bug | RC |
|-----|----|
| Row handle: focus extends too far right | RC6 |
| Cell text shifts down on edit | RC6 |
| Table under H1 without blank line: no render | RC6, RC2 |
| Can't bold/italic in table cells | RC6 |
| Multi-cell selection/clear | RC6 (feature) |

### Links
| Bug | RC |
|-----|----|
| Insert Link: not clickable until reload | RC4 |
| Typed URLs: only partially linked | RC4 |
| WikiLinks `[[...]]`: stay visible, not clickable | RC4 |
| Move Selected Lines in list: moves all | RC3 |

### Lines
| Bug | RC |
|-----|----|
| HR button: cursor not positioned right of line | RC1 |
| Checkbox moves 1-2px on first char | RC1 |
| Delete list item: cursor jumps to end | RC2 |

### Code blocks & MathJax
| Bug | RC |
|-----|----|
| ensureLayout called 3x | RC7 |
| Select + Code Block button deletes text | RC3 |

### Menu/UI (not root-cause-related)
| Bug | Notes |
|------|-------|
| Rename → Rename Note | Menu label change |
| Move → Move Note | Menu label change |
| Duplicate → Duplicate Note | Menu label change |
| Delete Orphaned Attachments icon | Asset addition |
| Shrinking window hides panes permanently | NSSplitView constraint issue |
| WYSIWYG↔Markdown clears Undo | UndoManager architecture |
| Print doesn't include QuickLook previews | Print pipeline |
| PDF export clips right margin | Table/mermaid width calculation |
| Remove Preview MathJax menu | Menu cleanup |
| Various Settings questions | Investigation/cleanup |
