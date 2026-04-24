//
//  Phase2f5ImageResizeInvalidationTests.swift
//  FSNotesTests
//
//  Phase 2f.5 — live TK2 layout invalidation during inline-image
//  drag-resize. The production path runs:
//
//    InlineImageView.mouseDragged
//      -> onResizeLiveUpdate?(newSize)
//      -> ImageAttachmentViewProvider.applyLiveResize(...)
//      -> attachment.bounds = newSize
//         NSTextLayoutManager.invalidateLayout(for: NSTextRange)
//
//  These tests exercise `applyLiveResize` directly — it is a pure
//  static helper precisely so this contract can be pinned without
//  spinning up an AppKit event loop. Per CLAUDE.md Rule 4, pure-function
//  tests are preferred over widget-wired tests.
//
//  Observable state asserted:
//    - `attachment.bounds` mutates to the new size on happy path.
//    - The helper returns `true` iff invalidation was actually issued
//      (all inputs present, NSTextRange conversion succeeded), `false`
//      otherwise. Boolean is the observable contract because
//      NSTextLayoutManager does not expose a public "was-invalidated"
//      flag, and spying on `invalidateLayout(for:)` would require
//      subclassing internal TK2 machinery.
//
//  Coverage:
//    1. Happy path: attachment present, TLM wired, location in range —
//       bounds mutate, helper returns true.
//    2. Nil attachment: no bounds mutation possible, helper returns
//       false, no crash.
//    3. Nil TLM: bounds still mutate (attachment side is independent
//       of layout), but invalidation cannot be issued — helper returns
//       false.
//    4. Location at end-of-document (offset-by-1 out of range): helper
//       returns false cleanly, no crash. Guards the "attachment at
//       storage-end" edge case.
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase2f5ImageResizeInvalidationTests: XCTestCase {

    // MARK: - Fixture

    /// Build a minimal TK2 stack (`NSTextContentStorage` +
    /// `NSTextLayoutManager` + `NSTextContainer`) and seed it with an
    /// `NSTextAttributedString` containing a single
    /// `NSTextAttachment` at offset 0. Returns all three pieces plus
    /// the attachment and the `NSTextLocation` for offset 0 so tests
    /// can call `applyLiveResize` directly.
    private func makeFixture() -> (
        contentStorage: NSTextContentStorage,
        layoutManager: NSTextLayoutManager,
        attachment: NSTextAttachment,
        location: NSTextLocation
    ) {
        let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)

        let attachment = NSTextAttachment()
        attachment.bounds = NSRect(x: 0, y: 0, width: 100, height: 100)

        let attachmentString = NSAttributedString(attachment: attachment)
        let body = NSMutableAttributedString()
        body.append(attachmentString)
        body.append(NSAttributedString(string: "\nfollowing text"))
        contentStorage.attributedString = body

        // Location for offset 0 — the attachment's position.
        let location = contentStorage.documentRange.location
        return (contentStorage, layoutManager, attachment, location)
    }

    // MARK: - Tests

    /// Happy path: with a valid attachment + TLM + location, the
    /// helper must mutate `attachment.bounds` to match `newSize` and
    /// return `true` indicating invalidation was issued.
    func test_phase2f5_applyLiveResize_happyPath_updatesBoundsAndInvalidates() {
        let fx = makeFixture()
        XCTAssertEqual(
            fx.attachment.bounds.size, NSSize(width: 100, height: 100),
            "Precondition: attachment must start at 100x100 so the new " +
            "250x180 size is observably different."
        )

        let didInvalidate = ImageAttachmentViewProvider.applyLiveResize(
            attachment: fx.attachment,
            newSize: NSSize(width: 250, height: 180),
            textLayoutManager: fx.layoutManager,
            location: fx.location
        )

        XCTAssertTrue(
            didInvalidate,
            "With all inputs valid and the location inside the document, " +
            "applyLiveResize must issue invalidateLayout and return true. " +
            "Returning false here means live-resize reflow is broken — text " +
            "around a dragging image will not reflow until commit."
        )
        XCTAssertEqual(
            fx.attachment.bounds.size, NSSize(width: 250, height: 180),
            "applyLiveResize must update attachment.bounds so TK2's line-" +
            "fragment sizing sees the new dimensions. Leaving bounds stale " +
            "makes the attachment sit in a wrongly-sized layout slot."
        )
        // Bounds origin must remain .zero — TK2 positions the attachment
        // via the view-provider, not via a non-zero bounds origin. If a
        // future change adds a non-zero origin it'll offset the image
        // visually in a way that compounds across drag ticks.
        XCTAssertEqual(
            fx.attachment.bounds.origin, .zero,
            "applyLiveResize must keep bounds.origin = .zero; TK2 positions " +
            "attachments via the view-provider, not via bounds offset."
        )
    }

    /// Nil attachment: helper must return false without crashing. This
    /// happens if the attachment was torn down between drag-start and
    /// a subsequent drag tick (e.g. document was externally re-rendered).
    func test_phase2f5_applyLiveResize_nilAttachment_returnsFalseCleanly() {
        let fx = makeFixture()

        let didInvalidate = ImageAttachmentViewProvider.applyLiveResize(
            attachment: nil,
            newSize: NSSize(width: 250, height: 180),
            textLayoutManager: fx.layoutManager,
            location: fx.location
        )

        XCTAssertFalse(
            didInvalidate,
            "Nil attachment means there's nothing whose bounds can be " +
            "updated — helper must short-circuit and return false. " +
            "Crashing or returning true here would falsely imply a " +
            "successful invalidation."
        )
    }

    /// Nil text layout manager: the attachment side can still be
    /// updated (it's independent of layout), but invalidation cannot
    /// be issued. Helper must return false so callers don't rely on a
    /// layout nudge that never happened.
    func test_phase2f5_applyLiveResize_nilLayoutManager_returnsFalse() {
        let fx = makeFixture()

        let didInvalidate = ImageAttachmentViewProvider.applyLiveResize(
            attachment: fx.attachment,
            newSize: NSSize(width: 250, height: 180),
            textLayoutManager: nil,
            location: fx.location
        )

        XCTAssertFalse(
            didInvalidate,
            "Without a text layout manager there is no invalidation " +
            "target; helper must return false. The attachment's bounds " +
            "DO still get updated (independent side-effect) — we don't " +
            "assert on bounds here because an attachment without a " +
            "layout manager is already a degenerate state worth " +
            "flagging via the boolean."
        )
    }

    /// Edge case: attachment at / past the last character. Asking for
    /// `offsetBy: 1` from the last location must fail cleanly, not
    /// crash. Real-world trigger: last keystroke in the document is
    /// placing an image and the user starts dragging before any
    /// following character is typed.
    func test_phase2f5_applyLiveResize_locationAtEnd_returnsFalseNoCrash() {
        let fx = makeFixture()
        // Pick the document END location — offsetBy:1 from here is
        // out of range, so NSTextRange construction returns nil.
        let endLocation = fx.contentStorage.documentRange.endLocation

        let didInvalidate = ImageAttachmentViewProvider.applyLiveResize(
            attachment: fx.attachment,
            newSize: NSSize(width: 200, height: 120),
            textLayoutManager: fx.layoutManager,
            location: endLocation
        )

        XCTAssertFalse(
            didInvalidate,
            "Location at document end means offsetBy:1 falls outside " +
            "the document — NSTextRange construction returns nil and " +
            "the helper must return false without crashing. This is " +
            "the 'image is the last character' edge case."
        )
        // attachment.bounds still mutates — the guard-fail happens
        // AFTER the bounds write. This is intentional: even if we
        // can't invalidate, matching the attachment's reported size to
        // the view's actual frame keeps downstream state self-
        // consistent.
        XCTAssertEqual(
            fx.attachment.bounds.size, NSSize(width: 200, height: 120),
            "Bounds update is unconditional — it happens before the " +
            "NSTextRange guard fires. This is intentional so the " +
            "attachment's size and the view's frame stay in sync even " +
            "when we can't nudge the layout manager."
        )
    }

    /// Consistency: the `mouseDragged` → `onResizeLiveUpdate` pathway
    /// must fire with the computed new size. If someone accidentally
    /// reorders the callback to fire before the frame update, or
    /// drops the callback, the live-reflow behavior silently breaks
    /// at the widget level even though `applyLiveResize` is correct.
    /// This test pins the widget-side wiring: a drag produces at
    /// least one callback with a size matching the new frame.
    func test_phase2f5_imageView_mouseDragFiresLiveUpdateCallback() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = InlineImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(view)

        var receivedSizes: [NSSize] = []
        view.onResizeLiveUpdate = { size in receivedSizes.append(size) }

        // mouseDown on the topRight handle at local (200, 0). The view
        // hit-tests handles by corner center; landing inside the 8×8
        // handle box centered at (200, 0) primes the drag.
        let handleLocal = CGPoint(x: 200, y: 0)
        let handleWindow = view.convert(handleLocal, to: nil)
        guard let downEvt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: handleWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ), let dragEvt = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: handleWindow.x + 40, y: handleWindow.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("Could not synthesize mouse event sequence")
            return
        }

        view.mouseDown(with: downEvt)
        XCTAssertTrue(
            receivedSizes.isEmpty,
            "mouseDown on a handle must NOT fire onResizeLiveUpdate — " +
            "that callback is for drag *motion*, not handle capture."
        )
        view.mouseDragged(with: dragEvt)

        XCTAssertEqual(
            receivedSizes.count, 1,
            "Exactly one drag tick must produce exactly one " +
            "onResizeLiveUpdate call. Got \(receivedSizes.count)."
        )
        // 200pt start + 40pt east-drag on topRight handle = 240pt width.
        // Aspect 1:1 so height must also be 240pt.
        if let last = receivedSizes.last {
            XCTAssertEqual(
                last.width, 240, accuracy: 0.5,
                "onResizeLiveUpdate size.width must equal the post-drag " +
                "frame width (200 + 40 = 240). Got \(last.width)."
            )
            XCTAssertEqual(
                last.height, 240, accuracy: 0.5,
                "Aspect-locked drag: size.height must track width. Got " +
                "\(last.height)."
            )
            XCTAssertEqual(
                last.width, view.frame.width, accuracy: 0.01,
                "The size passed to onResizeLiveUpdate must match the " +
                "frame the view just set — otherwise the attachment " +
                "bounds drift out of sync with the visible frame."
            )
        }
    }
}
