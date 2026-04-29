//
//  BugFsnotesibjTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-ibj (P1):
//  "META: bullet/Todo glyphs disappear during edit, reappear on scroll"
//
//  Verifiable property: NSTextAttachmentViewProvider instances
//  (BulletAttachmentViewProvider, CheckboxAttachmentViewProvider) hosted
//  by the editor must keep a non-nil drawn view across an in-place edit
//  to a *neighbouring* line. The bead reports glyphs vanishing during
//  edit and reappearing on scroll — i.e. the view provider's contents
//  are dropped between the edit applier and the next display pass.
//
//  Layer: in-process AppKit harness (per DEBUG.md §1). Per the plan's
//  tradeoff note, the in-process harness MAY miss the redraw race
//  because the view tree is sampled at a moment where the redraw
//  signal has already arrived. If this scaffold passes on a known-
//  broken commit, the bug requires the computer-use screenshot path
//  instead — capture before/after via running ~/Applications/FSNotes++
//  .app, attach to bd-fsnotes-ibj as visual evidence.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotesibjTests: XCTestCase {

    /// Three-item bullet list with one paragraph after, so we have
    /// neighbouring lines whose glyph attachments must survive edits.
    private static let markdown = """
    - alpha
    - beta
    - gamma

    paragraph
    """

    func test_bulletGlyphs_persistAcrossNeighbouringEdit() {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage,
              let tlm = harness.editor.textLayoutManager
        else {
            XCTFail("editor not initialised")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Snapshot 1: count bullet attachments before the edit.
        let bulletsBefore = countBulletAttachments(storage)
        XCTAssertEqual(
            bulletsBefore, 3,
            "expected 3 bullet attachments in seeded list"
        )

        // Position the caret at the end of the trailing paragraph and
        // type a character. The bullet attachments above must not be
        // disturbed by an edit several blocks away.
        let endOfDoc = NSRange(location: storage.length, length: 0)
        harness.editor.setSelectedRange(endOfDoc)
        harness.type("X")
        tlm.ensureLayout(for: tlm.documentRange)

        // Snapshot 2: count bullet attachments after the edit.
        let bulletsAfter = countBulletAttachments(storage)

        XCTAssertEqual(
            bulletsAfter, bulletsBefore,
            "bullet attachment count changed after neighbouring edit " +
            "(\(bulletsBefore) -> \(bulletsAfter)) — glyphs were dropped"
        )

        // Each surviving bullet attachment must be renderable —
        // either it carries a non-nil `.image` OR (TK2) it has a view
        // provider that returns a non-nil view via `loadView()`.
        var renderable = 0
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            guard let att = value as? NSTextAttachment else { return }
            let name = String(describing: type(of: att))
            guard name.contains("Bullet") else { return }
            if att.image != nil { renderable += 1; return }
            // TK2 path: ask the attachment for a view provider.
            // The viewProvider API takes parentView/textContainer/location,
            // so we synthesise plausible values from the harness.
            if let provider = att.viewProvider(
                for: harness.editor,
                location: NSTextLocation_dummy(),
                textContainer: harness.editor.textContainer
            ) {
                provider.loadView()
                if provider.view != nil { renderable += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(
            renderable, bulletsAfter,
            "at least \(bulletsAfter) bullet glyphs should remain " +
            "renderable post-edit, only \(renderable) did"
        )
    }

    /// QA 2026-04-29 (v3 / commit 63d3873): per-keystroke flicker on
    /// the bullet/checkbox of the line being typed in. Root cause is
    /// the block-level splice in `DocumentEditApplier` replacing the
    /// whole list block — including the leading bullet `U+FFFC` — on
    /// every keystroke, which drops TK2's cached view provider and
    /// forces `loadView()` again.
    ///
    /// Verifiable property: the `BulletTextAttachment` *object identity*
    /// at the start of an unchanged list item must survive a typing edit
    /// inside that same list block. If a fresh instance shows up at the
    /// same offset post-edit, TK2 has dropped the cached view provider
    /// and the user sees a flash. (Object identity is the cache key TK2
    /// uses, not value-equality.)
    func test_bulletAttachmentIdentity_preservedAcrossInListEdit() {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage,
              let tlm = harness.editor.textLayoutManager
        else {
            XCTFail("editor not initialised")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Snapshot the bullet attachment instances by storage offset
        // before the edit.
        let before = bulletAttachmentsByOffset(storage)
        XCTAssertEqual(before.count, 3,
                       "expected 3 bullet attachments before edit")

        // Park the caret AT THE END OF THE FIRST LIST ITEM ("alpha")
        // and type a single character. The first bullet attachment's
        // offset stays at 0; its instance must not be replaced.
        let alphaRange = (storage.string as NSString).range(of: "alpha")
        XCTAssertNotEqual(alphaRange.location, NSNotFound,
                          "expected 'alpha' in seeded markdown")
        let endOfAlpha = NSRange(
            location: alphaRange.location + alphaRange.length, length: 0
        )
        harness.editor.setSelectedRange(endOfAlpha)
        harness.type("X")
        tlm.ensureLayout(for: tlm.documentRange)

        let after = bulletAttachmentsByOffset(storage)
        XCTAssertEqual(after.count, before.count,
                       "bullet count changed (\(before.count) -> \(after.count))")

        // The bullets at offsets 0..2 (in the unchanged-prefix sense)
        // must be the *same instance* before and after. If any were
        // replaced, TK2's view-provider cache misses and the user sees
        // the per-keystroke flicker the bead reports. The first bullet
        // is the canary — its offset doesn't move on edits inside its
        // own list item.
        let firstBefore = before.min(by: { $0.key < $1.key })
        let firstAfter = after.min(by: { $0.key < $1.key })
        XCTAssertNotNil(firstBefore)
        XCTAssertNotNil(firstAfter)
        XCTAssertTrue(
            firstBefore?.value === firstAfter?.value,
            "first BulletTextAttachment instance was replaced after " +
            "in-list edit — TK2 view-provider cache will miss and the " +
            "user sees a per-keystroke flicker (fsnotes-ibj)"
        )
    }

    /// QA datum (v5, narrowing in DocumentEditApplier): user reports
    /// pressing Enter at the end of an L2 sub-item creates the new
    /// empty item AT THE BOTTOM of the list rather than directly after
    /// the cursor's current item. Pin the expected structure so we can
    /// localise whether narrowing introduced the regression or it's a
    /// pre-existing EditingOps issue.
    func test_enterAtEndOfMiddleL2_newItemAppearsAtCursorNotBottom() {
        let markdown = """
        - L1
          - L2-1
          - L2-2
        """
        let harness = EditorHarness(
            markdown: markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage,
              let tlm = harness.editor.textLayoutManager else {
            XCTFail("editor not initialised"); return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        let s = storage.string as NSString
        let l21Range = s.range(of: "L2-1")
        XCTAssertNotEqual(l21Range.location, NSNotFound)
        let endOfL21 = NSRange(
            location: l21Range.location + l21Range.length, length: 0
        )
        harness.editor.setSelectedRange(endOfL21)

        harness.pressReturn()

        guard let proj = harness.editor.documentProjection else {
            XCTFail("no projection"); return
        }
        var listBlockIdx: Int = -1
        for (i, block) in proj.document.blocks.enumerated() {
            if case .list = block { listBlockIdx = i; break }
        }
        XCTAssertGreaterThanOrEqual(listBlockIdx, 0)
        guard case .list(let items, _) = proj.document.blocks[listBlockIdx]
        else { XCTFail("not a list"); return }

        // Walk flat — the list may be body-nested or flat-indented.
        var flat: [(indent: Int, text: String)] = []
        func walk(_ ls: [ListItem]) {
            for item in ls {
                let plain = item.inline
                    .compactMap { node -> String? in
                        if case .text(let s) = node { return s }
                        return nil
                    }
                    .joined()
                flat.append((item.indent.count, plain))
                for body in item.body {
                    if case .list(let sub, _) = body { walk(sub) }
                }
            }
        }
        walk(items)
        // Diagnostic dump regardless of pass/fail.
        for (i, e) in flat.enumerated() {
            print("[enter-mid] flat[\(i)] indent=\(e.indent) text='\(e.text)'")
        }

        guard let i21 = flat.firstIndex(where: { $0.text == "L2-1" }),
              let i22 = flat.firstIndex(where: { $0.text == "L2-2" }),
              let iEmpty = flat.firstIndex(where: { $0.text.isEmpty && $0.indent > 0 }) else {
            XCTFail("expected items not found in flat list: \(flat)")
            return
        }
        XCTAssertGreaterThan(iEmpty, i21,
            "empty item should come after L2-1; got iEmpty=\(iEmpty), i21=\(i21)")
        XCTAssertLessThan(iEmpty, i22,
            "empty item should come BEFORE L2-2 (not at bottom); " +
            "got iEmpty=\(iEmpty), i22=\(i22)")
    }

    private func bulletAttachmentsByOffset(
        _ storage: NSTextStorage
    ) -> [Int: NSTextAttachment] {
        var result: [Int: NSTextAttachment] = [:]
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            guard let att = value as? NSTextAttachment else { return }
            let name = String(describing: type(of: att))
            if name.contains("Bullet") {
                result[range.location] = att
            }
        }
        return result
    }

    /// `viewProvider(for:location:textContainer:)` requires an
    /// `NSTextLocation` argument; production code passes the live
    /// element location. For test purposes any valid `NSTextLocation`
    /// works because `BulletAttachmentViewProvider.loadView()` doesn't
    /// consult the location — it reads `textAttachment.bounds`.
    private final class NSTextLocation_dummy: NSObject, NSTextLocation {
        func compare(_ location: NSTextLocation) -> ComparisonResult {
            .orderedSame
        }
    }

    /// Walk storage and count `BulletTextAttachment` instances. Under
    /// TK2 (Phase 4.5+), the bullet glyph lives on the attachment
    /// subclass directly, not on `attachmentCell` (which is TK1-only
    /// and `nil` here). Class-name match is used because the concrete
    /// type is private to ListRenderer.swift.
    private func countBulletAttachments(_ storage: NSTextStorage) -> Int {
        var n = 0
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            guard let att = value as? NSTextAttachment else { return }
            let attName = String(describing: type(of: att))
            if attName.contains("Bullet") { n += 1 }
        }
        return n
    }
}
