//
//  AIChatScrollToBottomTests.swift
//  FSNotesTests
//
//  Regression test for the AI chat panel quick-action crash:
//
//      -[NSStackView scrollToEndOfDocument:]: unrecognized selector
//      sent to instance ...
//
//  `AIChatPanelView.scrollToBottom()` previously called
//  `messagesScrollView.documentView?.scrollToEndOfDocument(nil)`.
//  The documentView IS the messages NSStackView, which does not
//  respond to that selector — every quick-action dropdown click
//  crashed the app on the dispatch_main_queue tick that followed.
//
//  These tests assert two things:
//    1. The synchronous scroll-to-bottom math runs to completion
//       without an unrecognized-selector trap, and the contentView's
//       bounds.origin.y is correctly positioned at the document
//       view's bottom edge.
//    2. The quick-action handler can be driven end-to-end with no
//       API key configured (the typical unit-test environment) and
//       the resulting `scrollToBottom()` dispatch fires cleanly.
//
//  Hermetic: no NSWindow needed. The view hierarchy is constructed
//  in-memory; layout is forced via `layoutSubtreeIfNeeded`.
//

import XCTest
import Cocoa
@testable import FSNotes

final class AIChatScrollToBottomTests: XCTestCase {

    // MARK: - Builders

    /// Make a panel sized so its scroll view is small enough that the
    /// stack view, once filled with multiple bubbles, exceeds the
    /// clip view's height — i.e. there's actual scrolling room.
    private func makePanel() -> AIChatPanelView {
        let panel = AIChatPanelView(frame: NSRect(x: 0, y: 0,
                                                  width: AIChatPanelView.panelWidth,
                                                  height: 240))
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    /// Force a few bubbles into the messages stack so the document
    /// view has non-zero height that exceeds the clip view's height.
    /// Long lines force wrap so each bubble's height is meaningful.
    /// We drive the panel through real `.sendMessage` /
    /// `.completeResponse(.success(...))` action pairs because those
    /// are the only public reducer transitions that append to
    /// `state.messages`. Each loop adds one user-turn and one
    /// assistant-turn.
    private func seedMessages(_ panel: AIChatPanelView, pairs: Int = 3) {
        for i in 0..<pairs {
            let userText = String(repeating: "lorem ipsum dolor sit amet ", count: 4) + "U#\(i)"
            let asstText = String(repeating: "consectetur adipiscing elit ", count: 4) + "A#\(i)"
            panel.store.dispatch(.sendMessage(userText))
            panel.store.dispatch(.completeResponse(.success(asstText)))
        }
        panel.layoutSubtreeIfNeeded()
    }

    // MARK: - 1. The crash precondition still holds (documentView is the stack view)

    func test_documentViewIsNSStackView_andDoesNotRespondToScrollToEnd() {
        let panel = makePanel()
        let scroll = panel.__test_messagesScrollView
        let doc = scroll.documentView
        XCTAssertNotNil(doc, "messages scroll view must have a document view")
        XCTAssertTrue(doc is NSStackView,
                      "documentView is the messages NSStackView — that is the precondition for the crash this test guards against")
        // Sanity: NSStackView does not implement scrollToEndOfDocument:.
        // We DO NOT call it; merely confirm the responder check is false.
        let sel = NSSelectorFromString("scrollToEndOfDocument:")
        XCTAssertFalse(doc!.responds(to: sel),
                       "if NSStackView ever starts responding to scrollToEndOfDocument:, the historical fix becomes unnecessary — re-evaluate this test")
    }

    // MARK: - 2. scrollToBottomNow() runs without crash and lands at the bottom

    func test_scrollToBottomNow_movesClipViewToDocumentBottom() {
        let panel = makePanel()
        seedMessages(panel, pairs: 4)

        let scroll = panel.__test_messagesScrollView
        let clip = scroll.contentView
        let doc = scroll.documentView!

        // Force layout so the stack view has a real height.
        panel.layoutSubtreeIfNeeded()

        // Precondition: the document is taller than the clip view —
        // otherwise the test would be vacuous.
        XCTAssertGreaterThan(doc.bounds.height, clip.bounds.height,
                             "test setup: document view must overflow the clip view; got doc=\(doc.bounds.height) clip=\(clip.bounds.height)")

        // Scroll up to the top first so we can verify scrollToBottomNow() actually moves.
        clip.scroll(to: .zero)
        scroll.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5)

        // Drive the same code path the production async block runs.
        panel.scrollToBottomNow()

        let expectedY = max(0, doc.bounds.height - clip.bounds.height)
        XCTAssertEqual(clip.bounds.origin.y, expectedY, accuracy: 0.5,
                       "clip view should be parked at document-bottom after scrollToBottomNow()")
    }

    func test_scrollToBottomNow_clampsToZero_whenDocumentIsShorterThanClip() {
        // Construct a fresh panel and immediately call scrollToBottomNow()
        // before any messages are appended. The empty-state hint is the
        // only documentView content, which is small. Whether that content
        // fits in the clip view is layout-dependent — what we DO assert
        // is the math result: scroll position is non-negative (clamped
        // by the `max(0, ...)` floor in `scrollToBottomNow`) and the call
        // does not crash. This is the documented clamp contract.
        let panel = AIChatPanelView(frame: NSRect(x: 0, y: 0,
                                                  width: AIChatPanelView.panelWidth,
                                                  height: 800))
        panel.layoutSubtreeIfNeeded()

        // Should not crash, should not produce a negative scroll origin.
        panel.scrollToBottomNow()

        let clip = panel.__test_messagesScrollView.contentView
        XCTAssertGreaterThanOrEqual(clip.bounds.origin.y, 0,
                                    "scroll origin must never go below zero — the max(0, …) clamp guarantees this")
    }

    // MARK: - 3. Quick-action dropdown path: no crash, scroll dispatch is benign

    func test_quickActionInvocation_doesNotCrash_evenWhenScrollDispatchFires() {
        let panel = makePanel()
        seedMessages(panel, pairs: 2)

        // Drive the quick-action handler the way the popup button would.
        // No API key is configured in unit tests, so the provider-create
        // path will dispatch .completeResponse(.failure(noAPIKey)).
        // That, in turn, drives render() which appends an error bubble
        // and calls scrollToBottom() — exactly the production path that
        // crashed pre-fix.
        let invoked = panel.__test_invokeQuickAction(at: 1)
        XCTAssertTrue(invoked, "quick action at index 1 must dispatch")

        // Pump the main run loop briefly so the DispatchQueue.main.async
        // block inside scrollToBottom() fires. If the old broken code
        // were still in place, this is where the unrecognized-selector
        // exception would be raised on the main queue.
        let exp = expectation(description: "main-queue tick after quick action")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // If we get here, the async scroll block ran without crashing.
        // The panel's render() will have appended either a user-bubble
        // (always) and a noAPIKey error bubble (when no provider key
        // is set), so the stack has new arranged subviews.
        XCTAssertGreaterThan(panel.__test_messagesStack.arrangedSubviews.count, 0,
                             "quick action must materialise at least one bubble in the stack")
    }

    // MARK: - 4. Production wrapper runs the async path without crashing

    func test_scrollToBottom_asyncWrapper_dispatchesAndCompletes() {
        let panel = makePanel()
        seedMessages(panel, pairs: 3)

        // Indirectly: invoke the same wrapper by dispatching an action
        // that drives render() to call scrollToBottom(). `.sendMessage`
        // flips `isStreaming = true` in the reducer, then `.receiveToken`
        // updates the streaming label and triggers the scrollToBottom()
        // call inside render() (lines 431-437 of AIChatPanelView.swift).
        panel.store.dispatch(.sendMessage("user prompt"))
        panel.store.dispatch(.receiveToken("first chunk"))
        panel.store.dispatch(.receiveToken(" second chunk"))

        let exp = expectation(description: "main-queue tick after streaming token")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // No assertion on coordinates — the test's purpose is purely
        // crash-coverage. If the unrecognized selector regression
        // returns, the run loop tick that drains the dispatched scroll
        // closure raises before this test exits.
        XCTAssertTrue(true, "async scrollToBottom completed without crashing")
    }
}
