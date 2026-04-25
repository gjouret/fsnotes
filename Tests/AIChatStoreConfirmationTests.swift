//
//  AIChatStoreConfirmationTests.swift
//  FSNotesTests
//
//  Reducer tests for the Phase 4 destructive-tool confirmation
//  slice. Validates the new `.toolCallConfirmRequested`,
//  `.toolCallApproved`, `.toolCallRejected` actions plus the
//  `pendingConfirmations` state field. Also covers the
//  `OllamaProvider.needsConfirmToolNames` static set, since the
//  needs-confirm policy is part of the contract these tests pin down.
//

import XCTest
@testable import FSNotes

final class AIChatStoreConfirmationTests: XCTestCase {

    // MARK: - State invariants

    func test_initialState_pendingConfirmations_isEmpty() {
        let s = AIChatState()
        XCTAssertEqual(s.pendingConfirmations.count, 0)
    }

    // MARK: - Confirm requested

    func test_confirmRequested_appendsToPendingConfirmations() {
        let s0 = AIChatState()
        let call = ToolCall(id: "c1", name: "delete_note", arguments: ["path": "Inbox/x.md"])
        let s1 = reduce(state: s0, action: .toolCallConfirmRequested(call))
        XCTAssertEqual(s1.pendingConfirmations.map(\.id), ["c1"])
    }

    func test_confirmRequested_doesNotTouchPendingToolCalls() {
        let s0 = AIChatState()
        let call = ToolCall(id: "c1", name: "delete_note", arguments: [:])
        let s1 = reduce(state: s0, action: .toolCallConfirmRequested(call))
        XCTAssertEqual(s1.pendingToolCalls.count, 0,
                       "confirm-requested must not appear in pendingToolCalls (different surface)")
    }

    // MARK: - Approve

    func test_approved_removesMatchingPending() {
        var s0 = AIChatState()
        s0.pendingConfirmations = [
            ToolCall(id: "c1", name: "delete_note", arguments: [:]),
            ToolCall(id: "c2", name: "move_note", arguments: [:]),
        ]
        let s1 = reduce(state: s0,
                        action: .toolCallApproved(ToolCall(id: "c1", name: "delete_note", arguments: [:])))
        XCTAssertEqual(s1.pendingConfirmations.map(\.id), ["c2"])
    }

    func test_approved_unknownIDIsNoOp() {
        var s0 = AIChatState()
        s0.pendingConfirmations = [
            ToolCall(id: "c1", name: "delete_note", arguments: [:]),
        ]
        let s1 = reduce(state: s0,
                        action: .toolCallApproved(ToolCall(id: "ghost", name: "delete_note", arguments: [:])))
        XCTAssertEqual(s1.pendingConfirmations.map(\.id), ["c1"])
    }

    // MARK: - Reject

    func test_rejected_removesMatchingPending() {
        var s0 = AIChatState()
        s0.pendingConfirmations = [
            ToolCall(id: "c1", name: "delete_note", arguments: [:]),
        ]
        let s1 = reduce(state: s0,
                        action: .toolCallRejected(ToolCall(id: "c1", name: "delete_note", arguments: [:])))
        XCTAssertEqual(s1.pendingConfirmations.count, 0)
    }

    // MARK: - clearChat

    func test_clearChat_drainsPendingConfirmations() {
        var s0 = AIChatState()
        s0.pendingConfirmations = [
            ToolCall(id: "c1", name: "delete_note", arguments: [:]),
            ToolCall(id: "c2", name: "move_note", arguments: [:]),
        ]
        let s1 = reduce(state: s0, action: .clearChat)
        XCTAssertEqual(s1.pendingConfirmations.count, 0)
    }

    // MARK: - Needs-confirm policy

    func test_needsConfirmToolNames_includesDestructiveTools() {
        XCTAssertTrue(OllamaProvider.needsConfirmToolNames.contains("delete_note"))
        XCTAssertTrue(OllamaProvider.needsConfirmToolNames.contains("move_note"))
    }

    func test_needsConfirmToolNames_excludesSafeTools() {
        XCTAssertFalse(OllamaProvider.needsConfirmToolNames.contains("read_note"))
        XCTAssertFalse(OllamaProvider.needsConfirmToolNames.contains("list_folders"))
        XCTAssertFalse(OllamaProvider.needsConfirmToolNames.contains("search_notes"))
    }

    // MARK: - Action subscriber sees confirm flow

    func test_actionSubscriber_seesConfirmRequestedAndApproved() {
        let store = AIChatStore()
        var seen: [String] = []
        let sub = store.subscribeToActions { action, _ in
            switch action {
            case .toolCallConfirmRequested(let c): seen.append("confirm:\(c.id)")
            case .toolCallApproved(let c): seen.append("approve:\(c.id)")
            case .toolCallRejected(let c): seen.append("reject:\(c.id)")
            default: break
            }
        }

        let call = ToolCall(id: "x1", name: "delete_note", arguments: [:])
        store.dispatch(.toolCallConfirmRequested(call))
        store.dispatch(.toolCallApproved(call))

        XCTAssertEqual(seen, ["confirm:x1", "approve:x1"])
        sub.cancel()
    }

    func test_confirmationBubble_resolveResumesContinuationOnce() {
        let exp = expectation(description: "continuation resumed exactly once")
        let call = ToolCall(id: "c1", name: "delete_note", arguments: [:])
        let bubble = ToolCallConfirmationBubble(call: call, maxWidth: 280) { _ in }

        var resumeCount = 0
        Task { @MainActor in
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                bubble.attach(continuation: cont)
                // Resolve approved=true; second resolve must be ignored
                bubble.resolve(approved: true)
                bubble.resolve(approved: false)
            }
            resumeCount += 1
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertTrue(bubble.isResolved)
    }
}
