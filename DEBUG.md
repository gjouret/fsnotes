# DEBUG.md — Plan for the FSNotes++ Refactor 4 bug inventory

**Source**: Notes "FSNotes++ Bugs - Refactor 4" + "FSNotes++ Refactor 4" (running plan)
**Tracker**: `bd` (beads) — 59 open issues as of 2026-04-29 (4 P1 / 42 P2 / 13 P3)
**Scope**: define a workflow for (1) detecting bugs that are already fixed, (2) fixing the open ones, (3) handling new bugs discovered while testing or fixing.

---

## Core insight

Each bead's contract is a *failing test* that captures its symptom.

- **Definitively fixed** = the test passes on master AND there is a prior SHA where it failed (so the test isn't tautologically green).
- **Definitively not fixed** = the test fails on master.

User validation drops out as the close gate for any bug with a verifiable property. Only perceptual judgments ("the gray looks too bright") still need the user.

---

## §1 — Detect bugs already fixed (no validation needed)

Pipeline per bead:

1. **Classify by test layer** (CLAUDE.md Rule 4 — pure-fn first, view glue last). The first four layers are described authoritatively in [ARCHITECTURE.md §"Test Infrastructure"](ARCHITECTURE.md) (line 604+) — go there for harness internals; the table below is just the routing decision.

   | Layer | Use for | Existing infra |
   |-------|---------|----------------|
   | Pure-fn | `EditingOps` / `MarkdownParser` / `DocumentRenderer` output | `BlockParserTests`, `EditingOperationsTests`, `DocumentEditApplierTests`, `MarkdownSerializer*Tests`, `ListEditingFSMTests` |
   | HTML Parity (canonical live-edit harness, ~85 tests) | live-vs-expected `Document` HTML byte-equality + round-trip identity `HTML(doc) == HTML(parse(serialize(doc)))` | `Tests/EditorHTMLParityTests.swift` |
   | EditorHarness DSL | scripted edits, `Invariants.assertContract` after each input | `Tests/EditorHarness.swift` |
   | TK2 fragment dispatch (~55 tests) | correct `NSTextLayoutFragment` subclass per tagged range | `Tests/TextKit2FragmentDispatchTests.swift`, `TextKit2ElementDispatchTests.swift` |
   | Coord-space | `caretRect` / `typographicBounds` / cell rect geometric relationships | new — see below |
   | View-snapshot | `cacheDisplay`, only where chrome lives in view (not fragment) | new |
   | Theme-pixel | sample `(x,y)` and `XCTAssertEqual` against `Theme.shared.<key>` | new |
   | Computer-use screenshot | running-app verification when the property is only observable on screen — redraw-timing (META glyph wipe), final rendered appearance of WKWebView-driven content (Mermaid/MathJax against editor background), dark-mode pixel colors of glyphs drawn through paths that don't expose their color in code | `computer-use` MCP — `request_access` for `~/Applications/FSNotes++.app` (full tier, native app), then `screenshot` + `key`/`type` to drive |
   | **Perceptual** | last resort — bug stays open, `bd update <id> --notes="needs visual confirmation"` | n/a |

   For cascade closure (§3), every regression test for a bead with combinatorial siblings should also be expressible as a row in `Tests/Combinatorial/Generator.swift`. **bd is the single source of truth for which scenarios are currently failing** — the combinatorial runner queries `bd list --label=combinatorial --status=open` at startup, extracts each scenario label from the bead's `--notes`, and `XCTExpectFailure(strict: true)`-wraps that scenario. When a root-cause fix lands and a downstream scenario flips to "unexpectedly passed," the runner reports it; we then `bd close` the corresponding bead and the wrap goes away on the next run. (`Tests/Combinatorial/DiscoveredBugs.txt` is being migrated to bd — see bd-fsnotes-wlp; it is no longer authoritative.)

   **CI-runnable vs. one-shot.** The first six layers are regression tests that run in CI and act as the close gate. A computer-use screenshot is a one-shot observation, archived in the bead's `--notes` as visual evidence — it complements but does not replace a programmatic test. Order of preference for verification: programmatic (cheap, deterministic, runs in CI) → screenshot (the property cannot be read in code, e.g. redraw timing) → user perceptual confirmation.

2. **Write the failing test** at the chosen layer under `Tests/Regression/Bug<beadID>Tests.swift`. One file per bead.

3. **Bisect-anchor**: run the test in a temp worktree at `master~50` (or wider). If it failed at any prior SHA, the test is real (not tautologically green). Capture the SHA where it transitioned to passing — that is the fix commit.

4. **Close gate**:
   - Test green on master AND failed at some prior SHA → `bd close <id> --reason="regression test green at <SHA>; failed at <prior SHA>"`
   - Test still fails on master → real bug, route to §2
   - Bug is perceptual → flag for user review, do not auto-close

---

## §2 — Fix open bugs

**Order**: P1 first (4 bugs), then P2 in pipeline-stage clusters so one fix can close multiple beads.

Per bead:

1. `bd update <id> --claim`
2. Confirm the regression test from §1 fails (existence proof).
3. `gitnexus_impact` on each symbol I would modify — halt and report if HIGH or CRITICAL.
4. Identify the owning pipeline stage (CLAUDE.md Rule 6). Fix *at* that stage, not downstream.
5. Re-run the regression test, the full pure suite, and `scripts/rule7-gate.sh`.
6. Build + deploy via the `xcode-build-deploy` skill. Verify with `nm` / `strings` that the changes landed in the deployed binary.
7. For UI bugs: read the verifiable property programmatically (caret rect, layer color, fragment class) where possible. If the property is only observable in the running app (redraw timing, WKWebView-rendered Mermaid/MathJax pixels against the live editor background, dark-mode glyph colors drawn through opaque paths), drive the deployed `~/Applications/FSNotes++.app` via `computer-use` — `request_access`, scripted `key`/`type` to reproduce the symptom, `screenshot` before and after the fix, archive both in the bead's `--notes`. Still no "does it look right?" questions to the user — the screenshot pair is the evidence.
8. `bd close <id> --reason="test green at <SHA>"` + `git commit` + `git push`.

**Pipeline-stage clusters** (one fix → multiple closures, ordered roughly by leverage):

| Cluster | Beads | Owning stage |
|---------|-------|--------------|
| `EditingOps` caret/newline family | new-note caret height, triple-click+delete, wikilink trailing newline, HR cursor placement, mermaid block insert, last-cell `<br>` regression | `FSNotesCore/Rendering/EditingOperations.swift` |
| `TableLayoutFragment` coord-space | column-handle box, row-handle drift, multi-line-cell handle overlap, cell text-left-of-cursor | `FSNotesCore/Rendering/TableLayoutFragment.swift` |
| WYSIWYG↔Source bridge | toggle cursor position, toggle selection preservation | `EditTextView+Toggle.swift` (or equivalent) |
| Wikilink resolver | trailing-newline picker, click-to-open handler | parser + URL handler |
| URL autolink at type time | toolbar Insert Link, typed URL prefix | `EditingOps.reparseInlinesIfNeeded` |
| Theme / dark mode | Todo glyph color, table shading, fold ellipsis gray, banner gray, mode-aware MathJax/Mermaid/QuickLook cache | `ThemeSchema.swift` + render-cache invalidator on `NSAppearance` change |
| Attachment redraw / META glyph wipe | META glyph wipe, `ensureLayout` coalescing, possibly Todo glyph color | attachment view providers + edit applier |
| Print pipeline | non-image attachment QuickLook in print | print path |
| External-edit watcher | `text.md` mtime → reload | `Note` reload path |

---

## §3 — New bugs discovered while testing/fixing

Decision tree at the moment of discovery:

- **Same root cause as current bead** → fold into current fix; one-line mention in commit message; no new bead.
- **Adjacent symptom, same pipeline stage, < 10 LoC delta to also fix** → fix in same commit; file the bead retroactively with `bd close --reason="folded into <commit-sha>"` and `bd dep add` to current bead so history is honest.
- **Different pipeline stage or substantial work** → `bd create --type=bug --priority=N` immediately; capture the failing test as `Tests/Regression/Bug<newID>Tests.swift` with `XCTExpectFailure` (so the suite stays green); `bd dep add` if it blocks the current bead; return to current bead.
- **Combinatorial-generator discovery** (Phase 11 Slice E pattern) → one bead per *root-cause cluster*, not per variant. Record all variants in `--notes`. The existing generator at `Tests/Combinatorial/Generator.swift` already does this.
- **Cascade closure**: after fixing a P1 root cause, re-run the combinatorial matrix. Any `XCTExpectFailure` that flips to green gets `bd close --reason="cascade from <root-bead>"`. (Slice E showed bug #45's 10 variants close on bug #37's fix — the pattern is real.)

**Hard rule**: never silently absorb a discovered bug. Either it is named in the commit message of the current fix, or it is a new bead with a captured test. No third option.

---

## What runs first

1. Build the regression-test scaffold for the 4 P1 beads:
   - META: bullet/Todo glyphs disappear during edit, reappear on scroll
   - Table cell: typed text appears left of cursor (1-2 char offset)
   - Last table cell: typing inserts `<br>` per character (regression)
   - `HeaderTests.test_headerFonts_areBold` hangs (existing P1 from prior session)

   One `Tests/Regression/Bug<id>Tests.swift` per bead.

2. Run them on master.

3. Bisect-anchor each: find the SHA where each transitioned from failing to passing (or confirm it never did).

4. Report: which P1s are already fixed (close gate), which are real (move to fix queue).

That cycle proves the methodology on the 4 highest-stakes beads before applying it to all 59.

**Tradeoff to note**: bugs that need a *running* app to reproduce (META glyph wipe is the obvious one — it is about redraw timing during edits) have two verification paths:

1. **Programmatic AppKit harness in-process** — snapshot `attachmentViewProvider.view.layer.contents` after each scripted edit, assert non-nil. Reusable across all redraw-related beads, runs in CI. First choice when the property is reachable from inside the test process.
2. **Computer-use screenshot of the deployed app** — when the in-process harness doesn't reproduce the bug because the redraw race only fires under real AppKit run-loop and graphics-driver conditions. Drive `~/Applications/FSNotes++.app` via `computer-use` MCP (full tier, no restrictions); script the edit sequence with `key` / `type`; capture before/after screenshots; archive in bead notes as evidence. Not CI-runnable — captured once during the fix, referenced thereafter.

The META glyph wipe likely needs path 2: in-process snapshots may freeze the view tree at a moment where the redraw signal *did* arrive, masking the user-visible flicker. A real-app screenshot taken mid-typing is the honest test.

---

## Conventions

- **One bead → one regression test file**. Path: `Tests/Regression/Bug<beadID>Tests.swift` (use the bd-assigned suffix, e.g. `BugFsnotes5fbTests.swift`).
- **Commit message format**: `bd-<id>: <title> — <test-SHA>`. Bead ID as a stable cross-ref.
- **Worktrees for bisect**: per CLAUDE.md "Worktrees: CocoaPods symlinks required" — symlink `Pods` / `Podfile` / `Podfile.lock` from main repo before first build in any new worktree. Prune after the bisect lands.
- **`scripts/rule7-gate.sh`**: run before *any* edit under `FSNotes/Rendering/` or `FSNotesCore/Rendering/`. If the baseline is dirty, stop — pattern-matching from a violating baseline extends the violation.
- **Build redirection**: `xcodebuild ... > /tmp/xcbuild.log 2>&1` always (CLAUDE.md context-window discipline). Same for `xcodebuild test`.

### Parallel-agent collision rule

When two agents share a working tree (no per-agent worktree), files can be observed mid-edit. A file with broken syntax or partial content is **probably Agent B writing in pieces**, not corruption to revert.

**Before running `git checkout HEAD -- <file>` to "fix" a syntax error**, run:
```bash
ls -la <file>                    # mtime tells you whether something just touched it
git diff HEAD <file>             # is the partial change semantically related to an open bead another actor owns?
bd list --status=in_progress     # who's working what?
ls Tests/Regression/Bug<id>Tests.swift  # untracked test files for the same change?
```

If the partial content corresponds to a bead claimed by another actor, **leave it alone**. `git checkout` will undo their progress.

This was added 2026-04-29 after I (`claude-A`) reverted DEEPSEEK's mid-edit fix for `fsnotes-nw2` three times in a row in `EditTextView+BlockModel.swift:1379`, each time misreading their incomplete write as file corruption. The test file `BugFsnotesNw2Tests.swift` and the bead description both made the intent obvious; I didn't check.

### Bead lifecycle (every bead must transition through these states explicitly)

> **Canonical source**: `~/.claude/skills/beadbox/SKILL.md`. The Beadbox skill defines an 8-state lifecycle for multi-agent workflows: `open → in_progress → ready_for_qa → qa_passed → ready_to_ship → closed` (plus `blocked` / `deferred` branches). Per-agent transition rules ("only the impl agent transitions in_progress → ready_for_qa") prevent two agents from claiming the same bead.

For solo-agent work the 3-state subset (`open / in_progress / closed`) is sufficient. For multi-agent runs (impl + QA + ops, or two parallel impl agents working different beads), use the 8-state lifecycle and pass `--actor <name>` on every transition. The lifecycle table below covers both modes — the `ready_for_qa` / `qa_passed` rows are skipped in solo mode.

| State change | Command | When |
|--------------|---------|------|
| open → in_progress | `bd update <id> --claim --actor <name>` | At the start of work on a bead. **Always claim before editing code or running tests** — `--claim` is what stops a parallel agent from grabbing the same bead. Never leave a bead silently in_progress without claiming. |
| in_progress (annotate) | `bd update <id> --notes="<finding>"` | Each non-trivial discovery during work — root cause confirmed, dead end ruled out, related symptom found. Future sessions read this. |
| in_progress (visual evidence) | `bd update <id> --notes="screenshot:<path>"` | When verification used computer-use; archive the before/after screenshot pair path. |
| in_progress → ready_for_qa (multi-agent) | `bd update <id> --status ready_for_qa --actor <impl-agent>` | Impl agent posts `DONE: ... Commit: <sha>` in notes, then transitions. Only the impl agent makes this transition. |
| ready_for_qa → qa_passed (multi-agent) | `bd update <id> --claim --actor <qa-agent>` then `--status qa_passed` | QA agent claims, runs the regression test on master + bisect-anchor, then transitions. If broken, transitions to `blocked` instead. |
| qa_passed → ready_to_ship → closed (multi-agent) | `bd update <id> --status ready_to_ship --actor <ops-agent>` then `bd close <id>` | Ops agent ships and closes. |
| in_progress → closed (solo, fix) | `bd close <id> --reason="test green at <SHA>"` | Solo workflow. After §2 step 7 verification. Must include commit SHA of the fix. |
| in_progress → closed (solo, already-fixed §1) | `bd close <id> --reason="regression test green at <SHA>; failed at <prior SHA>"` | When the bisect-anchored test passes on master with prior-SHA failure proof. |
| any → closed (cascade §3) | `bd close <id> --reason="cascade from <root-bead-id> at <SHA>"` | When a P1 fix flips a `Tests/Combinatorial/DiscoveredBugs.txt` `XCTExpectFailure` entry to "unexpectedly passed" for a sibling bead. |
| any → deferred | `bd defer <id> --until="<date>"` | Discovered out-of-scope; document why in `--notes`. |
| any → blocked | `bd update <id> --status blocked --actor <name>` | QA fails or external dependency missing. Resumes to `in_progress` when unblocked. |
| any → human flag | `bd human <id>` | Bug is perceptual ("looks too white"); needs the user before it can close. |
| new bead | `bd create --type=bug --priority=N --title=... --description=...` | §3 discovery path. Capture failing test as `XCTExpectFailure` in same commit so the suite stays green. |
| dependency | `bd dep add <bead> <depends-on>` | When a discovered bead blocks the current one, or when a cascade root-bead is identified. |

### Session-close protocol (per CLAUDE.md)

After every work session, before stopping:
1. `bd preflight` — lint, stale, orphans.
2. `git pull --rebase`.
3. `bd dolt push` — sync beads to Dolt remote.
4. `git push` — push code.
5. `git status` — must show "up to date with origin". Work is **not** complete until this prints clean.
