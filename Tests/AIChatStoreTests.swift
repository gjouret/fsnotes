//
//  AIChatStoreTests.swift
//  FSNotesTests
//
//  Pure-function tests for the chat store reducer plus the
//  subscribe / unsubscribe contract. The store does no I/O and no
//  AppKit work, so these tests run with no harness setup.
//

import XCTest
@testable import FSNotes

final class AIChatStoreTests: XCTestCase {

    // MARK: - Reducer: per-action

    func test_sendMessage_appendsUserTurnAndStartsStreaming() {
        let s0 = AIChatState()
        let s1 = reduce(state: s0, action: .sendMessage("Hello"))

        XCTAssertEqual(s1.messages.count, 1)
        XCTAssertEqual(s1.messages.first?.role, .user)
        XCTAssertEqual(s1.messages.first?.content, "Hello")
        XCTAssertTrue(s1.isStreaming)
        XCTAssertEqual(s1.streamingResponse, "")
        XCTAssertNil(s1.error)
    }

    func test_sendMessage_clearsPriorError() {
        var s0 = AIChatState()
        s0.error = .noAPIKey
        let s1 = reduce(state: s0, action: .sendMessage("Hi"))
        XCTAssertNil(s1.error)
    }

    func test_receiveToken_appendsToStreamingBufferOnly() {
        let s0 = AIChatState(isStreaming: true)
        let s1 = reduce(state: s0, action: .receiveToken("Hel"))
        let s2 = reduce(state: s1, action: .receiveToken("lo"))
        XCTAssertEqual(s2.streamingResponse, "Hello")
        // Tokens never touch `messages` directly — assistant turn is
        // committed only on .completeResponse.
        XCTAssertEqual(s2.messages.count, 0)
        XCTAssertTrue(s2.isStreaming)
    }

    func test_completeResponse_success_commitsAssistantTurnAndClearsBuffer() {
        var s0 = AIChatState(isStreaming: true, streamingResponse: "Hel")
        s0.messages = [ChatMessage(role: .user, content: "Hi")]
        let s1 = reduce(state: s0, action: .completeResponse(.success("Hello there")))

        XCTAssertFalse(s1.isStreaming)
        XCTAssertEqual(s1.messages.count, 2)
        XCTAssertEqual(s1.messages.last?.role, .assistant)
        XCTAssertEqual(s1.messages.last?.content, "Hello there")
        XCTAssertEqual(s1.streamingResponse, "")
        XCTAssertNil(s1.error)
    }

    func test_completeResponse_emptySuccessFallsBackToStreamingBuffer() {
        let s0 = AIChatState(isStreaming: true, streamingResponse: "buffered")
        let s1 = reduce(state: s0, action: .completeResponse(.success("")))
        XCTAssertEqual(s1.messages.last?.content, "buffered")
        XCTAssertEqual(s1.streamingResponse, "")
    }

    func test_completeResponse_failureStoresErrorAndDoesNotCommitTurn() {
        let s0 = AIChatState(messages: [ChatMessage(role: .user, content: "Hi")],
                             isStreaming: true,
                             streamingResponse: "partial")
        let s1 = reduce(state: s0, action: .completeResponse(.failure(AIError.noAPIKey)))

        XCTAssertFalse(s1.isStreaming)
        XCTAssertEqual(s1.messages.count, 1, "Failed stream must not commit a partial assistant turn")
        XCTAssertEqual(s1.streamingResponse, "")
        if case .noAPIKey = s1.error {
            // ok
        } else {
            XCTFail("Expected .noAPIKey, got \(String(describing: s1.error))")
        }
    }

    func test_completeResponse_genericErrorWrappedAsApiError() {
        struct BoringError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let s0 = AIChatState(isStreaming: true)
        let s1 = reduce(state: s0, action: .completeResponse(.failure(BoringError())))
        if case .apiError(let msg) = s1.error {
            XCTAssertEqual(msg, "boom")
        } else {
            XCTFail("Expected .apiError(\"boom\"), got \(String(describing: s1.error))")
        }
    }

    func test_toolCallRequested_appendsToPending() {
        let s0 = AIChatState()
        let call = ToolCall(id: "c1", name: "read_note", arguments: [:])
        let s1 = reduce(state: s0, action: .toolCallRequested(call))
        XCTAssertEqual(s1.pendingToolCalls.count, 1)
        XCTAssertEqual(s1.pendingToolCalls.first?.id, "c1")
    }

    func test_toolCallCompleted_removesMatchingPendingByID() {
        var s0 = AIChatState()
        s0.pendingToolCalls = [
            ToolCall(id: "c1", name: "a", arguments: [:]),
            ToolCall(id: "c2", name: "b", arguments: [:]),
        ]
        let s1 = reduce(state: s0,
                        action: .toolCallCompleted(ToolCall(id: "c1", name: "a", arguments: [:]),
                                                    .success(.success(["ok": true]))))
        XCTAssertEqual(s1.pendingToolCalls.count, 1)
        XCTAssertEqual(s1.pendingToolCalls.first?.id, "c2")
        XCTAssertNil(s1.error)
    }

    func test_toolCallCompleted_failureStoresError() {
        var s0 = AIChatState()
        s0.pendingToolCalls = [ToolCall(id: "c1", name: "a", arguments: [:])]
        let s1 = reduce(state: s0,
                        action: .toolCallCompleted(ToolCall(id: "c1", name: "a", arguments: [:]),
                                                    .failure(AIError.apiError("tool failed"))))
        XCTAssertEqual(s1.pendingToolCalls.count, 0)
        if case .apiError(let msg) = s1.error {
            XCTAssertEqual(msg, "tool failed")
        } else {
            XCTFail("Expected .apiError, got \(String(describing: s1.error))")
        }
    }

    func test_clearChat_resetsConversationFully() {
        // `clearChat` resets every conversation field but does not
        // touch any editor-side state. The actual editor flow lives
        // in `EditingOps` → `applyEditResultWithUndo` →
        // `applyDocumentEdit` (single write path) and Phase 5f's
        // `UndoJournal`; the chat store doesn't hold a reference.
        let store = AIChatStore(initialState: AIChatState(
            messages: [ChatMessage(role: .user, content: "Hi"),
                       ChatMessage(role: .assistant, content: "Hello")],
            isStreaming: true,
            error: .noAPIKey,
            pendingToolCalls: [ToolCall(id: "c1", name: "a", arguments: [:])],
            streamingResponse: "wip"))

        store.dispatch(.clearChat)

        XCTAssertEqual(store.state.messages.count, 0)
        XCTAssertFalse(store.state.isStreaming)
        XCTAssertNil(store.state.error)
        XCTAssertEqual(store.state.pendingToolCalls.count, 0)
        XCTAssertEqual(store.state.streamingResponse, "")
    }

    // MARK: - Subscribe / dispatch / unsubscribe

    func test_subscribe_firesImmediatelyWithCurrentState() {
        let store = AIChatStore(initialState: AIChatState(
            messages: [ChatMessage(role: .user, content: "x")]))
        var seen: [Int] = []
        let token = store.subscribe { state in
            seen.append(state.messages.count)
        }
        XCTAssertEqual(seen, [1], "subscribe must fire once immediately with the current state")
        token.cancel()
    }

    func test_dispatch_notifiesAllSubscribers() {
        let store = AIChatStore()
        var aHits = 0
        var bHits = 0
        let a = store.subscribe { _ in aHits += 1 }
        let b = store.subscribe { _ in bHits += 1 }
        // Each starts with one initial-state notification.
        XCTAssertEqual(aHits, 1)
        XCTAssertEqual(bHits, 1)

        store.dispatch(.sendMessage("hi"))
        XCTAssertEqual(aHits, 2)
        XCTAssertEqual(bHits, 2)

        store.dispatch(.receiveToken("yo"))
        XCTAssertEqual(aHits, 3)
        XCTAssertEqual(bHits, 3)

        a.cancel()
        b.cancel()
    }

    func test_unsubscribe_stopsFurtherNotifications() {
        let store = AIChatStore()
        var hits = 0
        let token = store.subscribe { _ in hits += 1 }
        XCTAssertEqual(hits, 1, "initial-state notification")

        store.dispatch(.sendMessage("a"))
        XCTAssertEqual(hits, 2)

        token.cancel()

        store.dispatch(.sendMessage("b"))
        store.dispatch(.receiveToken("x"))
        XCTAssertEqual(hits, 2, "no further notifications after cancel")
    }

    func test_subscribeUnsubscribeFromInsideCallback_isSafe() {
        // A subscriber that cancels itself during dispatch must not
        // crash the dispatch loop or skip sibling subscribers. The
        // store snapshots the subscriber list before iterating.
        let store = AIChatStore()

        var siblingHits = 0
        let sibling = store.subscribe { _ in siblingHits += 1 }

        var selfCancellingHits = 0
        var selfToken: AIChatSubscription?
        selfToken = store.subscribe { _ in
            selfCancellingHits += 1
            if selfCancellingHits >= 2 {
                selfToken?.cancel()
            }
        }

        // Each subscribe fired once at registration. Then dispatch.
        store.dispatch(.sendMessage("a")) // selfHits -> 2 (cancels), sibling -> 2
        store.dispatch(.receiveToken("z")) // self stays at 2, sibling -> 3

        XCTAssertEqual(selfCancellingHits, 2, "self-cancelling subscriber stops after cancel")
        XCTAssertEqual(siblingHits, 3, "sibling keeps receiving notifications")

        sibling.cancel()
    }

    func test_state_pendingToolCalls_accumulateAndClearProperly() {
        let store = AIChatStore()
        let c1 = ToolCall(id: "c1", name: "a", arguments: [:])
        let c2 = ToolCall(id: "c2", name: "b", arguments: [:])

        store.dispatch(.toolCallRequested(c1))
        store.dispatch(.toolCallRequested(c2))
        XCTAssertEqual(store.state.pendingToolCalls.map(\.id), ["c1", "c2"])

        store.dispatch(.toolCallCompleted(c1, .success(.success(["ok": true]))))
        XCTAssertEqual(store.state.pendingToolCalls.map(\.id), ["c2"])

        store.dispatch(.toolCallCompleted(c2, .success(.error("tool said no"))))
        XCTAssertEqual(store.state.pendingToolCalls.count, 0)
    }
}
