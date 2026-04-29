//
//  BugFsnotesibjTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-ibj (P1):
//  "META: bullet/Todo glyphs disappear during edit, reappear on scroll"
//
//  Verifiable property: bullet and Todo markers are static image-backed
//  NSTextAttachments, not hosted NSTextAttachmentViewProvider subviews.
//  That removes the provider lifecycle from list markers entirely, so
//  an active edited line cannot enter the "provider absent/blank" state.
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

        // Each surviving bullet attachment must be renderable through
        // its image. List markers no longer use TK2 hosted subviews.
        var renderable = 0
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            guard let att = value as? NSTextAttachment else { return }
            let name = String(describing: type(of: att))
            guard name.contains("Bullet") else { return }
            if att.image != nil {
                renderable += 1
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
    /// every keystroke, which forces marker layout/repaint work on
    /// unchanged items.
    ///
    /// Verifiable property: the `BulletTextAttachment` *object identity*
    /// at the start of an unchanged list item must survive a typing edit
    /// inside that same list block. Fresh marker attachments on every
    /// keystroke would force attachment image re-layout and repaint.
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
        // must be the *same instance* before and after. The first bullet
        // is the canary — its offset doesn't move on edits inside its
        // own list item.
        let firstBefore = before.min(by: { $0.key < $1.key })
        let firstAfter = after.min(by: { $0.key < $1.key })
        XCTAssertNotNil(firstBefore)
        XCTAssertNotNil(firstAfter)
        XCTAssertTrue(
            firstBefore?.value === firstAfter?.value,
            "first BulletTextAttachment instance was replaced after " +
            "in-list edit — static marker attachment identity should " +
            "survive ordinary typing (fsnotes-ibj)"
        )
    }

    /// Live symptom from user screenshots: while the insertion point is
    /// inside a list item, a TK2-hosted marker view for that active line
    /// could be absent or blank. The fix is to make list markers image-
    /// backed attachments, so no BulletGlyphView should exist at all.
    func test_activeLineBullet_usesImageBackedAttachmentAfterTyping() {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage,
              let tlm = harness.editor.textLayoutManager else {
            XCTFail("editor not initialised")
            return
        }

        tlm.ensureLayout(for: tlm.documentRange)
        tlm.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        tlm.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(countBulletAttachments(storage), 3)
        XCTAssertEqual(
            countHostedMarkerViews(in: harness.editor, named: "BulletGlyphView"),
            0,
            "bullet markers should not depend on TK2 hosted subviews"
        )
        XCTAssertTrue(
            allBulletAttachmentsHaveVisibleImages(storage),
            "seeded bullet attachments should carry visible marker images"
        )

        let gammaRange = (storage.string as NSString).range(of: "gamma")
        XCTAssertNotEqual(gammaRange.location, NSNotFound)
        harness.editor.setSelectedRange(NSRange(
            location: gammaRange.location + gammaRange.length,
            length: 0
        ))
        harness.type("X")

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        harness.editor.displayIfNeeded()

        XCTAssertEqual(countBulletAttachments(storage), 3)
        XCTAssertEqual(
            countHostedMarkerViews(in: harness.editor, named: "BulletGlyphView"),
            0,
            "typing should not create bullet marker hosted subviews"
        )
        XCTAssertTrue(
            allBulletAttachmentsHaveVisibleImages(storage),
            "bullet marker images must remain visible after typing"
        )
    }

    /// User QA 2026-04-29 after the fallback-image candidate: the
    /// bullet is visible while typing, then disappears again when the
    /// editor goes idle. This pins the stronger invariant we actually
    /// want: after the idle layout cycle settles, the active line still
    /// has a visible marker image and no hosted marker provider exists.
    func test_activeLineBullet_imageBackedAttachmentAfterIdle() {
        let harness = EditorHarness(
            markdown: Self.markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage,
              let tlm = harness.editor.textLayoutManager else {
            XCTFail("editor not initialised")
            return
        }

        tlm.ensureLayout(for: tlm.documentRange)
        tlm.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        tlm.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let gammaRange = (storage.string as NSString).range(of: "gamma")
        XCTAssertNotEqual(gammaRange.location, NSNotFound)
        harness.editor.setSelectedRange(NSRange(
            location: gammaRange.location + gammaRange.length,
            length: 0
        ))
        harness.type("X")

        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        tlm.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(countBulletAttachments(storage), 3)
        XCTAssertEqual(
            countHostedMarkerViews(in: harness.editor, named: "BulletGlyphView"),
            0,
            "the idle layout cycle must not create bullet marker hosted subviews"
        )
        XCTAssertTrue(
            allBulletAttachmentsHaveVisibleImages(storage),
            "bullet marker images must remain visible after idle layout"
        )
    }

    func test_activeLineCheckbox_usesImageBackedAttachmentAfterTyping() {
        let markdown = """
        - [ ] alpha
        - [x] beta
        - [ ] gamma
        """
        let harness = EditorHarness(
            markdown: markdown, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage,
              let tlm = harness.editor.textLayoutManager else {
            XCTFail("editor not initialised")
            return
        }

        tlm.ensureLayout(for: tlm.documentRange)
        tlm.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        tlm.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(countCheckboxAttachments(storage), 3)

        let gammaRange = (storage.string as NSString).range(of: "gamma")
        XCTAssertNotEqual(gammaRange.location, NSNotFound)
        harness.editor.setSelectedRange(NSRange(
            location: gammaRange.location + gammaRange.length,
            length: 0
        ))
        harness.type("X")

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        harness.editor.displayIfNeeded()

        XCTAssertEqual(countCheckboxAttachments(storage), 3)
        XCTAssertEqual(
            countHostedMarkerViews(in: harness.editor, named: "CheckboxGlyphView"),
            0,
            "typing should not create checkbox marker hosted subviews"
        )
        XCTAssertTrue(
            allCheckboxAttachmentsHaveVisibleImages(storage),
            "checkbox marker images must remain visible after typing"
        )
    }

    /// Static list markers must not enter the TK2 hosted-view lifecycle.
    /// They draw through NSTextAttachment.image instead.
    func test_listMarkers_doNotVendViewProviders() {
        let tk2 = makeTK2Container()

        let bullet = BulletTextAttachment(
            glyph: "\u{2022}",
            size: 20,
            bodyPointSize: 14
        )
        let checkbox = CheckboxTextAttachment(
            checked: false,
            size: 20,
            bodyPointSize: 14
        )

        let bulletProvider = bullet.viewProvider(
            for: nil,
            location: NSTextLocation_dummy(),
            textContainer: tk2.container
        )
        let checkboxProvider = checkbox.viewProvider(
            for: nil,
            location: NSTextLocation_dummy(),
            textContainer: tk2.container
        )

        XCTAssertNil(bulletProvider)
        XCTAssertNil(checkboxProvider)
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

    private func countHostedMarkerViews(in root: NSView, named suffix: String) -> Int {
        var count = 0
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).hasSuffix(suffix) {
                count += 1
            }
            for child in view.subviews {
                walk(child)
            }
        }
        walk(root)
        return count
    }

    private func allBulletAttachmentsHaveVisibleImages(
        _ storage: NSTextStorage
    ) -> Bool {
        return allAttachmentsHaveVisibleImages(
            storage,
            classNameContains: "Bullet"
        )
    }

    private func allCheckboxAttachmentsHaveVisibleImages(
        _ storage: NSTextStorage
    ) -> Bool {
        return allAttachmentsHaveVisibleImages(
            storage,
            classNameContains: "Checkbox"
        )
    }

    private func allAttachmentsHaveVisibleImages(
        _ storage: NSTextStorage,
        classNameContains needle: String
    ) -> Bool {
        var ok = true
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, stop in
            guard let att = value as? NSTextAttachment else { return }
            let name = String(describing: type(of: att))
            guard name.contains(needle) else { return }
            guard let image = att.image, imageHasDrawnPixels(image) else {
                ok = false
                stop.pointee = true
                return
            }
        }
        return ok
    }

    private func imageHasDrawnPixels(_ image: NSImage) -> Bool {
        let width = max(1, Int(ceil(image.size.width * 2)))
        let height = max(1, Int(ceil(image.size.height * 2)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return false
        }
        rep.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return false
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return false }
        let stride = rep.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                if data[i + 3] > 8 {
                    return true
                }
            }
        }
        return false
    }

    private func countCheckboxAttachments(_ storage: NSTextStorage) -> Int {
        var n = 0
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            guard let att = value as? NSTextAttachment else { return }
            let attName = String(describing: type(of: att))
            if attName.contains("Checkbox") { n += 1 }
        }
        return n
    }

    /// `viewProvider(for:location:textContainer:)` requires an
    /// `NSTextLocation` argument; production code passes the live
    /// element location. For test purposes any valid `NSTextLocation`
    /// works because static list markers must return nil regardless
    /// of location.
    private final class NSTextLocation_dummy: NSObject, NSTextLocation {
        func compare(_ location: NSTextLocation) -> ComparisonResult {
            .orderedSame
        }
    }

    private func makeTK2Container() -> (
        container: NSTextContainer,
        tlm: NSTextLayoutManager,
        cs: NSTextContentStorage
    ) {
        let contentStorage = NSTextContentStorage()
        let tlm = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(tlm)
        let container = NSTextContainer(size: NSSize(width: 1000, height: 10000))
        tlm.textContainer = container
        return (container, tlm, contentStorage)
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
