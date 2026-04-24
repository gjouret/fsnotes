//
//  Phase5aDeleteBypassFixTests.swift
//  FSNotesTests
//
//  Phase 5a follow-up — regression tests for the AppKit delete-command
//  bypass found via user-reported SIGTRAP on 2026-04-24.
//
//  Context
//  -------
//  The Phase 5a DEBUG assertion in
//  `TextStorageProcessor.didProcessEditing` fired when a user pressed
//  backspace inside a table cell. Stack trace showed:
//      NSTextView.deleteBackward:
//        → _userReplaceRange:withString:
//            → NSTextContentStorage.replaceCharactersInRange
//                → processEditing
//                    → didProcessEditing (the assertion site)
//
//  AppKit's default `deleteBackward:` / `deleteForward:` implementations
//  use the private `_userReplaceRange:withString:` API, which mutates
//  `NSTextContentStorage` *without* calling
//  `shouldChangeText(in:replacementString:)`. That means the gatekeeper
//  in `EditTextView+Input.swift` — the hook that routes every edit
//  through `handleEditViaBlockModel` — never runs, no `StorageWriteGuard`
//  scope is active, and the Phase 5a assertion traps.
//
//  Fix: overrides of `deleteBackward(_:)` and `deleteForward(_:)` on
//  `EditTextView` in `EditTextView+Input.swift`. Both compute the delete
//  target range (respecting grapheme-cluster boundaries via
//  `rangeOfComposedCharacterSequence(at:)`) and route the edit through
//  `handleEditViaBlockModel` with an empty replacement string.
//
//  These tests drive the real `deleteBackward(_:)` / `deleteForward(_:)`
//  NSResponder methods on a live `EditTextView` — the harness's
//  `pressDelete` helper short-circuits directly to
//  `handleEditViaBlockModel` and therefore would NOT catch the bypass
//  this fix closes. We call the actual NSResponder selectors so the
//  test fails if a future change re-introduces the AppKit-private
//  dispatch path.
//

import XCTest
@testable import FSNotes

final class Phase5aDeleteBypassFixTests: XCTestCase {

    // MARK: - deleteBackward

    func test_deleteBackward_singleCharacter_routesThroughBlockModel() {
        let harness = EditorHarness(markdown: "hello")
        defer { harness.teardown() }

        // Park the caret at end of "hello"
        harness.editor.setSelectedRange(
            NSRange(location: 5, length: 0)
        )

        // Clear any prior contract so we can detect the new one
        harness.editor.lastEditContract = nil

        // Call the real NSResponder selector — this is the path AppKit
        // invokes when the user presses the backspace key.
        harness.editor.deleteBackward(nil)

        // Route verification: the block-model gatekeeper fires an
        // `EditContract` into `lastEditContract`. If the AppKit bypass
        // had run, `lastEditContract` would stay nil.
        XCTAssertNotNil(
            harness.editor.lastEditContract,
            "deleteBackward must route through handleEditViaBlockModel; " +
            "if this is nil the AppKit _userReplaceRange bypass re-surfaced."
        )

        // Storage result: "hello" → "hell"
        XCTAssertEqual(harness.editor.textStorage?.string, "hell")

        // Projection result: the paragraph block's inline text is "hell"
        guard let doc = harness.editor.documentProjection?.document,
              case .paragraph(let inlines) = doc.blocks.first else {
            return XCTFail("expected one paragraph block")
        }
        let rendered = inlines.map { inline -> String in
            if case .text(let s) = inline { return s }
            return ""
        }.joined()
        XCTAssertEqual(rendered, "hell")
    }

    func test_deleteBackward_selectedRange_routesThroughBlockModel() {
        let harness = EditorHarness(markdown: "hello world")
        defer { harness.teardown() }

        // Select "hello "
        harness.editor.setSelectedRange(NSRange(location: 0, length: 6))
        harness.editor.lastEditContract = nil

        harness.editor.deleteBackward(nil)

        XCTAssertNotNil(
            harness.editor.lastEditContract,
            "range-deletion via deleteBackward must route through block model"
        )
        XCTAssertEqual(harness.editor.textStorage?.string, "world")
    }

    func test_deleteBackward_atDocumentStart_isNoOp() {
        let harness = EditorHarness(markdown: "hello")
        defer { harness.teardown() }

        harness.editor.setSelectedRange(NSRange(location: 0, length: 0))
        harness.editor.lastEditContract = nil

        harness.editor.deleteBackward(nil)

        // No edit routed — contract remains nil, storage unchanged.
        XCTAssertNil(harness.editor.lastEditContract)
        XCTAssertEqual(harness.editor.textStorage?.string, "hello")
    }

    // Grapheme-cluster coverage (emoji, combining accents) deferred to
    // a follow-up. The production code uses
    // `NSString.rangeOfComposedCharacterSequence(at:)` which matches
    // AppKit's default delete-granularity behaviour byte-for-byte —
    // correctness of that primitive is Apple's problem, not ours. A
    // dedicated grapheme test needs to bypass the markdown parser's
    // Unicode normalisation so the test input doesn't collapse
    // "e + U+0301" → "é" before the range-calc runs. Tracked separately.

    // MARK: - deleteForward

    func test_deleteForward_singleCharacter_routesThroughBlockModel() {
        let harness = EditorHarness(markdown: "hello")
        defer { harness.teardown() }

        // Caret at start of "hello"
        harness.editor.setSelectedRange(NSRange(location: 0, length: 0))
        harness.editor.lastEditContract = nil

        harness.editor.deleteForward(nil)

        XCTAssertNotNil(
            harness.editor.lastEditContract,
            "deleteForward must route through handleEditViaBlockModel"
        )
        XCTAssertEqual(harness.editor.textStorage?.string, "ello")
    }

    func test_deleteForward_atDocumentEnd_isNoOp() {
        let harness = EditorHarness(markdown: "hello")
        defer { harness.teardown() }

        let storageLen = harness.editor.textStorage?.length ?? 0
        harness.editor.setSelectedRange(
            NSRange(location: storageLen, length: 0)
        )
        harness.editor.lastEditContract = nil

        harness.editor.deleteForward(nil)

        XCTAssertNil(harness.editor.lastEditContract)
        XCTAssertEqual(harness.editor.textStorage?.string, "hello")
    }
}
