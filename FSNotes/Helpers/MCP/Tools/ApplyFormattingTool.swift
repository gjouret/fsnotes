//
//  ApplyFormattingTool.swift
//  FSNotes
//
//  Apply a single inline-formatting toggle (bold, italic, code, …)
//  or a structural toggle (heading level, list, blockquote, HR) to
//  the editor's current selection. Per docs/AI.md "MCP Tools" →
//  ApplyFormattingTool: this is meaningful only when a note is open
//  in WYSIWYG mode; the bridge owns the cursor / selection and
//  delegates to `EditingOps.toggleBold`, `toggleInlineTrait`,
//  `changeHeadingLevel`, etc.
//
//  Closed notes have no selection, so the tool returns a clear
//  error when none is open. The WYSIWYG branch returns
//  `.notImplemented` until ViewController adopts `applyFormatting`
//  in a Phase 3 follow-up.
//

import Foundation

public struct ApplyFormattingTool: MCPTool {
    public let name = "apply_formatting"
    public let description = "Toggle inline or structural formatting on the editor's current selection. Requires a note open in WYSIWYG mode. Commands: bold, italic, strikethrough, inline_code, heading (with level 1–6), blockquote, unordered_list, ordered_list, todo_list, horizontal_rule."

    private let server: MCPServer

    public init(server: MCPServer = .shared) {
        self.server = server
    }

    public var inputSchema: [String: Any] {
        return [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "Formatting command. One of: bold, italic, strikethrough, inline_code, heading, blockquote, unordered_list, ordered_list, todo_list, horizontal_rule.",
                    "enum": [
                        "bold", "italic", "strikethrough", "inline_code",
                        "heading", "blockquote", "unordered_list",
                        "ordered_list", "todo_list", "horizontal_rule"
                    ]
                ],
                "level": [
                    "type": "integer",
                    "description": "Heading level (1–6). Required when command='heading'. Use 0 to clear back to a paragraph."
                ]
            ],
            "required": ["command"]
        ]
    }

    public func execute(input: [String: Any]) async -> ToolOutput {
        guard let cmdString = input["command"] as? String else {
            return .error("Missing 'command' parameter")
        }

        let bridge = server.appBridge
        guard let openPath = bridge.currentNotePath() else {
            return .error("apply_formatting requires a note open in the editor. None is currently open.")
        }

        let mode = bridge.editorMode(for: openPath)
        if mode != "wysiwyg" {
            return .error("apply_formatting requires WYSIWYG mode (current mode: \(mode ?? "unknown")). Switch to WYSIWYG and retry, or use edit_note to rewrite the markdown directly.")
        }

        let command: BridgeFormattingCommand
        switch cmdString {
        case "bold":
            command = .toggleBold
        case "italic":
            command = .toggleItalic
        case "strikethrough":
            command = .toggleStrikethrough
        case "inline_code":
            command = .toggleInlineCode
        case "heading":
            let level = (input["level"] as? Int) ?? 1
            if level < 0 || level > 6 {
                return .error("Heading 'level' must be between 0 and 6 (got \(level)).")
            }
            command = .toggleHeading(level: level)
        case "blockquote":
            command = .toggleBlockquote
        case "unordered_list":
            command = .toggleUnorderedList
        case "ordered_list":
            command = .toggleOrderedList
        case "todo_list":
            command = .toggleTodoList
        case "horizontal_rule":
            command = .insertHorizontalRule
        default:
            return .error("Unsupported command '\(cmdString)'.")
        }

        switch bridge.applyFormatting(toPath: openPath, command: command) {
        case .applied(let info):
            var payload: [String: Any] = [
                "status": "applied",
                "command": cmdString,
                "path": openPath
            ]
            for (k, v) in info { payload[k] = v }
            return .success(payload)
        case .failed(let reason):
            return .error("Formatting failed: \(reason)")
        case .notImplemented:
            return .error("apply_formatting requires the AppBridge formatting API, which is a Phase 3 follow-up. The tool surface is ready; the ViewController hook needs wiring.")
        }
    }
}
