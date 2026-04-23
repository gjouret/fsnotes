# TextKit 2 Migration — Pre-flight Spike Report

> Temporary document. Gate for Phase 0. User approval of the conclusion is required before Phase 0 starts.

---

## 1. Deployment target

**Resolved by user decision: target macOS 26.**

- Current `FSNotes` app target: `MACOSX_DEPLOYMENT_TARGET = 12.4` (`FSNotes.xcodeproj/project.pbxproj:4163, 4200`; same for iCloud and Tests targets at `4239, 4281, 4317, 4350`).
- Current project global Debug/Release: `10.14` (`project.pbxproj:4070, 4130`).
- `Podfile` already declares `platform :osx, '26.0'` (`Podfile:29, 40`).
- `Info.plist` inherits deployment target via build-setting (`FSNotes/Info.plist:172`).

**Implication.** Targeting macOS 26 unconditionally unlocks every TextKit 2 surface we care about without availability guards:
- `NSTextLayoutManager` + `NSTextContentStorage` (macOS 12+).
- `NSTextElement.childElements` / `parentElement` / `isRepresentedElement` (macOS 13+) — the tree APIs we'd need for any T1-style sub-element work.
- `NSTextLayoutManager.setRenderingAttributes(_:for:)` with reliable composition (documented-reliable on macOS 13+).
- `NSTextListElement` patterns and the selection-navigation improvements shipped in Ventura/Sonoma.

**Phase 0 action.** Raise `MACOSX_DEPLOYMENT_TARGET` on all four targets from `12.4` → `26.0` and set the project-global from `10.14` → `26.0`. Bundle this with the harness-scaffold PR so CI is run once on the new floor before any production code changes.

---

## 2. Prototype — `HorizontalRuleElement` + `HorizontalRuleLayoutFragment`

**Written.** `FSNotesCore/Rendering/Spike/HorizontalRuleElement.swift` (leaf `NSTextElement`, 20pt intrinsic height) and `FSNotesCore/Rendering/Spike/HorizontalRuleLayoutFragment.swift` (overrides `layoutFragmentFrame`, `renderingSurfaceBounds`, `draw(at:in:)` — 4pt gray bar RGB 0.906, matching today's `HorizontalRuleDrawer`).

**Not wired into `project.pbxproj`** intentionally. The spike is throwaway code that validates the shape of the two classes. Phase 0 replaces it with a pbxproj-wired, harness-tested pair under `FSNotesCore/Rendering/Elements/` and `FSNotesCore/Rendering/Fragments/`.

**Feasibility findings:**
- `NSTextElement` is sparsely subclassed in AppKit — only `NSTextParagraph` is public and non-paragraph elements risk selection-navigation runtime assertions (Krzyżanowski 2025). Confirms the plan's 2a-first gate: get `NSTextLayoutManager` up on paragraph-only content before introducing any non-paragraph subclass.
- Custom fragment `draw(at:in:)` gives us the equivalent of today's `AttributeDrawer` cleanly. The HR case — a block with no text content — is the most forgiving prototype: no glyph runs to coordinate with, no selection geometry to expose.
- Files outside an existing Xcode group (our `Spike/` folder) are silently ignored by `xcodebuild`. Same trap called out in `CLAUDE.md` feedback. Phase 0 must wire new element/fragment files in four places per new file (CLAUDE.md build-env rules).

---

## 3. Table primitive choice — recommendation: **T2** (cells as text ranges in one element)

**Decision informed by (a) the NSTextFinder finding in §4 below and (b) shipping-precedent research.**

| Criterion | T1 (sub-elements) | T2 (attribute-encoded cells) |
|---|---|---|
| Apple-shipped precedent | Only `NSTextListElement` — and even there, storage is linear with tree reconstructed | WWDC21 `BubbleLayoutFragment` is the closest analogue; all shipping custom elements store content linearly |
| `NSTextContentStorage` write path | Element-tree mutation; ultimately still writes to flat `NSTextStorage` | Native `replaceCharacters(in:with:)` inside `performEditingTransaction` |
| `NSTextFinder` visibility (bug #60) | Children need flattening / custom provider to appear in finder `string` | Cell text already in backing `NSTextStorage` → Find walks it natively |
| Selection / cursor | Inter-child navigation requires custom `NSTextSelectionNavigation` delegate | Linear stream; cursor moves cell-to-cell as "next character" (attributes on runs) |
| `NSTextLayoutFragment` (grid geometry) | Aggregates child fragment geometry; layout manager treats children as peers | Single fragment hosts multiple line fragments at computed cell positions |
| Field-report warnings | Krzyżanowski: non-`NSTextParagraph` elements "trip runtime assertions" | On the path Apple tests (attributed-string primitive) |

**Recommendation: prototype T2.** It keeps the backing store on the single path Apple actively tests, makes bug #60 a structural property (not a feature we have to engineer), and aligns with the Phase 3 design where `applyDocumentEdit` is an element-level diff writing through `performEditingTransaction`.

**Fallback.** If T2 hits a wall during Phase 2 (most likely: grid-layout hit-testing or per-cell selection rectangle mismatch), mirror `NSTextListElement`'s child-element pattern as T1. This is the explicit "acceptable half-win" from the plan's risk section — keep `InlineTableView`-on-attachment for tables while other block types migrate.

Key sources: WWDC21 "Meet TextKit 2"; WWDC22 "What's new in TextKit and text views"; `NSTextElement.childElements` docs; Krzyżanowski "TextKit 2 — the promised land" (2025); STTextView discussion #79; Apple forum threads 682375, 709127.

---

## 4. `NSTextFinder` behavior on TextKit 2 custom elements — bug #60 verification

**Finding: Find will work across cell text only if that text is stored as real characters in the backing `NSTextStorage`. Custom element "side state" is invisible to Find.**

Mechanism:
- `NSTextFinder` reads content via `NSTextFinderClient` (`stringLength`, `string(at:effectiveRange:)`), not via `NSTextContentManager.enumerateTextElements` (Apple docs; Apple forum 707359).
- `NSTextView` conforms to `NSTextFinderClient` by default; the client string it hands over is its `NSTextStorage` (the one backing `NSTextContentStorage`). Custom `NSTextContentManager` subclasses are not supported on `NSTextView` (Apple forum 690859).
- There is no per-element "contributes-to-find-string" hook. `NSTextParagraph` only accepts an `NSAttributedString`; nothing on `NSTextElement` extends the finder client string (Apple forum 747583, `NSTextElement` docs).

**Consequence for the plan.** The plan's claim that "Find works for free on TextKit 2 across all block types" is only true when the block's text content lives as real characters in `NSTextContentStorage`'s backing storage. This is automatic for:
- `ParagraphElement` / `HeadingElement` / `ListItemElement` / `BlockquoteElement` / `CodeBlockElement` — they already carry their text.
- `TableElement` **under T2** — cell text IS the backing-storage content, with cell boundaries on attributes. Bug #60 dissolves structurally.
- `MermaidElement` / `MathElement` — if we store the source text as real element content (the plan's explicit intent), Find sees it and the fragment visually hides it.

**Not automatic for:**
- `TableElement` **under T1** — cell text would live inside `TableCellElement`'s own attributed-string state, which does not extend the finder client string. We'd need to flatten cells into a custom provider.
- `HorizontalRuleElement` — no text content (acceptable: HR is structurally non-textual).

**Find-match highlighting in custom fragments** uses `NSTextLayoutManager.setRenderingAttributes(_:for:)` — reliable on macOS 13+ (our target). Custom `draw(at:in:)` must honor the rendering attributes on its line fragments; they are not auto-composited (STTextView discussion #8).

**Verdict: the T2 recommendation stands not only on its own precedent merits but because it's the construction that makes bug #60 a structural property. T1 would re-introduce bug #60 in a new form.**

---

## 5. Migration ordering

`EditTextView` already detaches and reattaches its layout manager in `initTextStorage()` (`FSNotes/View/EditTextView.swift:313-333`):
1. Gets existing textStorage / layoutManager / textContainer from the nib-constructed `NSTextView`.
2. Removes the old layout manager.
3. Installs custom `LayoutManager` subclass (`FSNotes/LayoutManager.swift:23`, ~500 lines).
4. Re-adds to the storage.

**Implication.** Swapping to `NSTextLayoutManager` + `NSTextContentStorage` at init time is mechanically feasible without re-parenting the view hierarchy. We hand the `NSTextContainer` to a new `NSTextLayoutManager` instead of the TextKit 1 stack. The work is swap logic, not view-hierarchy restructuring.

**Biggest engineering item.** The `LayoutManager` subclass (~500 lines of custom drawing: bullets, checkboxes, ordered markers, blockquote borders, HR, syntax-attribute draws) is the largest single migration task. Phase 2c and 2d together port its responsibilities into per-fragment `draw(at:in:)` overrides and retire the subclass. `AttributeDrawer` (today called from `LayoutManager.drawBackground`) becomes a set of per-fragment helpers.

**Secondary observation.** No `NSTextStorage` subclass in the codebase (only extensions at `NSTextStorage++.swift`). `TextStorageProcessor` is a delegate, not a subclass — it listens to storage-edit callbacks and runs the incremental parse pipeline. The delegate is TextKit-version-agnostic in shape; what changes is what it reads (attributed string) and what it writes (element stream vs. attributed string).

---

## Spike conclusion

1. **Deployment target** resolved by user (macOS 26). Phase 0 raises the project setting. No product surface to surface.
2. **Prototype** validates the basic shape of `NSTextElement` + `NSTextLayoutFragment` in our codebase; HR is the cleanest case; Phase 0 wires it properly.
3. **Table primitive: T2.** Cells as text ranges in one element with attribute-encoded boundaries. Fallback: T1 (child-element pattern from `NSTextListElement`).
4. **`NSTextFinder`:** the plan's "Find for free" thesis holds *if and only if* block text content lives in the backing `NSTextStorage`. T2 satisfies this by construction. T1 does not.
5. **Migration ordering:** mechanically feasible at `EditTextView.initTextStorage`. The `LayoutManager` subclass is the largest single migration item; retired across 2c/2d.

**Adjustment to Phase 2 risk section in `REFACTOR_PLAN.md`.** Field reports (Krzyżanowski 2025; STTextView issues) indicate non-`NSTextParagraph` custom elements can trip runtime assertions in selection navigation. Phase 2a (TextKit 2 baseline on paragraph-only content) must run on real notes before any custom element subclass lands in production. Add a manual-dogfood gate to 2a exit criteria: "selection, Find, IME, copy/paste, scroll verified on a 50k-char paragraph-only corpus note; no runtime assertions in console."

**No other changes to the plan are warranted by spike findings.** Proceed to Phase 0 on user approval.

---

## Files produced by the spike

| File | Purpose | Status |
|---|---|---|
| `FSNotesCore/Rendering/Spike/HorizontalRuleElement.swift` | Minimal `NSTextElement` prototype | Written; not in pbxproj (intentional) |
| `FSNotesCore/Rendering/Spike/HorizontalRuleLayoutFragment.swift` | Minimal `NSTextLayoutFragment` prototype | Written; not in pbxproj (intentional) |
| `PREFLIGHT.md` | This report | Written at project root |

**Phase 0 first action (after your approval):** raise deployment target to macOS 26 across all targets, then begin harness scaffolding per `REFACTOR_PLAN.md` Phase 0.
