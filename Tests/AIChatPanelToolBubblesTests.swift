//
//  AIChatPanelToolBubblesTests.swift
//  FSNotesTests
//
//  Tests for the tool-call visualization slice. Construct the bubble
//  view directly, drive it with synthetic ToolCall + ToolOutput
//  values, and assert the visible labels reflect the in-flight /
//  success / error state.
//
//  These are pure unit tests in the sense they do not need an
//  NSWindow or a real chat panel — the bubble is a self-contained
//  NSView whose label text we can read back via test accessors. A
//  separate (mini) integration test wires an AIChatStore action
//  subscription to the same render flow and verifies that
//  `.toolCallRequested` followed by `.toolCallCompleted` produces the
//  expected sequence of label updates.
//

import XCTest
import Cocoa
@testable import FSNotes

final class AIChatPanelToolBubblesTests: XCTestCase {

    // MARK: - In-flight rendering

    func test_inFlightBubble_showsToolNameAndArgsAndRunningPlaceholder() {
        let call = ToolCall(id: "c1", name: "read_note", arguments: ["path": "Inbox/Note.md"])
        let bubble = ToolCallBubble(call: call, maxWidth: 280)

        XCTAssertTrue(bubble.nameText.hasPrefix("Calling: read_note"))
        XCTAssertTrue(bubble.nameText.contains("path=\"Inbox/Note.md\""),
                      "expected args render, got: \(bubble.nameText)")
        XCTAssertEqual(bubble.detailText, "\u{2026}running")
    }

    func test_inFlightBubble_emptyArgsRendersAsEmptyParens() {
        let call = ToolCall(id: "c2", name: "list_folders", arguments: [:])
        let bubble = ToolCallBubble(call: call, maxWidth: 280)
        XCTAssertEqual(bubble.nameText, "Calling: list_folders()")
    }

    // MARK: - Success transition

    func test_applyResult_success_flipsLabelsAndShowsPreview() {
        let call = ToolCall(id: "c3", name: "read_note", arguments: [:])
        let bubble = ToolCallBubble(call: call, maxWidth: 280)
        bubble.applyResult(.success(.success(["content": "hello world"])))

        XCTAssertTrue(bubble.nameText.contains("read_note returned"),
                      "got: \(bubble.nameText)")
        XCTAssertTrue(bubble.nameText.hasPrefix("\u{2713}"))
        XCTAssertTrue(bubble.detailText.contains("hello world"))
    }

    func test_applyResult_success_truncatesLongPreview() {
        let big = String(repeating: "x", count: 200)
        let call = ToolCall(id: "c4", name: "read_note", arguments: [:])
        let bubble = ToolCallBubble(call: call, maxWidth: 280)
        bubble.applyResult(.success(.success(["body": big])))

        XCTAssertLessThanOrEqual(bubble.detailText.count, 81,
                                 "preview must be ≤80 chars + ellipsis")
        XCTAssertTrue(bubble.detailText.hasSuffix("\u{2026}"),
                      "long preview must end in ellipsis: \(bubble.detailText)")
    }

    // MARK: - Failure transition

    func test_applyResult_toolError_rendersInRed() {
        let call = ToolCall(id: "c5", name: "delete_note", arguments: [:])
        let bubble = ToolCallBubble(call: call, maxWidth: 280)
        bubble.applyResult(.success(.error("permission denied")))

        XCTAssertTrue(bubble.nameText.hasPrefix("\u{2717}"))
        XCTAssertTrue(bubble.nameText.contains("delete_note failed"))
        XCTAssertEqual(bubble.detailText, "permission denied")
    }

    func test_applyResult_throwingError_rendersDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom!" } }
        let call = ToolCall(id: "c6", name: "list_folders", arguments: [:])
        let bubble = ToolCallBubble(call: call, maxWidth: 280)
        bubble.applyResult(.failure(Boom()))

        XCTAssertTrue(bubble.nameText.contains("list_folders failed"))
        XCTAssertEqual(bubble.detailText, "boom!")
    }

    // MARK: - Argument formatter (pure)

    func test_formatArguments_sortsKeysAndQuotesStrings() {
        let s = ToolCallBubble.formatArguments(["b": "two", "a": "one"])
        XCTAssertEqual(s, "(a=\"one\", b=\"two\")")
    }

    func test_formatArguments_truncatesLongStrings() {
        let long = String(repeating: "z", count: 100)
        let s = ToolCallBubble.formatArguments(["q": long])
        // formatted as q="zzz…zzz…" — value truncated at 40 chars + ellipsis
        XCTAssertTrue(s.contains("\u{2026}"),
                      "long string must be truncated, got: \(s)")
        XCTAssertLessThanOrEqual(s.count, 60)
    }

    // MARK: - Store integration via action subscriber

    func test_storeActionSubscriber_seesRequestedAndCompletedActions() {
        let store = AIChatStore()
        var seen: [String] = []
        let sub = store.subscribeToActions { action, _ in
            switch action {
            case .toolCallRequested(let c): seen.append("requested:\(c.id)")
            case .toolCallCompleted(let c, _): seen.append("completed:\(c.id)")
            default: break
            }
        }

        let call = ToolCall(id: "x1", name: "read_note", arguments: [:])
        store.dispatch(.toolCallRequested(call))
        store.dispatch(.toolCallCompleted(call, .success(.success(["ok": true]))))

        XCTAssertEqual(seen, ["requested:x1", "completed:x1"])
        sub.cancel()
    }

    func test_storeActionSubscriber_unsubscribeStopsNotifications() {
        let store = AIChatStore()
        var hits = 0
        let sub = store.subscribeToActions { _, _ in hits += 1 }

        let call = ToolCall(id: "x2", name: "read_note", arguments: [:])
        store.dispatch(.toolCallRequested(call))
        XCTAssertEqual(hits, 1)

        sub.cancel()
        store.dispatch(.toolCallCompleted(call, .success(.success([:]))))
        XCTAssertEqual(hits, 1, "no further notifications after cancel")
    }
}
