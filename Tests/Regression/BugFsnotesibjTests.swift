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
