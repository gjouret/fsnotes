//
//  InlineQuickLookScrollPropagationTests.swift
//  FSNotesTests
//
//  Bug #22: scroll events on a long-scrollable QuickLook preview
//  (e.g. a multi-page log file) should be consumed by the QuickLook
//  inner scroll view until it reaches a boundary, then propagate to
//  the parent note's scroll view (Obsidian-style).
//
//  These tests pin the pure predicate that `InlineQuickLookView.scrollWheel`
//  uses to decide between consume vs. propagate. Live behavior is
//  verified manually since `QLPreviewView`'s inner scroll view is
//  populated asynchronously and depends on a real preview-able file.
//

import XCTest
import AppKit
@testable import FSNotes

final class InlineQuickLookScrollPropagationTests: XCTestCase {

    // MARK: - canScroll == false → always propagate

    func test_propagate_whenInnerScrollViewMissing() {
        // Without an inner scroll view there is nothing to consume the
        // event; it must always reach the parent note.
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: 5, contentOffsetY: 0, contentHeight: 0, viewportHeight: 0,
                canScroll: false
            )
        )
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: -5, contentOffsetY: 0, contentHeight: 0, viewportHeight: 0,
                canScroll: false
            )
        )
    }

    // MARK: - content fits viewport → always propagate

    func test_propagate_whenContentFitsInViewport() {
        // No internal scrolling needed → propagate every event.
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: 5, contentOffsetY: 0, contentHeight: 200, viewportHeight: 400,
                canScroll: true
            )
        )
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: -5, contentOffsetY: 0, contentHeight: 400, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    // MARK: - mid-content → consume

    func test_consume_whenScrollingDownInsideContent() {
        // Long content, viewport in the middle, user scrolling down.
        // Inner scroll view should consume; nothing propagates.
        XCTAssertFalse(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: -10, contentOffsetY: 500, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    func test_consume_whenScrollingUpInsideContent() {
        XCTAssertFalse(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: 10, contentOffsetY: 500, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    // MARK: - boundary cases

    func test_propagate_atTop_whenScrollingUp() {
        // Already at top, gesture is upward (deltaY > 0 = content moves down).
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: 10, contentOffsetY: 0, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    func test_consume_atTop_whenScrollingDown() {
        // At top, gesture is downward — inner scroll view has room to
        // move; consume.
        XCTAssertFalse(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: -10, contentOffsetY: 0, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    func test_propagate_atBottom_whenScrollingDown() {
        // Already at bottom, gesture is downward.
        // maxOffset = contentHeight - viewportHeight = 2000 - 400 = 1600.
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: -10, contentOffsetY: 1600, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    func test_consume_atBottom_whenScrollingUp() {
        // At bottom, gesture is upward — inner content has room to
        // travel back up; consume.
        XCTAssertFalse(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: 10, contentOffsetY: 1600, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    // MARK: - tolerance for sub-pixel residue

    func test_propagate_atTop_withSubPixelResidue() {
        // After momentum scroll, contentOffsetY can be 0.0001 instead of
        // exactly 0. Treat sub-half-pixel residue as "at boundary."
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: 5, contentOffsetY: 0.3, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    func test_propagate_atBottom_withSubPixelResidue() {
        // Same idea at the bottom edge.
        XCTAssertTrue(
            InlineQuickLookView.shouldPropagateVerticalScroll(
                deltaY: -5, contentOffsetY: 1599.7, contentHeight: 2000, viewportHeight: 400,
                canScroll: true
            )
        )
    }

    // MARK: - findInnerScrollView walker

    func test_findInnerScrollView_returnsNil_whenNoScrollViewPresent() {
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(InlineQuickLookView.findInnerScrollView(in: plain))
    }

    func test_findInnerScrollView_findsDirectChild() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let scroll = NSScrollView()
        parent.addSubview(scroll)
        XCTAssertTrue(InlineQuickLookView.findInnerScrollView(in: parent) === scroll)
    }

    func test_findInnerScrollView_findsNestedDescendant() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let inner = NSView()
        let inner2 = NSView()
        let scroll = NSScrollView()
        parent.addSubview(inner)
        inner.addSubview(inner2)
        inner2.addSubview(scroll)
        XCTAssertTrue(InlineQuickLookView.findInnerScrollView(in: parent) === scroll)
    }

    func test_findInnerScrollView_returnsRoot_whenRootIsScrollView() {
        let scroll = NSScrollView()
        XCTAssertTrue(InlineQuickLookView.findInnerScrollView(in: scroll) === scroll)
    }
}
