//
//  AIChatToolCallBubble.swift
//  FSNotes
//
//  Inline status bubble rendered in the chat scroll area whenever the
//  LLM emits a tool call. Phase 4 polish (docs/AI.md:920): tool
//  execution must be visible to the user — the bubble shows
//  "Calling: tool_name(args)" while the call is in flight, then
//  flips to "✓ tool_name returned: <preview>" or
//  "✗ tool_name failed: <message>" once the result lands.
//
//  Style: lighter background than message bubbles, monospace font for
//  the tool name + arguments so the wire shape is readable. Error
//  state tints the background red. The bubble is a value-typed
//  `NSView` so it can be unit-tested without a real window: tests
//  construct a bubble, assert its labels, call `applyResult(...)`,
//  assert the new labels.
//

import Cocoa

final class ToolCallBubble: NSView {

    let call: ToolCall
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField

    /// Maximum width preview text wraps at. The chat panel's stack
    /// view is fixed-width so the bubble inherits its width via stack
    /// alignment, but we still constrain the inner labels for safety
    /// against very long single-token strings.
    init(call: ToolCall, maxWidth: CGFloat) {
        self.call = call
        self.nameLabel = NSTextField(labelWithString: "")
        self.detailLabel = NSTextField(wrappingLabelWithString: "")

        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.15).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameLabel)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: max(maxWidth, 100)),
        ])

        renderInFlightState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ToolCallBubble")
    }

    // MARK: - Rendering

    /// "Calling: tool_name(arg1=value, arg2=…)" — pre-result state.
    func renderInFlightState() {
        nameLabel.stringValue = "Calling: \(call.name)\(formatArguments(call.arguments))"
        detailLabel.stringValue = "…running"
        detailLabel.textColor = .secondaryLabelColor
        layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.15).cgColor
    }

    /// Update the bubble in place when the matching tool call
    /// finishes. Success: green-tinged checkmark + 80-char output
    /// preview. Failure: red-tinged x + verbatim error message.
    func applyResult(_ result: Result<ToolOutput, Error>) {
        switch result {
        case .success(.success(let payload)):
            nameLabel.stringValue = "\u{2713} \(call.name) returned"
            nameLabel.textColor = .systemGreen
            detailLabel.stringValue = previewPayload(payload)
            detailLabel.textColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.05).cgColor
            layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.2).cgColor
        case .success(.error(let message)):
            renderFailure(message)
        case .failure(let err):
            renderFailure(err.localizedDescription)
        }
    }

    private func renderFailure(_ message: String) {
        nameLabel.stringValue = "\u{2717} \(call.name) failed"
        nameLabel.textColor = .systemRed
        detailLabel.stringValue = message
        detailLabel.textColor = .systemRed
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.05).cgColor
        layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.2).cgColor
    }

    // MARK: - Formatters (pure helpers, exposed for tests)

    /// Render `(k1=v1, k2=v2, …)`. Empty arguments → `()`.
    /// Per-value rendering: numbers / bools as-is; strings double-
    /// quoted; everything else via JSON-like coercion. Long argument
    /// strings are truncated to 40 characters with "…" suffix.
    static func formatArguments(_ args: [String: Any]) -> String {
        if args.isEmpty { return "()" }
        let parts = args.keys.sorted().map { key -> String in
            let value = args[key] ?? ""
            return "\(key)=\(formatValue(value))"
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    private func formatArguments(_ args: [String: Any]) -> String {
        return Self.formatArguments(args)
    }

    private static func formatValue(_ value: Any) -> String {
        if let str = value as? String {
            let truncated = str.count > 40 ? String(str.prefix(40)) + "\u{2026}" : str
            return "\"\(truncated)\""
        }
        if let bool = value as? Bool { return String(bool) }
        if let num = value as? NSNumber { return num.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) {
            return str.count > 40 ? String(str.prefix(40)) + "\u{2026}" : str
        }
        return String(describing: value)
    }

    /// Encode payload as JSON, truncate to 80 characters for preview.
    static func previewPayload(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "(unserialisable payload)"
        }
        if str.count > 80 {
            return String(str.prefix(80)) + "\u{2026}"
        }
        return str
    }

    private func previewPayload(_ payload: [String: Any]) -> String {
        return Self.previewPayload(payload)
    }

    // MARK: - Test accessors

    /// Test-only accessor for the headline label text.
    var nameText: String { nameLabel.stringValue }

    /// Test-only accessor for the detail / preview label text.
    var detailText: String { detailLabel.stringValue }
}

// MARK: - Confirmation bubble

/// Variant rendered when a destructive tool call (`delete_note`,
/// `move_note`) is awaiting user approval. Carries the
/// `CheckedContinuation` that resumes the provider's dispatch loop
/// with the user's decision. Two buttons: Approve / Reject.
///
/// Phase 4 polish (docs/AI.md:880): destructive ops MUST be confirmed
/// by the user, not the LLM. The continuation is owned by the bubble
/// so the panel can `resolve(approved:)` to flush a pending decision
/// even if the chat is cleared mid-flight (treated as rejection).
final class ToolCallConfirmationBubble: NSView {

    let call: ToolCall
    private let nameLabel: NSTextField
    private let summaryLabel: NSTextField
    private let approveButton: NSButton
    private let rejectButton: NSButton
    private let onDecision: (Bool) -> Void
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved: Bool = false

    init(call: ToolCall,
         maxWidth: CGFloat,
         onDecision: @escaping (Bool) -> Void) {
        self.call = call
        self.onDecision = onDecision
        self.nameLabel = NSTextField(labelWithString: "Confirm: \(call.name)")
        self.summaryLabel = NSTextField(wrappingLabelWithString: ToolCallBubble.formatArguments(call.arguments))
        self.approveButton = NSButton(title: "Approve",
                                      target: nil,
                                      action: nil)
        self.rejectButton = NSButton(title: "Reject",
                                     target: nil,
                                     action: nil)

        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.isSelectable = true
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        approveButton.bezelStyle = .rounded
        approveButton.target = self
        approveButton.action = #selector(approveClicked)
        approveButton.translatesAutoresizingMaskIntoConstraints = false

        rejectButton.bezelStyle = .rounded
        rejectButton.target = self
        rejectButton.action = #selector(rejectClicked)
        rejectButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [approveButton, rejectButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nameLabel)
        addSubview(summaryLabel)
        addSubview(buttonRow)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            summaryLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: max(maxWidth, 100)),

            buttonRow.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for ToolCallConfirmationBubble")
    }

    /// Capture the continuation that the provider's dispatch loop is
    /// suspended on. The bubble retains it until either button is
    /// clicked, the chat is cleared, or the panel is torn down.
    func attach(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// Resume the captured continuation. Idempotent — additional
    /// calls are ignored so a re-entrant resolve (clearChat fires
    /// while a button click is in flight, etc.) cannot trap.
    func resolve(approved: Bool) {
        guard !resolved else { return }
        resolved = true
        approveButton.isEnabled = false
        rejectButton.isEnabled = false
        if approved {
            nameLabel.stringValue = "\u{2713} Approved: \(call.name)"
            nameLabel.textColor = .systemGreen
        } else {
            nameLabel.stringValue = "\u{2717} Rejected: \(call.name)"
            nameLabel.textColor = .systemRed
        }
        continuation?.resume(returning: approved)
        continuation = nil
    }

    @objc private func approveClicked() {
        guard !resolved else { return }
        onDecision(true)
    }

    @objc private func rejectClicked() {
        guard !resolved else { return }
        onDecision(false)
    }

    // MARK: - Test accessors

    /// Test-only accessor: headline label text.
    var nameText: String { nameLabel.stringValue }

    /// Test-only accessor: argument-summary label text.
    var summaryText: String { summaryLabel.stringValue }

    /// Test-only: simulate the user clicking Approve.
    func _testApprove() { approveClicked() }

    /// Test-only: simulate the user clicking Reject.
    func _testReject() { rejectClicked() }

    /// Test-only: has this bubble already been resolved?
    var isResolved: Bool { resolved }
}
