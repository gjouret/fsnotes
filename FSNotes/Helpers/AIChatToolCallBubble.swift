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
