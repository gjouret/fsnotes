//
//  AIChatPanelView.swift
//  FSNotes
//
//  AI assistant chat panel for reviewing, editing, and transforming notes.
//
//  This view is a thin reactor over `AIChatStore`. Users type into
//  the input field; the view dispatches actions to the store; the
//  store's reducer is the only thing that mutates conversation state;
//  the view's subscribe callback (`render(state:)`) reconciles the
//  message-stack against the current `AIChatState`. The view never
//  reaches into provider code or its own conversation state directly.
//
//  Provider invocation lives in `sendUserMessage` and feeds tokens
//  back to the store via `.receiveToken` / `.completeResponse`. This
//  keeps the store pure and testable on value types — the
//  `AIChatStoreTests` suite covers every reducer transition without
//  any AppKit setup.
//

import Cocoa

class AIChatPanelView: NSView {

    private var messagesScrollView: NSScrollView!
    private var messagesStack: NSStackView!
    private var inputTextView: NSTextView!
    private var inputScrollView: NSScrollView!
    private var sendButton: NSButton!
    private var headerLabel: NSTextField!
    private var closeButton: NSButton!
    private var quickActionsPopup: NSPopUpButton!

    /// Single source of truth for chat state. View dispatches actions
    /// to mutate; reducer in `AIChatStore.swift` handles transitions;
    /// subscribe callback re-renders. Constructed eagerly per panel
    /// instance — multi-window chat (Phase 4 follow-up) will switch
    /// this to an injected store, but one-per-panel is the right
    /// default for testability today.
    let store = AIChatStore()
    private var subscription: AIChatSubscription?
    private var actionSubscription: AIChatSubscription?

    /// Number of messages already materialised as bubbles in the
    /// stack. The render reconciler appends bubbles for indices
    /// `renderedMessageCount ..< state.messages.count` so a
    /// subscribe callback that fires every dispatch doesn't rebuild
    /// the entire history each time.
    private var renderedMessageCount: Int = 0

    /// The single in-flight streaming bubble, or nil when not
    /// streaming. Kept as a UI handle (not state) so the render
    /// reconciler can update its text in place from
    /// `state.streamingResponse` without rebuilding sibling bubbles.
    private var currentStreamingLabel: NSTextField?

    /// True once the user's first message has been dispatched and
    /// the empty-state hint has been removed. Tracked separately so
    /// the reconciler doesn't re-add the hint after `.clearChat`
    /// rebuilds (Phase 4 follow-up handles that case).
    private var emptyStateRemoved: Bool = false

    /// The error bubble currently displayed (if any). Cleared and
    /// removed when state.error transitions back to nil.
    private weak var currentErrorBubble: NSView?

    /// Bubble views keyed by `ToolCall.id` for in-flight tool-call
    /// status visualization. Phase 4 polish: the LLM may emit
    /// tool_calls during a streaming response — each gets its own
    /// distinct bubble that updates in place when the matching
    /// `.toolCallCompleted` action fires (success or error). Bubbles
    /// are inserted in chronological order between the assistant
    /// message that triggered them and any text response that
    /// follows. The dictionary survives clearChat — the bubble views
    /// themselves are removed via stack-view tear-down.
    private var toolCallBubbles: [String: ToolCallBubble] = [:]

    /// Confirmation bubbles awaiting user click, keyed by
    /// `ToolCall.id`. Each bubble holds a continuation that resumes
    /// the provider's dispatch loop once the user clicks Approve or
    /// Reject. Cleared on cancel / approve / reject so we never
    /// resume a continuation twice (which would trap).
    private var pendingConfirmationBubbles: [String: ToolCallConfirmationBubble] = [:]

    /// Stable per-note id (SHA-256 of note URL path). nil before
    /// first load.
    private var currentNoteId: String?

    /// Debounced persister — saves 500ms after each successful round.
    private lazy var persistenceDebouncer = AIChatPersistenceDebouncer()

    weak var editorViewController: EditorViewController?

    static let panelWidth: CGFloat = 320

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        wireStore()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        wireStore()
    }

    deinit {
        subscription?.cancel()
        actionSubscription?.cancel()
    }

    private func wireStore() {
        // Initial subscribe also fires synchronously with the empty
        // state, which is a no-op here (no messages, not streaming,
        // no error) — safe.
        subscription = store.subscribe { [weak self] state in
            self?.render(state: state)
        }
        // Action subscriber: tool-call completions erase the matching
        // entry from `state.pendingToolCalls`, so the state-only
        // subscriber can't tell whether a call ended with success or
        // error. The action callback carries the Result and lets the
        // view update the in-flight bubble in place.
        actionSubscription = store.subscribeToActions { [weak self] action, _ in
            self?.handleAction(action)
        }
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Left border
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        // Header
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)

        headerLabel = NSTextField(labelWithString: "AI Assistant")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        closeButton = NSButton()
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        headerStack.addArrangedSubview(headerLabel)
        headerStack.addArrangedSubview(closeButton)

        // Quick actions
        quickActionsPopup = NSPopUpButton()
        quickActionsPopup.pullsDown = true
        quickActionsPopup.translatesAutoresizingMaskIntoConstraints = false
        (quickActionsPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom

        quickActionsPopup.addItem(withTitle: "Quick Actions...")
        quickActionsPopup.addItem(withTitle: "Summarize this note")
        quickActionsPopup.addItem(withTitle: "Fix grammar and spelling")
        quickActionsPopup.addItem(withTitle: "Make more concise")
        quickActionsPopup.addItem(withTitle: "Expand on this")
        quickActionsPopup.addItem(withTitle: "Generate table of contents")
        quickActionsPopup.addItem(withTitle: "Translate to English")
        quickActionsPopup.addItem(withTitle: "Translate to Spanish")
        quickActionsPopup.addItem(withTitle: "Translate to French")
        quickActionsPopup.target = self
        quickActionsPopup.action = #selector(quickActionSelected)
        addSubview(quickActionsPopup)

        // Messages area
        messagesScrollView = NSScrollView()
        messagesScrollView.hasVerticalScroller = true
        messagesScrollView.hasHorizontalScroller = false
        messagesScrollView.borderType = .noBorder
        messagesScrollView.drawsBackground = false
        messagesScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messagesScrollView)

        messagesStack = NSStackView()
        messagesStack.orientation = .vertical
        messagesStack.spacing = 8
        messagesStack.alignment = .leading
        messagesStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = messagesStack
        clipView.drawsBackground = false
        messagesScrollView.contentView = clipView

        // Input area
        inputScrollView = NSScrollView()
        inputScrollView.hasVerticalScroller = true
        inputScrollView.borderType = .bezelBorder
        inputScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputScrollView)

        inputTextView = NSTextView()
        inputTextView.isEditable = true
        inputTextView.isRichText = false
        inputTextView.font = NSFont.systemFont(ofSize: 13)
        inputTextView.isVerticallyResizable = true
        inputTextView.isHorizontallyResizable = false
        inputTextView.textContainer?.widthTracksTextView = true
        inputTextView.delegate = self
        inputScrollView.documentView = inputTextView

        sendButton = NSButton()
        sendButton.bezelStyle = .accessoryBarAction
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")
        sendButton.imagePosition = .imageOnly
        sendButton.target = self
        sendButton.action = #selector(sendMessage)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sendButton)

        // Layout
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.widthAnchor.constraint(equalToConstant: 1),

            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            quickActionsPopup.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
            quickActionsPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            quickActionsPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            messagesScrollView.topAnchor.constraint(equalTo: quickActionsPopup.bottomAnchor, constant: 8),
            messagesScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            messagesScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            messagesScrollView.bottomAnchor.constraint(equalTo: inputScrollView.topAnchor, constant: -8),

            messagesStack.widthAnchor.constraint(equalTo: messagesScrollView.widthAnchor, constant: -16),

            inputScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            inputScrollView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            inputScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            inputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            inputScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 100),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        addEmptyStateLabel()
    }

    private func addEmptyStateLabel() {
        let label = NSTextField(wrappingLabelWithString: "Ask the AI to review, edit, summarize, or transform the current note.")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.tag = 999 // marker for removal
        messagesStack.addArrangedSubview(label)
    }

    // MARK: - Actions

    @objc private func closePanel() {
        if let vc = ViewController.shared() {
            vc.toggleAIChat(self)
        }
    }

    @objc private func quickActionSelected() {
        let index = quickActionsPopup.indexOfSelectedItem
        guard index > 0 else { return }
        let title = quickActionsPopup.titleOfSelectedItem ?? ""
        quickActionsPopup.selectItem(at: 0)
        sendUserMessage(title)
    }

    @objc private func sendMessage() {
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputTextView.string = ""
        sendUserMessage(text)
    }

    private func sendUserMessage(_ text: String) {
        // Guard against double-dispatch while a stream is in flight.
        // Single source of truth: the store, not the local flag that
        // used to live here.
        guard !store.state.isStreaming else { return }

        // Phase 4 polish: lazy-load any persisted conversation for
        // the current note before proceeding.
        ensureConversationLoaded(for: editorViewController?.vcEditor?.note)

        // Build the rich prompt context from the open note (if any).
        let context = makePromptContext()

        // Get AI provider before mutating store, so a missing-key
        // failure surfaces as an error bubble without first staging
        // a user-turn that has nothing to respond to. (Behaviour
        // preserved from pre-refactor: empty-state stays, no user
        // bubble appears, only the error message.)
        guard let provider = AIServiceFactory.createProvider() else {
            store.dispatch(.completeResponse(.failure(AIError.noAPIKey)))
            return
        }

        // Snapshot messages we'll send to the provider INCLUDING
        // the user turn we're about to commit. The reducer will
        // append the user turn to `state.messages`, and the captured
        // copy here matches what the provider needs to see (system
        // turns are filtered inside provider.sendMessage).
        var conversationToSend = store.state.messages
        conversationToSend.append(ChatMessage(role: .user, content: text))

        // Dispatch the user turn + start streaming. The render
        // callback will materialise the user bubble and the empty
        // streaming bubble in one pass.
        store.dispatch(.sendMessage(text))

        // Wire tool-call observers when the provider supports them.
        // Only Ollama emits tool calls today; other providers are
        // text-only via the AIProvider protocol.
        if let ollama = provider as? OllamaProvider {
            ollama.onToolCallStarted = { [weak self] call in
                self?.store.dispatch(.toolCallRequested(call))
            }
            ollama.onToolCallCompleted = { [weak self] call, output in
                // Translate the wire-shape ToolOutput into the
                // store's Result<ToolOutput, Error> envelope. The
                // failure case is reserved for transport-level
                // errors that never reach the tool dispatcher.
                self?.store.dispatch(.toolCallCompleted(call, .success(output)))
            }
            // Confirmation gate for destructive ops. Dispatch the
            // .toolCallConfirmRequested action and await the user's
            // click via a CheckedContinuation. The continuation is
            // captured by the bubble view; clicking Approve / Reject
            // resumes it with the matching Bool.
            ollama.confirmationRequester = { [weak self] call in
                guard let self = self else { return false }
                return await self.requestConfirmation(for: call)
            }
        }

        provider.sendMessage(messages: conversationToSend, context: context, onToken: { [weak self] token in
            self?.store.dispatch(.receiveToken(token))
        }, onComplete: { [weak self] result in
            guard let self = self else { return }
            self.store.dispatch(.completeResponse(result))
            // Apply-button rendering is a render-time concern that
            // depends on the assistant turn we just committed; it
            // lives outside the reducer because it manipulates
            // AppKit views, not state.
            if case .success(let fullText) = result,
               (fullText.contains("```") || fullText.count > 100) {
                self.addApplyButton(for: fullText)
            }
        })
    }

    // MARK: - Render reconciler

    /// Reconcile the visible UI against `state`. Called once on
    /// subscribe and again after every dispatch.
    private func render(state: AIChatState) {
        // 1. Remove the empty-state hint as soon as we have anything
        //    to show (a message, an in-flight stream, or an error).
        let hasContent = !state.messages.isEmpty
            || state.isStreaming
            || state.error != nil
        if hasContent && !emptyStateRemoved {
            messagesStack.arrangedSubviews
                .filter { $0.tag == 999 }
                .forEach { $0.removeFromSuperview() }
            emptyStateRemoved = true
        }

        // 2. Streaming-end fast path. Handle BEFORE adding new
        //    message bubbles so a successful commit reuses the
        //    streaming bubble as the final assistant bubble (no
        //    visual jump). The reducer guarantees that on
        //    .completeResponse(.success) it both appends the
        //    assistant turn and flips isStreaming to false in one
        //    transition, so this branch sees both at once.
        if !state.isStreaming, let label = currentStreamingLabel {
            if state.messages.count > renderedMessageCount,
               state.messages[renderedMessageCount].role == .assistant {
                // Reuse: the streaming label IS the bubble for
                // this committed assistant turn. Sync its text.
                label.stringValue = state.messages[renderedMessageCount].content
                renderedMessageCount += 1
            } else {
                // Stream ended without committing a turn (failure
                // case, or a stream that produced no text). Remove
                // the empty placeholder bubble so we don't leave
                // dead UI in the stack.
                if let bubble = label.superview {
                    messagesStack.removeArrangedSubview(bubble)
                    bubble.removeFromSuperview()
                }
            }
            currentStreamingLabel = nil
        }

        // 3. Append bubbles for any messages we haven't rendered.
        //    This runs after step 2 so a streaming-end commit is
        //    accounted for before we look at unrendered indices.
        if state.messages.count > renderedMessageCount {
            for index in renderedMessageCount..<state.messages.count {
                let msg = state.messages[index]
                addMessageBubble(text: msg.content, isUser: msg.role == .user)
            }
            renderedMessageCount = state.messages.count
        }

        // 4. Streaming-start / streaming-token path. Materialise
        //    an empty assistant bubble on the first token-or-flag
        //    transition; thereafter mirror state.streamingResponse
        //    into its label.
        if state.isStreaming {
            if currentStreamingLabel == nil {
                currentStreamingLabel = addMessageBubble(text: state.streamingResponse, isUser: false)
            } else {
                currentStreamingLabel?.stringValue = state.streamingResponse
                scrollToBottom()
            }
        }

        // 5. Error pane. One bubble at a time; replaces any prior
        //    error bubble. Cleared when state.error returns to nil
        //    (the next .sendMessage clears it via the reducer).
        if let err = state.error {
            currentErrorBubble?.removeFromSuperview()
            let label = addMessageBubble(text: "Error: \(err.localizedDescription)",
                                         isUser: false,
                                         isError: true)
            currentErrorBubble = label.superview
        } else if let bubble = currentErrorBubble {
            bubble.removeFromSuperview()
            currentErrorBubble = nil
        }

        // 6. Send button enabled iff not streaming.
        sendButton.isEnabled = !state.isStreaming
    }

    /// Resolve the rich prompt context from the open note. When no note
    /// is open, returns a default-initialised `AIPromptContext` whose
    /// `editorMode` is `.none` so the system prompt still renders cleanly.
    private func makePromptContext() -> AIPromptContext {
        guard let note = editorViewController?.vcEditor?.note else {
            return AIPromptContext(
                allTags: Storage.shared().tags
            )
        }

        // Editor mode: the global `hideSyntax` flag is the same gate
        // AppBridgeImpl.editorMode(for:) consults; mirror that here so
        // the prompt is consistent across providers and tool-side reads.
        let editorMode: AIPromptContext.EditorMode =
            NotesTextProcessor.hideSyntax ? .wysiwyg : .source

        // Folder: project's filesystem path relative to the storage
        // root. Falls back to the project label when no root is
        // configured (rare; only happens before bootstrap).
        let folder: String?
        if let root = UserDefaultsManagement.storageUrl?.standardizedFileURL.path {
            let projectPath = note.project.url.standardizedFileURL.path
            if projectPath.hasPrefix(root) {
                let trimmed = String(projectPath.dropFirst(root.count))
                folder = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
            } else {
                folder = note.project.label
            }
        } else {
            folder = note.project.label
        }

        // Project name: walk up to the top-level project (parent == nil)
        // so the LLM sees the storage container, not a nested folder.
        var topProject = note.project
        while let parent = topProject.parent {
            topProject = parent
        }

        return AIPromptContext(
            noteTitle: note.getTitle(),
            noteContent: note.content.string,
            noteFolder: folder,
            projectName: topProject.label,
            allTags: Storage.shared().tags,
            editorMode: editorMode,
            isTextBundle: note.isTextBundle()
        )
    }

    // MARK: - Message Bubbles

    /// Add a message bubble to the chat. Returns the label for streaming use.
    @discardableResult
    private func addMessageBubble(text: String, isUser: Bool, isError: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false

        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.translatesAutoresizingMaskIntoConstraints = false

        if isError {
            bubble.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
            label.textColor = .systemRed
        } else if isUser {
            bubble.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        } else {
            bubble.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.05).cgColor
        }
        bubble.layer?.cornerRadius = 8

        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -8),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: AIChatPanelView.panelWidth - 40),
        ])

        messagesStack.addArrangedSubview(bubble)

        if isUser {
            bubble.trailingAnchor.constraint(equalTo: messagesStack.trailingAnchor).isActive = true
        }

        scrollToBottom()
        return label
    }

    // MARK: - Tool-call bubbles

    /// Handle an action that affects tool-call bubble UI. Bubble
    /// state only depends on `.toolCallRequested` and
    /// `.toolCallCompleted`; everything else is ignored. Called from
    /// the action subscriber.
    private func handleAction(_ action: AIChatAction) {
        switch action {
        case .toolCallRequested(let call):
            addToolCallBubble(call)
        case .toolCallCompleted(let call, let result):
            updateToolCallBubble(call, result: result)
        case .clearChat:
            // Drop the bubble dictionary; the message-stack tear-down
            // happens in render() when it sees the empty messages
            // array. Future Phase 4 follow-up to handle clearChat
            // rebuild more cleanly.
            toolCallBubbles.removeAll()
            // Cancel any in-flight confirmations by resuming with
            // false (treated as rejection). Without this the
            // provider's continuation would leak.
            for (_, bubble) in pendingConfirmationBubbles {
                bubble.resolve(approved: false)
            }
            pendingConfirmationBubbles.removeAll()
            // Phase 4 polish: persist intent. Cleared chat must not
            // reappear on next note open.
            persistenceDebouncer.cancel()
            if let id = currentNoteId {
                AIChatPersistence.delete(noteId: id)
            }
        case .completeResponse(.success):
            // Phase 4 polish: schedule a debounced save after every
            // successful round.
            if let id = currentNoteId {
                persistenceDebouncer.schedule(noteId: id, messages: store.state.messages)
            }
        default:
            break
        }
    }

    // MARK: - Per-note conversation loading

    /// Activate a note's conversation. Idempotent — only touches
    /// disk on note-change.
    private func ensureConversationLoaded(for note: Note?) {
        guard let note = note else { return }
        let id = AIChatPersistence.noteId(forURL: note.url)
        if id == currentNoteId { return }
        currentNoteId = id
        persistenceDebouncer.cancel()
        let loaded = AIChatPersistence.load(noteId: id) ?? []
        store.dispatch(.loadConversation(loaded))
        rebuildMessageStackForLoadedConversation()
    }

    /// Hard-reset the visible bubble stack to match a freshly
    /// loaded `state.messages`. Removes every arranged subview
    /// except the empty-state hint placeholder, then re-renders.
    private func rebuildMessageStackForLoadedConversation() {
        let arranged = messagesStack.arrangedSubviews
        for view in arranged where view.tag != 999 {
            messagesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        renderedMessageCount = 0
        currentStreamingLabel = nil
        currentErrorBubble = nil
        toolCallBubbles.removeAll()
        for (_, bubble) in pendingConfirmationBubbles {
            bubble.resolve(approved: false)
        }
        pendingConfirmationBubbles.removeAll()
        emptyStateRemoved = false
        render(state: store.state)
    }

    // MARK: - Confirmation bubbles

    /// Async entry point invoked by the provider's confirmation
    /// requester. Dispatches the `.toolCallConfirmRequested` action
    /// (which the reducer adds to `pendingConfirmations`), inserts a
    /// confirmation bubble into the stack, and suspends until the
    /// user clicks Approve or Reject. The continuation is owned by
    /// the bubble — its `resolve(approved:)` resumes the suspension.
    @MainActor
    private func requestConfirmation(for call: ToolCall) async -> Bool {
        store.dispatch(.toolCallConfirmRequested(call))
        return await withCheckedContinuation { continuation in
            addConfirmationBubble(for: call, continuation: continuation)
        }
    }

    private func addConfirmationBubble(for call: ToolCall,
                                        continuation: CheckedContinuation<Bool, Never>) {
        if !emptyStateRemoved {
            messagesStack.arrangedSubviews
                .filter { $0.tag == 999 }
                .forEach { $0.removeFromSuperview() }
            emptyStateRemoved = true
        }
        let bubble = ToolCallConfirmationBubble(
            call: call,
            maxWidth: AIChatPanelView.panelWidth - 40
        ) { [weak self] approved in
            self?.handleConfirmation(call: call, approved: approved)
        }
        bubble.attach(continuation: continuation)
        pendingConfirmationBubbles[call.id] = bubble
        messagesStack.addArrangedSubview(bubble)
        scrollToBottom()
    }

    private func handleConfirmation(call: ToolCall, approved: Bool) {
        guard let bubble = pendingConfirmationBubbles.removeValue(forKey: call.id) else {
            return
        }
        if approved {
            store.dispatch(.toolCallApproved(call))
        } else {
            store.dispatch(.toolCallRejected(call))
        }
        bubble.resolve(approved: approved)
    }

    private func addToolCallBubble(_ call: ToolCall) {
        guard toolCallBubbles[call.id] == nil else { return }
        // Drop the empty-state hint as soon as we have anything to
        // show — mirrors the same logic in render().
        if !emptyStateRemoved {
            messagesStack.arrangedSubviews
                .filter { $0.tag == 999 }
                .forEach { $0.removeFromSuperview() }
            emptyStateRemoved = true
        }
        let bubble = ToolCallBubble(call: call,
                                    maxWidth: AIChatPanelView.panelWidth - 40)
        toolCallBubbles[call.id] = bubble
        messagesStack.addArrangedSubview(bubble)
        scrollToBottom()
    }

    private func updateToolCallBubble(_ call: ToolCall, result: Result<ToolOutput, Error>) {
        guard let bubble = toolCallBubbles[call.id] else { return }
        bubble.applyResult(result)
        scrollToBottom()
    }

    private func addApplyButton(for text: String) {
        let button = NSButton(title: "Apply to Note", target: self, action: #selector(applyToNote(_:)))
        button.bezelStyle = .accessoryBarAction
        // Tag stores the index of the assistant message in
        // `store.state.messages`. The button's lifetime is bounded
        // by the panel — even after future `.clearChat` rebuilds
        // (Phase 4 follow-up), the index lookup is bounds-checked
        // so a stale button stays inert rather than crashing.
        button.tag = store.state.messages.count - 1
        button.translatesAutoresizingMaskIntoConstraints = false
        messagesStack.addArrangedSubview(button)
        scrollToBottom()
    }

    @objc private func applyToNote(_ sender: NSButton) {
        let msgIndex = sender.tag
        let messages = store.state.messages
        guard msgIndex >= 0, msgIndex < messages.count else { return }

        let content = messages[msgIndex].content
        guard let editor = editorViewController?.vcEditor,
              editor.note != nil else { return }

        // Extract code block content if present, otherwise use full response
        var textToInsert = content
        if let codeBlockRange = content.range(of: "```[^\n]*\n", options: .regularExpression),
           let closeRange = content.range(of: "\n```", options: [], range: codeBlockRange.upperBound..<content.endIndex) {
            textToInsert = String(content[codeBlockRange.upperBound..<closeRange.lowerBound])
        }

        // Replace note content
        let fullRange = NSRange(location: 0, length: editor.textStorage?.length ?? 0)
        editor.insertText(textToInsert, replacementRange: fullRange)

        editor.save()
    }

    private func scrollToBottom() {
        DispatchQueue.main.async {
            if let documentView = self.messagesScrollView.documentView {
                documentView.scrollToEndOfDocument(nil)
            }
        }
    }
}

// MARK: - NSTextViewDelegate

extension AIChatPanelView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                return false // Allow Shift+Return for newline
            }
            sendMessage()
            return true // Return sends message
        }
        return false
    }
}
