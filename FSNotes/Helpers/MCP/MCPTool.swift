//
//  MCPTool.swift
//  FSNotes
//
//  Protocol every MCP tool conforms to. See docs/AI.md "Components"
//  section. Tools are pure value-producers: they receive a JSON
//  argument dictionary, do their work, and return a `ToolOutput`.
//  They never throw; recoverable failures become `ToolOutput.error`.
//

import Foundation

/// An MCP tool exposed to the LLM. The protocol is `Sendable`-friendly
/// in practice (tools either hold no state or hold immutable refs to
/// `MCPServer.shared` / `AppBridge`), but we don't formally annotate
/// `Sendable` so existing AppKit-bound types remain usable.
public protocol MCPTool {
    /// Stable wire name. Must match the `function.name` used in the
    /// LLM tool-calling protocol. Lowercase snake_case by convention.
    var name: String { get }

    /// One-sentence human-readable description, included verbatim in
    /// the tool schema sent to the LLM.
    var description: String { get }

    /// JSON-Schema `parameters` object describing the tool input.
    var inputSchema: [String: Any] { get }

    /// Run the tool. The returned `ToolOutput` is JSON-encoded by the
    /// server before it is forwarded to the LLM; tools should never
    /// return non-JSON-serialisable values inside the success payload.
    func execute(input: [String: Any]) async -> ToolOutput
}

/// A tool call requested by the LLM. Decoded from the Ollama / OpenAI
/// tool-calling response.
public struct ToolCall {
    public let id: String
    public let name: String
    public let arguments: [String: Any]

    public init(id: String, name: String, arguments: [String: Any]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Pairing of a tool call with its execution result. Sent back to the
/// LLM as a `tool` role message.
public struct ToolResult {
    public let callID: String
    public let toolName: String
    public let output: ToolOutput

    public init(callID: String, toolName: String, output: ToolOutput) {
        self.callID = callID
        self.toolName = toolName
        self.output = output
    }
}
