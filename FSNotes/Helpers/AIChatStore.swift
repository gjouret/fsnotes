//
//  AIChatStore.swift
//  FSNotes
//
//  Redux-style state container for the AI chat panel. Architecture
//  Principle 1 in `docs/AI.md` (lines 19, 104-133): the chat surface
//  must dispatch actions through a single store rather than calling
//  the provider and mutating view state inline.
//
//  The store owns the conversation history, streaming flag, last
//  error, and any pending tool calls. It is a *pure* state holder:
//  it does NOT call the AI provider itself. The view layer (or a
//  future controller) is responsible for invoking the provider and
//  feeding results back via `dispatch(.receiveToken)` /
//  `.completeResponse` / `.toolCallRequested` /
//  `.toolCallCompleted`. This keeps the reducer testable as a pure
//  function on value types.
//
//  Threading: every public method asserts main-queue. Subscribers are
//  invoked synchronously after each dispatch on the same queue. Move
//  off-main work (provider calls, tool execution) outside the store.
//
//  Access level: types here are `internal` (module-private) to match
//  the rest of the AI surface (`ChatMessage`, `AIError`, `ToolCall`,
//  `ToolOutput` are all internal in the FSNotes target). The
//  `docs/AI.md` spec writes them as `public`; that's aspirational —
//  if the AI layer is later split into its own framework, raise
//  every type's access in lockstep.
//

import Foundation

// MARK: - State

struct AIChatState {
    var messages: [ChatMessage]
    var isStreaming: Bool
    var error: AIError?
    var pendingToolCalls: [ToolCall]

    /// Tool calls awaiting user confirmation before they execute.
    /// Phase 4 polish: destructive operations (delete_note, move_note)
    /// must be approved by the user, not the LLM. The provider's
    /// dispatch loop pauses while the matching call sits here; the
    /// view renders a confirm/reject bubble; one of `.toolCallApproved`
    /// or `.toolCallRejected` resumes the loop and removes the entry.
    var pendingConfirmations: [ToolCall]

    /// Buffer for the assistant token stream currently in flight.
    /// Surfaces in the view as the streaming bubble's text. Cleared
    /// on `.completeResponse` (when the buffered text is appended to
    /// `messages` as the final assistant turn) and on `.clearChat`.
    var streamingResponse: String

    init(messages: [ChatMessage] = [],
         isStreaming: Bool = false,
         error: AIError? = nil,
         pendingToolCalls: [ToolCall] = [],
         pendingConfirmations: [ToolCall] = [],
         streamingResponse: String = "") {
        self.messages = messages
        self.isStreaming = isStreaming
        self.error = error
        self.pendingToolCalls = pendingToolCalls
        self.pendingConfirmations = pendingConfirmations
        self.streamingResponse = streamingResponse
    }
}

// MARK: - Actions

enum AIChatAction {
    /// User submitted a new message. Reducer appends a user-role
    /// `ChatMessage`, sets `isStreaming = true`, clears any prior
    /// error and streaming buffer.
    case sendMessage(String)

    /// One streaming token arrived from the provider. Reducer
    /// appends to `streamingResponse` only — the assistant turn is
    /// committed to `messages` on `.completeResponse(.success)`.
    case receiveToken(String)

    /// Stream finished. On success, the final string is appended to
    /// `messages` as an assistant turn and `streamingResponse` is
    /// cleared. On failure, the error is stored and the streaming
    /// buffer is cleared without committing a partial turn.
    case completeResponse(Result<String, Error>)

    /// LLM requested a tool call. Reducer appends to
    /// `pendingToolCalls`. View can render confirmation UI gated on
    /// this list (Phase 4 follow-up: tool-call confirmation for
    /// destructive ops).
    case toolCallRequested(ToolCall)

    /// Tool call finished (success or error). Reducer removes the
    /// matching entry from `pendingToolCalls` (matched by `id`).
    case toolCallCompleted(ToolCall, Result<ToolOutput, Error>)

    /// Reset the conversation. Clears messages, streaming state,
    /// error, pending tool calls. Subscribers are still notified.
    case clearChat

    /// LLM requested a destructive tool call. Reducer appends to
    /// `pendingConfirmations`; the provider's dispatch loop is
    /// paused until the user dispatches `.toolCallApproved` or
    /// `.toolCallRejected`. The view renders a confirm-bubble in
    /// response.
    case toolCallConfirmRequested(ToolCall)

    /// User approved a pending confirmation. Reducer removes the
    /// matching entry from `pendingConfirmations`; the provider's
    /// continuation observes the action via `subscribeToActions`
    /// and resumes the chat round.
    case toolCallApproved(ToolCall)

    /// User rejected a pending confirmation. Reducer removes the
    /// matching entry. The provider feeds back a synthetic
    /// `ToolOutput.error("user rejected destructive operation")`
    /// in place of the real result and continues the chat loop.
    case toolCallRejected(ToolCall)
}

// MARK: - Reducer

/// Pure reduction. Tested directly in `AIChatStoreTests`.
func reduce(state: AIChatState, action: AIChatAction) -> AIChatState {
    var s = state
    switch action {
    case .sendMessage(let text):
        s.messages.append(ChatMessage(role: .user, content: text))
        s.isStreaming = true
        s.error = nil
        s.streamingResponse = ""

    case .receiveToken(let token):
        s.streamingResponse += token

    case .completeResponse(let result):
        s.isStreaming = false
        switch result {
        case .success(let fullText):
            // Prefer the fully accumulated text from the provider.
            // If empty (defensive — provider emitted nothing), fall
            // back to the streaming buffer so we don't drop a turn.
            let finalText = fullText.isEmpty ? s.streamingResponse : fullText
            if !finalText.isEmpty {
                s.messages.append(ChatMessage(role: .assistant, content: finalText))
            }
        case .failure(let err):
            s.error = (err as? AIError) ?? .apiError(err.localizedDescription)
        }
        s.streamingResponse = ""

    case .toolCallRequested(let call):
        s.pendingToolCalls.append(call)

    case .toolCallCompleted(let call, let result):
        s.pendingToolCalls.removeAll { $0.id == call.id }
        if case .failure(let err) = result {
            s.error = (err as? AIError) ?? .apiError(err.localizedDescription)
        }

    case .clearChat:
        s.messages = []
        s.isStreaming = false
        s.error = nil
        s.pendingToolCalls = []
        s.pendingConfirmations = []
        s.streamingResponse = ""

    case .toolCallConfirmRequested(let call):
        s.pendingConfirmations.append(call)

    case .toolCallApproved(let call):
        s.pendingConfirmations.removeAll { $0.id == call.id }

    case .toolCallRejected(let call):
        s.pendingConfirmations.removeAll { $0.id == call.id }
    }
    return s
}

// MARK: - Store

/// Token returned by `subscribe(_:)` so the caller can stop
/// receiving notifications. The store keeps a weak handle to the
/// subscription block via the token's identity; cancelling sets the
/// underlying slot to nil so the dispatch loop skips it.
final class AIChatSubscription {
    fileprivate let id: UUID
    fileprivate weak var store: AIChatStore?

    fileprivate init(id: UUID, store: AIChatStore) {
        self.id = id
        self.store = store
    }

    func cancel() {
        store?.unsubscribe(self)
    }
}

final class AIChatStore {

    private(set) var state: AIChatState

    private struct Subscriber {
        let id: UUID
        let callback: (AIChatState) -> Void
    }
    private struct ActionSubscriber {
        let id: UUID
        let callback: (AIChatAction, AIChatState) -> Void
    }
    private var subscribers: [Subscriber] = []
    private var actionSubscribers: [ActionSubscriber] = []

    init(initialState: AIChatState = AIChatState()) {
        self.state = initialState
    }

    /// Apply an action. Synchronous, main-queue only.
    func dispatch(_ action: AIChatAction) {
        Self.assertMainQueue()
        state = reduce(state: state, action: action)
        // Snapshot the subscriber list so cancellations triggered by
        // a subscriber don't mutate the array we're iterating.
        let stateSnapshot = subscribers
        for sub in stateSnapshot {
            sub.callback(state)
        }
        let actionSnapshot = actionSubscribers
        for sub in actionSnapshot {
            sub.callback(action, state)
        }
    }

    /// Subscribe to state changes. The callback fires once
    /// immediately with the current state, then on every subsequent
    /// dispatch. Cancel via the returned `AIChatSubscription`.
    @discardableResult
    func subscribe(_ callback: @escaping (AIChatState) -> Void) -> AIChatSubscription {
        Self.assertMainQueue()
        let token = AIChatSubscription(id: UUID(), store: self)
        subscribers.append(Subscriber(id: token.id, callback: callback))
        callback(state)
        return token
    }

    /// Subscribe to actions. Callback fires AFTER the reducer has
    /// applied the action, with both the action and the resulting
    /// state. Lets the view layer react to transitions that erase
    /// information from `state` (e.g. `.toolCallCompleted` removes
    /// the matching pending call so the state alone can't drive a
    /// bubble update). Cancel via the returned subscription.
    @discardableResult
    func subscribeToActions(_ callback: @escaping (AIChatAction, AIChatState) -> Void) -> AIChatSubscription {
        Self.assertMainQueue()
        let token = AIChatSubscription(id: UUID(), store: self)
        actionSubscribers.append(ActionSubscriber(id: token.id, callback: callback))
        return token
    }

    fileprivate func unsubscribe(_ token: AIChatSubscription) {
        Self.assertMainQueue()
        subscribers.removeAll { $0.id == token.id }
        actionSubscribers.removeAll { $0.id == token.id }
    }

    // MARK: - Threading

    private static func assertMainQueue() {
        dispatchPrecondition(condition: .onQueue(.main))
    }
}
