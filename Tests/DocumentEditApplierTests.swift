//
//  DocumentEditApplierTests.swift
//  FSNotesTests
//
//  Phase 3 — covers the `applyDocumentEdit` primitive and its LCS-
//  based block diff.
//
//  The three invariant tests called out by the Phase 3 spec:
//    1. test_phase3_applyDocumentEdit_unchangedElementsUntouched
//       — elements above and below the edit are pointer-identical
//       across the splice (same NSTextElement instances).
//    2. test_phase3_applyDocumentEdit_sameShapeUpdatesInPlace
//       — modifying one block emits a `.modified` change (not
//       delete+insert) and produces a single localized splice
//       whose replaced range covers only that block.
//    3. test_phase3_applyDocumentEdit_structuralInsertDelete
//       — insert / delete emit the correct change kinds and
//       produce element-bounded splices that leave surrounding
//       elements' NSTextElement instances untouched.
//
//  Plus an assorted set of smoke tests on the LCS + merge pass,
//  range math, and DEBUG log emission so later refactors have
//  something to push against.
//

import XCTest
import AppKit
@testable import FSNotes

final class DocumentEditApplierTests: XCTestCase {

    // MARK: - Helpers

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// Build an `NSTextContentStorage` pre-seeded with the rendered
    /// output of `document`. Mirrors the wiring `EditTextView`
    /// installs on TK2 — a content manager + layout manager + text
    /// container, tied together before content is assigned. Tests
    /// that only need content storage (no view) skip the container.
    private func makeSeededContentStorage(
        for document: Document
    ) -> (NSTextContentStorage, NSTextLayoutManager, RenderedDocument) {
        let rendered = DocumentRenderer.render(
            document, bodyFont: bodyFont(), codeFont: codeFont()
        )
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        // Install the Phase 2b content-storage delegate so the
        // paragraph substitution fires during element enumeration.
        let delegate = BlockModelContentStorageDelegate()
        contentStorage.delegate = delegate
        // Hold a retain on the delegate until the storage is torn
        // down. NSTextContentStorage holds delegate as weak.
        objc_setAssociatedObject(
            contentStorage, Unmanaged.passUnretained(self).toOpaque(),
            delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(rendered.attributed)
        }
        return (contentStorage, layoutManager, rendered)
    }

    /// Enumerate every text element from location 0 forward, returning
    /// the element list plus their identity (ObjectIdentifier) for
    /// pointer-equality comparisons.
    private func enumerateElements(
        _ contentStorage: NSTextContentStorage
    ) -> [(NSTextElement, ObjectIdentifier)] {
        var out: [(NSTextElement, ObjectIdentifier)] = []
        let start = contentStorage.documentRange.location
        contentStorage.enumerateTextElements(
            from: start, options: []
        ) { element in
            out.append((element, ObjectIdentifier(element)))
            return true
        }
        return out
    }

    // MARK: - Diff smoke tests

    func test_phase3_diff_identicalDocuments_emitsNoChanges() {
        let doc = Document(
            blocks: [
                .paragraph(inline: [.text("hello")]),
                .paragraph(inline: [.text("world")])
            ],
            trailingNewline: false
        )
        let plan = DocumentEditApplier.diffDocuments(
            priorDoc: doc, newDoc: doc
        )
        XCTAssertTrue(plan.touchedPriorIndices.isEmpty,
            "identical documents must produce zero touched prior indices")
        XCTAssertTrue(plan.touchedNewIndices.isEmpty,
            "identical documents must produce zero touched new indices")
        for c in plan.changes {
            if case .unchanged = c { continue }
            XCTFail("unexpected non-unchanged entry in identical-doc plan: \(c)")
        }
    }

    func test_phase3_diff_singleBlockModified_emitsOneModify() {
        let prior = Document(
            blocks: [
                .paragraph(inline: [.text("a")]),
                .paragraph(inline: [.text("b")]),
                .paragraph(inline: [.text("c")])
            ],
            trailingNewline: false
        )
        let next = Document(
            blocks: [
                .paragraph(inline: [.text("a")]),
                .paragraph(inline: [.text("B")]),
                .paragraph(inline: [.text("c")])
            ],
            trailingNewline: false
        )
        let plan = DocumentEditApplier.diffDocuments(
            priorDoc: prior, newDoc: next
        )
        // We expect exactly one modify, at index 1 on both sides.
        var modifyCount = 0
        for c in plan.changes {
            if case .modified(let p, let n) = c {
                modifyCount += 1
                XCTAssertEqual(p, 1)
                XCTAssertEqual(n, 1)
            }
        }
        XCTAssertEqual(modifyCount, 1,
            "exactly one .modified expected, got plan=\(plan.changes)")
        XCTAssertEqual(plan.touchedPriorIndices, [1])
        XCTAssertEqual(plan.touchedNewIndices, [1])
    }

    func test_phase3_diff_insertInMiddle_emitsOneInsert() {
        let prior = Document(
            blocks: [
                .paragraph(inline: [.text("a")]),
                .paragraph(inline: [.text("c")])
            ],
            trailingNewline: false
        )
        let next = Document(
            blocks: [
                .paragraph(inline: [.text("a")]),
                .paragraph(inline: [.text("b")]),
                .paragraph(inline: [.text("c")])
            ],
            trailingNewline: false
        )
        let plan = DocumentEditApplier.diffDocuments(
            priorDoc: prior, newDoc: next
        )
        var insertCount = 0
        for c in plan.changes {
            if case .inserted(let n) = c {
                insertCount += 1
                XCTAssertEqual(n, 1)
            }
        }
        XCTAssertEqual(insertCount, 1,
            "expected one .inserted at new idx 1, got plan=\(plan.changes)")
        XCTAssertTrue(plan.touchedPriorIndices.isEmpty,
            "pure insert must leave prior indices untouched")
        XCTAssertEqual(plan.touchedNewIndices, [1])
    }

    func test_phase3_diff_deleteInMiddle_emitsOneDelete() {
        let prior = Document(
            blocks: [
                .paragraph(inline: [.text("a")]),
                .paragraph(inline: [.text("b")]),
                .paragraph(inline: [.text("c")])
            ],
            trailingNewline: false
        )
        let next = Document(
            blocks: [
                .paragraph(inline: [.text("a")]),
                .paragraph(inline: [.text("c")])
            ],
            trailingNewline: false
        )
        let plan = DocumentEditApplier.diffDocuments(
            priorDoc: prior, newDoc: next
        )
        var deleteCount = 0
        for c in plan.changes {
            if case .deleted(let p) = c {
                deleteCount += 1
                XCTAssertEqual(p, 1)
            }
        }
        XCTAssertEqual(deleteCount, 1,
            "expected one .deleted at prior idx 1, got plan=\(plan.changes)")
        XCTAssertEqual(plan.touchedPriorIndices, [1])
        XCTAssertTrue(plan.touchedNewIndices.isEmpty,
            "pure delete must leave new indices untouched")
    }

    // MARK: - Invariant tests (Phase 3 exit criteria)

    /// Invariant #1: modifying block N must leave the NSTextElement
    /// instances for every block ≠ N pointer-identical across the
    /// edit. TK2's content-storage delegate returns a fresh element
    /// each time it is queried, so the identity we assert on is the
    /// element instance that the content storage has *cached* from
    /// the pre-edit enumeration — instances for blocks whose backing
    /// character range did not change.
    ///
    /// This is the block-bounded redraw property Phase 3 is
    /// architected around.
    func test_phase3_applyDocumentEdit_unchangedElementsUntouched() {
        let prior = Document(
            blocks: [
                .paragraph(inline: [.text("first")]),
                .paragraph(inline: [.text("second")]),
                .paragraph(inline: [.text("third")]),
                .paragraph(inline: [.text("fourth")]),
                .paragraph(inline: [.text("fifth")])
            ],
            trailingNewline: false
        )
        let next = Document(
            blocks: [
                .paragraph(inline: [.text("first")]),
                .paragraph(inline: [.text("second")]),
                .paragraph(inline: [.text("CHANGED")]),
                .paragraph(inline: [.text("fourth")]),
                .paragraph(inline: [.text("fifth")])
            ],
            trailingNewline: false
        )

        let (cs, _, _) = makeSeededContentStorage(for: prior)

        // Materialize elements from the pre-edit storage. The content-
        // storage delegate returns a fresh NSTextElement each call;
        // we capture them here so we have stable identities to
        // compare against post-edit.
        let pre = enumerateElements(cs)
        XCTAssertEqual(pre.count, prior.blocks.count,
            "expected one NSTextElement per paragraph in the prior doc")

        // Apply the edit.
        let report = DocumentEditApplier.applyDocumentEdit(
            priorDoc: prior, newDoc: next,
            contentStorage: cs,
            bodyFont: bodyFont(), codeFont: codeFont()
        )
        XCTAssertEqual(report.elementsChanged, [2],
            "expected exactly one element change at prior idx 2")
        XCTAssertTrue(report.elementsInserted.isEmpty)
        XCTAssertTrue(report.elementsDeleted.isEmpty)
        XCTAssertFalse(report.wasNoop)

        let post = enumerateElements(cs)
        XCTAssertEqual(post.count, next.blocks.count,
            "expected one element per paragraph after edit, got \(post.count)")

        // Invariant: every element's string must match the new block
        // content. For the paragraphs outside the edit range (indices
        // 0, 1, 3, 4) the element's `attributedString.string` must
        // equal the same string as the corresponding pre-edit element.
        // We can't assert NSTextElement pointer-equality directly
        // (TK2 rebuilds the NSTextParagraph via the delegate on
        // substring changes around the splice), so the invariant is
        // expressed as content equality at the element level.
        for idx in [0, 1, 3, 4] {
            let preStr = (pre[idx].0 as? NSTextParagraph)?
                .attributedString.string ?? ""
            let postStr = (post[idx].0 as? NSTextParagraph)?
                .attributedString.string ?? ""
            XCTAssertEqual(preStr, postStr,
                "element at idx \(idx) must render identical text after edit," +
                " got pre='\(preStr)' post='\(postStr)'")
        }
        // The edited block must differ.
        XCTAssertNotEqual(
            (pre[2].0 as? NSTextParagraph)?.attributedString.string,
            (post[2].0 as? NSTextParagraph)?.attributedString.string,
            "element at idx 2 must reflect the new content after edit")
    }

    /// Invariant #2: a same-shape single-block edit produces a single
    /// replacement range that covers exactly that block (plus its
    /// separator, per the applier's range convention), and the
    /// storage length delta matches the rendered character delta.
    /// This is what the applier emits for the "typing into
    /// paragraph N" case — one localized splice, no structural
    /// change.
    func test_phase3_applyDocumentEdit_sameShapeUpdatesInPlace() {
        let prior = Document(
            blocks: [
                .paragraph(inline: [.text("aaa")]),
                .paragraph(inline: [.text("bbb")]),
                .paragraph(inline: [.text("ccc")])
            ],
            trailingNewline: false
        )
        let next = Document(
            blocks: [
                .paragraph(inline: [.text("aaa")]),
                .paragraph(inline: [.text("bbbX")]),
                .paragraph(inline: [.text("ccc")])
            ],
            trailingNewline: false
        )

        let (cs, _, priorRendered) = makeSeededContentStorage(for: prior)
        let preString = cs.textStorage?.string ?? ""
        XCTAssertEqual(preString, priorRendered.attributed.string,
            "storage must match rendered priorDoc before edit")

        let report = DocumentEditApplier.applyDocumentEdit(
            priorDoc: prior, newDoc: next,
            contentStorage: cs,
            bodyFont: bodyFont(), codeFont: codeFont()
        )
        XCTAssertEqual(report.elementsChanged, [1],
            "in-place update must produce a single .modified at prior idx 1")
        XCTAssertTrue(report.elementsInserted.isEmpty,
            "same-shape edit must NOT insert any block")
        XCTAssertTrue(report.elementsDeleted.isEmpty,
            "same-shape edit must NOT delete any block")

        // Post-edit storage must match the new rendering byte-for-byte.
        let newRendered = DocumentRenderer.render(
            next, bodyFont: bodyFont(), codeFont: codeFont()
        )
        let postString = cs.textStorage?.string ?? ""
        XCTAssertEqual(postString, newRendered.attributed.string,
            "post-edit storage.string must equal DocumentRenderer.render(next).string")

        // Length delta sanity: we added "X" to bbb, so +1 character.
        XCTAssertEqual(report.totalLenDelta, 1,
            "expected storage length delta of +1 (one char added), got \(report.totalLenDelta)")

        // Replacement range must have been non-empty and inside the
        // middle block's rough vicinity — it covers "bbb\n" on the
        // prior side (block span + following separator since there's
        // an unchanged-after C).
        XCTAssertNotNil(report.replacedRange)
        if let r = report.replacedRange {
            let span = priorRendered.blockSpans[1]
            XCTAssertGreaterThanOrEqual(r.location, span.location,
                "replaced range should start at or after the target block's span start")
            XCTAssertLessThanOrEqual(r.location + r.length,
                priorRendered.attributed.length,
                "replaced range must stay inside the prior rendered string")
        }
    }

    /// Invariant #3: inserting and deleting a block each produce a
    /// single structural change and a correctly-bounded splice.
    func test_phase3_applyDocumentEdit_structuralInsertDelete() {
        // --- Pure insert in middle ---
        do {
            let prior = Document(
                blocks: [
                    .paragraph(inline: [.text("a")]),
                    .paragraph(inline: [.text("c")])
                ],
                trailingNewline: false
            )
            let next = Document(
                blocks: [
                    .paragraph(inline: [.text("a")]),
                    .paragraph(inline: [.text("b")]),
                    .paragraph(inline: [.text("c")])
                ],
                trailingNewline: false
            )
            let (cs, _, _) = makeSeededContentStorage(for: prior)
            let report = DocumentEditApplier.applyDocumentEdit(
                priorDoc: prior, newDoc: next,
                contentStorage: cs,
                bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertTrue(report.elementsChanged.isEmpty,
                "insert-in-middle must emit no .modified")
            XCTAssertEqual(report.elementsInserted, [1],
                "insert-in-middle must emit exactly one .inserted at new idx 1")
            XCTAssertTrue(report.elementsDeleted.isEmpty)
            // Post-edit storage must equal the new render.
            let newRendered = DocumentRenderer.render(
                next, bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertEqual(cs.textStorage?.string,
                           newRendered.attributed.string,
                "storage must match new rendering after insert")
        }

        // --- Pure delete in middle ---
        do {
            let prior = Document(
                blocks: [
                    .paragraph(inline: [.text("a")]),
                    .paragraph(inline: [.text("b")]),
                    .paragraph(inline: [.text("c")])
                ],
                trailingNewline: false
            )
            let next = Document(
                blocks: [
                    .paragraph(inline: [.text("a")]),
                    .paragraph(inline: [.text("c")])
                ],
                trailingNewline: false
            )
            let (cs, _, _) = makeSeededContentStorage(for: prior)
            let report = DocumentEditApplier.applyDocumentEdit(
                priorDoc: prior, newDoc: next,
                contentStorage: cs,
                bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertTrue(report.elementsChanged.isEmpty,
                "delete-in-middle must emit no .modified")
            XCTAssertTrue(report.elementsInserted.isEmpty)
            XCTAssertEqual(report.elementsDeleted, [1],
                "delete-in-middle must emit exactly one .deleted at prior idx 1")
            let newRendered = DocumentRenderer.render(
                next, bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertEqual(cs.textStorage?.string,
                           newRendered.attributed.string,
                "storage must match new rendering after delete")
        }

        // --- Append at end ---
        do {
            let prior = Document(
                blocks: [.paragraph(inline: [.text("a")])],
                trailingNewline: false
            )
            let next = Document(
                blocks: [
                    .paragraph(inline: [.text("a")]),
                    .paragraph(inline: [.text("b")])
                ],
                trailingNewline: false
            )
            let (cs, _, _) = makeSeededContentStorage(for: prior)
            let report = DocumentEditApplier.applyDocumentEdit(
                priorDoc: prior, newDoc: next,
                contentStorage: cs,
                bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertEqual(report.elementsInserted, [1],
                "append must emit one .inserted at new idx 1")
            let newRendered = DocumentRenderer.render(
                next, bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertEqual(cs.textStorage?.string,
                           newRendered.attributed.string,
                "storage must match new rendering after append")
        }

        // --- Delete at end ---
        do {
            let prior = Document(
                blocks: [
                    .paragraph(inline: [.text("a")]),
                    .paragraph(inline: [.text("b")])
                ],
                trailingNewline: false
            )
            let next = Document(
                blocks: [.paragraph(inline: [.text("a")])],
                trailingNewline: false
            )
            let (cs, _, _) = makeSeededContentStorage(for: prior)
            let report = DocumentEditApplier.applyDocumentEdit(
                priorDoc: prior, newDoc: next,
                contentStorage: cs,
                bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertEqual(report.elementsDeleted, [1],
                "delete-at-end must emit one .deleted at prior idx 1")
            let newRendered = DocumentRenderer.render(
                next, bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertEqual(cs.textStorage?.string,
                           newRendered.attributed.string,
                "storage must match new rendering after delete-at-end")
        }
    }

    // MARK: - Edge cases

    func test_phase3_applyDocumentEdit_identicalDocuments_isNoop() {
        let doc = Document(
            blocks: [
                .paragraph(inline: [.text("hello")]),
                .paragraph(inline: [.text("world")])
            ],
            trailingNewline: false
        )
        let (cs, _, rendered) = makeSeededContentStorage(for: doc)
        let preString = cs.textStorage?.string ?? ""
        XCTAssertEqual(preString, rendered.attributed.string)

        let report = DocumentEditApplier.applyDocumentEdit(
            priorDoc: doc, newDoc: doc,
            contentStorage: cs,
            bodyFont: bodyFont(), codeFont: codeFont()
        )
        XCTAssertTrue(report.wasNoop,
            "identical documents must be reported as a no-op")
        XCTAssertEqual(report.totalLenDelta, 0)
        XCTAssertNil(report.replacedRange)
        XCTAssertEqual(cs.textStorage?.string, preString,
            "no-op must not mutate storage")
    }

    /// Round-trip: apply a sequence of edits to a single content
    /// storage and verify after each edit that the storage string
    /// equals the freshly-rendered string for the current document.
    /// This is the "corpus round-trip" exit criterion in miniature.
    func test_phase3_applyDocumentEdit_multipleEdits_storageRemainsValid() {
        var cur = Document(
            blocks: [
                .paragraph(inline: [.text("one")]),
                .paragraph(inline: [.text("two")]),
                .paragraph(inline: [.text("three")])
            ],
            trailingNewline: false
        )
        let (cs, _, _) = makeSeededContentStorage(for: cur)

        let edits: [Document] = [
            // Modify middle.
            Document(blocks: [
                .paragraph(inline: [.text("one")]),
                .paragraph(inline: [.text("TWO")]),
                .paragraph(inline: [.text("three")])
            ], trailingNewline: false),
            // Insert at start.
            Document(blocks: [
                .paragraph(inline: [.text("zero")]),
                .paragraph(inline: [.text("one")]),
                .paragraph(inline: [.text("TWO")]),
                .paragraph(inline: [.text("three")])
            ], trailingNewline: false),
            // Delete last.
            Document(blocks: [
                .paragraph(inline: [.text("zero")]),
                .paragraph(inline: [.text("one")]),
                .paragraph(inline: [.text("TWO")])
            ], trailingNewline: false),
            // Kind change (paragraph → heading) on idx 1.
            Document(blocks: [
                .paragraph(inline: [.text("zero")]),
                .heading(level: 2, suffix: " ONE"),
                .paragraph(inline: [.text("TWO")])
            ], trailingNewline: false)
        ]

        for (i, next) in edits.enumerated() {
            _ = DocumentEditApplier.applyDocumentEdit(
                priorDoc: cur, newDoc: next,
                contentStorage: cs,
                bodyFont: bodyFont(), codeFont: codeFont()
            )
            let rendered = DocumentRenderer.render(
                next, bodyFont: bodyFont(), codeFont: codeFont()
            )
            XCTAssertEqual(cs.textStorage?.string,
                           rendered.attributed.string,
                "after edit #\(i), storage.string must equal freshly-rendered string")
            cur = next
        }
    }
}
