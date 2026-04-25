//
//  InlineAttachmentDoubleClickTests.swift
//  FSNotesTests
//
//  Bug #23: double-clicking an inline PDF or file attachment should
//  open the underlying file in its default macOS app (Preview for
//  PDFs, Numbers for `.numbers`, etc.).
//
//  The live wiring is an `NSClickGestureRecognizer(numberOfClicksRequired:
//  2)` attached to `InlinePDFView` and `InlineQuickLookView`. The
//  pure predicate `InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick`
//  encodes the decision and is exercised here. Mock-NSWorkspace
//  injection inside the live `mouseDown` path would require invasive
//  surgery on Apple's gesture-recognizer wiring; instead we cover the
//  load-bearing decision in pure form per CLAUDE.md Rule 4 ("widgets
//  capture intent, primitives decide").
//

import XCTest
@testable import FSNotes

final class InlineAttachmentDoubleClickTests: XCTestCase {

    // MARK: - shouldOpenOnDoubleClick

    func test_singleClick_doesNotOpen() {
        XCTAssertFalse(InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick(clickCount: 1))
    }

    func test_doubleClick_opens() {
        XCTAssertTrue(InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick(clickCount: 2))
    }

    func test_tripleClick_doesNotOpen() {
        // Triple-click is a normal in-content selection gesture for
        // QuickLook text previews. We must not hijack it.
        XCTAssertFalse(InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick(clickCount: 3))
    }

    func test_zeroClick_doesNotOpen() {
        // Defensive: a synthetic event with clickCount == 0 should
        // never trigger the open action.
        XCTAssertFalse(InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick(clickCount: 0))
    }

    func test_highClickCount_doesNotOpen() {
        // Quadruple-click and beyond are not part of the contract;
        // only an exact double-click opens the file. This guards
        // against a future change that loosens the predicate to
        // `>= 2` and accidentally hijacks selection gestures.
        XCTAssertFalse(InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick(clickCount: 4))
        XCTAssertFalse(InlineAttachmentOpenPolicy.shouldOpenOnDoubleClick(clickCount: 7))
    }
}
