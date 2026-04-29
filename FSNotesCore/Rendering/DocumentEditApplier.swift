//
//  DocumentEditApplier.swift
//  FSNotesCore
//
//  Phase 3 — Element-level edit application on NSTextContentStorage.
//
//  ARCHITECTURAL CONTRACT
//  ----------------------
//  `applyDocumentEdit(priorDoc:newDoc:contentStorage:...)` is the one
//  function that mutates an `NSTextContentStorage` on the TextKit 2
//  path. It takes two `Document` values (before / after) and emits
//  minimal element-level mutations via
//  `NSTextContentStorage.performEditingTransaction`.
//
//  The invariant it preserves: **elements above the first changed
//  block are untouched across every edit** (block-bounded redraw).
//
//  Block identity
//  --------------
//  This primitive does NOT invade the `Block` model with UUIDs (see
//  Phase 3 design constraints in `REFACTOR_PLAN.md`). It uses
//  **structural matching** via a Longest-Common-Subsequence diff keyed
//  on value equality (`Block: Equatable`). Blocks that are
//  byte-identical across `priorDoc` → `newDoc` are treated as
//  "unchanged" and contribute to the LCS; everything else is a delete
//  or an insert.
//
//  A secondary post-LCS pass merges adjacent `(delete priorIdx,
//  insert newIdx)` pairs of the **same block kind** at the **same
//  relative position** into a single `.modified(priorIdx, newIdx)`
//  operation. This is the typing-into-a-paragraph case: the paragraph
//  at index N has new inline content but is still a paragraph — it
//  should be reported as modified (same element slot, new content),
//  not deleted-and-inserted.
//
//  Why structural, not UUID: `Document.blockIds` exists as a side-
//  table, but its identities are ephemeral (minted fresh on every
//  parse, not serialized), so a parse-driven diff would see every
//  block as new. A structural diff works for any two `Document`
//  values regardless of origin. If a future phase needs `EditContract`
//  to carry hints ("I know block id X moved to index Y"), that's an
//  additive optimization — this primitive stays sound without it.
//
//  Rollback
//  --------
//  If the differ produces an incorrect plan for some edit, the
//  fallback is to replace-on-any-change within the affected block
//  range: treat the entire `[firstChange ... lastChange]` span as
//  one big modified chunk. That fallback is emitted today for every
//  edit — we do not split non-contiguous changes into multiple
//  transactions. This is both the "rollback position" and the v1
//  default; future passes can reduce granularity once perf metrics
//  demand.
//
//  DEBUG instrumentation
//  ---------------------
//  Under `#if DEBUG`, each call appends one line to
//  `<project-root>/logs/element-edits.log` describing the scope of
//  the edit (which element indices changed / inserted / deleted,
//  total storage length delta). Same convention as `bmLog`. Release
//  builds skip the log write entirely.
//
//  What this primitive does NOT do
//  --------------------------------
//  - Undo registration (handled by the caller — `applyDocumentEdit`
//    is stateless aside from the log).
//  - Cursor / selection preservation (the caller sets the cursor
//    after applying).
//  - IME / composition interaction (Phase 5e territory — the caller
//    is responsible for gating calls during composition).
//  - Wire-in to the live editor (Phase 3 ships the primitive + tests;
//    `fillViaBlockModel` / `handleEditViaBlockModel` still use the
//    legacy TK1 splice path until a follow-up slice).
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Public entry point

public enum DocumentEditApplier {

    /// One-line description of a block-level change, emitted by the
    /// differ and consumed by the applier. Indices refer into each
    /// document's `blocks` array.
    public enum BlockChange: Equatable {
        case unchanged(priorIdx: Int, newIdx: Int)
        case modified(priorIdx: Int, newIdx: Int)
        case inserted(newIdx: Int)
        case deleted(priorIdx: Int)
    }

    /// The plan produced by `diffDocuments` and consumed by the
    /// applier. Exposed publicly so tests can inspect it without
    /// driving a full apply.
    public struct EditPlan: Equatable {
        public let changes: [BlockChange]
        /// The indices in `priorDoc.blocks` that are touched by the
        /// plan (modified or deleted). Empty when no blocks change.
        public let touchedPriorIndices: [Int]
        /// The indices in `newDoc.blocks` that replace the touched
        /// prior indices (modified or inserted). Empty when no blocks
        /// change.
        public let touchedNewIndices: [Int]
    }

    /// Summary of what the applier did, returned for test assertions
    /// and DEBUG instrumentation.
    public struct ApplyReport: Equatable {
        /// Element indices (in `priorDoc.blocks` coordinates) whose
        /// backing characters were replaced in place.
        public let elementsChanged: [Int]
        /// Element indices (in `newDoc.blocks` coordinates) whose
        /// blocks did not exist in `priorDoc`.
        public let elementsInserted: [Int]
        /// Element indices (in `priorDoc.blocks` coordinates) whose
        /// blocks do not exist in `newDoc`.
        public let elementsDeleted: [Int]
        /// The storage range (in the PRIOR rendered string) that was
        /// replaced. `nil` when no change was applied (docs equal).
        public let replacedRange: NSRange?
        /// Net change in storage length.
        public let totalLenDelta: Int
        /// True when `priorDoc == newDoc` and no transaction ran.
        public let wasNoop: Bool
    }

    /// Apply the minimal element-level edit transforming `priorDoc`
    /// into `newDoc` on the given `NSTextContentStorage`. The content
    /// storage is expected to already contain the rendered output of
    /// `priorDoc` (i.e. `contentStorage.textStorage?.length` matches
    /// `DocumentRenderer.render(priorDoc, …).attributed.length`).
    ///
    /// The mutation runs inside a single
    /// `performEditingTransaction`. Elements whose character ranges
    /// are not touched by the replacement are not re-queried or
    /// re-created by TK2 — that is the element-level-bounded redraw
    /// property the primitive guarantees.
    ///
    /// - Parameters:
    ///   - priorDoc: document currently rendered in `contentStorage`.
    ///   - newDoc: target document.
    ///   - contentStorage: the TK2 `NSTextContentStorage`. Its
    ///     `textStorage` backing store is mutated via
    ///     `replaceCharacters(in:with:)`.
    ///   - bodyFont, codeFont: passed to `DocumentRenderer.render` so
    ///     the rendering matches what the content storage currently
    ///     holds.
    ///   - note: optional `Note` threaded through `DocumentRenderer`
    ///     for relative-path resolution. Pass the same value that
    ///     produced the prior render.
    ///   - priorEditingBlocks: Code-Block Edit Toggle (slice 1) —
    ///     the set of `BlockRef`s that were in EDITING form in the
    ///     prior render. Pass the same set the caller used on the
    ///     previous `applyDocumentEdit` / initial `fillViaBlockModel`
    ///     call (or `[]` if none). Default `[]` keeps existing
    ///     callers source-compatible.
    ///   - newEditingBlocks: the set of `BlockRef`s that should be in
    ///     EDITING form in the NEW render. When `priorDoc == newDoc`
    ///     and `priorEditingBlocks != newEditingBlocks`, the toggled
    ///     blocks' rendered bytes differ between prior and new renders,
    ///     so the existing LCS diff naturally picks them up as
    ///     `.modified` and replaces just their spans — no separate
    ///     toggle-write path. Default `[]` keeps existing callers
    ///     source-compatible.
    /// - Returns: a summary of the operation for test assertions and
    ///   logging.
    @discardableResult
    public static func applyDocumentEdit(
        priorDoc: Document,
        newDoc: Document,
        contentStorage: NSTextContentStorage,
        bodyFont: PlatformFont,
        codeFont: PlatformFont,
        note: Note? = nil,
        priorEditingBlocks: Set<BlockRef> = [],
        newEditingBlocks: Set<BlockRef> = [],
        priorRenderedOverride: RenderedDocument? = nil
    ) -> ApplyReport {
        var plan = diffDocuments(priorDoc: priorDoc, newDoc: newDoc)

        // Code-Block Edit Toggle (slice 1): the LCS diff compares
        // `Block` values only; it has no view into the editing-form
        // state. When a block is `.unchanged` on both sides (same
        // `Block` value, same index) but its membership in the
        // editing set CHANGED across the two renders, the rendered
        // bytes still differ. Promote those entries to `.modified`
        // so the applier re-renders just their spans. This is the
        // single source of truth for "toggle a block's edit form"
        // — there is no separate toggle-write path.
        if priorEditingBlocks != newEditingBlocks {
            plan = promoteToggledBlocksToModified(
                plan: plan,
                priorDoc: priorDoc,
                newDoc: newDoc,
                priorEditingBlocks: priorEditingBlocks,
                newEditingBlocks: newEditingBlocks
            )
        }

        // Fast path: identical documents — no transaction, no log.
        if plan.touchedPriorIndices.isEmpty && plan.touchedNewIndices.isEmpty {
            let report = ApplyReport(
                elementsChanged: [],
                elementsInserted: [],
                elementsDeleted: [],
                replacedRange: nil,
                totalLenDelta: 0,
                wasNoop: true
            )
            #if DEBUG
            logEdit(report: report)
            #endif
            return report
        }

        // Re-render both documents via the same renderer used at
        // fill time. `DocumentRenderer.render` is pure, so the prior
        // render matches whatever is currently in storage (so long as
        // the caller held the render invariant when they last called
        // `applyDocumentEdit` or the initial `fillViaBlockModel`).
        //
        // Callers that own a `DocumentProjection` whose rendered form
        // has been patched out-of-band (e.g. the async inline-math
        // renderer swaps source chars for an attachment and mutates
        // `proj.rendered.{attributed,blockSpans}` accordingly without
        // updating `proj.document`) can pass `priorRenderedOverride`
        // to tell the applier "this is the current storage layout,
        // don't re-render". In that case `priorDoc` is still used
        // for the LCS diff, but span-offset math uses the override.
        // This is the only sanctioned way to address the drift that
        // arises between `proj.document` and `proj.rendered` — see
        // ARCHITECTURE.md → "Async inline-math hydration" for the
        // full story.
        let priorRendered: RenderedDocument
        if let override = priorRenderedOverride {
            priorRendered = override
        } else {
            priorRendered = DocumentRenderer.render(
                priorDoc,
                bodyFont: bodyFont,
                codeFont: codeFont,
                note: note,
                editingCodeBlocks: priorEditingBlocks
            )
        }
        let newRendered = DocumentRenderer.render(
            newDoc,
            bodyFont: bodyFont,
            codeFont: codeFont,
            note: note,
            editingCodeBlocks: newEditingBlocks
        )

        // Minimal affected range: from the first changed prior block's
        // span start to the last changed prior block's span end.
        // Inclusive of the inter-block separator trailing the last
        // changed prior block when that separator's "ownership" shifts
        // across the edit (e.g. a deleted block took its separator
        // with it). We compute this by extending the replaced range
        // to the start of the FIRST unchanged tail block (if any) in
        // the prior render — this is the safest "element-bounded"
        // range that keeps inter-block separators tidy.
        let (priorRange, newRange) = computeReplacementRanges(
            plan: plan,
            priorRendered: priorRendered,
            newRendered: newRendered
        )

        // Replacement substring in the NEW rendered attributed string.
        let initialReplacement: NSAttributedString
        if newRange.length > 0 {
            initialReplacement = newRendered.attributed.attributedSubstring(from: newRange)
        } else {
            initialReplacement = NSAttributedString(string: "")
        }

        // Apply inside a single editing transaction. This is the TK2
        // contract — the content storage batches delegate callbacks
        // and layout invalidation across the whole transaction.
        guard let textStorage = contentStorage.textStorage else {
            let report = ApplyReport(
                elementsChanged: plan.changes.compactMap {
                    if case .modified(let p, _) = $0 { return p }
                    return nil
                },
                elementsInserted: plan.changes.compactMap {
                    if case .inserted(let n) = $0 { return n }
                    return nil
                },
                elementsDeleted: plan.changes.compactMap {
                    if case .deleted(let p) = $0 { return p }
                    return nil
                },
                replacedRange: priorRange,
                totalLenDelta: 0,
                wasNoop: false
            )
            #if DEBUG
            logEdit(report: report, extra: "⚠️ no textStorage — transaction skipped")
            #endif
            return report
        }

        // bd-fsnotes-ibj: character-level narrowing on top of the
        // block-level priorRange / replacement. The block-level range
        // covers the entire affected block (e.g. the whole list block
        // when one item changes), so a one-character typing edit
        // produces a `replaceCharacters` covering hundreds of chars —
        // every fragment in that range gets invalidated, every
        // attachment view-provider unmounts and remounts on the next
        // layout pass. User-visible: bullets/checkboxes briefly
        // disappear on every keystroke ("META glyph wipe" — fsnotes-ibj).
        //
        // Narrowing the splice to ONLY the actually-changed bytes means
        // TK2 only invalidates the one fragment containing the typed
        // char — the bullets and checkboxes in unchanged paragraphs
        // never go through unmount/remount.
        //
        // U+FFFC (attachment character) is treated as common when both
        // sides have it at the corresponding position. This is safe:
        // NSAttributedString interns `isEqual` attachment values, so
        // the original instance survives the `replaceCharacters` call
        // anyway — the narrowing just keeps TK2 from invalidating its
        // hosting fragment.
        let (narrowedPrior, narrowedReplacement) = narrowSpliceAtCharacterLevel(
            priorRange: priorRange,
            replacement: initialReplacement,
            textStorage: textStorage
        )
        let priorRangeForReport = priorRange  // pre-narrow, for ApplyReport

        let preLen = textStorage.length
        // Phase 5a: mark this mutation as authorized so the debug
        // assertion in `TextStorageProcessor.didProcessEditing` sees
        // an active write scope. Release builds use the same wrapper
        // — the flag flip is cheap and keeps the primitive honest
        // across all build configurations.
        StorageWriteGuard.performingApplyDocumentEdit {
            contentStorage.performEditingTransaction {
                // Clamp the prior range against the current storage length.
                // In normal use the lengths match exactly; the clamp guards
                // against call-site drift (a caller that invoked
                // applyDocumentEdit on a stale priorDoc).
                let clampedLoc = max(0, min(narrowedPrior.location, textStorage.length))
                let clampedLen = max(0, min(narrowedPrior.length, textStorage.length - clampedLoc))
                let clampedRange = NSRange(location: clampedLoc, length: clampedLen)
                textStorage.replaceCharacters(in: clampedRange, with: narrowedReplacement)
            }
        }
        let postLen = textStorage.length

        let elementsChanged = plan.changes.compactMap { c -> Int? in
            if case .modified(let p, _) = c { return p }
            return nil
        }
        let elementsInserted = plan.changes.compactMap { c -> Int? in
            if case .inserted(let n) = c { return n }
            return nil
        }
        let elementsDeleted = plan.changes.compactMap { c -> Int? in
            if case .deleted(let p) = c { return p }
            return nil
        }
        let report = ApplyReport(
            elementsChanged: elementsChanged,
            elementsInserted: elementsInserted,
            elementsDeleted: elementsDeleted,
            replacedRange: priorRangeForReport,
            totalLenDelta: postLen - preLen,
            wasNoop: false
        )
        #if DEBUG
        logEdit(report: report)
        #endif
        return report
    }

    // MARK: - Splice narrowing (fsnotes-ibj)

    /// Shrink a block-level splice to the actual changed character span.
    ///
    /// `priorRange` and `replacement` start out as the entire affected
    /// block range (computed from `EditPlan` block-level diff). For a
    /// one-character edit inside a multi-item list block, that's
    /// hundreds of bytes — `replaceCharacters` on that wide range
    /// invalidates every fragment in the block, which TK2 turns into
    /// per-fragment unmount + remount of every attachment view-provider.
    /// The user sees that as bullets/checkboxes blinking on every
    /// keystroke (fsnotes-ibj).
    ///
    /// Narrowing finds the longest common prefix and longest common
    /// suffix between `textStorage[priorRange]` and `replacement` at
    /// the character level. The narrowed splice covers only the
    /// difference. Untouched paragraphs in the same block are no
    /// longer in the splice range, so TK2 doesn't invalidate their
    /// fragments — bullets and checkboxes in those paragraphs keep
    /// their mounted view providers across the edit.
    ///
    /// **Why character-only comparison.** Attribute objects (attachments,
    /// paragraph styles) from a fresh `DocumentRenderer.render(...)`
    /// are different instances from the ones already in storage, even
    /// when they're `isEqual`. Comparing attribute identity would
    /// break the prefix at offset 0 (different `BulletTextAttachment`
    /// instances), defeating the purpose. Character-only comparison
    /// treats both attachment characters as common — and
    /// `NSAttributedString` interns `isEqual` attachment values during
    /// `replaceCharacters`, so the original attachment instance
    /// survives the splice anyway. The narrowing's job is to keep
    /// TK2 from invalidating the hosting fragment, not to preserve
    /// instance identity (which is already preserved).
    ///
    /// **No-op cases.** If either side is empty (pure insert / pure
    /// delete) or no common prefix/suffix exists, returns
    /// `(priorRange, replacement)` unchanged.
    private static func narrowSpliceAtCharacterLevel(
        priorRange: NSRange,
        replacement: NSAttributedString,
        textStorage: NSTextStorage
    ) -> (NSRange, NSAttributedString) {
        // Cheap early exits.
        if priorRange.length == 0 || replacement.length == 0 {
            return (priorRange, replacement)
        }
        let storageLen = textStorage.length
        let priorEnd = priorRange.location + priorRange.length
        guard priorRange.location >= 0, priorEnd <= storageLen else {
            return (priorRange, replacement)
        }

        let oldNS = (textStorage.string as NSString).substring(
            with: priorRange
        ) as NSString
        let newNS = replacement.string as NSString
        let oldLen = oldNS.length
        let newLen = newNS.length
        let minLen = min(oldLen, newLen)

        // Common prefix at character (UTF-16) level.
        var prefix = 0
        while prefix < minLen
            && oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }

        // Common suffix — never overlapping the prefix range on either
        // side (so a string like "abab" doesn't double-count its tail).
        var suffix = 0
        while suffix < (minLen - prefix)
            && oldNS.character(at: oldLen - 1 - suffix)
                == newNS.character(at: newLen - 1 - suffix) {
            suffix += 1
        }

        if prefix == 0 && suffix == 0 {
            return (priorRange, replacement)
        }

        let narrowPriorLen = oldLen - prefix - suffix
        let narrowPriorRange = NSRange(
            location: priorRange.location + prefix,
            length: narrowPriorLen
        )
        let narrowReplacementLen = newLen - prefix - suffix
        let narrowReplacement: NSAttributedString
        if narrowReplacementLen > 0 {
            narrowReplacement = replacement.attributedSubstring(
                from: NSRange(location: prefix, length: narrowReplacementLen)
            )
        } else {
            narrowReplacement = NSAttributedString(string: "")
        }
        return (narrowPriorRange, narrowReplacement)
    }

    // MARK: - Diff

    /// Compute the edit plan transforming `priorDoc` into `newDoc`.
    /// Exposed for tests; production callers go through
    /// `applyDocumentEdit`.
    public static func diffDocuments(
        priorDoc: Document, newDoc: Document
    ) -> EditPlan {
        let prior = priorDoc.blocks
        let next = newDoc.blocks

        // Longest-common-subsequence DP on block value equality.
        // O(M·N) time and space. M and N are typically under a few
        // hundred for real notes; Phase 3's perf exit criterion is
        // <10% regression on the corpus and this fits comfortably.
        let m = prior.count
        let n = next.count
        var dp = Array(
            repeating: Array(repeating: 0, count: n + 1),
            count: m + 1
        )
        for i in 0..<m {
            for j in 0..<n {
                if prior[i] == next[j] {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i][j + 1], dp[i + 1][j])
                }
            }
        }

        // Backtrace into an ordered change list (in priorDoc order).
        var changes: [BlockChange] = []
        var i = m
        var j = n
        while i > 0 && j > 0 {
            if prior[i - 1] == next[j - 1] {
                changes.append(.unchanged(priorIdx: i - 1, newIdx: j - 1))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                changes.append(.deleted(priorIdx: i - 1))
                i -= 1
            } else {
                changes.append(.inserted(newIdx: j - 1))
                j -= 1
            }
        }
        while i > 0 {
            changes.append(.deleted(priorIdx: i - 1))
            i -= 1
        }
        while j > 0 {
            changes.append(.inserted(newIdx: j - 1))
            j -= 1
        }
        changes.reverse()

        // Post-pass: merge adjacent (delete, insert) / (insert, delete)
        // of the SAME block kind into a `.modified`. This is the
        // "typing into paragraph N" case — without this pass, the LCS
        // emits "delete old N, insert new N" and the applier would
        // treat both as structural changes. With the merge, the
        // applier knows block N's slot still exists, which matters
        // for element-bounded redraw assertions.
        changes = mergeAdjacentDeleteInsertSameKind(
            changes, prior: prior, next: next
        )

        let touchedPrior = changes.compactMap { c -> Int? in
            switch c {
            case .modified(let p, _): return p
            case .deleted(let p): return p
            default: return nil
            }
        }
        let touchedNew = changes.compactMap { c -> Int? in
            switch c {
            case .modified(_, let n): return n
            case .inserted(let n): return n
            default: return nil
            }
        }
        return EditPlan(
            changes: changes,
            touchedPriorIndices: touchedPrior,
            touchedNewIndices: touchedNew
        )
    }

    // MARK: - Diff helpers

    /// Code-Block Edit Toggle (slice 1): promote `.unchanged` entries
    /// whose block is present on only one side of the editing set
    /// from `.unchanged` to `.modified`. Rebuild `touchedPriorIndices`
    /// / `touchedNewIndices` accordingly. Called when
    /// `priorEditingBlocks != newEditingBlocks` so the applier
    /// re-renders just the toggled blocks' spans.
    ///
    /// A `.unchanged(priorIdx, newIdx)` entry is toggled when:
    /// - the prior block is in `priorEditingBlocks` and the new block
    ///   is NOT in `newEditingBlocks` (editing → rendered), OR
    /// - the prior block is NOT in `priorEditingBlocks` and the new
    ///   block IS in `newEditingBlocks` (rendered → editing).
    ///
    /// When both sides are in the set (or both sides out), the
    /// rendered bytes are byte-identical so no promotion is needed.
    private static func promoteToggledBlocksToModified(
        plan: EditPlan,
        priorDoc: Document,
        newDoc: Document,
        priorEditingBlocks: Set<BlockRef>,
        newEditingBlocks: Set<BlockRef>
    ) -> EditPlan {
        var changed: [BlockChange] = []
        changed.reserveCapacity(plan.changes.count)
        for c in plan.changes {
            if case .unchanged(let p, let n) = c,
               p >= 0, p < priorDoc.blocks.count,
               n >= 0, n < newDoc.blocks.count {
                let priorBlock = priorDoc.blocks[p]
                let newBlock = newDoc.blocks[n]
                let priorRef = BlockRef(priorBlock)
                let newRef = BlockRef(newBlock)
                let priorInSet = priorEditingBlocks.contains(priorRef)
                let newInSet = newEditingBlocks.contains(newRef)
                if priorInSet != newInSet {
                    changed.append(.modified(priorIdx: p, newIdx: n))
                    continue
                }
            }
            changed.append(c)
        }

        let touchedPrior = changed.compactMap { c -> Int? in
            switch c {
            case .modified(let p, _): return p
            case .deleted(let p):     return p
            default:                  return nil
            }
        }
        let touchedNew = changed.compactMap { c -> Int? in
            switch c {
            case .modified(_, let n): return n
            case .inserted(let n):    return n
            default:                  return nil
            }
        }
        return EditPlan(
            changes: changed,
            touchedPriorIndices: touchedPrior,
            touchedNewIndices: touchedNew
        )
    }

    /// Fold adjacent `(delete priorIdx, insert newIdx)` or
    /// `(insert newIdx, delete priorIdx)` pairs of the SAME block
    /// kind into a single `.modified` entry. Applied after the LCS
    /// backtrace so the change list is as close to "one modify per
    /// user-visible action" as the primitive can report without
    /// block identity tracking.
    private static func mergeAdjacentDeleteInsertSameKind(
        _ input: [BlockChange],
        prior: [Block], next: [Block]
    ) -> [BlockChange] {
        var out: [BlockChange] = []
        out.reserveCapacity(input.count)
        var idx = 0
        while idx < input.count {
            let cur = input[idx]
            if idx + 1 < input.count {
                let nxt = input[idx + 1]
                if case .deleted(let p) = cur, case .inserted(let n) = nxt,
                   sameKind(priorIdx: p, newIdx: n, prior: prior, next: next) {
                    out.append(.modified(priorIdx: p, newIdx: n))
                    idx += 2
                    continue
                }
                if case .inserted(let n) = cur, case .deleted(let p) = nxt,
                   sameKind(priorIdx: p, newIdx: n, prior: prior, next: next) {
                    out.append(.modified(priorIdx: p, newIdx: n))
                    idx += 2
                    continue
                }
            }
            out.append(cur)
            idx += 1
        }
        return out
    }

    private static func sameKind(
        priorIdx: Int, newIdx: Int, prior: [Block], next: [Block]
    ) -> Bool {
        guard priorIdx >= 0, priorIdx < prior.count,
              newIdx >= 0, newIdx < next.count else { return false }
        return blockKindTag(prior[priorIdx]) == blockKindTag(next[newIdx])
    }

    /// Stable per-kind tag for structural matching. Associated values
    /// are intentionally ignored — two paragraphs with different
    /// inlines map to the same tag, so the merge pass can promote
    /// them from delete+insert to modify.
    private static func blockKindTag(_ block: Block) -> String {
        switch block {
        case .codeBlock:       return "codeBlock"
        case .heading:         return "heading"
        case .paragraph:       return "paragraph"
        case .list:            return "list"
        case .blockquote:      return "blockquote"
        case .horizontalRule:  return "horizontalRule"
        case .htmlBlock:       return "htmlBlock"
        case .table:           return "table"
        case .blankLine:       return "blankLine"
        }
    }

    // MARK: - Range math

    /// Compute the replacement ranges: the character range in the
    /// prior rendered string that will be replaced, and the
    /// corresponding range in the new rendered string that supplies
    /// the replacement content.
    ///
    /// Convention: the range for each side covers
    /// `[firstChanged ... lastChanged]` blocks plus the inter-block
    /// separator that follows the last changed block when there's an
    /// unchanged block after it on that side; OR the separator that
    /// precedes the first changed block when there's an unchanged
    /// block before AND no unchanged-after (end-of-document edit).
    /// Middle-of-document edits consume the trailing separator;
    /// end-of-document edits consume the leading separator. This
    /// keeps the unchanged prefix and suffix character-identical
    /// across the edit, including the separator characters they
    /// bound.
    ///
    /// Empty bands (pure insert on prior side, pure delete on new
    /// side) anchor at the span-start of the following unchanged
    /// block on that side; or at the document's `totalLength` if
    /// there is no following unchanged block.
    private static func computeReplacementRanges(
        plan: EditPlan,
        priorRendered: RenderedDocument,
        newRendered: RenderedDocument
    ) -> (prior: NSRange, new: NSRange) {
        let changes = plan.changes

        // Collect touched band per side. Absent → empty band on that
        // side (pure insert or pure delete for that doc).
        let priorTouched = changes.compactMap { c -> Int? in
            switch c {
            case .modified(let p, _): return p
            case .deleted(let p):     return p
            default:                  return nil
            }
        }
        let newTouched = changes.compactMap { c -> Int? in
            switch c {
            case .modified(_, let n): return n
            case .inserted(let n):    return n
            default:                  return nil
            }
        }

        let priorRange = computeSideRange(
            touched: priorTouched,
            indexOfUnchangedAfter: anyUnchangedAfterBand(
                touched: priorTouched,
                unchanged: changes.compactMap { c -> Int? in
                    if case .unchanged(let p, _) = c { return p }
                    return nil
                }
            ),
            indexOfUnchangedBefore: anyUnchangedBeforeBand(
                touched: priorTouched,
                unchanged: changes.compactMap { c -> Int? in
                    if case .unchanged(let p, _) = c { return p }
                    return nil
                }
            ),
            followingUnchangedAnchor: firstUnchangedPriorAfterBand(
                touched: priorTouched, changes: changes
            ),
            rendered: priorRendered
        )

        let newRange = computeSideRange(
            touched: newTouched,
            indexOfUnchangedAfter: anyUnchangedAfterBand(
                touched: newTouched,
                unchanged: changes.compactMap { c -> Int? in
                    if case .unchanged(_, let n) = c { return n }
                    return nil
                }
            ),
            indexOfUnchangedBefore: anyUnchangedBeforeBand(
                touched: newTouched,
                unchanged: changes.compactMap { c -> Int? in
                    if case .unchanged(_, let n) = c { return n }
                    return nil
                }
            ),
            followingUnchangedAnchor: firstUnchangedNewAfterBand(
                touched: newTouched, changes: changes
            ),
            rendered: newRendered
        )

        return (priorRange, newRange)
    }

    /// Compute a side's storage range given:
    /// - `touched`: the band of changed block indices on this side
    ///   (sorted ascending; empty for pure insert/delete).
    /// - `indexOfUnchangedAfter`: does any unchanged block come AFTER
    ///   the band on this side?
    /// - `indexOfUnchangedBefore`: does any unchanged block come
    ///   BEFORE the band on this side?
    /// - `followingUnchangedAnchor`: the block index on this side of
    ///   the FIRST unchanged block after the band (used only for
    ///   empty-band anchoring).
    /// - `rendered`: the full renders of this side's document.
    private static func computeSideRange(
        touched: [Int],
        indexOfUnchangedAfter hasUnchangedAfter: Bool,
        indexOfUnchangedBefore hasUnchangedBefore: Bool,
        followingUnchangedAnchor: Int?,
        rendered: RenderedDocument
    ) -> NSRange {
        let totalLen = rendered.attributed.length
        if touched.isEmpty {
            // Empty band: anchor at the start of the following
            // unchanged block (if any), else at the end of the doc.
            if let anchorIdx = followingUnchangedAnchor,
               anchorIdx >= 0,
               anchorIdx < rendered.blockSpans.count {
                return NSRange(
                    location: rendered.blockSpans[anchorIdx].location,
                    length: 0
                )
            }
            return NSRange(location: totalLen, length: 0)
        }
        let f = touched.min()!
        let l = touched.max()!
        guard f >= 0, l < rendered.blockSpans.count else {
            // Defensive: band indices out of range. Return
            // end-of-document empty splice so we at least don't
            // corrupt storage.
            return NSRange(location: totalLen, length: 0)
        }
        var start = rendered.blockSpans[f].location
        var end = rendered.blockSpans[l].location + rendered.blockSpans[l].length

        if hasUnchangedAfter {
            // Consume trailing separator. Always a "\n" at end in
            // this case (the renderer emits a single "\n" between
            // consecutive blocks).
            if end < totalLen { end += 1 }
        } else {
            // Band extends to end of doc on this side. Consume the
            // leading separator if there's an unchanged-before to
            // attach it to (keeps the prefix character-identical
            // across the splice).
            if hasUnchangedBefore, start > 0 { start -= 1 }
            // Also include the document's trailing newline, if any
            // — it hangs off the last block and must be re-emitted
            // by the replacement attributed substring from the new
            // side's equivalent range.
            if end < totalLen { end = totalLen }
        }

        return NSRange(location: start, length: end - start)
    }

    private static func anyUnchangedAfterBand(
        touched: [Int], unchanged: [Int]
    ) -> Bool {
        guard let maxTouched = touched.max() else {
            // Empty band — consider "after" relative to the
            // preceding unchanged block if any.
            return !unchanged.isEmpty
        }
        return unchanged.contains { $0 > maxTouched }
    }

    private static func anyUnchangedBeforeBand(
        touched: [Int], unchanged: [Int]
    ) -> Bool {
        guard let minTouched = touched.min() else {
            // Empty band — consider "before" relative to the
            // following unchanged block if any.
            return !unchanged.isEmpty
        }
        return unchanged.contains { $0 < minTouched }
    }

    private static func firstUnchangedPriorAfterBand(
        touched: [Int], changes: [BlockChange]
    ) -> Int? {
        if let maxTouched = touched.max() {
            for c in changes {
                if case .unchanged(let p, _) = c, p > maxTouched {
                    return p
                }
            }
            return nil
        }
        // Empty band on this side (pure insert on prior, or pure
        // delete on new). The anchor is the first unchanged entry in
        // the plan that comes AFTER at least one insert/delete —
        // i.e. the unchanged block immediately following the band
        // position.
        var sawNonUnchanged = false
        for c in changes {
            switch c {
            case .unchanged(let p, _):
                if sawNonUnchanged { return p }
            default:
                sawNonUnchanged = true
            }
        }
        return nil
    }

    private static func firstUnchangedNewAfterBand(
        touched: [Int], changes: [BlockChange]
    ) -> Int? {
        if let maxTouched = touched.max() {
            for c in changes {
                if case .unchanged(_, let n) = c, n > maxTouched {
                    return n
                }
            }
            return nil
        }
        var sawNonUnchanged = false
        for c in changes {
            switch c {
            case .unchanged(_, let n):
                if sawNonUnchanged { return n }
            default:
                sawNonUnchanged = true
            }
        }
        return nil
    }

    // MARK: - DEBUG instrumentation

    #if DEBUG
    /// Log file for element-level edit diagnostics. Mirrors the
    /// convention used by `bmLog`: a gitignored `logs/` directory at
    /// the project root, single file per subsystem, appended to on
    /// each call. Release builds never hit this code path — the whole
    /// function lives inside `#if DEBUG`.
    private static let elementEditLogURL: URL = {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile
            .deletingLastPathComponent()  // .../Rendering/
            .deletingLastPathComponent()  // .../FSNotesCore/
            .deletingLastPathComponent()  // .../<project root>/
        let logsDir = projectRoot.appendingPathComponent("logs")
        // Primary: write to <project-root>/logs/. If the sandbox or
        // filesystem perms reject the directory (test hosts launched
        // from DerivedData are often sandboxed to their container),
        // fall back to NSTemporaryDirectory() so DEBUG runs still
        // get a log. The fallback path is stable across invocations
        // and discoverable via `find $TMPDIR -name element-edits.log`.
        do {
            try FileManager.default.createDirectory(
                at: logsDir, withIntermediateDirectories: true
            )
            // Probe writability with a zero-byte touch.
            let probe = logsDir.appendingPathComponent(".write-probe")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return logsDir.appendingPathComponent("element-edits.log")
        } catch {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fsnotes-logs", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: tmp, withIntermediateDirectories: true
            )
            return tmp.appendingPathComponent("element-edits.log")
        }
    }()

    private static let elementEditLogFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    private static func logEdit(report: ApplyReport, extra: String = "") {
        let ts = elementEditLogFormatter.string(from: Date())
        let changed = report.elementsChanged
            .map { String($0) }.joined(separator: ",")
        let inserted = report.elementsInserted
            .map { String($0) }.joined(separator: ",")
        let deleted = report.elementsDeleted
            .map { String($0) }.joined(separator: ",")
        let rangeStr: String
        if let r = report.replacedRange {
            rangeStr = "[\(r.location),\(r.length)]"
        } else {
            rangeStr = "nil"
        }
        var line = "[\(ts)] elementsChanged=[\(changed)]" +
                   " elementsInserted=[\(inserted)]" +
                   " elementsDeleted=[\(deleted)]" +
                   " replacedRange=\(rangeStr)" +
                   " totalLenDelta=\(report.totalLenDelta)" +
                   " noop=\(report.wasNoop)"
        if !extra.isEmpty { line += " note=\"\(extra)\"" }
        line += "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: elementEditLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: elementEditLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: elementEditLogURL)
        }
    }
    #endif
}

